/**
 * Verifies a Confidential Space attestation token, and prints what it actually asserts.
 *
 *   node enclave/verify-token.mjs <token-file|->
 *
 * Zero dependencies. Node's own crypto verifies RS256 against Google's published JWKS.
 *
 * This exists so that "the enclave is attested" is a checkable claim rather than a sentence in a
 * README. Anyone can run it against the token committed in this repository and reach the same
 * conclusion, or a different one.
 *
 * What it refuses to do is treat a token it could not verify as evidence of anything. Every
 * failure below exits non-zero and says which check failed.
 */
import { readFileSync } from 'node:fs';
import { createPublicKey, verify as cryptoVerify } from 'node:crypto';
import { keccak256, toHex } from './crypto.mjs';

const DISCOVERY = process.env.CS_DISCOVERY_URL
  ?? 'https://confidentialcomputing.googleapis.com/.well-known/openid-configuration';
const EXPECTED_ISS = process.env.CS_EXPECTED_ISS ?? 'https://confidentialcomputing.googleapis.com';

const b64u = (s) => Buffer.from(s.replace(/-/g, '+').replace(/_/g, '/'), 'base64');
const die = (msg) => { console.error(`\nFAILED: ${msg}`); process.exit(1); };
const ok = (label, detail) => console.log(`ok    ${label}${detail ? '  ' + detail : ''}`);

const src = process.argv[2];
if (!src) die('usage: node enclave/verify-token.mjs <token-file|->');
const token = (src === '-' ? readFileSync(0, 'utf8') : readFileSync(src, 'utf8')).trim();

const parts = token.split('.');
if (parts.length !== 3) die('that is not a three-part JWT');
const [h64, p64, s64] = parts;

let header, claims;
try { header = JSON.parse(b64u(h64)); } catch { die('the header is not JSON'); }
try { claims = JSON.parse(b64u(p64)); } catch { die('the payload is not JSON'); }

if (header.alg !== 'RS256') die(`unexpected algorithm ${header.alg}. Only RS256 is accepted, so "alg": "none" cannot walk in.`);
if (!header.kid) die('the header carries no kid, so there is no way to choose a key');
ok('header is RS256 with a key id', header.kid);

// ---- the signing key, from Google's published JWKS ----

const disc = await fetch(DISCOVERY).then((r) => r.ok ? r.json() : die(`discovery document returned HTTP ${r.status}`));
if (disc.issuer !== EXPECTED_ISS) die(`discovery issuer is ${disc.issuer}, expected ${EXPECTED_ISS}`);
if (!disc.jwks_uri) die('discovery document has no jwks_uri');
ok('discovery document fetched', disc.jwks_uri);

const jwks = await fetch(disc.jwks_uri).then((r) => r.ok ? r.json() : die(`JWKS returned HTTP ${r.status}`));
const jwk = (jwks.keys ?? []).find((k) => k.kid === header.kid);
if (!jwk) die(`no key in the JWKS matches kid ${header.kid}. The token may be from somewhere else, or too old.`);
ok('signing key found in the JWKS');

// ---- the signature ----

const key = createPublicKey({ key: jwk, format: 'jwk' });
const signed = Buffer.from(`${h64}.${p64}`);
if (!cryptoVerify('RSA-SHA256', signed, key, b64u(s64))) die('the signature does not verify. This token is not what it claims to be.');
ok('signature verifies against that key');

// ---- the claims ----

if (claims.iss !== EXPECTED_ISS) die(`issuer is ${claims.iss}, expected ${EXPECTED_ISS}`);
ok('issuer is Google Cloud Attestation', claims.iss);

const now = Math.floor(Date.now() / 1000);
if (typeof claims.exp !== 'number') die('no exp claim');
const expired = claims.exp < now;
console.log(`${expired ? 'note ' : 'ok   '} expiry ${new Date(claims.exp * 1000).toISOString()}${expired ? '  EXPIRED, so this token is a historical record rather than a live proof' : ''}`);
if (typeof claims.nbf === 'number' && claims.nbf > now + 60) die('the token is not valid yet, which should not be possible');

const container = claims.submods?.container;
if (!container) die('no submods.container claim, so this token says nothing about a workload');
if (!container.image_digest) die('no submods.container.image_digest, so nothing identifies the code');

const digest = String(container.image_digest);
if (!/^sha256:[0-9a-f]{64}$/.test(digest)) die(`image_digest is not a sha256 digest: ${digest}`);
const measurement = '0x' + digest.slice('sha256:'.length);

ok('a workload image is named', digest);

console.log('');
console.log('what this token asserts');
console.log(`  image reference   ${container.image_reference ?? '(absent)'}`);
console.log(`  image digest      ${digest}`);
console.log(`  hardware model    ${claims.hwmodel ?? '(absent)'}`);
console.log(`  secure boot       ${claims.secboot ?? '(absent)'}`);
console.log(`  software          ${claims.swname ?? '?'} ${claims.swversion ?? ''}`);
console.log(`  debug status      ${claims.dbgstat ?? '(absent)'}`);
console.log(`  restart policy    ${container.restart_policy ?? '(absent)'}`);
const nonces = [].concat(claims.eat_nonce ?? []);
console.log(`  key binding       ${nonces.length ? nonces.join(', ') : '(no eat_nonce: this token proves the image, and the image asserts its keys)'}`);

if (claims.dbgstat && claims.dbgstat !== 'disabled-since-boot') {
  console.log('');
  console.log('  NOTE: dbgstat is not disabled-since-boot, so this is a debug Confidential Space');
  console.log('  image. Debug images allow operator access that production images do not, so this');
  console.log('  attestation is weaker than a production one. Say so wherever it is cited.');
}

const evidenceHash = toHex(keccak256(Buffer.from(token, 'utf8')));

console.log('');
console.log('for the registry');
console.log(`  ENCLAVE_MEASUREMENT=${measurement}`);
for (const n of nonces) {
  if (/^0x[0-9a-fA-F]{40}$/.test(n)) console.log(`  ENCLAVE_SIGNING_KEY=${n}    (bound by Google, from eat_nonce)`);
  if (/^0x[0-9a-fA-F]{64}$/.test(n)) console.log(`  ENCLAVE_ENCRYPTION_KEY=${n}    (bound by Google, from eat_nonce)`);
}
console.log(`  ENCLAVE_EVIDENCE_HASH=${evidenceHash}`);
console.log('');
console.log('The measurement is the container image digest itself, so it is checkable against the');
console.log('registry from a docker manifest inspect, with no indirection to take on trust.');
