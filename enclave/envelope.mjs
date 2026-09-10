/**
 * The envelope that carries a buyer's input into the enclave, and the enclave's result back out.
 *
 * Both legs ride inside transactions that already exist: the input is appended to the buyer's
 * createJob calldata on the source chain, the result to the worker's settle calldata on
 * Creditcoin. Solidity's ABI decoder ignores trailing bytes, so neither contract changes, and
 * nothing in between the buyer's browser and this process can read either one.
 *
 * Format, all bytes:
 *
 *   0x01                       version
 *   ephemeralPublicKey[32]     sender's one-time X25519 key
 *   nonce[12]                  AES-GCM nonce
 *   ciphertext || tag          AES-256-GCM
 *
 * key = HKDF-SHA256(X25519(ephemeralPrivate, recipientPublic), salt = "", info = INFO || recipientPub || ephemeralPub)
 *
 * The browser side is written against WebCrypto and must produce byte-identical output; see
 * site/desk.html and the round-trip test in test/envelope.test.mjs, which drives both.
 *
 * Zero dependencies, like everything else inside the trust boundary.
 */
import {
  generateKeyPairSync, createPrivateKey, createPublicKey, diffieHellman, hkdfSync,
  createCipheriv, createDecipheriv, randomBytes,
} from 'node:crypto';

export const VERSION = 0x01;
const INFO = Buffer.from('proofsettle.envelope.v1');

/** Raw 32-byte X25519 public key from a KeyObject. */
export function rawPublicKey(keyObject) {
  const jwk = keyObject.export({ format: 'jwk' });
  return Buffer.from(jwk.x, 'base64url');
}

/** KeyObject from a raw 32-byte X25519 public key. */
export function publicKeyFromRaw(raw) {
  if (raw.length !== 32) throw new Error('X25519 public key must be 32 bytes');
  return createPublicKey({ key: { kty: 'OKP', crv: 'X25519', x: Buffer.from(raw).toString('base64url') }, format: 'jwk' });
}

export function generateRecipientKey() {
  const { publicKey, privateKey } = generateKeyPairSync('x25519');
  return { publicKey, privateKey, raw: rawPublicKey(publicKey) };
}

function deriveKey(sharedSecret, recipientRaw, ephemeralRaw) {
  const info = Buffer.concat([INFO, recipientRaw, ephemeralRaw]);
  return Buffer.from(hkdfSync('sha256', sharedSecret, Buffer.alloc(0), info, 32));
}

/**
 * Encrypt plaintext to a raw 32-byte recipient public key.
 *
 * Returns the envelope bytes and the one-time private key that made them, because the sender
 * keeps that key: it is what the enclave seals the result back to.
 */
export function seal(recipientRaw, plaintext, aad = Buffer.alloc(0)) {
  const recipient = publicKeyFromRaw(recipientRaw);
  const eph = generateKeyPairSync('x25519');
  const ephRaw = rawPublicKey(eph.publicKey);
  const shared = diffieHellman({ privateKey: eph.privateKey, publicKey: recipient });
  const key = deriveKey(shared, Buffer.from(recipientRaw), ephRaw);
  const nonce = randomBytes(12);
  const cipher = createCipheriv('aes-256-gcm', key, nonce);
  cipher.setAAD(aad);
  const body = Buffer.concat([cipher.update(plaintext), cipher.final(), cipher.getAuthTag()]);
  return {
    envelope: Buffer.concat([Buffer.from([VERSION]), ephRaw, nonce, body]),
    ephemeralPrivateKey: eph.privateKey,
    ephemeralRaw: ephRaw,
  };
}

/**
 * Decrypt an envelope with the recipient's private KeyObject. Returns { plaintext, ephemeralRaw }.
 * The ephemeral key is returned because the enclave encrypts its result back to it.
 */
export function open(recipientPrivateKey, envelope, aad = Buffer.alloc(0)) {
  const env = Buffer.from(envelope);
  if (env.length < 1 + 32 + 12 + 16) throw new Error('envelope too short');
  if (env[0] !== VERSION) throw new Error(`unsupported envelope version ${env[0]}`);
  const ephRaw = env.subarray(1, 33);
  const nonce = env.subarray(33, 45);
  const body = env.subarray(45);
  const tag = body.subarray(body.length - 16);
  const ct = body.subarray(0, body.length - 16);
  const recipientRaw = rawPublicKey(createPublicKey(recipientPrivateKey));
  const shared = diffieHellman({ privateKey: recipientPrivateKey, publicKey: publicKeyFromRaw(ephRaw) });
  const key = deriveKey(shared, recipientRaw, ephRaw);
  const decipher = createDecipheriv('aes-256-gcm', key, nonce);
  decipher.setAAD(aad);
  decipher.setAuthTag(tag);
  const plaintext = Buffer.concat([decipher.update(ct), decipher.final()]);
  return { plaintext, ephemeralRaw: Buffer.from(ephRaw) };
}

/**
 * X25519 private KeyObject from a raw 32-byte scalar. Node cannot take a JWK with only `d`, so
 * this wraps the scalar in the fixed PKCS#8 header RFC 8410 defines for X25519.
 */
export function privateKeyFromRaw(raw) {
  if (raw.length !== 32) throw new Error('X25519 private key must be 32 bytes');
  const header = Buffer.from('302e020100300506032b656e04220420', 'hex');
  return createPrivateKey({ key: Buffer.concat([header, Buffer.from(raw)]), format: 'der', type: 'pkcs8' });
}

/**
 * How an envelope rides inside calldata.
 *
 * The ABI decoder ignores whatever follows a function's arguments, so the envelope is appended
 * after them. Finding it again is the problem: createJob's arguments have a fixed length but
 * settle's do not, and re-encoding the decoded arguments in a browser to find the boundary is
 * fragile. So the envelope is followed by its own length and a four byte marker, and a reader
 * works from the end: check the marker, read the length, take that many bytes before it.
 *
 *   envelope || uint32 big-endian length || "PSE1"
 */
export const TRAILER_MAGIC = Buffer.from('PSE1');

export function withTrailer(envelope) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(envelope.length, 0);
  return Buffer.concat([Buffer.from(envelope), len, TRAILER_MAGIC]);
}

/** The envelope at the end of calldata, or null when there is none. */
export function fromTrailer(calldata) {
  const b = Buffer.from(calldata);
  if (b.length < 8 || !b.subarray(b.length - 4).equals(TRAILER_MAGIC)) return null;
  const len = b.readUInt32BE(b.length - 8);
  if (len === 0 || len > b.length - 8) return null;
  return b.subarray(b.length - 8 - len, b.length - 8);
}
