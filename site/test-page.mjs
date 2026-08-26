/**
 * Clicks the verifier page in a real browser.
 *
 * The Flare entry shipped correct markup and correct CSS that still produced a nav nobody could
 * click, because nothing in the sandbox did layout or hit testing. This is that lesson applied:
 * open the page, run the checks against a real deployment, and read what a visitor would see.
 *
 *   node site/test-page.mjs [settlement] [registry] [jobId]
 */
import pw from '/opt/node22/lib/node_modules/playwright/index.js';
const { chromium } = pw;

/** The sandbox ships chromium at a pinned build. Point at it rather than downloading another. */
const EXECUTABLE = process.env.PW_CHROMIUM ?? '/opt/pw-browsers/chromium-1194/chrome-linux/chrome';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join } from 'node:path';

const ROOT = new URL('.', import.meta.url).pathname;
const PORT = 8123;
const TYPES = { '.html': 'text/html', '.json': 'application/json', '.js': 'text/javascript' };

/**
 * A mock CC3 node, so the chain-reading path is exercised for real.
 *
 * The sandboxed browser has no direct egress, so pointing the page at the live RPC only ever
 * produces "Failed to fetch". That would leave the parsing and check logic completely untested
 * while the suite looked green. The live RPC does allow browsers (access-control-allow-origin: *,
 * verified with curl), so this stands in for it rather than papering over it.
 */
const SETTLED_JOB = '0x' + '77'.repeat(32);
const ENCLAVE = '0x' + 'ab'.repeat(20);
const MEASUREMENT = '0x' + 'cd'.repeat(32);
const w = (hex) => hex.replace(/^0x/, '').padStart(64, '0');

function mockRpc(body) {
  const to = (body.params?.[0]?.to ?? '').toLowerCase();
  const data = body.params?.[0]?.data ?? '';
  const sel = data.slice(0, 10);
  const arg = data.slice(10, 74);

  // settlements(bytes32) -> the struct, 11 words
  if (sel === '0x9f2a1e9b' || (to.endsWith('11'.repeat(20)) && data.length > 74 && arg === w(SETTLED_JOB))) {
    // fall through below; selector is resolved dynamically by the page, so match on the argument
  }
  if (arg === w(SETTLED_JOB)) {
    const words = [
      w('0x' + 'aa'.repeat(32)),                 // queryId
      w('0x' + '01'.repeat(20)),                 // provider
      w('0x' + '02'.repeat(20)),                 // payer
      w((10n ** 18n).toString(16)),              // amount 1e18
      w((75n * 10n ** 16n).toString(16)),        // paidToProvider 0.75e18
      w((25n * 10n ** 16n).toString(16)),        // returnedToPayer 0.25e18
      w('0x' + 'ee'.repeat(32)),                 // resultHash
      w(ENCLAVE),                                // enclave
      w('2'),                                    // outcome Partial
      w((7500).toString(16)),                    // scoreBps
      w((1756000000).toString(16)),              // settledAt
    ];
    return '0x' + words.join('');
  }
  // consumedQueries(bytes32) -> true
  if (arg === w('0x' + 'aa'.repeat(32))) return '0x' + w('1');
  // measurementOf(address) -> a measurement
  if (arg === w(ENCLAVE)) return '0x' + w(MEASUREMENT);
  // isActiveSigner(bytes32,address) -> true
  if (arg === w(MEASUREMENT)) return '0x' + w('1');
  return '0x' + w('0');
}

const server = createServer(async (req, res) => {
  if (req.method === 'POST' && req.url.startsWith('/mockrpc')) {
    let body = '';
    req.on('data', (c) => (body += c));
    await new Promise((r) => req.on('end', r));
    const parsed = JSON.parse(body);
    const result = mockRpc(parsed);
    res.writeHead(200, { 'content-type': 'application/json', 'access-control-allow-origin': '*' });
    return res.end(JSON.stringify({ jsonrpc: '2.0', id: parsed.id, result }));
  }
  // Split the query string BEFORE the index check. Getting this the wrong way round made the
  // page 404 the moment a ?rpc= override was added, and every assertion below failed at once.
  const path = req.url.split('?')[0];
  const p = join(ROOT, path === '/' ? 'index.html' : path);
  try {
    const body = await readFile(p);
    res.writeHead(200, { 'content-type': TYPES[extname(p)] ?? 'text/plain' });
    res.end(body);
  } catch {
    res.writeHead(404).end('not found');
  }
});
await new Promise((r) => server.listen(PORT, r));

const browser = await chromium.launch({ executablePath: EXECUTABLE });
let failures = 0;
const check = (ok, label, detail = '') => {
  if (!ok) failures++;
  console.log(`${ok ? 'ok  ' : 'FAIL'}  ${label}${detail ? `  ${detail}` : ''}`);
};

for (const scheme of ['light', 'dark']) {
  const ctx = await browser.newContext({ colorScheme: scheme, viewport: { width: 1100, height: 900 } });
  const page = await ctx.newPage();

  const consoleErrors = [];
  page.on('console', (m) => { if (m.type() === 'error') consoleErrors.push(m.text()); });
  page.on('pageerror', (e) => consoleErrors.push(String(e)));

  // The page asks Google Fonts for Tektur and Inter, which are Creditcoin's own faces. This
  // sandbox has no egress to them, and more to the point the page must not depend on them: a
  // judge on a locked-down network still has to be able to read it. Serve an empty stylesheet
  // and assert the page works anyway, rather than tolerating a font error in the console.
  await ctx.route(/fonts\.(googleapis|gstatic)\.com/, (route) =>
    route.fulfill({ status: 200, contentType: 'text/css', body: '' }));

  await page.goto(`http://127.0.0.1:${PORT}/?rpc=http://127.0.0.1:${PORT}/mockrpc`, { waitUntil: 'networkidle' });

  console.log(`\n--- ${scheme} mode ---`);
  check(consoleErrors.length === 0, 'no console errors', consoleErrors.slice(0, 2).join(' | '));

  // This is a standalone page now, so it has to say what it is and which chain it is about
  // without the reader having arrived from the repository.
  const h1 = await page.$eval('h1', (e) => e.textContent.trim());
  check(/Creditcoin/i.test(h1), 'the headline names Creditcoin', h1.slice(0, 60));

  const frame = await page.$eval('.frame', (e) => e.textContent.replace(/\s+/g, ' ').trim());
  check(/audit tool/i.test(frame) && /including me/i.test(frame),
    'the page states who it is for and that it trusts nobody, including me');

  // Creditcoin's own site is dark, and this page commits to that rather than following the
  // viewer. A light-mode visitor must still get the designed page, not a half-inverted one.
  const ground = await page.evaluate(() => getComputedStyle(document.body).backgroundColor);
  check(ground === 'rgb(12, 14, 16)', 'the Creditcoin ground colour holds in both schemes', ground);

  // The scroll reveal must never be able to leave content permanently invisible. This is a real
  // bug that shipped for about twenty minutes: a full-page screenshot came back with a blank
  // band where two sections should have been.
  await page.waitForTimeout(1900);
  const hidden = await page.$$eval('.r', (els) =>
    els.filter((e) => Number(getComputedStyle(e).opacity) < 0.99).map((e) => e.id || e.className));
  check(hidden.length === 0, 'no revealable section stays invisible', hidden.join(', '));

  // Nothing may overflow horizontally.
  const overflow = await page.evaluate(() =>
    document.documentElement.scrollWidth > document.documentElement.clientWidth + 1);
  check(!overflow, 'no horizontal page overflow');

  // The button must be genuinely clickable, not covered by something.
  const btn = await page.$('#go');
  const box = await btn.boundingBox();
  check(box && box.width > 40 && box.height > 20, 'run button has a real hit area',
    box ? `${Math.round(box.width)}x${Math.round(box.height)}` : 'none');

  // elementFromPoint only sees the viewport, and the page is now long enough that the button
  // starts below the fold. Scroll to it the way a visitor would, then hit test: the point of this
  // assertion is overlays that swallow the click, not where the button happens to sit at load.
  // scroll-behavior is smooth, so an instant scroll keeps this deterministic. Waiting a fixed
  // 250ms instead made this fail while the page was still gliding, which looks exactly like the
  // overlay bug it is meant to catch and wasted a diagnosis.
  await page.evaluate(() => document.querySelector('#go').scrollIntoView({ block: 'center', behavior: 'instant' }));
  await page.waitForTimeout(400);
  const hitsButton = await page.evaluate(() => {
    const b = document.querySelector('#go');
    const r = b.getBoundingClientRect();
    const el = document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2);
    return el === b || b.contains(el);
  });
  check(hitsButton, 'clicking the centre of the button hits the button');

  // Bad input must produce a visible, honest failure rather than silence.
  await page.fill('#settlement', '0xnope');
  await page.click('#go');
  await page.waitForSelector('#results li', { timeout: 5000 });
  const firstMsg = await page.$eval('#results li', (e) => e.textContent.trim());
  check(firstMsg.includes('looks wrong'), 'invalid address is reported to the user', firstMsg.slice(0, 60));

  // A well formed but non-existent settlement must say so rather than inventing a pass.
  await page.fill('#settlement', '0x' + '11'.repeat(20));
  await page.fill('#registry', '0x' + '22'.repeat(20));
  await page.fill('#jobid', '0x' + '33'.repeat(32));
  await page.click('#go');
  await page.waitForTimeout(2500);
  let results = await page.$$eval('#results li', (els) => els.map((e) => e.textContent.trim()));
  const anyFalsePass = results.some((t) => t.startsWith('✓') && /Settled/.test(t));
  check(!anyFalsePass, 'a non-existent settlement never reports as verified', results[0]?.slice(0, 70) ?? '');
  check(/has not settled|No settlement found/.test(results.join(' ')), 'and it says why');

  // A settlement that does exist must produce the full set of green checks.
  await page.fill('#jobid', '0x' + '77'.repeat(32));
  await page.click('#go');
  await page.waitForTimeout(2500);
  results = await page.$$eval('#results li', (els) => els.map((e) => e.textContent.trim()));
  check(results.length >= 5, 'a real settlement produces the full check list', `${results.length} checks`);
  // The attestation half needs a published token and Google's keys, which site/test-attestation.mjs
  // supplies properly across four scenarios. Here there is deliberately no token, so the useful
  // assertion is the other one: a missing attestation has to read as a failure rather than quietly
  // vanishing from the list. A page that drops a check it cannot perform is worse than useless.
  const chainChecks = results.filter((t) => !/attestation/i.test(t));
  check(chainChecks.every((t) => t.startsWith('✓')), 'every chain check passes for a valid settlement',
    chainChecks.filter((t) => t.startsWith('✗')).join(' | ').slice(0, 80));
  check(results.some((t) => t.startsWith('✗') && /No attestation token is published/.test(t)),
    'a missing attestation is reported, not silently skipped');
  check(results.some((t) => /Partial at 75%/.test(t)), 'the verdict and score are decoded correctly');
  check(results.some((t) => /conserves the payment/.test(t)), 'value conservation is checked');
  check(results.some((t) => /consumed, and cannot be reused/.test(t)), 'replay protection is surfaced');
  check(results.some((t) => /binding is live, not revoked/.test(t)), 'the enclave binding is checked');

  // The hero animation states two facts about real transactions, so it has to actually reach both
  // of them. Run this once rather than in both colour schemes; it takes about ten seconds.
  if (scheme === 'dark') {
    await page.evaluate(() => document.getElementById('rig').scrollIntoView({ block: 'center' }));
    const reached = async (want) => {
      try {
        await page.waitForFunction(
          (w) => document.getElementById('verdict')?.textContent === w, want, { timeout: 20000 });
        return true;
      } catch { return false; }
    };
    check(await reached('settled'), 'the hero animation reaches the settled state');
    check(await reached('refused'), 'and goes on to show the refusal');
    const cap = await page.$eval('#rig-cap', (e) => e.textContent);
    check(/EnclaveNotAccepted/.test(cap) && /5,367,004/.test(cap),
      'the refusal caption names the real error and the real block', cap.slice(0, 70));
  }

  await page.screenshot({ path: `/tmp/verifier-${scheme}.png`, fullPage: true });
  await ctx.close();
}

await browser.close();
server.close();

console.log(failures === 0 ? '\nPAGE OK' : `\n${failures} PAGE CHECK(S) FAILED`);
process.exit(failures === 0 ? 0 : 1);
