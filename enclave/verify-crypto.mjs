/**
 * Proves the enclave's hand-rolled crypto matches a reference implementation.
 *
 * Pinned standard primitives are checked against ethers reference results and the contract ABI.
 */
import { ethers } from 'ethers';
import { keccak256 } from './crypto.mjs';

let failures = 0;
const check = (name, got, want) => {
  const ok = String(got).toLowerCase() === String(want).toLowerCase();
  if (!ok) failures++;
  console.log(`${ok ? 'ok  ' : 'FAIL'}  ${name}`);
  if (!ok) {
    console.log(`        got  ${got}`);
    console.log(`        want ${want}`);
  }
};

console.log('keccak256 against ethers');
for (const s of ['', 'a', 'abc', 'proofsettle.result.v1', 'x'.repeat(135), 'y'.repeat(136), 'z'.repeat(137), 'q'.repeat(500)]) {
  const mine = '0x' + keccak256(Buffer.from(s, 'utf8')).toString('hex');
  check(`keccak256("${s.length > 12 ? s.slice(0, 9) + '...' + s.length : s}")`, mine, ethers.keccak256(ethers.toUtf8Bytes(s)));
}

const rnd = Buffer.from(Array.from({ length: 64 }, (_, i) => (i * 37 + 11) % 256));
check('keccak256(64 random bytes)', '0x' + keccak256(rnd).toString('hex'), ethers.keccak256(rnd));

console.log('\nsignature and address, against ethers');
const { signDigest, addressFor, encodeDigest } = await import('./crypto.mjs');

const PRIV = '4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362318';
check('address derivation', addressFor(PRIV), new ethers.Wallet('0x' + PRIV).address);

for (const seed of ['job-a', 'job-b', 'job-c', 'job-d', 'job-e']) {
  const digest = ethers.keccak256(ethers.toUtf8Bytes(seed));
  const sig = signDigest(PRIV, Buffer.from(digest.slice(2), 'hex'));
  const recovered = ethers.recoverAddress(digest, { r: sig.r, s: sig.s, v: sig.v });
  check(`signature recovers (${seed})`, recovered, new ethers.Wallet('0x' + PRIV).address);

  const sBn = BigInt(sig.s);
  const half = BigInt('0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0');
  check(`signature is canonical, low s (${seed})`, sBn <= half, true);
  check(`recovery id in {27,28} (${seed})`, sig.v === 27 || sig.v === 28, true);
}

console.log('\ndigest encoding, against the contract ABI');
const chainId = 102031;
const settlement = '0x2Be9B8640ED32815d3B9e8C92AbcD3F15F07396f';
const jobId = ethers.keccak256(ethers.toUtf8Bytes('job-1'));
const resultHash = ethers.keccak256(ethers.toUtf8Bytes('result-1'));

for (const [outcome, bps] of [[0, 0], [1, 10000], [2, 2500], [2, 9999]]) {
  const mine = '0x' + encodeDigest(chainId, settlement, jobId, resultHash, outcome, bps, jobId, resultHash).toString('hex');
  const reference = ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ['string', 'uint256', 'address', 'bytes32', 'bytes32', 'uint8', 'uint16', 'bytes32', 'bytes32'],
      ['proofsettle.result.v2', chainId, settlement, jobId, resultHash, outcome, bps, jobId, resultHash]
    )
  );
  check(`digest(outcome=${outcome}, bps=${bps})`, mine, reference);
}

console.log(failures === 0 ? '\nALL CHECKS PASSED' : `\n${failures} CHECK(S) FAILED`);
process.exit(failures === 0 ? 0 : 1);
