/**
 * Drives the desk page in a real browser against the real enclave code.
 *
 * What is real: the enclave server (enclave/server.mjs, unattested), its X25519 key, the model,
 * the envelope format on both sides (WebCrypto in the page, Node crypto in the enclave), the
 * calldata the page builds, and the settlement calldata the worker would build.
 *
 * What is stood in for: MetaMask (a stub that records what the page asked it to send), Sepolia
 * and Creditcoin (a mock JSON-RPC that replays what the two chains would say once the payment is
 * mined, attested and settled), and Blockscout (routed to a fixture for the refusal scenario).
 *
 * Four scenarios: a job the enclave accepts, the same job resumed from a reload with only the
 * saved one-time key, a job refused on chain because the buyer named a revoked build, and a job
 * the enclave refused to run, whose refusal rides in the clear.
 *
 *   node site/test-desk.mjs
 */
import pw from 'playwright';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { readFileSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { extname, join } from 'node:path';
import { ethers } from 'ethers';
import { fromTrailer, withTrailer } from '../enclave/envelope.mjs';
import { loadModel, score, canonical, hashOf } from '../enclave/model.mjs';
import { keccak256, toHex } from '../enclave/crypto.mjs';

const { chromium } = pw;
const EXECUTABLE = process.env.PW_CHROMIUM ?? chromium.executablePath();
const ROOT = new URL('.', import.meta.url).pathname;
const PORT = 8137 + Math.floor(Math.random() * 500);
const ENCLAVE_PORT = 18500 + Math.floor(Math.random() * 500);
const ENCLAVE = `http://127.0.0.1:${ENCLAVE_PORT}`;
const TYPES = { '.html': 'text/html', '.json': 'application/json', '.js': 'text/javascript' };

let failures = 0;
const check = (ok, label, detail = '') => { if (!ok) failures++; console.log(`${ok ? 'ok  ' : 'FAIL'}  ${label}${detail ? `  ${detail}` : ''}`); };
const w = (h) => String(h).replace(/^0x/, '').padStart(64, '0');
const sel = (sig) => ethers.id(sig).slice(0, 10);

/**
 * Event topics come from the Solidity source, not from a signature retyped here. The first
 * version of this suite mirrored the page's hand-written JobSettled signature into the mock, so
 * both agreed with each other and neither agreed with the contract: the live lookup returned
 * nothing while the test stayed green. The source is the only thing the chain agrees with.
 */
const SRC = {};
const eventTopic = (file, name) => {
  SRC[file] ??= readFileSync(join(ROOT, '..', 'src', file), 'utf8');
  const m = SRC[file].match(new RegExp(`event\\s+${name}\\s*\\(([^)]*)\\)`));
  if (!m) throw new Error(`no event ${name} in src/${file}`);
  const types = m[1].split(',').map((p) => p.replace(/\/\/.*$/gm, '').trim().split(/\s+/)[0]).map((t) => (t === 'Outcome' ? 'uint8' : t));
  return ethers.id(`${name}(${types.join(',')})`);
};
const TOPIC_CREATED = eventTopic('ComputeJobEscrow.sol', 'JobCreated');
const TOPIC_SETTLED = eventTopic('ComputeSettlement.sol', 'JobSettled');

// ---------------------------------------------------------------- the enclave, for real
const enclave = spawn(process.execPath, [join(ROOT, '..', 'enclave', 'server.mjs')], {
  env: { ...process.env, PORT: String(ENCLAVE_PORT), ATTESTATION_TOKEN_PATH: '/nonexistent', ATTESTATION_LAUNCHER_SOCKET: '/nonexistent.sock' },
  stdio: ['ignore', 'ignore', 'inherit'],
});
for (let i = 0; ; i++) {
  try { if ((await fetch(ENCLAVE + '/health')).ok) break; } catch {}
  if (i > 60) throw new Error('enclave did not start');
  await new Promise((r) => setTimeout(r, 100));
}
const identity = await (await fetch(ENCLAVE + '/identity')).json();
const runJob = async (job) => (await fetch(ENCLAVE + '/run', { method: 'POST', body: JSON.stringify(job) })).json();

// ---------------------------------------------------------------- what the register step publishes
const deployments = JSON.parse(await readFile(join(ROOT, 'deployments.json'), 'utf8'));
const PROVIDER = '0x' + '5a'.repeat(20);
deployments.provider = PROVIDER;
const MEASUREMENT = '0x' + 'cd'.repeat(32);
const PREVIOUS = '0x' + 'c0'.repeat(32);
const enclaveJson = {
  build: 'proofsettle-enclave/test', measurement: MEASUREMENT, signer: identity.signer,
  encryptionPublicKey: identity.encryptionPublicKey, modelHash: identity.modelHash, modelName: 'thin-file logistic v1',
  previousMeasurement: PREVIOUS, previousBuild: 'proofsettle-enclave/1.1.0', provider: PROVIDER, nonceBound: false,
};

// ---------------------------------------------------------------- the two chains, replayed
const chain = { jobs: new Map(), attestedHeight: 0 };
const gates = new Map();  // txHash -> resolves when the test has "mined" it
const gateFor = (h) => { if (!gates.has(h)) { let open; const p = new Promise((r) => (open = r)); gates.set(h, { p, open }); } return gates.get(h); };

async function mockRpc(path, body) {
  const { method, params } = body;
  const p0 = params?.[0] ?? {};
  if (path === '/sep') {
    if (method === 'eth_getTransactionReceipt') {
      const h = params[0].toLowerCase();
      await gateFor(h).p;
      const job = chain.jobs.get(h); if (!job) return null;
      return { status: '0x1', blockNumber: '0x' + job.block.toString(16), transactionHash: h, logs: [{ address: deployments.sourceEscrow, topics: [TOPIC_CREATED, job.jobId, w(job.payer), w(PROVIDER)], data: '0x' }] };
    }
    if (method === 'eth_call') return '0x'+w('1');
    return null;
  }
  // Creditcoin
  if (method === 'eth_blockNumber') return '0x' + (9_000_000).toString(16);
  if (method === 'eth_call') {
    const data = (p0.data ?? '').toLowerCase(), s = data.slice(0, 10), arg = data.slice(10, 74);
    if (s === sel('isActiveSigner(bytes32,address)')) return '0x' + w(arg === w(MEASUREMENT) && data.slice(74, 138) === w(identity.signer).toLowerCase() ? '1' : '0');
    if (s === sel('get_latest_attestation_height_and_hash(uint64)')) return '0x' + w(chain.attestedHeight.toString(16)) + w('0x' + 'ab'.repeat(32)) + w('1') + w('1');
    if (s === sel('settlements(bytes32)')) {
      const job = [...chain.jobs.values()].find((j) => j.jobId === '0x' + arg);
      if (!job?.settled) return '0x' + '0'.repeat(64 * 11);
      const st = job.settled;
      return '0x' + [w('0x' + 'aa'.repeat(32)), w(PROVIDER), w(job.payer), w((10n ** 15n).toString(16)), w(st.outcome === 1 ? (10n ** 15n).toString(16) : '0'), w(st.outcome === 1 ? '0' : (10n ** 15n).toString(16)), w(st.resultHash), w(identity.signer), w(st.outcome.toString(16)), w(st.scoreBps.toString(16)), w((1757400000).toString(16))].join('');
    }
    // The refusal replay: the same calldata against the block before, which reverts by name.
    if (s === sel('settle(uint64,uint64,bytes,bytes,bytes,bytes)') || data.includes('deadbeef')) {
      const job = [...chain.jobs.values()].find((j) => j.refusal && data.includes(j.jobId.slice(2)));
      if (job) throw { code: 3, message: 'execution reverted', data: sel('EnclaveNotAccepted(bytes32,address)') + w(job.requiredMeasurement) + w(identity.signer) };
    }
    return '0x' + w('0');
  }
  if (method === 'eth_getLogs') {
    // The node road: only answered for the exact topic the contract emits, and only over a window
    // the real node can serve. A wider request is what the live node times out on.
    const span = Number(p0.toBlock === 'latest' ? 9_000_000 : p0.toBlock) - Number(p0.fromBlock);
    if (span > 10_000) throw { code: -32603, message: 'query timeout of 10 seconds exceeded' };
    const [t0, jobId] = p0.topics ?? [];
    if (t0 !== TOPIC_SETTLED) return [];
    const job = [...chain.jobs.values()].find((j) => j.jobId === jobId && j.settled);
    return job ? [{ transactionHash: job.settled.txHash, topics: [TOPIC_SETTLED, jobId] }] : [];
  }
  if (method === 'eth_getTransactionByHash') {
    const h = params[0].toLowerCase();
    for (const job of chain.jobs.values()) {
      if (job.settled?.txHash === h) return { hash: h, to: deployments.settlement, from: '0x' + '77'.repeat(20), blockNumber: '0x' + (8_999_990).toString(16), input: job.settled.input };
      if (job.refusal?.txHash === h) return { hash: h, to: deployments.settlement, from: '0x' + '77'.repeat(20), blockNumber: '0x' + (8_999_991).toString(16), input: job.refusal.input };
    }
    return null;
  }
  return null;
}

let serveSeed = false;
const server = createServer(async (req, res) => {
  const path = req.url.split('?')[0];
  if (req.method === 'POST' && (path === '/cc' || path === '/sep')) {
    let body = ''; req.on('data', (c) => (body += c)); await new Promise((r) => req.on('end', r));
    const parsed = JSON.parse(body);
    res.writeHead(200, { 'content-type': 'application/json', 'access-control-allow-origin': '*' });
    try { const result = await mockRpc(path, parsed); return res.end(JSON.stringify({ jsonrpc: '2.0', id: parsed.id, result })); }
    catch (e) { return res.end(JSON.stringify({ jsonrpc: '2.0', id: parsed.id, error: { code: e.code ?? -32000, message: e.message, data: e.data } })); }
  }
  if (path === '/enclave.json') { res.writeHead(200, { 'content-type': 'application/json' }); return res.end(serveSeed ? await readFile(join(ROOT, 'enclave.json')) : JSON.stringify(enclaveJson)); }
  if (path === '/deployments.json') { res.writeHead(200, { 'content-type': 'application/json' }); return res.end(JSON.stringify(deployments)); }
  try {
    const body = await readFile(join(ROOT, path === '/' ? 'desk.html' : path));
    res.writeHead(200, { 'content-type': TYPES[extname(path)] ?? 'text/plain' }); res.end(body);
  } catch { res.writeHead(404).end('not found'); }
});
await new Promise((r) => server.listen(PORT, r));
const BASE = `http://127.0.0.1:${PORT}`;
const PAGE = `${BASE}/desk.html?rpc=${BASE}/cc&sepolia=${BASE}/sep&poll=300`;

// ---------------------------------------------------------------- the wallet, stubbed
const ACCOUNT = '0x' + '1234'.repeat(10);
const WALLET_STUB = `
  window.__sent = []; let chainId = '0x1';
  window.ethereum = { isMetaMask: true, request: async ({ method, params }) => {
    if (method === 'eth_requestAccounts') return ['${ACCOUNT}'];
    if (method === 'eth_chainId') return chainId;
    if (method === 'wallet_switchEthereumChain') { chainId = params[0].chainId; return null; }
    if (method === 'eth_sendTransaction') { window.__sent.push(params[0]); const n = Number(localStorage.getItem('__txn') || 0) + 1; localStorage.setItem('__txn', String(n)); return '0x' + n.toString(16).padStart(64, '0'); }
    throw new Error('unexpected wallet call ' + method);
  } };`;

const browser = await chromium.launch({ executablePath: EXECUTABLE });
const ctx = await browser.newContext({ viewport: { width: 1100, height: 900 } });
await ctx.addInitScript(WALLET_STUB);
await ctx.route(/fonts\.(googleapis|gstatic)\.com/, (route) => route.fulfill({ status: 200, contentType: 'text/css', body: '' }));
await ctx.route(/googleapis\.com\/service_accounts/, (route) => route.fulfill({ status: 200, contentType: 'application/json', body: '{"keys":[]}' }));
// Blockscout's indexed log query: answered only for the contract's real JobSettled topic. Half the
// scenarios take this road and half are forced onto the node's eth_getLogs, so both are exercised.
let blockscoutLogs = true;
await ctx.route(/blockscout\.com\/api\?module=logs/, (route) => {
  const u = new URL(route.request().url());
  const hit = blockscoutLogs && u.searchParams.get('topic0') === TOPIC_SETTLED
    ? [...chain.jobs.values()].filter((j) => j.settled && j.jobId === u.searchParams.get('topic1')).map((j) => ({ transactionHash: j.settled.txHash, topics: [TOPIC_SETTLED, j.jobId] }))
    : [];
  route.fulfill({ status: 200, contentType: 'application/json', headers: { 'access-control-allow-origin': '*' }, body: JSON.stringify(hit.length ? { status: '1', message: 'OK', result: hit } : { status: '0', message: 'No logs found', result: [] }) });
});
// Blockscout, for the refusal scenario: one failed transaction into the settlement contract.
await ctx.route(/blockscout\.com\/api\/v2\/addresses\/.*\/transactions/, (route) => {
  const items = [...chain.jobs.values()].filter((j) => j.refusal).map((j) => ({ hash: j.refusal.txHash, status: 'error', result: 'Reverted', revert_reason: null }));
  route.fulfill({ status: 200, contentType: 'application/json', headers: { 'access-control-allow-origin': '*' }, body: JSON.stringify({ items }) });
});

const page = await ctx.newPage();
// The only tolerated console line is the 404 for attestation.jwt, which this suite deliberately
// does not publish (site/test-attestation.mjs covers the token across four scenarios).
const consoleErrors = [];
page.on('console', (m) => { if (m.type() === 'error' && !/404/.test(m.text())) consoleErrors.push(m.text()); });
page.on('pageerror', (e) => consoleErrors.push(String(e)));
const texts = (s) => page.$$eval(s, (els) => els.map((e) => e.textContent.replace(/\s+/g, ' ').trim()));
const waitText = (s, re, timeout = 20000) => page.waitForFunction(([s, src]) => [...document.querySelectorAll(s)].some((e) => new RegExp(src).test(e.textContent)), [s, re.source], { timeout });

/** Take the payment the stub captured, decode it, run the enclave on it, and settle it on the mock chain. */
async function mineAndSettle(index, { enclaveRejects = false, refuse = false } = {}) {
  const sent = (await page.evaluate(() => window.__sent)).at(-1);
  const txHash = '0x' + (index + 1).toString(16).padStart(64, '0');
  const data = sent.data.toLowerCase();
  const args = data.slice(10);
  const decoded = { provider: '0x' + args.slice(24, 64), requiredMeasurement: '0x' + args.slice(64, 128), modelHash: '0x' + args.slice(128, 192), inputHash: '0x' + args.slice(192, 256) };
  const envelope = fromTrailer(Buffer.from(data.slice(2), 'hex'));
  const jobId = ethers.keccak256(ethers.concat([txHash, decoded.inputHash]));
  const job = { txHash, jobId, block: 7_000_000 + index, payer: ACCOUNT, ...decoded, envelope };
  chain.jobs.set(txHash, job);
  chain.attestedHeight = job.block + 10;

  if (refuse) {
    // The worker submits; the contract reverts by name because the buyer asked for another build.
    job.refusal = { txHash: '0x' + 'f'.repeat(62) + (index + 1).toString(16).padStart(2, '0'), input: '0xdeadbeef' + w(jobId) };
  } else {
    const att = await runJob({ jobId, modelHash: decoded.modelHash, inputHash: decoded.inputHash, settlementAddress: deployments.settlement, chainId: 102031,
      ciphertext: enclaveRejects ? toHex(Buffer.alloc(80, 7)) : (envelope ? toHex(envelope) : undefined) });
    const rider = att.resultCiphertext ? Buffer.from(att.resultCiphertext.slice(2), 'hex') : Buffer.concat([Buffer.from([0x02]), Buffer.from(canonical(att.rejection), 'utf8')]);
    job.settled = { txHash: '0x' + 'e'.repeat(62) + (index + 1).toString(16).padStart(2, '0'), outcome: att.outcome, scoreBps: att.scoreBps, resultHash: att.resultHash,
      input: sel('settle(uint64,uint64,bytes,bytes,bytes,bytes)') + w('1') + w(job.block.toString(16)) + withTrailer(rider).toString('hex') };
    job.att = att;
  }
  gateFor(txHash).open();
  return job;
}

// ================================================================ scenario 1: accepted
console.log('\n--- scenario 1: a job the enclave accepts ---');
await page.goto(PAGE, { waitUntil: 'networkidle' });
await page.waitForSelector('#provider-checks li');
await page.waitForTimeout(500);
let provider = await texts('#provider-checks li');
check(consoleErrors.length === 0, 'no console errors on load', consoleErrors.slice(0, 2).join(' | '));
check(provider.some((t) => t.startsWith('✓') && /bound to this build/.test(t)), 'registry binding read live and reported green', provider[0]);
check(provider.some((t) => t.startsWith('✗') && /attestation/i.test(t)), 'a missing attestation token reads as a failure, not silence', provider[1]);
const kvText = (await texts('#provider-kv .v')).join(' ');
check(kvText.includes(identity.encryptionPublicKey) && kvText.includes(identity.signer), 'both enclave keys are shown to the buyer');

// The commitment shown must be exactly what the enclave will recompute from the plaintext.
const { model } = loadModel();
const presets = await page.$$eval('.preset', (els) => els.length);
check(presets === 3, 'three applicant presets', String(presets));
const record = await page.evaluate(() => window.__desk.state.record);
const shown = await page.$eval('#input-hash', (e) => e.textContent.trim());
check(shown === toHex(keccak256(Buffer.from(JSON.stringify(record)))), 'the input commitment on screen is keccak256 of the record bytes', shown.slice(0, 18));

const expected = score(model, record);
check(await page.$eval('#pay', (e) => e.hidden), 'pay button hidden until a wallet connects');
// Token failure must block purchases. Other suites exercise signed enrollment evidence.
await page.evaluate(() => { window.__desk.state.providerVerified = true; });
await page.click('#connect');
await waitText('#pay-checks li', /Connected/);
check(await page.$eval('#pay', (e) => !e.hidden && !e.disabled), 'pay button enabled after connecting on Sepolia');
const payKv = (await texts('#pay-kv .v')).join(' ');
check(payKv.includes(MEASUREMENT) && payKv.includes(identity.modelHash) && payKv.includes(PROVIDER), 'the pay panel names build, model and provider');

await page.click('#pay');
await waitText('#pay-checks li', /Payment sent/);
const sent0 = (await page.evaluate(() => window.__sent))[0];
check(sent0.to.toLowerCase() === deployments.sourceEscrow.toLowerCase() && BigInt(sent0.value) === 10n ** 15n, 'pays 0.001 ETH to the escrow');
check(sent0.data.startsWith(sel('createJob(address,bytes32,bytes32,bytes32)')), 'calldata is createJob');
const env0 = fromTrailer(Buffer.from(sent0.data.slice(2), 'hex'));
check(env0 && env0[0] === 1 && env0.length > 45, 'a sealed envelope rides behind the arguments', env0 ? `${env0.length} bytes` : 'none');
check(sent0.data.length === 2 + 8 + 256 + 2 * (env0.length + 8), 'nothing else rides in the calldata');
const saved = await page.evaluate(() => Object.keys(localStorage).filter((k) => k.startsWith('proofsettle.job.')).length);
check(saved >= 1, 'the one-time key is kept in this browser for the answer');

await waitText('#settle-checks li', /Waiting for Sepolia/);
const job1 = await mineAndSettle(0);
check(job1.requiredMeasurement === MEASUREMENT && job1.modelHash === identity.modelHash.toLowerCase(), 'payment named the attested build and the served model');
check(job1.att.outcome === 1 && job1.att.resultCiphertext, 'the real enclave opened the browser-sealed record and accepted the job', job1.att.rejection?.rejected ?? '');
await waitText('#settle-checks li', /hashes to the result/);
let settle = await texts('#settle-checks li');
check(settle.some((t) => /✓\s*Paid on Sepolia/.test(t)), 'payment shown mined with its job id');
check(settle.some((t) => /✓\s*Attested on Creditcoin/.test(t)), 'attestation height read from the precompile');
check(settle.some((t) => /✓\s*Settled on Creditcoin: Accepted/.test(t)), 'settlement read from the contract', settle.find((t) => /Settled/.test(t)));
check(settle.some((t) => /✓\s*The answer hashes to the result/.test(t)), 'the opened answer hashes to the on-chain result');
const decision = await page.$eval('#result .decision', (e) => e.textContent.trim());
check(decision === expected.decision, `the decision the browser decrypted is the model's: ${expected.decision}`, decision);
const resultText = await page.$eval('#result', (e) => e.textContent);
check(resultText.includes(String(expected.probability)), 'and so is the probability', String(expected.probability));
check(consoleErrors.length === 0, 'still no console errors', consoleErrors.slice(0, 2).join(' | '));
// DESK_SHOT=path captures the settled page, for the deck and the video.
if (process.env.DESK_SHOT) { await page.waitForTimeout(600); await page.screenshot({ path: process.env.DESK_SHOT, fullPage: true }); }

// ================================================================ scenario 2: reload, the answer comes back from the saved key
console.log('\n--- scenario 2: the same job after a reload ---');
blockscoutLogs = false;  // force the node road for this one
await page.goto(`${PAGE}&tx=${job1.txHash}`, { waitUntil: 'networkidle' });
await waitText('#settle-checks li', /hashes to the result/);
const decision2 = await page.$eval('#result .decision', (e) => e.textContent.trim());
check(decision2 === expected.decision, 'the answer is recovered with the key saved at payment time', decision2);
blockscoutLogs = true;

// ================================================================ scenario 3: refused on chain by name
console.log('\n--- scenario 3: the buyer names the revoked build ---');
await page.goto(PAGE, { waitUntil: 'networkidle' });
await page.waitForSelector('#build-choice input');
await page.check(`input[name=build][value="${PREVIOUS}"]`);
// Token failure must block purchases. Other suites exercise signed enrollment evidence.
await page.evaluate(() => { window.__desk.state.providerVerified = true; });
await page.click('#connect'); await waitText('#pay-checks li', /Connected/);
await page.click('#pay'); await waitText('#pay-checks li', /Payment sent/);
await waitText('#settle-checks li', /Waiting for Sepolia/);
const job3 = await mineAndSettle(1, { refuse: true });
check(job3.requiredMeasurement === PREVIOUS, 'payment carries the revoked measurement');
await waitText('#settle-checks li', /Refused on Creditcoin/, 30000);
settle = await texts('#settle-checks li');
const refusedLine = settle.find((t) => /Refused/.test(t)) ?? '';
check(/EnclaveNotAccepted\(required 0xc0c0/.test(refusedLine) && new RegExp(identity.signer.slice(2, 12), 'i').test(refusedLine), 'the refusal is decoded by name: required build and the signer refused', refusedLine.slice(0, 120));
check(/rail working/.test(await page.$eval('#after', (e) => e.textContent)), 'the page explains the refusal as the rail working');

// ================================================================ scenario 4: the enclave refuses to run
console.log('\n--- scenario 4: the enclave refuses the job and signs the refusal ---');
await page.goto(PAGE, { waitUntil: 'networkidle' });
await page.waitForSelector('#build-choice input');
await page.click('.preset[data-i="2"]');
// Token failure must block purchases. Other suites exercise signed enrollment evidence.
await page.evaluate(() => { window.__desk.state.providerVerified = true; });
await page.click('#connect'); await waitText('#pay-checks li', /Connected/);
await page.click('#pay'); await waitText('#pay-checks li', /Payment sent/);
await waitText('#settle-checks li', /Waiting for Sepolia/);
const job4 = await mineAndSettle(2, { enclaveRejects: true });
check(job4.att.outcome === 0 && job4.att.rejection?.rejected === 'input-undecryptable', 'the enclave signed a refusal for a record not sealed to it', job4.att.rejection?.rejected);
check(job4.att.resultHash === hashOf(job4.att.rejection), 'the refusal hash is keccak256 of the canonical refusal');
await waitText('#settle-checks li', /hashes to the result/);
settle = await texts('#settle-checks li');
check(settle.some((t) => /✓\s*Settled on Creditcoin: Rejected/.test(t)), 'settlement shown as Rejected');
const notRun = await page.$eval('#result', (e) => e.textContent.replace(/\s+/g, ' '));
check(/Not run/.test(notRun) && /input-undecryptable/.test(notRun), 'the plain-text refusal is shown with its reason', notRun.slice(0, 80));
check(consoleErrors.length === 0, 'no console errors across all scenarios', consoleErrors.slice(0, 3).join(' | '));

// ================================================================ scenario 5: the committed seed file, a build with no encryption key
console.log('\n--- scenario 5: the seed enclave.json in the repository ---');
serveSeed = true;
await page.goto(PAGE, { waitUntil: 'networkidle' });
await page.waitForSelector('#provider-checks li');
const seed = JSON.parse(await readFile(join(ROOT, 'enclave.json'), 'utf8'));
check(/^0x[0-9a-f]{64}$/.test(seed.measurement) && /^0x[0-9a-fA-F]{40}$/.test(seed.signer), 'the seed names a measurement and a signer');
await page.click('#connect'); await waitText('#pay-checks li', /Connected/);
await page.waitForTimeout(300);
const payChecks = await texts('#pay-checks li');
check(await page.$eval('#pay', (e) => e.disabled), 'failed provider verification blocks payment even with a connected wallet');
check((await texts('#provider-checks li')).some(t=>t.startsWith('✗')), 'the failed identity check remains visible');
serveSeed = false;

// Layout sanity, once.
const overflow = await page.evaluate(() => document.documentElement.scrollWidth > document.documentElement.clientWidth + 1);
check(!overflow, 'no horizontal overflow');

await browser.close(); server.close(); enclave.kill();
console.log(`\n${failures === 0 ? 'ALL GREEN' : failures + ' FAILED'}`);
process.exit(failures ? 1 : 0);
