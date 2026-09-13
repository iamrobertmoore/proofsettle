import { keccak256 } from 'ethers';
import { TRAILER_MAGIC } from '../enclave/envelope.mjs';

/**
 * Wallets can wrap createJob in a batch or smart-account call, leaving ABI padding
 * after its trailer. Locate the input by the hash emitted by the pinned escrow,
 * not by assuming the outer transaction ends at the inner call's trailer.
 * The settlement contract independently verifies that same event commitment.
 */
export function paymentEnvelope(calldata, envelopeHash) {
  if (envelopeHash.toLowerCase() === keccak256('0x')) return null;
  const bytes = Buffer.from(calldata);
  for (let marker = bytes.indexOf(TRAILER_MAGIC); marker !== -1;
    marker = bytes.indexOf(TRAILER_MAGIC, marker + TRAILER_MAGIC.length)) {
    if (marker < 4) continue;
    const length = bytes.readUInt32BE(marker - 4);
    if (!length || length > marker - 4) continue;
    const candidate = bytes.subarray(marker - 4 - length, marker - 4);
    if (keccak256(candidate) === envelopeHash.toLowerCase()) return candidate;
  }
  // Missing a committed input is a transport failure, not an enclave verdict.
  // Keep the job retryable instead of submitting a guaranteed RequestMismatch.
  throw new Error('Committed sealed input not found in payment calldata; refusing to submit a mismatched result');
}
