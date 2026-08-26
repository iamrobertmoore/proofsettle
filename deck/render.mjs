/**
 * Render deck.html to ProofSettle-deck.pdf, one slide per page.
 *
 *   node deck/render.mjs
 */
import pw from '/opt/node22/lib/node_modules/playwright/index.js';
import { readFileSync, writeFileSync } from 'node:fs';
const { chromium } = pw;

// Facts that change between runs live here, so the deck is never edited by hand and never
// carries a stale hash.
const facts = JSON.parse(readFileSync(new URL('./facts.json', import.meta.url), 'utf8'));
let html = readFileSync(new URL('./deck.html', import.meta.url), 'utf8');
for (const [k, v] of Object.entries(facts)) {
  const token = `__${k}__`;
  if (!html.includes(token)) { console.error(`WARNING: token ${token} not present in deck.html`); }
  html = html.replaceAll(token, v);
}

const left = html.match(/__[A-Z_]+__/g);
if (left) { console.error('UNSUBSTITUTED TOKENS:', [...new Set(left)].join(', ')); process.exit(1); }
writeFileSync(new URL('./deck.rendered.html', import.meta.url), html);

const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' });
const p = await b.newPage({ viewport: { width: 1280, height: 720 } });
await p.setContent(html, { waitUntil: 'load' });
await p.emulateMedia({ media: 'screen' });

/*
 * Number the footers from their position rather than from what is typed in the markup, so
 * inserting a slide never means renumbering every footer after it by hand.
 *
 * Done through the DOM, not a regex over the HTML. The first attempt matched every
 * <span class="n">, and the bar charts use that class for their values, so it quietly rewrote a
 * column of measured numbers into slide numbers. A selector cannot make that mistake.
 */
const slideNo = await p.$$eval('.slide', (ns) => {
  ns.forEach((n, i) => {
    const el = n.querySelector('.foot .n');
    if (el) el.textContent = String(i + 1);
  });
  return ns.length;
});

/*
 * An element given an explicit width must actually have one. The bar chart set width on an inline
 * span, which CSS ignores, so seven bars rendered empty and the slide still passed every other
 * check. A zero-width element that was told to be 40% wide is always a mistake.
 */
const zeroWidth = await p.$$eval('[style*="width"]', (els) => els
  .filter((e) => /width:\s*[1-90]/.test(e.getAttribute('style') || ''))
  .filter((e) => e.getBoundingClientRect().width < 0.5)
  .map((e) => (e.className || e.tagName) + ' ' + e.getAttribute('style')));
if (zeroWidth.length) {
  console.error('ELEMENTS SIZED BUT NOT RENDERED:', JSON.stringify(zeroWidth, null, 1));
  process.exit(1);
}

/*
 * Every slide must be exactly one page.
 *
 * This used to compare the slide's own scrollHeight against 720, which was worthless: .slide sets
 * overflow:hidden, so scrollHeight can never exceed clientHeight. A slide whose content spilled
 * up over its heading and down through its footer still measured 720 and printed as a blank page.
 * Three measurements now, because content can go wrong in three different ways:
 *
 *   above/below/sides   content escaping the slide box entirely
 *   bodyAbove/bodyBelow content taller than the space between the heading and the footer, which
 *                       .body centres, so it overflows in both directions at once
 *   underFoot           content reaching the footer rule on slides that have no .body
 */
const overflow = await p.$$eval('.slide', (ns) => ns.map((n, i) => {
  const r = n.getBoundingClientRect();
  const union = (root, skipFoot) => {
    let top = Infinity, bottom = -Infinity, leftX = Infinity, rightX = -Infinity;
    const foot = n.querySelector('.foot');
    for (const el of root.querySelectorAll('*')) {
      if (skipFoot && foot && (el === foot || foot.contains(el))) continue;
      const bb = el.getBoundingClientRect();
      if (bb.width === 0 && bb.height === 0) continue;
      top = Math.min(top, bb.top); bottom = Math.max(bottom, bb.bottom);
      leftX = Math.min(leftX, bb.left); rightX = Math.max(rightX, bb.right);
    }
    return { top, bottom, left: leftX, right: rightX };
  };

  const all = union(n, false);
  const body = n.querySelector('.body');
  let bodyAbove = 0, bodyBelow = 0;
  if (body) {
    const br = body.getBoundingClientRect();
    const u = union(body, false);
    if (u.top !== Infinity) {
      bodyAbove = Math.round(Math.max(0, br.top - u.top));
      bodyBelow = Math.round(Math.max(0, u.bottom - br.bottom));
    }
  }

  let underFoot = 0;
  const foot = n.querySelector('.foot');
  if (foot) {
    const fr = foot.getBoundingClientRect();
    const u = union(n, true);
    if (u.bottom !== -Infinity) underFoot = Math.round(Math.max(0, u.bottom - fr.top));
  }

  return {
    i: i + 1,
    above: Math.round(Math.max(0, r.top - all.top)),
    below: Math.round(Math.max(0, all.bottom - r.bottom)),
    sides: Math.round(Math.max(0, r.left - all.left) + Math.max(0, all.right - r.right)),
    bodyAbove, bodyBelow, underFoot,
  };
}).filter((s) => s.above > 1 || s.below > 1 || s.sides > 1
              || s.bodyAbove > 1 || s.bodyBelow > 1 || s.underFoot > 1));

if (overflow.length) {
  console.error('SLIDES OVERFLOWING (px outside where they belong):', JSON.stringify(overflow));
  process.exit(1);
}

await p.pdf({
  path: new URL('./ProofSettle-deck.pdf', import.meta.url).pathname,
  width: '1280px', height: '720px',
  printBackground: true,
  margin: { top: '0', right: '0', bottom: '0', left: '0' },
  pageRanges: '',
});
console.log(`rendered ${slideNo} slides`);
await b.close();
