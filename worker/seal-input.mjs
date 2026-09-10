/**
 * Seal an applicant record to an enclave's encryption key, the way the desk page does in the
 * browser, so the command-line road and the browser road produce the same calldata.
 *
 *   node worker/seal-input.mjs <encryptionPublicKey 0x…32 bytes> '<record JSON>'
 *
 * Prints JSON: the input commitment (keccak256 of the record bytes, what goes on chain), the
 * envelope, the calldata suffix (envelope plus the 8 byte trailer), and the one-time private key
 * the answer will come back sealed to. Keep that key: worker/open-result.mjs needs it.
 */
import { seal } from '../enclave/envelope.mjs';
import { keccak256, toHex } from '../enclave/crypto.mjs';
import { withTrailer } from '../enclave/envelope.mjs';

const [, , recipientHex, recordJson] = process.argv;
if (!/^0x[0-9a-fA-F]{64}$/.test(recipientHex ?? '')) throw new Error('first argument must be the enclave encryption key, 0x plus 64 hex characters');
const record = JSON.parse(recordJson ?? '{}');
const plaintext = Buffer.from(JSON.stringify(record), 'utf8');
const { envelope, ephemeralPrivateKey, ephemeralRaw } = seal(Buffer.from(recipientHex.slice(2), 'hex'), plaintext, Buffer.from('proofsettle.input.v1'));
console.log(JSON.stringify({
  inputHash: toHex(keccak256(plaintext)),
  envelope: toHex(envelope),
  calldataSuffix: withTrailer(envelope).toString('hex'),
  ephemeralPublicKey: toHex(ephemeralRaw),
  ephemeralPrivateKey: toHex(ephemeralPrivateKey.export({ type: 'pkcs8', format: 'der' })),
}));
