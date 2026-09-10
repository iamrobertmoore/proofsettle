/**
 * Builds the proof for the canonical settlement's payment locally and compares it, field by
 * field, with the one the hosted Proof Builder returns. Needs the network, so it is opt-in:
 *
 *   RAW_PROOF_LIVE=1 node worker/test/raw-proof.live.mjs
 *
 * The claim it backs is in the README: the hosted service is a convenience, not a trusted party,
 * because the same bytes come out of public Sepolia data and it is the precompile that checks them.
 */
import { JsonRpcProvider } from 'ethers';
import { chainInfo, proofProvider } from '@gluwa/usc-sdk';
import { PatientBlockProvider } from '../block-provider.ts';

if (!process.env.RAW_PROOF_LIVE) { console.log('skipped: set RAW_PROOF_LIVE=1 to run against the network'); process.exit(0); }

const TX = process.env.PAYMENT_TX ?? '0x9f6c9980eea0878b4eba27c677fc8add83dd32fc5c2185dbe76506cce35f33e1';
const cc = new JsonRpcProvider(process.env.CREDITCOIN_RPC_URL ?? 'https://rpc.cc3-testnet.creditcoin.network');
const sep = new JsonRpcProvider(process.env.SOURCE_CHAIN_RPC_URL ?? 'https://ethereum-sepolia-rpc.publicnode.com');
const info = new chainInfo.PrecompileChainInfoProvider(cc);
const raw = new proofProvider.raw.RawProofBuilder(1, new PatientBlockProvider(sep), info, proofProvider.raw.EncodingVersion.V1);
const svc = new proofProvider.service.ProofBuilder(1, process.env.PROOF_BUILDER_URL ?? 'https://prover.cc3-testnet.creditcoin.network');

const t0 = Date.now(); const r = await raw.getProof(TX); const tr = Date.now() - t0;
const t1 = Date.now(); const s = await svc.getProof(TX); const ts = Date.now() - t1;
if (!r.success) { console.log('raw builder failed:', r.error); process.exit(1); }
if (!s.success) { console.log('hosted builder failed:', s.error); process.exit(1); }
const a = r.data, b = s.data;
const checks = {
  headerNumber: a.headerNumber === b.headerNumber,
  txIndex: a.txIndex === b.txIndex,
  txBytes: a.txBytes === b.txBytes,
  merkleRoot: a.merkleProof.root === b.merkleProof.root,
  siblings: JSON.stringify(a.merkleProof.siblings) === JSON.stringify(b.merkleProof.siblings),
  lowerEndpoint: a.continuityProof.lowerEndpointDigest === b.continuityProof.lowerEndpointDigest,
  continuityRoots: JSON.stringify(a.continuityProof.roots) === JSON.stringify(b.continuityProof.roots),
};
console.log(`raw ${tr}ms, hosted ${ts}ms, block ${a.headerNumber} txIndex ${a.txIndex}, ${a.merkleProof.siblings.length} siblings, ${a.continuityProof.roots.length} continuity roots`);
for (const [k, v] of Object.entries(checks)) console.log(`  ${v ? 'ok  ' : 'DIFF'} ${k}`);
const same = Object.values(checks).every(Boolean);
console.log(same ? '\nBYTE-IDENTICAL: the locally built proof is the one the hosted service returns' : '\nMISMATCH');
process.exit(same ? 0 : 1);
