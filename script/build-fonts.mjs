/**
 * Inline Creditcoin's own typefaces into the deck and the verifier page.
 *
 *   node script/build-fonts.mjs
 *
 * creditcoin.org sets its headings in Tektur and its body text in Inter, both of which are open
 * fonts. Rather than link to Google's CDN, the woff2 files are vendored in assets/fonts and
 * embedded as data URIs between the FONTS:BEGIN and FONTS:END markers in each file.
 *
 * Two reasons, and neither is aesthetic. The deck is printed to PDF by a headless browser with no
 * outbound network, so a CDN link produces a deck set in whatever the renderer falls back to. And
 * a verification page that a judge opens on a locked-down network should look like itself rather
 * than degrade quietly. Latin subsets only, which is what the deck and the page use.
 *
 * Licences are in assets/fonts. Both faces are SIL Open Font License 1.1, which permits embedding.
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const FACES = [
  ['Tektur', 400, 'tektur-latin-400-normal.woff2'],
  ['Tektur', 500, 'tektur-latin-500-normal.woff2'],
  ['Tektur', 600, 'tektur-latin-600-normal.woff2'],
  ['Inter',  400, 'inter-latin-400-normal.woff2'],
  ['Inter',  500, 'inter-latin-500-normal.woff2'],
  ['Inter',  600, 'inter-latin-600-normal.woff2'],
  ['Inter',  700, 'inter-latin-700-normal.woff2'],
];

const css = FACES.map(([family, weight, file]) => {
  const b64 = readFileSync(join(ROOT, 'assets/fonts', file)).toString('base64');
  return `@font-face{font-family:"${family}";font-style:normal;font-weight:${weight};`
       + `font-display:swap;src:url(data:font/woff2;base64,${b64}) format("woff2")}`;
}).join('\n');

const BEGIN = '/* FONTS:BEGIN */';
const END = '/* FONTS:END */';
let touched = 0;

for (const rel of ['deck/deck.html', 'site/index.html', 'site/desk.html']) {
  const path = join(ROOT, rel);
  const src = readFileSync(path, 'utf8');
  const a = src.indexOf(BEGIN);
  const b = src.indexOf(END);
  if (a === -1 || b === -1) {
    console.error(`no ${BEGIN} … ${END} markers in ${rel}, so nothing was written to it`);
    process.exitCode = 1;
    continue;
  }
  const out = src.slice(0, a + BEGIN.length) + '\n' + css + '\n' + src.slice(b);
  writeFileSync(path, out);
  console.log(`${rel}: ${FACES.length} faces inlined, ${(out.length / 1024).toFixed(0)} kB total`);
  touched++;
}
if (touched === 0) process.exitCode = 1;
