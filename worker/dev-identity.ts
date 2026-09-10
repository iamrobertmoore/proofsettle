/**
 * Print the development stand-in's identity, so a buyer can seal input to it and the registry can
 * bind it, exactly as they would for the real enclave's /identity.
 *
 *   npx tsx worker/dev-identity.ts
 */
import 'dotenv/config';
import { devIdentity } from './enclave-client.js';

const key = process.env.DEV_ENCLAVE_PRIVATE_KEY;
if (!key) throw new Error('DEV_ENCLAVE_PRIVATE_KEY is not set');
devIdentity(key).then((d) =>
  console.log(JSON.stringify({ build: 'proofsettle-enclave/dev (unattested)', signer: d.signer, encryptionPublicKey: d.encryptionPublicKey, modelHash: d.modelHash, attested: false }, null, 2))
);
