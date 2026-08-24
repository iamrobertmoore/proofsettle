/**
 * Crypto primitives for the ProofSettle enclave: keccak256, secp256k1 signing, address derivation,
 * and the exact ABI encoding the settlement contract hashes.
 *
 * Zero dependencies on purpose. A supply chain is a poor thing to put inside a trust boundary, so
 * everything the enclave needs is here in the open where it can be read.
 *
 * The cost of that choice is that this is hand-rolled crypto, which is a liability unless it is
 * checked. `verify-crypto.mjs` proves every function here against ethers, including the ABI
 * encoding, so drift fails loudly rather than producing signatures the chain silently rejects.
 */
const SIGNING_DOMAIN = 'proofsettle.result.v1';

// ---------------------------------------------------------------- keccak256

const KECCAK_RC = [
  0x0000000000000001n, 0x0000000000008082n, 0x800000000000808an, 0x8000000080008000n,
  0x000000000000808bn, 0x0000000080000001n, 0x8000000080008081n, 0x8000000000008009n,
  0x000000000000008an, 0x0000000000000088n, 0x0000000080008009n, 0x000000008000000an,
  0x000000008000808bn, 0x800000000000008bn, 0x8000000000008089n, 0x8000000000008003n,
  0x8000000000008002n, 0x8000000000000080n, 0x000000000000800an, 0x800000008000000an,
  0x8000000080008081n, 0x8000000000008080n, 0x0000000080000001n, 0x8000000080008008n,
];
const KECCAK_ROT = [
  [0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61], [28, 55, 25, 21, 56], [27, 20, 39, 8, 14],
];
const M64 = (1n << 64n) - 1n;
const rotl = (x, n) => ((x << BigInt(n)) | (x >> BigInt(64 - n))) & M64;

function keccakF(s) {
  for (let round = 0; round < 24; round++) {
    const c = [0, 1, 2, 3, 4].map((x) => s[x][0] ^ s[x][1] ^ s[x][2] ^ s[x][3] ^ s[x][4]);
    for (let x = 0; x < 5; x++) {
      const d = c[(x + 4) % 5] ^ rotl(c[(x + 1) % 5], 1);
      for (let y = 0; y < 5; y++) s[x][y] ^= d;
    }
    const b = Array.from({ length: 5 }, () => new Array(5).fill(0n));
    for (let x = 0; x < 5; x++) for (let y = 0; y < 5; y++) b[y][(2 * x + 3 * y) % 5] = rotl(s[x][y], KECCAK_ROT[x][y]);
    for (let x = 0; x < 5; x++) {
      for (let y = 0; y < 5; y++) s[x][y] = b[x][y] ^ (~b[(x + 1) % 5][y] & M64 & b[(x + 2) % 5][y]);
    }
    s[0][0] ^= KECCAK_RC[round];
  }
  return s;
}

export function keccak256(bytes) {
  const rate = 136;
  const padded = Buffer.concat([bytes, Buffer.from([0x01]), Buffer.alloc((rate - ((bytes.length + 1) % rate)) % rate)]);
  padded[padded.length - 1] |= 0x80;
  let state = Array.from({ length: 5 }, () => new Array(5).fill(0n));
  for (let off = 0; off < padded.length; off += rate) {
    for (let i = 0; i < rate / 8; i++) {
      const lane = padded.readBigUInt64LE(off + i * 8);
      state[i % 5][Math.floor(i / 5)] ^= lane;
    }
    state = keccakF(state);
  }
  const out = Buffer.alloc(32);
  for (let i = 0; i < 4; i++) out.writeBigUInt64LE(state[i % 5][Math.floor(i / 5)], i * 8);
  return out;
}

// ---------------------------------------------------------------- secp256k1

const N = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141n;
const Pp = 0xfffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2fn;
const G = {
  x: 0x79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798n,
  y: 0x483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8n,
};

const mod = (a, m) => ((a % m) + m) % m;
function inv(a, m) {
  let [lm, hm, low, high] = [1n, 0n, mod(a, m), m];
  while (low > 1n) {
    const r = high / low;
    [lm, low, hm, high] = [hm - lm * r, high - low * r, lm, low];
  }
  return mod(lm, m);
}
function add(p, q) {
  if (!p) return q;
  if (!q) return p;
  if (p.x === q.x && p.y !== q.y) return null;
  const m = p.x === q.x ? mod(3n * p.x * p.x * inv(2n * p.y, Pp), Pp) : mod((q.y - p.y) * inv(q.x - p.x, Pp), Pp);
  const x = mod(m * m - p.x - q.x, Pp);
  return { x, y: mod(m * (p.x - x) - p.y, Pp) };
}
function mul(p, k) {
  let r = null;
  let acc = p;
  while (k > 0n) {
    if (k & 1n) r = add(r, acc);
    acc = add(acc, acc);
    k >>= 1n;
  }
  return r;
}

export const toHex = (b) => '0x' + Buffer.from(b).toString('hex');
const bnTo32 = (v) => Buffer.from(v.toString(16).padStart(64, '0'), 'hex');

/** Deterministic ECDSA over a 32 byte digest, returning Ethereum style {v, r, s}. */
export function signDigest(privHex, digest) {
  const d = BigInt('0x' + privHex);
  const z = BigInt(toHex(digest));
  for (let counter = 0n; ; counter++) {
    // RFC6979-flavoured deterministic k. Simplified but deterministic and never reused, which is
    // the property that matters: a repeated k leaks the key.
    const k = mod(BigInt(toHex(keccak256(Buffer.concat([bnTo32(d), digest, bnTo32(counter)])))), N);
    if (k === 0n) continue;
    const R = mul(G, k);
    const r = mod(R.x, N);
    if (r === 0n) continue;
    let s = mod(inv(k, N) * (z + r * d), N);
    if (s === 0n) continue;
    let recovery = (R.y & 1n) === 1n ? 1 : 0;
    // Reject the malleable half of the curve, matching what the contract enforces.
    if (s > N / 2n) {
      s = N - s;
      recovery ^= 1;
    }
    return { v: 27 + recovery, r: toHex(bnTo32(r)), s: toHex(bnTo32(s)) };
  }
}

export function addressFor(privHex) {
  const pub = mul(G, BigInt('0x' + privHex));
  const raw = Buffer.concat([bnTo32(pub.x), bnTo32(pub.y)]);
  return '0x' + keccak256(raw).subarray(12).toString('hex');
}

// ---------------------------------------------------------------- abi encoding

export function encodeDigest(chainId, settlement, jobId, resultHash, outcome, scoreBps) {
  // abi.encode(string, uint256, address, bytes32, bytes32, uint8, uint16)
  // A dynamic string is encoded as an offset, then length and padded content at the tail.
  const head = [];
  const domain = Buffer.from(SIGNING_DOMAIN, 'utf8');
  head.push(bnTo32(7n * 32n)); // offset to the string tail
  head.push(bnTo32(BigInt(chainId)));
  head.push(Buffer.concat([Buffer.alloc(12), Buffer.from(settlement.slice(2), 'hex')]));
  head.push(Buffer.from(jobId.slice(2), 'hex'));
  head.push(Buffer.from(resultHash.slice(2), 'hex'));
  head.push(bnTo32(BigInt(outcome)));
  head.push(bnTo32(BigInt(scoreBps)));
  const tail = Buffer.concat([
    bnTo32(BigInt(domain.length)),
    Buffer.concat([domain, Buffer.alloc((32 - (domain.length % 32)) % 32)]),
  ]);
  return keccak256(Buffer.concat([...head, tail]));
}

