import pw from '/opt/node22/lib/node_modules/playwright/index.js';
import { readFileSync, writeFileSync } from 'node:fs';
const { chromium } = pw;

// Facts that change between runs live here, so the deck is never edited by hand and never
// carries a stale hash.
const facts = JSON.parse(readFileSync('/home/claude/deck/facts.json', 'utf8'));
let html = readFileSync('/home/claude/deck/deck.html', 'utf8');
for (const [k, v] of Object.entries(facts)) {
  const token = `__${k}__`;
  if (!html.includes(token)) { console.error(`WARNING: token ${token} not present in deck.html`); }
  html = html.replaceAll(token, v);
}
const left = html.match(/__[A-Z_]+__/g);
if (left) { console.error('UNSUBSTITUTED TOKENS:', [...new Set(left)].join(', ')); process.exit(1); }
writeFileSync('/home/claude/deck/deck.rendered.html', html);

const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' });
const p = await b.newPage({ viewport: { width: 1280, height: 720 } });
await p.setContent(html, { waitUntil: 'load' });
await p.emulateMedia({ media: 'screen' });

// Every slide must be exactly one page, so check none has overflowed its box before printing.
const overflow = await p.$$eval('.slide', ns => ns.map((n, i) => ({
  i: i + 1, h: n.scrollHeight, w: n.scrollWidth,
})).filter(s => s.h > 721 || s.w > 1281));
if (overflow.length) {
  console.error('SLIDES OVERFLOWING:', JSON.stringify(overflow));
  process.exit(1);
}

await p.pdf({
  path: '/home/claude/deck/ProofSettle-deck.pdf',
  width: '1280px', height: '720px',
  printBackground: true,
  margin: { top: '0', right: '0', bottom: '0', left: '0' },
  pageRanges: '',
});
const n = await p.$$eval('.slide', ns => ns.length);
console.log(`rendered ${n} slides`);
await b.close();
