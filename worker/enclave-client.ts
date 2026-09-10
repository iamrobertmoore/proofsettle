/**
 * Client for the attested compute enclave.
 *
 * The worker calls this to have a job run and its verdict signed. The signing key never leaves the
 * enclave, so the worker cannot alter the verdict: the outcome and score are inside the signed
 * digest and any change makes `ecrecover` return a different address, which the registry then
 * refuses.
 *
 * ENCLAVE_URL points at the running Confidential Space workload. When it is not set, this falls
 * back to a local development signer so the pipeline can be exercised end to end without spending
 * money on a VM. **The fallback is loud on purpose.** A silent fallback would let a demo appear to
 * prove hardware attestation while proving nothing at all, which is the failure mode this whole
 * project exists to make visible.
 */
import { ethers } from 'ethers';

export enum Outcome {
  Rejected = 0,
  Accepted = 1,
  Partial = 2,
}

export interface JobRequest {
  jobId: string;
  modelHash: string;
  inputHash: string;
  settlementAddress: string;
  chainId: number;
  /**
   * The buyer's input, sealed to the enclave's X25519 key, exactly as it rode in the calldata of
   * the payment. Absent when the payment carried none, which the enclave refuses by name.
   */
  ciphertext?: string;
}

export interface SignedResult {
  resultHash: string;
  outcome: Outcome;
  scoreBps: number;
  v: number;
  r: string;
  s: string;
  /** True only when the signature came from a real attested enclave. */
  attested: boolean;
  signer: string;
  /** The result, sealed to the buyer's one-time key. The worker cannot read it. Null on a refusal. */
  resultCiphertext?: string | null;
  /** On a refusal, the enclave's reason, in the clear, because there is no key to seal it to. */
  rejection?: { rejected: string; detail: string | null } & Record<string, unknown>;
}

const SIGNING_DOMAIN = 'proofsettle.result.v1';

/** Must match ComputeSettlement.resultDigest byte for byte. */
export function resultDigest(
  settlementAddress: string,
  chainId: number,
  jobId: string,
  resultHash: string,
  outcome: Outcome,
  scoreBps: number
): string {
  return ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ['string', 'uint256', 'address', 'bytes32', 'bytes32', 'uint8', 'uint16'],
      [SIGNING_DOMAIN, chainId, settlementAddress, jobId, resultHash, outcome, scoreBps]
    )
  );
}

export async function signResult(job: JobRequest): Promise<SignedResult> {
  const url = process.env.ENCLAVE_URL;

  if (url) {
    const res = await fetch(`${url.replace(/\/$/, '')}/run`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(job),
    });
    if (!res.ok) throw new Error(`enclave returned HTTP ${res.status}: ${await res.text()}`);
    const out = (await res.json()) as SignedResult;

    // Verify the enclave's own arithmetic before trusting it enough to spend gas on.
    const digest = resultDigest(
      job.settlementAddress, job.chainId, job.jobId, out.resultHash, out.outcome, out.scoreBps
    );
    const recovered = ethers.recoverAddress(digest, { r: out.r, s: out.s, v: out.v });
    if (recovered.toLowerCase() !== out.signer.toLowerCase()) {
      throw new Error(`enclave signature does not recover to its claimed signer (${recovered} vs ${out.signer})`);
    }
    return { ...out, attested: true };
  }

  const devKey = process.env.DEV_ENCLAVE_PRIVATE_KEY;
  if (!devKey) {
    throw new Error(
      'Neither ENCLAVE_URL nor DEV_ENCLAVE_PRIVATE_KEY is set. Point ENCLAVE_URL at a running ' +
        'attested enclave, or set DEV_ENCLAVE_PRIVATE_KEY to run unattested for local development.'
    );
  }

  console.warn(
    '\n  !! UNATTESTED SIGNER IN USE. ENCLAVE_URL is not set, so this result is signed by a local\n' +
      '  !! development key and proves nothing about what code produced it. Do not present output\n' +
      '  !! from this mode as evidence of hardware attestation.\n'
  );

  const dev = await devIdentity(devKey);
  const { outcome, scoreBps, resultHash, resultCiphertext, rejection } = dev.run(job);
  const digest = resultDigest(job.settlementAddress, job.chainId, job.jobId, resultHash, outcome, scoreBps);
  const sig = dev.wallet.signingKey.sign(digest);

  return { resultHash, outcome, scoreBps, v: sig.v, r: sig.r, s: sig.s, attested: false, signer: dev.wallet.address, resultCiphertext, rejection };
}

/**
 * The development stand-in for the enclave. It runs the same model, the same envelope and the
 * same refusals as enclave/server.mjs, because a stand-in that behaves differently from the thing
 * it stands in for is how demos come to prove something the product does not do. The only
 * difference is the keys: the signer is the development key, and the X25519 key is derived from
 * it so a buyer can seal input to it ahead of time.
 */
export async function devIdentity(devKey: string) {
  const [{ loadModel, score, canonical, hashOf }, envelope, crypto, nodeCrypto] = await Promise.all([
    import('../enclave/model.mjs'),
    import('../enclave/envelope.mjs'),
    import('../enclave/crypto.mjs'),
    import('node:crypto'),
  ]);
  const wallet = new ethers.Wallet(devKey);
  const seed = Buffer.from(nodeCrypto.hkdfSync('sha256', Buffer.from(devKey.replace(/^0x/, ''), 'hex'), Buffer.alloc(0), Buffer.from('proofsettle.dev-x25519.v1'), 32));
  const privateKey = envelope.privateKeyFromRaw(seed);
  const encRaw = envelope.rawPublicKey(nodeCrypto.createPublicKey(privateKey));
  const { model, modelHash } = loadModel();
  const BUILD = 'proofsettle-enclave/dev (unattested)';
  const AAD_INPUT = Buffer.from('proofsettle.input.v1');

  const rejected = (jobId: string, reason: string, detail: string | null) => {
    const result = { v: 1, jobId, build: BUILD, rejected: reason, detail };
    return { outcome: Outcome.Rejected, scoreBps: 0, resultHash: hashOf(result), resultCiphertext: null, rejection: result };
  };

  return {
    wallet,
    signer: wallet.address,
    encryptionPublicKey: crypto.toHex(encRaw),
    modelHash,
    run(job: JobRequest) {
      if (job.modelHash.toLowerCase() !== modelHash.toLowerCase()) return rejected(job.jobId, 'model-not-served', `this stand-in serves ${modelHash}`);
      if (!job.ciphertext) return rejected(job.jobId, 'no-input', 'the payment carried no sealed input');
      let plaintext: Buffer, ephemeralRaw: Buffer;
      try {
        ({ plaintext, ephemeralRaw } = envelope.open(privateKey, Buffer.from(job.ciphertext.replace(/^0x/, ''), 'hex'), AAD_INPUT));
      } catch {
        return rejected(job.jobId, 'input-undecryptable', 'the sealed input was not encrypted to this key');
      }
      const commitment = crypto.toHex(crypto.keccak256(plaintext));
      if (commitment.toLowerCase() !== job.inputHash.toLowerCase()) return rejected(job.jobId, 'input-commitment-mismatch', `input hashes to ${commitment}, payment committed to ${job.inputHash}`);
      let scored: any;
      try { scored = score(model, JSON.parse(plaintext.toString('utf8'))); }
      catch (e: any) { return rejected(job.jobId, 'input-invalid', String(e.message ?? e)); }
      const result = { v: 1, jobId: job.jobId, build: BUILD, modelHash, inputHash: job.inputHash, decision: scored.decision, probability: scored.probability, scoreBps: scored.scoreBps, contributions: scored.contributions };
      const resultHash = hashOf(result);
      const resultCiphertext = crypto.toHex(envelope.seal(ephemeralRaw, Buffer.from(canonical(result), 'utf8'), Buffer.from('proofsettle.result.v1' + job.jobId.toLowerCase())).envelope);
      return { outcome: Outcome.Accepted, scoreBps: 10_000, resultHash, resultCiphertext, rejection: undefined };
    },
  };
}
