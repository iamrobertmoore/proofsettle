// A fake enclave and a fake Google JWKS, so 30-launch.sh's "is it the image I am about to
// launch" check can be exercised for real rather than reasoned about.
import { generateKeyPairSync, createSign } from 'node:crypto';
import { createServer } from 'node:http';

const DIGEST = process.argv[2];               // what the fake enclave will attest to
const { privateKey, publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
const jwk = { ...publicKey.export({ format: 'jwk' }), kid: 'k1', alg: 'RS256', use: 'sig' };
const ISS = 'http://127.0.0.1:8791';
const b64u = (o) => Buffer.from(typeof o === 'string' ? o : JSON.stringify(o)).toString('base64url');
const now = Math.floor(Date.now() / 1000);
const claims = {
  iss: ISS, exp: now + 3600, nbf: now - 60, iat: now - 60,
  hwmodel: 'GCP_AMD_SEV', secboot: true, swname: 'CONFIDENTIAL_SPACE', dbgstat: 'disabled-since-boot',
  submods: { container: { image_reference: 'x', image_digest: DIGEST, restart_policy: 'Always' } },
};
const h = b64u({ alg: 'RS256', kid: 'k1', typ: 'JWT' }), p = b64u(claims);
const sg = createSign('RSA-SHA256'); sg.update(`${h}.${p}`); sg.end();
const TOKEN = `${h}.${p}.${sg.sign(privateKey).toString('base64url')}`;

createServer((req, res) => {
  if (req.url === '/.well-known/openid-configuration') {
    res.writeHead(200, {'content-type':'application/json'});
    return res.end(JSON.stringify({ issuer: ISS, jwks_uri: `${ISS}/jwks` }));
  }
  if (req.url === '/jwks') {
    res.writeHead(200, {'content-type':'application/json'});
    return res.end(JSON.stringify({ keys: [jwk] }));
  }
  res.writeHead(404); res.end();
}).listen(8791);

createServer((req, res) => {
  res.writeHead(200, {'content-type':'application/json'});
  if (req.url === '/health')   return res.end(JSON.stringify({ ok: true, signer: '0x' + 'aa'.repeat(20) }));
  if (req.url === '/identity') return res.end(JSON.stringify({
    build: 'test', signer: '0x' + 'aa'.repeat(20), encryptionPublicKey: '0x' + 'bb'.repeat(32), modelHash: '0x' + 'cc'.repeat(32),
    attested: true, nonceBound: false, attestationToken: TOKEN }));
  res.end('{}');
}).listen(8080);
console.log('harness up, attesting', DIGEST);
