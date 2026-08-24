/**
 * Boots the enclave, asks it to sign a job, and writes the result as a Solidity test fixture.
 *
 * This is the cross-language check. The enclave computes the digest in JavaScript with a
 * hand-rolled keccak and ABI encoder; the contract recomputes it in Solidity. If either drifts,
 * `EnclaveSignature.t.sol` fails. Without this, the two halves could disagree and the only place
 * it would show up is a settlement reverting on a live testnet with real fees.
 *
 *   node enclave/make-fixture.mjs
 */
import { spawn } from 'node:child_process';
import { writeFileSync } from 'node:fs';

const PORT = 8099;
const CHAIN_ID = 102031;
const SETTLEMENT = '0x2Be9B8640ED32815d3B9e8C92AbcD3F15F07396f';

/** Search deterministic job ids until every outcome is represented, so the fixture exercises the
 *  outcome byte inside the digest rather than only the Accepted path. */
const hex32 = (n) => '0x' + n.toString(16).padStart(64, '0');

const child = spawn(process.execPath, ['enclave/server.mjs'], {
  env: { ...process.env, PORT: String(PORT) },
  stdio: ['ignore', 'pipe', 'inherit'],
});

let ready = false;
child.stdout.on('data', (d) => {
  process.stdout.write(`[enclave] ${d}`);
  if (String(d).includes('listening')) ready = true;
});

const wait = (ms) => new Promise((r) => setTimeout(r, ms));
for (let i = 0; i < 40 && !ready; i++) await wait(150);
if (!ready) { child.kill(); throw new Error('enclave did not start'); }
await wait(300);

const identity = await (await fetch(`http://127.0.0.1:${PORT}/identity`)).json();
console.log(`\nenclave signer: ${identity.signer}  attested=${identity.attested}`);

const NAMES = { 0: 'rejected', 1: 'accepted', 2: 'partial' };
const results = [];
const have = new Set();
for (let i = 1; i <= 200 && have.size < 3; i++) {
  const job = { jobId: hex32(i), modelHash: hex32(i * 7 + 1), inputHash: hex32(i * 13 + 2) };
  const res = await fetch(`http://127.0.0.1:${PORT}/run`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ ...job, settlementAddress: SETTLEMENT, chainId: CHAIN_ID }),
  });
  if (!res.ok) throw new Error(`enclave HTTP ${res.status}`);
  const out = await res.json();
  if (have.has(out.outcome)) continue;
  have.add(out.outcome);
  results.push({ name: NAMES[out.outcome], ...job, ...out });
  console.log(`  ${NAMES[out.outcome].padEnd(9)} outcome=${out.outcome} bps=${out.scoreBps} result=${out.resultHash.slice(0, 18)}...`);
}
if (have.size < 3) console.warn('  note: not every outcome was reachable within the search window');

child.kill();

const fixture = { chainId: CHAIN_ID, settlement: SETTLEMENT, signer: identity.signer, attested: identity.attested, jobs: results };
writeFileSync('test/fixtures/enclave-signatures.json', JSON.stringify(fixture, null, 2));
console.log('\nwrote test/fixtures/enclave-signatures.json');
