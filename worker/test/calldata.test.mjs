/**
 * The two calldata tricks the rail relies on, checked against the real ABIs.
 *
 * The buyer's sealed input rides after the arguments of createJob, and the enclave's sealed result
 * rides after the arguments of settle. Both depend on the ABI decoder ignoring trailing bytes and
 * on both sides agreeing exactly where the arguments end. This pins those offsets to the compiled
 * ABI rather than to a number somebody typed.
 *
 *   node --test worker/test/
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ethers } from 'ethers';
import { readFileSync } from 'node:fs';
import { withTrailer, fromTrailer } from '../../enclave/envelope.mjs';

const escrowAbi = JSON.parse(readFileSync(new URL('../../out/ComputeJobEscrow.sol/ComputeJobEscrow.json', import.meta.url), 'utf8')).abi;
const settlementAbi = JSON.parse(readFileSync(new URL('../../out/ComputeSettlement.sol/ComputeSettlement.json', import.meta.url), 'utf8')).abi;

const envelope = Buffer.from('01' + 'ab'.repeat(32) + 'cd'.repeat(12) + 'ef'.repeat(90), 'hex');
const hex = (b) => '0x' + Buffer.from(b).toString('hex');

test('createJob calldata: arguments still decode with the trailer appended, and the trailer gives the envelope back', () => {
  const iface = new ethers.Interface(escrowAbi);
  const args = ['0x' + '11'.repeat(20), '0x' + '22'.repeat(32), '0x' + '33'.repeat(32), '0x' + '44'.repeat(32)];
  const clean = iface.encodeFunctionData('createJob', args);
  const withInput = clean + withTrailer(envelope).toString('hex');
  const decoded = iface.decodeFunctionData('createJob', withInput);
  assert.deepEqual([...decoded].map(String), args.map((a) => (a.length === 42 ? ethers.getAddress(a) : a)));
  assert.equal(hex(fromTrailer(Buffer.from(withInput.slice(2), 'hex'))), hex(envelope));
  assert.equal(fromTrailer(Buffer.from(clean.slice(2), 'hex')), null, 'clean calldata carries no envelope');
});

test('the trailer refuses lengths that run off the front of the calldata', () => {
  const bogus = Buffer.concat([Buffer.from('aa', 'hex'), Buffer.from([0, 0, 0, 200]), Buffer.from('PSE1')]);
  assert.equal(fromTrailer(bogus), null);
});

test('settle calldata: the sealed result appended after dynamic arguments still decodes, and the trailer finds it', () => {
  const iface = new ethers.Interface(settlementAbi);
  const args = [
    1, 123456, '0x' + 'aa'.repeat(300),
    { root: '0x' + '55'.repeat(32), siblings: [{ hash: '0x' + '66'.repeat(32), isLeft: true }, { hash: '0x' + '77'.repeat(32), isLeft: false }] },
    { lowerEndpointDigest: '0x' + '88'.repeat(32), roots: ['0x' + '99'.repeat(32), '0x' + '00'.repeat(32)] },
    { resultHash: '0x' + 'bb'.repeat(32), outcome: 1, scoreBps: 10000, v: 27, r: '0x' + 'cc'.repeat(32), s: '0x' + 'dd'.repeat(32) },
  ];
  const clean = iface.encodeFunctionData('settle', args);
  const withResult = clean + withTrailer(envelope).toString('hex');
  const decoded = iface.decodeFunctionData('settle', withResult);
  assert.equal(Number(decoded[1]), 123456);
  assert.equal(decoded[5].scoreBps, 10000n);
  // settle has dynamic arguments, so its argument block has no fixed length. The trailer is what
  // lets a browser find the result without re-encoding anything.
  assert.equal(hex(fromTrailer(Buffer.from(withResult.slice(2), 'hex'))), hex(envelope));
});
