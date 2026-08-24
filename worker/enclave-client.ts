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

  const wallet = new ethers.Wallet(devKey);
  const { resultHash, outcome, scoreBps } = await runJobLocally(job);
  const digest = resultDigest(job.settlementAddress, job.chainId, job.jobId, resultHash, outcome, scoreBps);
  const sig = wallet.signingKey.sign(digest);

  return { resultHash, outcome, scoreBps, v: sig.v, r: sig.r, s: sig.s, attested: false, signer: wallet.address };
}

/**
 * Development stand-in for the model. The real one runs inside the enclave.
 *
 * It is deterministic on the job so a demo replays identically, and it produces all three outcomes
 * across different jobs so the settlement paths are all exercisable without waiting for a real
 * model to happen to fail.
 */
async function runJobLocally(job: JobRequest): Promise<{ resultHash: string; outcome: Outcome; scoreBps: number }> {
  const resultHash = ethers.keccak256(
    ethers.solidityPacked(['bytes32', 'bytes32', 'bytes32'], [job.jobId, job.modelHash, job.inputHash])
  );
  const bucket = Number(BigInt(resultHash) % 10n);
  if (bucket === 0) return { resultHash, outcome: Outcome.Rejected, scoreBps: 0 };
  if (bucket === 1) return { resultHash, outcome: Outcome.Partial, scoreBps: 5000 };
  return { resultHash, outcome: Outcome.Accepted, scoreBps: 10_000 };
}
