/**
 * Drives the page's in-browser attestation checks, in a real browser.
 *
 *   node site/test-attestation.mjs
 *
 * The page claims it can verify a Confidential Space attestation without a backend. That claim is
 * worth exactly as much as a test that can fail, so this serves the page a token it signs itself
 * with a local key, publishes a matching JWKS, and then breaks the token four different ways.
 *
 * A page that accepts a valid attestation and also accepts a tampered one has told you nothing.
 */
// Playwright is not a dependency of this project. The sandbox this was built in provides one, and
// PW_PLAYWRIGHT / PW_CHROMIUM let you point at your own. Without a browser the test says so and
// exits clean rather than failing, because a missing browser is not a broken page.
const PW = process.env.PW_PLAYWRIGHT ?? '/opt/node22/lib/node_modules/playwright/index.js';
let chromium;
try {
  const mod = await import(PW);
  chromium = mod.chromium ?? mod.default?.chromium;   // the bundled build is CommonJS
} catch { /* handled below */ }
if (!chromium) {
  console.log('skipped: no usable playwright at ' + PW + '. Set PW_PLAYWRIGHT to run this.');
  process.exit(0);
}
import { createServer } from 'node:http';
import { fileURLToPath } from 'node:url';
import { dirname } from 'node:path';
import { readFile } from 'node:fs/promises';
import { generateKeyPairSync, createSign } from 'node:crypto';
import { ethers } from 'ethers';

const SITE = dirname(fileURLToPath(import.meta.url));
const DIGEST_HEX = 'c0a8e85a53c13a607b108683cd75ad896047a2b526d8ef64065bb27aac1396d0';
const ENCLAVE = '0x' + 'c7'.repeat(20);

// A locally signed token that is structurally identical to a real Confidential Space one.
const { privateKey, publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
const jwk = { ...publicKey.export({ format: 'jwk' }), kid: 'test-kid', alg: 'RS256', use: 'sig' };
const b64u = (o) => Buffer.from(typeof o === 'string' ? o : JSON.stringify(o)).toString('base64url');
const now = Math.floor(Date.now() / 1000);
function mint(over = {}, badSig = false) {
  const claims = {
    iss: 'https://confidentialcomputing.googleapis.com', exp: now + 3600, iat: now - 60,
    hwmodel: 'GCP_AMD_SEV', secboot: true, swname: 'CONFIDENTIAL_SPACE', swversion: ['260701'],
    dbgstat: 'disabled-since-boot',
    submods: { container: { image_digest: 'sha256:' + DIGEST_HEX, image_reference: 'x', restart_policy: 'Always' } },
    ...over,
  };
  const h = b64u({ alg: over.alg ?? 'RS256', kid: 'test-kid', typ: 'JWT' }), p = b64u(claims);
  const s = createSign('RSA-SHA256'); s.update(`${h}.${p}`); s.end();
  let sig = s.sign(privateKey).toString('base64url');
  if (badSig) sig = sig.slice(0, -4) + (sig.slice(-4) === 'AAAA' ? 'BBBB' : 'AAAA');
  return `${h}.${p}.${sig}`;
}

const w = (h) => h.replace(/^0x/, '').padStart(64, '0');
const sel = (s) => ethers.id(s).slice(0, 10);
function mockRpc(body) {
  const data = body.params?.[0]?.data ?? '';
  const s = data.slice(0, 10);
  if (s === sel('settlements(bytes32)')) {
    return '0x' + [w('0x'+'11'.repeat(32)), w(ENCLAVE), w('0x'+'22'.repeat(20)),
      w('0x'+(10n**15n).toString(16)), w('0x'+(10n**15n).toString(16)), w('0x0'),
      w('0x'+'33'.repeat(32)), w(ENCLAVE), w('0x1'), w('0x2710'), w('0x'+now.toString(16))].join('');
  }
  if (s === sel('consumedQueries(bytes32)')) return '0x' + w('0x1');
  if (s === sel('measurementOf(address)'))   return '0x' + w('0x' + DIGEST_HEX);
  if (s === sel('isActiveSigner(bytes32,address)')) return '0x' + w('0x1');
  return '0x' + w('0x0');
}

let TOKEN = mint();
const srv = createServer(async (req, res) => {
  const path = req.url.split('?')[0];
  if (req.method === 'POST' && path === '/rpc') {
    let b = ''; for await (const c of req) b += c;
    const out = { jsonrpc: '2.0', id: 1, result: mockRpc(JSON.parse(b)) };
    res.writeHead(200, {'content-type':'application/json'}); return res.end(JSON.stringify(out));
  }
  if (path === '/jwks')  { res.writeHead(200,{'content-type':'application/json'}); return res.end(JSON.stringify({ keys: [jwk] })); }
  if (path === '/token') { res.writeHead(200,{'content-type':'text/plain'}); return res.end(TOKEN); }
  try {
    const f = path === '/' ? '/index.html' : path;
    const buf = await readFile(SITE + f);
    res.writeHead(200, {'content-type': f.endsWith('.json') ? 'application/json' : 'text/html'});
    res.end(buf);
  } catch { res.writeHead(404); res.end('no'); }
});
await new Promise(r => srv.listen(8130, r));

const b = await chromium.launch({ executablePath: process.env.PW_CHROMIUM ?? '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' });
const url = 'http://127.0.0.1:8130/?rpc=http://127.0.0.1:8130/rpc&jwks=http://127.0.0.1:8130/jwks&token=http://127.0.0.1:8130/token';

async function run(label) {
  const pg = await b.newPage();
  await pg.goto(url, { waitUntil: 'networkidle' });
  await pg.fill('#settlement', '0x' + '11'.repeat(20));
  await pg.fill('#registry',   '0x' + '22'.repeat(20));
  await pg.fill('#jobid',      '0x' + '77'.repeat(32));
  await pg.click('#go');
  await pg.waitForFunction(() => document.querySelectorAll('#results li').length >= 5, { timeout: 15000 });
  await pg.waitForTimeout(1500);
  const items = await pg.$$eval('#results li', ns => ns.map(n => ({
    ok: n.querySelector('.mark')?.classList.contains('ok'),
    t: n.querySelector('strong')?.textContent ?? '' })));
  console.log('\n== ' + label);
  for (const i of items) console.log(`   ${i.ok ? 'PASS' : 'FAIL'}  ${i.t}`);
  await pg.close();
  return items;
}

const good = await run('a genuine token');
TOKEN = mint({}, true);            const tampered = await run('signature tampered');
TOKEN = mint({ submods: { container: { image_digest: 'sha256:' + 'de'.repeat(32) } } });
const wrongImage = await run('token names a different image');
TOKEN = mint({ dbgstat: 'enabled' }); const debugImg = await run('debug image');

await b.close(); srv.close();

let failed = 0;
const t = (c, ok) => { if (!ok) failed++; console.log(`${ok ? 'ok  ' : 'FAIL'}  ${c}`); };
console.log('');
t('a genuine token passes every attestation check', good.slice(4).every(i => i.ok) && good.length >= 9);
t('a tampered signature is refused', tampered.some(i => !i.ok && /signature does not verify/i.test(i.t)));
t('an image mismatch is refused', wrongImage.some(i => !i.ok && /not the measurement bound on chain/i.test(i.t)));
t('a debug image is flagged', debugImg.some(i => !i.ok && /Debug status/i.test(i.t)));

console.log('');
if (failed) { console.error(`${failed} check(s) failed`); process.exit(1); }
console.log('ATTESTATION CHECKS OK');
