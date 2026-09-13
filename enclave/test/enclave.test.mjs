/**
 * Drives the enclave server end to end, outside an enclave, so every refusal path is exercised
 * and the accepted path round-trips a sealed result back to the buyer's one-time key.
 *
 *   node --test enclave/test/
 */
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { keccak256, toHex, encodeDigest } from '../crypto.mjs';
import { seal, open, generateRecipientKey } from '../envelope.mjs';
import { loadModel, hashOf, canonical } from '../model.mjs';
import { ethers } from 'ethers';

const PORT = 18080 + Math.floor(Math.random() * 1000);
const BASE = `http://127.0.0.1:${PORT}`;
let child;

before(async () => {
  child = spawn(process.execPath, [new URL('../server.mjs', import.meta.url).pathname], {
    env: { ...process.env, PORT: String(PORT), ATTESTATION_TOKEN_PATH: '/nonexistent', ATTESTATION_LAUNCHER_SOCKET: '/nonexistent.sock' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  for (let i = 0; i < 50; i++) {
    try { if ((await fetch(BASE + '/health')).ok) return; } catch {}
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error('enclave did not start');
});
after(() => child?.kill());

const get = async (p) => (await fetch(BASE + p)).json();
const post = async (p, body) => (await fetch(BASE + p, { method: 'POST', body: JSON.stringify(body) })).json();

const APPLICANT = { months_of_history: 24, inflows_per_month: 30, inflow_regularity: 0.95, avg_monthly_inflow_usd: 900,
  balance_volatility: 0.2, supplier_on_time_ratio: 0.95, prior_loans_repaid: 2, prior_loans_defaulted: 0 };
const JOB = '0x' + 'ab'.repeat(32);
const SETTLEMENT = '0x' + '11'.repeat(20);
const CHAIN = 102031;
const AAD_INPUT = Buffer.from('proofsettle.input.v1');

function sealed(identity, record = APPLICANT) {
  const plaintext = Buffer.from(JSON.stringify(record), 'utf8');
  const { envelope, ephemeralPrivateKey } = seal(Buffer.from(identity.encryptionPublicKey.slice(2), 'hex'), plaintext, AAD_INPUT);
  return { ciphertext: toHex(envelope), inputHash: toHex(keccak256(plaintext)), ephemeralPrivateKey };
}

function recovers(res, identity) {
  const digest = encodeDigest(CHAIN, SETTLEMENT, JOB, res.resultHash, res.outcome, res.scoreBps, res.requestHash, res.deliveryHash);
  return ethers.recoverAddress(digest, { r: res.r, s: res.s, v: res.v }).toLowerCase() === identity.signer.toLowerCase();
}

test('identity publishes both keys and the model hash, and says it is not attested here', async () => {
  const id = await get('/identity');
  assert.equal(id.attested, false);
  assert.equal(id.nonceBound, false);
  assert.match(id.signer, /^0x[0-9a-fA-F]{40}$/);
  assert.match(id.encryptionPublicKey, /^0x[0-9a-f]{64}$/);
  assert.equal(id.modelHash, loadModel().modelHash);
});

test('the served model hash is recomputable from the served model', async () => {
  const m = await get('/model');
  assert.equal(hashOf(m.model), m.modelHash);
});

test('accepted: the sealed input runs, and the result comes back sealed to the buyer', async () => {
  const id = await get('/identity');
  const { ciphertext, inputHash, ephemeralPrivateKey } = sealed(id);
  const res = await post('/run', { jobId: JOB, modelHash: id.modelHash, inputHash, settlementAddress: SETTLEMENT, chainId: CHAIN, ciphertext });
  assert.equal(res.outcome, 1, JSON.stringify(res));
  assert.equal(res.scoreBps, 10000);
  assert.ok(res.resultCiphertext, 'no sealed result');
  assert.equal(res.rejection, undefined);
  assert.ok(recovers(res, id), 'signature does not recover to the signer');

  // Only the buyer can open the result, and its hash is what the chain will carry.
  const { plaintext } = open(ephemeralPrivateKey, Buffer.from(res.resultCiphertext.slice(2), 'hex'), Buffer.from('proofsettle.result.v1' + JOB));
  const result = JSON.parse(plaintext.toString('utf8'));
  assert.equal(hashOf(result), res.resultHash);
  assert.equal(result.decision, 'approve');
  assert.equal(result.inputHash, inputHash);
  assert.equal(canonical(result), plaintext.toString('utf8'));
});

test('refused: a model this enclave does not serve', async () => {
  const id = await get('/identity');
  const { ciphertext, inputHash } = sealed(id);
  const res = await post('/run', { jobId: JOB, modelHash: '0x' + 'ee'.repeat(32), inputHash, settlementAddress: SETTLEMENT, chainId: CHAIN, ciphertext });
  assert.equal(res.outcome, 0);
  assert.equal(res.rejection.rejected, 'model-not-served');
  assert.equal(hashOf(res.rejection), res.resultHash);
  assert.ok(recovers(res, id));
});

test('refused: input that does not hash to the commitment in the payment', async () => {
  const id = await get('/identity');
  const { ciphertext } = sealed(id);
  const res = await post('/run', { jobId: JOB, modelHash: id.modelHash, inputHash: '0x' + 'cd'.repeat(32), settlementAddress: SETTLEMENT, chainId: CHAIN, ciphertext });
  assert.equal(res.outcome, 0);
  assert.equal(res.rejection.rejected, 'input-commitment-mismatch');
  assert.ok(recovers(res, id));
});

test('refused: input sealed to some other key', async () => {
  const id = await get('/identity');
  const other = generateRecipientKey();
  const plaintext = Buffer.from(JSON.stringify(APPLICANT));
  const { envelope } = seal(other.raw, plaintext, AAD_INPUT);
  const res = await post('/run', { jobId: JOB, modelHash: id.modelHash, inputHash: toHex(keccak256(plaintext)), settlementAddress: SETTLEMENT, chainId: CHAIN, ciphertext: toHex(envelope) });
  assert.equal(res.outcome, 0);
  assert.equal(res.rejection.rejected, 'input-undecryptable');
});

test('refused: no sealed input at all', async () => {
  const id = await get('/identity');
  const res = await post('/run', { jobId: JOB, modelHash: id.modelHash, inputHash: '0x' + '00'.repeat(32), settlementAddress: SETTLEMENT, chainId: CHAIN });
  assert.equal(res.outcome, 0);
  assert.equal(res.rejection.rejected, 'no-input');
});

test('refused: a record missing a feature the model needs', async () => {
  const id = await get('/identity');
  const { ciphertext, inputHash } = sealed(id, { months_of_history: 3 });
  const res = await post('/run', { jobId: JOB, modelHash: id.modelHash, inputHash, settlementAddress: SETTLEMENT, chainId: CHAIN, ciphertext });
  assert.equal(res.outcome, 0);
  assert.equal(res.rejection.rejected, 'input-invalid');
  assert.match(res.rejection.detail, /inflows_per_month/);
});

test('the same input always produces the same result hash', async () => {
  const id = await get('/identity');
  const a = sealed(id), b = sealed(id);
  const ra = await post('/run', { jobId: JOB, modelHash: id.modelHash, inputHash: a.inputHash, settlementAddress: SETTLEMENT, chainId: CHAIN, ciphertext: a.ciphertext });
  const rb = await post('/run', { jobId: JOB, modelHash: id.modelHash, inputHash: b.inputHash, settlementAddress: SETTLEMENT, chainId: CHAIN, ciphertext: b.ciphertext });
  assert.equal(ra.resultHash, rb.resultHash, 'result must not depend on the envelope, only on the input');
});

test('signature commits to source request and exact encrypted delivery, including return key', async () => {
  const id = await get('/identity');
  const a = sealed(id), b = sealed(id);
  const run = x => post('/run', { jobId: JOB, modelHash: id.modelHash, inputHash: x.inputHash, settlementAddress: SETTLEMENT, chainId: CHAIN, ciphertext: x.ciphertext });
  const ra = await run(a), rb = await run(b);
  const expected = ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(['bytes32','bytes32','bytes32'], [id.modelHash,a.inputHash,ethers.keccak256(a.ciphertext)]));
  assert.equal(ra.requestHash, expected);
  assert.notEqual(ra.requestHash, rb.requestHash, 'different return keys must bind different requests');
  assert.equal(ra.deliveryHash, ethers.keccak256(ra.resultCiphertext));
  assert.ok(recovers(ra,id));
  assert.equal(recovers({...ra, deliveryHash:rb.deliveryHash},id),false);
  assert.equal(recovers({...ra, requestHash:rb.requestHash},id),false);
});
