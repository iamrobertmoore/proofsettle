/** Standard primitives, pinned in package-lock.json and included in the measured image. */
import { secp256k1 } from '@noble/curves/secp256k1';
import { keccak_256 } from '@noble/hashes/sha3';

export const toHex = (value) => '0x' + Buffer.from(value).toString('hex');
export const keccak256 = (value) => Buffer.from(keccak_256(value));
const word = (value) => Buffer.from(BigInt(value).toString(16).padStart(64, '0'), 'hex');
const hashWord = (value) => {
  if (!/^0x[0-9a-fA-F]{64}$/.test(value)) throw new Error('expected a bytes32 commitment');
  return Buffer.from(value.slice(2), 'hex');
};
export function signDigest(privHex, digest) {
  const sig = secp256k1.sign(digest, privHex, { lowS: true });
  return { v: 27 + sig.recovery, r: toHex(word(sig.r)), s: toHex(word(sig.s)) };
}
export function addressFor(privHex) {
  return toHex(keccak256(secp256k1.getPublicKey(privHex, false).slice(1)).subarray(12));
}

/** Binds both plaintext commitments and the exact envelope, including the buyer's return key. */
export function requestCommitment(modelHash, inputHash, ciphertext) {
  const envelope = Buffer.from((ciphertext ?? '').replace(/^0x/, ''), 'hex');
  return toHex(keccak256(Buffer.concat([hashWord(modelHash), hashWord(inputHash), keccak256(envelope)])));
}

/** ABI parity with ComputeSettlement.resultDigest. A new domain excludes all v1 signatures. */
export function encodeDigest(chainId, settlement, jobId, resultHash, outcome, scoreBps, requestHash, deliveryHash) {
  if (!/^0x[0-9a-fA-F]{40}$/.test(settlement)) throw new Error('invalid settlement address');
  const domain = Buffer.from('proofsettle.result.v2');
  return keccak256(Buffer.concat([
    word(9 * 32), word(chainId), Buffer.concat([Buffer.alloc(12), Buffer.from(settlement.slice(2), 'hex')]),
    hashWord(jobId), hashWord(resultHash), word(outcome), word(scoreBps), hashWord(requestHash), hashWord(deliveryHash),
    word(domain.length), domain, Buffer.alloc((32 - domain.length % 32) % 32),
  ]));
}
