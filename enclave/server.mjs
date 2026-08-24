/**
 * ProofSettle attested compute enclave.
 *
 * Runs inside Google Confidential Space on AMD SEV. Holds a secp256k1 key that never leaves
 * the enclave, runs the requested job, and signs the result together with its verdict.
 *
 * The signing key is derived at startup and only ever exists in enclave memory. Its address is
 * published at /identity along with the attestation token that proves which image is running. The
 * registrar binds that address to the image's measurement on Creditcoin, and from then on the
 * settlement contract will only accept results signed by this key for jobs demanding this build.
 *
 * Zero runtime dependencies. Node's own crypto does secp256k1 and keccak is implemented below,
 * because a supply chain is a poor thing to put inside a trust boundary.
 */
import { createServer } from 'node:http';
import { generateKeyPairSync } from 'node:crypto';
import { readFile } from 'node:fs/promises';

const PORT = Number(process.env.PORT ?? 8080);
const SIGNING_DOMAIN = 'proofsettle.result.v1';

/**
 * Which build this is, in a form a human can read.
 *
 * The measurement registered on chain is the container image digest, which is exact but tells you
 * nothing on sight. This is the friendly half of the same fact, reported at /identity next to the
 * digest so the two can be compared. It is not a security boundary: anything can claim a version,
 * only the attestation token proves one.
 */
const BUILD = 'proofsettle-enclave/1.1.0';

/**
 * Confidential Space exposes the attestation token over this unix socket. Reading it is how the
 * enclave proves which image it is. If it is absent we are not in an enclave, and the service says
 * so rather than pretending.
 */
const TOKEN_PATH = process.env.ATTESTATION_TOKEN_PATH ?? '/run/container_launcher/attestation_verifier_claims_token';

import { keccak256, signDigest, addressFor, encodeDigest, toHex } from './crypto.mjs';

// ---------------------------------------------------------------- the job

/**
 * The work this enclave performs. Replace with the real model call.
 *
 * It returns a verdict, not just an answer, and the verdict is what the settlement contract acts
 * on. Deterministic on the job so a demo replays identically.
 */
async function runJob({ jobId, modelHash, inputHash }) {
  const resultHash = toHex(keccak256(Buffer.concat([
    Buffer.from(jobId.slice(2), 'hex'),
    Buffer.from(modelHash.slice(2), 'hex'),
    Buffer.from(inputHash.slice(2), 'hex'),
  ])));
  const bucket = Number(BigInt(resultHash) % 10n);
  if (bucket === 0) return { resultHash, outcome: 0, scoreBps: 0 };       // Rejected
  if (bucket === 1) return { resultHash, outcome: 2, scoreBps: 5000 };    // Partial
  return { resultHash, outcome: 1, scoreBps: 10000 };                     // Accepted
}

// ---------------------------------------------------------------- server

// The key is generated at startup, in memory, and never written anywhere.
const PRIV = generateKeyPairSync('ec', { namedCurve: 'secp256k1' })
  .privateKey.export({ format: 'jwk' }).d;
const PRIV_HEX = Buffer.from(PRIV, 'base64url').toString('hex').padStart(64, '0');
const SIGNER = addressFor(PRIV_HEX);

async function attestationToken() {
  try {
    return (await readFile(TOKEN_PATH, 'utf8')).trim();
  } catch {
    return null;
  }
}

const json = (res, code, body) => {
  const s = JSON.stringify(body);
  res.writeHead(code, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(s) });
  res.end(s);
};

const server = createServer(async (req, res) => {
  try {
    if (req.method === 'GET' && req.url === '/identity') {
      const token = await attestationToken();
      return json(res, 200, {
        build: BUILD,
        signer: SIGNER,
        attested: token !== null,
        attestationToken: token,
        note: token === null
          ? 'NOT RUNNING IN AN ENCLAVE. This signer proves nothing about what code produced a result.'
          : 'Confidential Space attestation token. Verify it before registering this signer.',
      });
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

      const { resultHash, outcome, scoreBps } = await runJob(job);
      const digest = encodeDigest(job.chainId, job.settlementAddress, job.jobId, resultHash, outcome, scoreBps);
      const sig = signDigest(PRIV_HEX, digest);

      return json(res, 200, { resultHash, outcome, scoreBps, ...sig, signer: SIGNER });
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
  attestationToken().then((t) => {
    console.log(t ? 'attestation token present, running inside Confidential Space' : 'NO ATTESTATION TOKEN: not running in an enclave');
  });
});
