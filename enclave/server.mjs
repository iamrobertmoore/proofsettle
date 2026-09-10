/**
 * ProofSettle attested compute enclave.
 *
 * Runs inside Google Confidential Space on AMD SEV. Holds two keys that never leave the enclave:
 * a secp256k1 key that signs results, and an X25519 key that buyers encrypt their input to. It
 * runs the model the buyer named, and signs the result together with its verdict.
 *
 * Both keys are generated at startup and only ever exist in enclave memory. Their public halves
 * are published at /identity, and they are bound into the attestation token as nonces, so the
 * Google-signed token does not just say which image is running: it says which keys that image
 * generated. The registrar binds the signer to the image's measurement on Creditcoin, and from
 * then on the settlement contract will only accept results signed by this key for jobs that
 * demand this build.
 *
 * The buyer's input arrives sealed to the X25519 key, riding inside the calldata of the payment
 * that names this build. The enclave opens it, checks it against the commitment in the proven
 * payment, runs the model, and seals the result back to the buyer's one-time key. Nothing between
 * the buyer's browser and this process can read either.
 *
 * Zero runtime dependencies. Node's own crypto does secp256k1, X25519, HKDF and AES-GCM, and
 * keccak is implemented in crypto.mjs, because a supply chain is a poor thing to put inside a
 * trust boundary.
 */
import { createServer, request as httpRequest } from 'node:http';
import { generateKeyPairSync } from 'node:crypto';
import { readFile } from 'node:fs/promises';

import { keccak256, signDigest, addressFor, encodeDigest, toHex } from './crypto.mjs';
import { generateRecipientKey, seal, open } from './envelope.mjs';
import { loadModel, score, canonical, hashOf } from './model.mjs';

const PORT = Number(process.env.PORT ?? 8080);

/**
 * Which build this is, in a form a human can read.
 *
 * The measurement registered on chain is the container image digest, which is exact but tells you
 * nothing on sight. This is the friendly half of the same fact, reported at /identity next to the
 * digest so the two can be compared. It is not a security boundary: anything can claim a version,
 * only the attestation token proves one.
 */
const BUILD = 'proofsettle-enclave/1.2.0';

/**
 * Confidential Space exposes the attestation token two ways. A default token is written to a file.
 * A token with custom nonces is requested over the launcher's unix socket, and that is the one
 * worth having, because the nonces let this process bind its own keys into a Google-signed
 * statement. If neither is available we are not in an enclave, and the service says so rather
 * than pretending.
 */
const TOKEN_PATH = process.env.ATTESTATION_TOKEN_PATH ?? '/run/container_launcher/attestation_verifier_claims_token';
const LAUNCHER_SOCKET = process.env.ATTESTATION_LAUNCHER_SOCKET ?? '/run/container_launcher/teeserver.sock';
const TOKEN_AUDIENCE = 'https://sts.google.com';

// ---------------------------------------------------------------- keys

// The signing key. Generated at startup, in memory, never written anywhere.
const PRIV = generateKeyPairSync('ec', { namedCurve: 'secp256k1' })
  .privateKey.export({ format: 'jwk' }).d;
const PRIV_HEX = Buffer.from(PRIV, 'base64url').toString('hex').padStart(64, '0');
const SIGNER = addressFor(PRIV_HEX);

// The encryption key. Same rules.
const ENC = generateRecipientKey();
const ENC_PUB_HEX = toHex(ENC.raw);

// ---------------------------------------------------------------- model

const { model: MODEL, modelHash: MODEL_HASH } = loadModel();

// ---------------------------------------------------------------- attestation

/**
 * Request a token with our two public keys as nonces. Confidential Space echoes them back in the
 * eat_nonce claim, signed by Google, which is what lets a verifier confirm that the signer and the
 * encryption key were generated inside this exact image rather than merely asserted by it.
 */
function tokenWithNonces() {
  return new Promise((resolve) => {
    const body = JSON.stringify({ audience: TOKEN_AUDIENCE, token_type: 'OIDC', nonces: [SIGNER, ENC_PUB_HEX] });
    const req = httpRequest(
      { socketPath: LAUNCHER_SOCKET, path: '/v1/token', method: 'POST',
        headers: { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body) }, timeout: 3000 },
      (res) => {
        let b = '';
        res.on('data', (c) => (b += c));
        res.on('end', () => resolve(res.statusCode === 200 && b.split('.').length === 3 ? b.trim() : null));
      },
    );
    req.on('error', () => resolve(null));
    req.on('timeout', () => { req.destroy(); resolve(null); });
    req.end(body);
  });
}

let tokenCache = null;   // { token, nonceBound }
async function attestation() {
  if (tokenCache) return tokenCache;
  const bound = await tokenWithNonces();
  if (bound) return (tokenCache = { token: bound, nonceBound: true });
  try {
    const t = (await readFile(TOKEN_PATH, 'utf8')).trim();
    return (tokenCache = { token: t, nonceBound: false });
  } catch {
    return { token: null, nonceBound: false };
  }
}

// ---------------------------------------------------------------- the job

const OUTCOME = { Rejected: 0, Accepted: 1, Partial: 2 };
const AAD_INPUT = Buffer.from('proofsettle.input.v1');
const aadResult = (jobId) => Buffer.from('proofsettle.result.v1' + jobId.toLowerCase());

/**
 * A refusal the enclave signs, so it settles on chain as Rejected and the buyer's claim comes back
 * without waiting out the refund delay. The reason is in the result record and its hash is what the
 * chain sees. The enclave has no opinion about whether the job should have been paid for; it
 * reports what it could and could not do.
 */
function rejected(jobId, reason, detail) {
  const result = { v: 1, jobId, build: BUILD, rejected: reason, detail: detail ?? null };
  return { outcome: OUTCOME.Rejected, scoreBps: 0, result, resultHash: hashOf(result), resultCiphertext: null };
}

/**
 * Run the job the buyer paid for.
 *
 * Every field except the ciphertext comes out of the proven source-chain event, so the enclave is
 * checking the buyer's own commitments, not the worker's word: the model hash the buyer named
 * must be this model, and the input must hash to the commitment the buyer put in the payment.
 */
function runJob({ jobId, modelHash, inputHash, ciphertext }) {
  if (modelHash.toLowerCase() !== MODEL_HASH.toLowerCase()) {
    return rejected(jobId, 'model-not-served', `this enclave serves ${MODEL_HASH}`);
  }
  if (!ciphertext) return rejected(jobId, 'no-input', 'the payment carried no sealed input');

  let plaintext, ephemeralRaw;
  try {
    ({ plaintext, ephemeralRaw } = open(ENC.privateKey, Buffer.from(ciphertext.replace(/^0x/, ''), 'hex'), AAD_INPUT));
  } catch (e) {
    return rejected(jobId, 'input-undecryptable', 'the sealed input was not encrypted to this enclave');
  }

  const commitment = toHex(keccak256(plaintext));
  if (commitment.toLowerCase() !== inputHash.toLowerCase()) {
    return rejected(jobId, 'input-commitment-mismatch', `input hashes to ${commitment}, payment committed to ${inputHash}`);
  }

  let record, scored;
  try {
    record = JSON.parse(plaintext.toString('utf8'));
    scored = score(MODEL, record);
  } catch (e) {
    return rejected(jobId, 'input-invalid', String(e.message || e));
  }

  const result = {
    v: 1, jobId, build: BUILD, modelHash: MODEL_HASH, inputHash,
    decision: scored.decision, probability: scored.probability, scoreBps: scored.scoreBps,
    contributions: scored.contributions,
  };
  const resultHash = hashOf(result);
  const resultCiphertext = toHex(seal(ephemeralRaw, Buffer.from(canonical(result), 'utf8'), aadResult(jobId)).envelope);

  // The settlement verdict is about the work, not the applicant: the model the buyer named ran
  // over the input the buyer committed to, so the provider is owed the payment in full. The
  // applicant's decision is inside the sealed result, and only the buyer can read it.
  return { outcome: OUTCOME.Accepted, scoreBps: 10000, result, resultHash, resultCiphertext };
}

// ---------------------------------------------------------------- server

const json = (res, code, body) => {
  const s = JSON.stringify(body);
  res.writeHead(code, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(s) });
  res.end(s);
};

const server = createServer(async (req, res) => {
  try {
    if (req.method === 'GET' && req.url === '/identity') {
      const { token, nonceBound } = await attestation();
      return json(res, 200, {
        build: BUILD,
        signer: SIGNER,
        encryptionPublicKey: ENC_PUB_HEX,
        modelHash: MODEL_HASH,
        attested: token !== null,
        nonceBound,
        attestationToken: token,
        note: token === null
          ? 'NOT RUNNING IN AN ENCLAVE. This signer proves nothing about what code produced a result.'
          : nonceBound
            ? 'Confidential Space attestation token with the signer and encryption key bound in as nonces. Verify it before registering this signer.'
            : 'Confidential Space attestation token without nonces: the launcher socket was unavailable, so the keys are asserted by this image rather than bound into the token.',
      });
    }

    if (req.method === 'GET' && req.url === '/model') {
      return json(res, 200, { modelHash: MODEL_HASH, model: MODEL, canonicalisation: 'keccak256 of canonical JSON: keys sorted, no whitespace' });
    }

    if (req.method === 'GET' && req.url === '/health') return json(res, 200, { ok: true, build: BUILD, signer: SIGNER });

    if (req.method === 'POST' && req.url === '/run') {
      const body = await new Promise((resolve, reject) => {
        let b = '';
        req.on('data', (c) => { b += c; if (b.length > 1e6) req.destroy(); });
        req.on('end', () => resolve(b));
        req.on('error', reject);
      });
      const job = JSON.parse(body);
      for (const k of ['jobId', 'modelHash', 'inputHash', 'settlementAddress', 'chainId']) {
        if (job[k] === undefined) return json(res, 400, { error: `missing field: ${k}` });
      }

      const { outcome, scoreBps, result, resultHash, resultCiphertext } = runJob(job);
      const digest = encodeDigest(job.chainId, job.settlementAddress, job.jobId, resultHash, outcome, scoreBps);
      const sig = signDigest(PRIV_HEX, digest);

      // The plaintext result is returned only for a rejection, where there is no key to seal it to
      // and the reason is what the buyer needs. An accepted result is returned sealed, and the
      // worker cannot read it.
      return json(res, 200, {
        resultHash, outcome, scoreBps, ...sig, signer: SIGNER,
        resultCiphertext,
        rejection: outcome === OUTCOME.Rejected ? result : undefined,
      });
    }

    json(res, 404, { error: 'not found' });
  } catch (e) {
    json(res, 500, { error: String(e && e.message ? e.message : e) });
  }
});

server.listen(PORT, () => {
  console.log(`proofsettle enclave listening on ${PORT}`);
  console.log(`build ${BUILD}`);
  console.log(`signer ${SIGNER}`);
  console.log(`encryption key ${ENC_PUB_HEX}`);
  console.log(`model ${MODEL.name} ${MODEL_HASH}`);
  attestation().then(({ token, nonceBound }) => {
    console.log(token
      ? (nonceBound ? 'attestation token present with keys bound as nonces, running inside Confidential Space'
                    : 'attestation token present (file, no nonces), running inside Confidential Space')
      : 'NO ATTESTATION TOKEN: not running in an enclave');
  });
});
