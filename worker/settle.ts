/**
 * ProofSettle off-chain worker.
 *
 * Watches ComputeJobEscrow on Ethereum Sepolia, waits for the Attestcoin oracle to attest the
 * block containing each payment, builds the inclusion proof, obtains the enclave's signed verdict,
 * and submits both to ComputeSettlement on Creditcoin.
 *
 * The proof-submission role cannot forge either proof. The separately authorized return-relayer
 * key IS trusted by the source escrow; see worker/return.ts. It cannot forge a payment, because the
 * proof is verified on chain by the Attestcoin precompile. It cannot forge a verdict, because the
 * verdict is inside the enclave's signature. It cannot read the buyer's input or the enclave's
 * result, because both are sealed to keys it does not hold: the input rides in the calldata of the
 * payment, the result rides in the calldata of the settlement, and the worker carries each from
 * one chain to the other without being able to open either. Its only power is to submit or to
 * fail to submit, and a failure is visible because the job never settles.
 *
 * Proofs are built locally from Sepolia receipts and headers by default, with Gluwa's hosted Proof
 * Builder as the fallback. The hosted service is a convenience, not a trusted party: the proof it
 * returns is byte-identical to the one built here, and either way the precompile is what checks
 * it. PROOF_SOURCE=service forces the hosted builder; PROOF_SOURCE=raw forbids the fallback.
 *
 * Usage:
 *   npx tsx worker/settle.ts watch            follow new jobs as they appear
 *   npx tsx worker/settle.ts once <txHash>    settle a single known payment
 */
import 'dotenv/config';
import { readFileSync, writeFileSync, renameSync } from 'node:fs';
import { Contract, EventLog, JsonRpcProvider, Wallet, ethers } from 'ethers';
import { chainInfo, proofProvider } from '@gluwa/usc-sdk';

import escrowAbi from '../out/ComputeJobEscrow.sol/ComputeJobEscrow.json' with { type: 'json' };
import settlementAbi from '../out/ComputeSettlement.sol/ComputeSettlement.json' with { type: 'json' };
import { signResult, Outcome } from './enclave-client.js';
import { releasePayment } from './return.js';
import { PatientBlockProvider } from './block-provider.js';
import { paymentEnvelope } from './payment-envelope.mjs';

const need = (k: string): string => {
  const v = process.env[k];
  if (!v) throw new Error(`${k} is not set. Copy .env.example to .env and fill it in.`);
  return v;
};

const CC_RPC = process.env.CREDITCOIN_RPC_URL ?? 'https://rpc.cc3-testnet.creditcoin.network';
const SEPOLIA_RPC = process.env.SOURCE_CHAIN_RPC_URL ?? 'https://ethereum-sepolia-rpc.publicnode.com';
const PROVER = process.env.PROOF_BUILDER_URL ?? 'https://prover.cc3-testnet.creditcoin.network';
const CHAIN_KEY = Number(process.env.SOURCE_CHAIN_KEY ?? 1);
const PROOF_SOURCE = (process.env.PROOF_SOURCE ?? 'raw-then-service') as 'raw' | 'service' | 'raw-then-service';
const STATE_FILE = process.env.WORKER_STATE_FILE ?? '.worker-state.json';

/** The envelope trailer format is defined once, in the enclave, and read from there. */
const envelopeMod = import('../enclave/envelope.mjs');

const POLL_MS = 20_000;
/** Attestation runs 7 to 9 minutes behind Sepolia, measured, so nothing is gained by polling hard. */
const ATTEST_POLL_MS = 15_000;
const ATTEST_TIMEOUT_MS = 25 * 60 * 1000;

async function main() {
  const mode = process.argv[2] ?? 'watch';

  // Validated before anything touches the network or the environment, so a mistyped or pasted
  // placeholder fails in the first millisecond with its own name in the message. Left to the RPC,
  // a malformed hash comes back as ethers' "could not coalesce error", which names nothing.
  if (mode === 'once') {
    const arg = process.argv[3];
    if (!arg) throw new Error('usage: settle.ts once <sepolia_tx_hash>');
    if (!/^0x[0-9a-fA-F]{64}$/.test(arg)) {
      throw new Error(
        `"${arg}" is not a transaction hash. It has to be 0x followed by 64 hex characters. ` +
          'If it looks like a placeholder, it is one: paste the hash first-settlement.sh printed.'
      );
    }
  }

  const cc = new JsonRpcProvider(CC_RPC, undefined, {batchMaxCount:1});
  const sepolia = new JsonRpcProvider(SEPOLIA_RPC, undefined, {batchMaxCount:1});
  const wallet = new Wallet(need('WORKER_PRIVATE_KEY'), cc);

  const escrow = new Contract(need('SOURCE_ESCROW_ADDRESS'), (escrowAbi as any).abi, sepolia);
  const settlement = new Contract(need('SETTLEMENT_ADDRESS'), (settlementAbi as any).abi, wallet);

  // The SDK bundles its own copy of ethers, so its provider types are nominally different from
  // ours. Same class at runtime; the cast is only for the type checker.
  const info = new chainInfo.PrecompileChainInfoProvider(cc as any);
  const proofs = makeProofSource(sepolia, info);

  console.log('ProofSettle worker');
  console.log(`  creditcoin  ${CC_RPC}`);
  console.log(`  sepolia     ${SEPOLIA_RPC}`);
  console.log(`  escrow      ${await escrow.getAddress()}`);
  console.log(`  settlement  ${await settlement.getAddress()}`);
  console.log(`  worker      ${wallet.address}`);
  console.log(`  proofs      ${proofs.describe}`);

  // Fail loudly rather than silently doing nothing all day.
  const bal = await cc.getBalance(wallet.address);
  if (bal === 0n) throw new Error('Worker has zero CTC on Creditcoin. Fund it before starting.');
  console.log(`  balance     ${ethers.formatEther(bal)} CTC\n`);

  if (mode === 'once') {
    const txHash = process.argv[3]!;
    const expectRefusal = process.argv.includes('--expect-refusal');
    await settleOne(txHash, { cc, sepolia, settlement, info, proofs, wallet, expectRefusal });
    return;
  }

  let fromBlock = Number(process.env.WORKER_FROM_BLOCK || readCursor() || (await sepolia.getBlockNumber()));
  const pending = new Set<string>(readPending());
  console.log(`watching from Sepolia block ${fromBlock} (cursor in ${STATE_FILE})\n`);

  for (;;) {
    try {
      const head = await sepolia.getBlockNumber();
      if (head >= fromBlock) {
        const events = await escrow.queryFilter(escrow.filters.JobCreated(), fromBlock, head);
        for (const ev of events) {
          if (!(ev instanceof EventLog)) continue;
          pending.add(ev.transactionHash);
        }
        fromBlock = head + 1;
        writeCursor(fromBlock, [...pending]);
        for (const txHash of [...pending]) {
          console.log(`\nProcessing ${txHash}`);
          try {
            await settleOne(txHash, { cc, sepolia, settlement, info, proofs, wallet });
            pending.delete(txHash);
            writeCursor(fromBlock, [...pending]);
          } catch (e: any) {
            // One job failing must not stop the worker. Report it, keep going, leave it unsettled
            // and visible rather than swallowed.
            console.error(`  job failed: ${e.shortMessage ?? e.message ?? e}`);
          }
        }
        writeCursor(fromBlock, [...pending]);
      }
    } catch (e: any) {
      console.error(`poll error: ${e.shortMessage ?? e.message ?? e}`);
    }
    await new Promise((r) => setTimeout(r, POLL_MS));
  }
}

interface Ctx {
  cc: JsonRpcProvider;
  sepolia: JsonRpcProvider;
  settlement: Contract;
  info: chainInfo.PrecompileChainInfoProvider;
  proofs: ProofSource;
  wallet: Wallet;
  /**
   * Demand that this settlement be refused, and treat success as the failure.
   *
   * A contract that enforces the buyer's policy should be shown refusing, not only succeeding, and
   * a refusal is only evidence if it happens on a public chain where anyone can look it up. So
   * this skips gas estimation, which would reject the call locally and broadcast nothing, sends
   * with a fixed limit so the transaction mines and fails, and reports the reason.
   */
  expectRefusal?: boolean;
}

async function settleOne(txHash: string, ctx: Ctx) {
  const { sepolia, settlement, info, proofs } = ctx;

  const tx = await sepolia.getTransaction(txHash);
  if (!tx) throw new Error(`transaction ${txHash} not found on Sepolia`);
  if (!tx.blockNumber) throw new Error(`transaction ${txHash} is not mined yet`);

  const receipt = await sepolia.getTransactionReceipt(txHash);
  if (!receipt || receipt.status !== 1) throw new Error('source transaction did not succeed, nothing to settle');

  const job = decodeJob(receipt);
  console.log(`  job ${job.jobId}`);
  console.log(`  payer ${job.payer} provider ${job.provider} amount ${ethers.formatEther(job.amount)}`);
  console.log(`  buyer requires enclave ${job.requiredMeasurement}`);

  const already = await settlement.settlements(job.jobId);
  if (already.settledAt !== 0n) {
    console.log('  already settled; checking the Sepolia return leg');
    await releasePayment(job.jobId, settlement, sepolia);
    return;
  }

  if (job.settleBy <= BigInt(Math.floor(Date.now() / 1000))) {
    console.log('  settlement window expired; the buyer retains the source timeout refund'); return;
  }
  // Match the escrow's input commitment even when a wallet wraps the inner call.
  // The worker carries only ciphertext and cannot read it.
  const { withTrailer } = await envelopeMod;
  const sealedInput = paymentEnvelope(Buffer.from(tx.data.slice(2), 'hex'), job.envelopeHash);
  const ciphertext = sealedInput ? '0x' + sealedInput.toString('hex') : undefined;
  console.log(ciphertext ? `  sealed input ${sealedInput!.length} bytes, riding in the payment` : '  no sealed input in the payment');

  // 1. Ask the enclave to run the job and sign the outcome. The worker never sees the signing key
  //    and cannot alter the verdict without invalidating the signature.
  const att = await signResult({
    jobId: job.jobId,
    modelHash: job.modelHash,
    inputHash: job.inputHash,
    settlementAddress: await settlement.getAddress(),
    chainId: Number((await ctx.cc.getNetwork()).chainId),
    ciphertext,
  });
  console.log(`  enclave verdict: ${Outcome[att.outcome]} score ${att.scoreBps}bps result ${att.resultHash}`);
  if (att.rejection) console.log(`  enclave refused: ${att.rejection.rejected}${att.rejection.detail ? ', ' + att.rejection.detail : ''}`);
  if (att.resultCiphertext) console.log(`  result sealed to the buyer, ${(att.resultCiphertext.length - 2) / 2} bytes. The worker cannot read it.`);

  // 2. Wait for the Attestcoin oracle. Measured cadence is a batch of 10 Sepolia blocks every
  //    113 to 123 seconds, so this normally resolves in 7 to 9 minutes.
  const latest = await info.getLatestAttestedHeightAndHash(CHAIN_KEY);
  console.log(`  attested height ${latest.height}, need ${tx.blockNumber} (${tx.blockNumber - latest.height} to go)`);
  await waitUntilAttested(info, tx.blockNumber);
  console.log('  attested');

  // 3. Build the inclusion proof.
  const { data: d, source } = await proofs.get(txHash);
  console.log(`  proof (${source}): block ${d.headerNumber} txIndex ${d.txIndex}, ${d.merkleProof.siblings.length} siblings, ${d.continuityProof.roots.length} continuity roots`);

  // 4. Submit both proofs in one transaction.
  const merkleProof = {
    root: d.merkleProof.root,
    siblings: d.merkleProof.siblings.map((s: any) => ({ hash: s.hash, isLeft: s.isLeft })),
  };
  const continuityProof = {
    lowerEndpointDigest: d.continuityProof.lowerEndpointDigest,
    roots: d.continuityProof.roots,
  };
  const attestation = {
    resultHash: att.resultHash,
    requestHash: att.requestHash,
    deliveryHash: att.deliveryHash,
    outcome: att.outcome,
    scoreBps: att.scoreBps,
    v: att.v,
    r: att.r,
    s: att.s,
  };

  const rider = att.resultCiphertext
    ? Buffer.from(att.resultCiphertext.slice(2), 'hex')
    : Buffer.concat([Buffer.from([2]), Buffer.from((await import('../enclave/model.mjs')).canonical(att.rejection), 'utf8')]);
  const data = settlement.interface.encodeFunctionData('settle', [CHAIN_KEY, d.headerNumber, d.txBytes, merkleProof, continuityProof, attestation]) + withTrailer(rider).toString('hex');

  if (ctx.expectRefusal) {
    // Ask the node what would happen, before spending anything. On pallet-evm the revert reason
    // does not always come back, so this is reported for what it is either way.
    let simulated = 'the node did not return a reason';
    try {
      await ctx.cc.call({to: await settlement.getAddress(), data});
      throw new Error('the simulation SUCCEEDED, so this job would settle. Nothing was refused.');
    } catch (e: any) {
      if (/simulation SUCCEEDED/.test(e.message ?? '')) throw e;
      const parsed = e.data ? settlement.interface.parseError(e.data) : null;
      simulated = parsed
        ? `${parsed.name}(${parsed.args.map(String).join(', ')})`
        : (e.shortMessage ?? e.message ?? String(e));
    }
    console.log(`  simulated refusal: ${simulated}`);

    const sent = await ctx.wallet.sendTransaction({
      to: await settlement.getAddress(),
      data,
      gasLimit: 700_000n,
    });
    console.log(`  submitted ${sent.hash}`);
    const rc = await ctx.cc.waitForTransaction(sent.hash);
    if (!rc) throw new Error('no receipt');

    if (rc.status === 1) {
      throw new Error(`expected a refusal, but ${sent.hash} succeeded. The contract accepted a signature it should not have.`);
    }
    console.log('');
    console.log(`  REFUSED on chain, which is the point`);
    console.log(`           tx      ${sent.hash}`);
    console.log(`           block   ${rc.blockNumber}, status 0, ${rc.gasUsed} gas`);
    console.log(`           reason  ${simulated}`);
    console.log(`           job     ${job.jobId}`);
    console.log('');
    console.log('  The buyer demanded a build this enclave is not. The settlement contract read that');
    console.log('  requirement out of the proven Sepolia payment and refused, and the refusal is now');
    console.log('  a public transaction anyone can look up.');
    return;
  }

  // The sealed result rides after the ABI-encoded arguments, where the decoder ignores it and the
  // buyer's browser reads it back off the chain. Same trick as the input, in the other direction.
  // An accepted result rides sealed (envelope version 0x01). A refusal has no key to seal to and
  // nothing secret in it, so it rides in the clear as canonical JSON behind a 0x02 byte, and the
  // buyer's browser checks its hash against the one the chain carries.
  const to = await settlement.getAddress();

  let gasLimit: bigint;
  try {
    const est = await ctx.wallet.estimateGas({ to, data });
    gasLimit = (est * 135n) / 100n;
    console.log(`  gas estimate ${est}, limit ${gasLimit}`);
  } catch (e: any) {
    // pallet-evm does not always propagate revert reasons during estimation. The examples repo
    // documents the same behaviour, so a failed estimate is not a failed call.
    gasLimit = BigInt(21_000 + d.continuityProof.roots.length * 5_000 + 400_000 + data.length * 8);
    console.warn(`  gas estimation failed (${e.shortMessage ?? e.message}), using ${gasLimit}`);
  }

  const sent = await ctx.wallet.sendTransaction({ to, data, gasLimit });
  console.log(`  submitted ${sent.hash}`);

  const rc = await ctx.cc.waitForTransaction(sent.hash);
  if (!rc) throw new Error(`no receipt for ${sent.hash}`);

  // A reverted settlement is a result, not a crash, and "transaction execution reverted" names
  // nothing. Replay the call at the block it failed in and decode the custom error, so the reason
  // is in the output rather than in somebody's head.
  if (rc.status !== 1) {
    let reason = 'the node returned no revert data, which pallet-evm does not always provide';
    try {
      await ctx.cc.call({ to: sent.to, from: sent.from, data: sent.data, blockTag: rc.blockNumber - 1 });
    } catch (e: any) {
      const raw = e.data ?? e.info?.error?.data;
      const parsed = raw && raw !== '0x' ? settlement.interface.parseError(raw) : null;
      if (parsed) reason = `${parsed.name}(${parsed.args.map(String).join(', ')})`;
      else if (e.shortMessage) reason = e.shortMessage;
    }
    console.log('');
    console.log(`  REFUSED on chain`);
    console.log(`           tx      ${sent.hash}`);
    console.log(`           block   ${rc.blockNumber}, status 0, ${rc.gasUsed} gas`);
    console.log(`           reason  ${reason}`);
    console.log('');
    console.log('  If you meant to demonstrate a refusal, that is the transaction to link to.');
    console.log('  If you did not, the reason above says which guarantee stopped it.');
    return;
  }

  const parsed = rc.logs
    .map((l: any) => {
      try { return settlement.interface.parseLog({ topics: [...l.topics], data: l.data }); } catch { return null; }
    })
    .find((x: any) => x?.name === 'JobSettled');

  if (!parsed) throw new Error('transaction mined but no JobSettled event was emitted');

  console.log(`  SETTLED  outcome=${Outcome[Number(parsed.args.outcome)]}`);
  console.log(`           provider ${ethers.formatEther(parsed.args.paidToProvider)}`);
  console.log(`           payer    ${ethers.formatEther(parsed.args.returnedToPayer)}`);
  console.log(`           enclave  ${parsed.args.enclave}`);
  for (let attempt = 0; attempt < 5; attempt++) {
    try { await releasePayment(job.jobId, settlement, sepolia); return; }
    catch (e: any) { if (attempt === 4) throw e; console.log(`  return leg pending: ${e.shortMessage ?? e.message}`); await new Promise(r => setTimeout(r, 15000)); }
  }
}

interface ProofSource {
  describe: string;
  get(txHash: string): Promise<{ data: proofProvider.ContinuityResponse; source: 'raw' | 'service' }>;
}

/**
 * Local first, hosted second. The raw builder reads Sepolia receipts and headers itself and
 * produces the same bytes the service would, so the service is only ever a convenience.
 */
function makeProofSource(sepolia: JsonRpcProvider, info: chainInfo.PrecompileChainInfoProvider): ProofSource {
  const raw = new proofProvider.raw.RawProofBuilder(
    CHAIN_KEY, new PatientBlockProvider(sepolia), info, proofProvider.raw.EncodingVersion.V1
  );
  const service = new proofProvider.service.ProofBuilder(CHAIN_KEY, PROVER);
  const tryOne = async (name: 'raw' | 'service', p: { getProof(h: string): Promise<proofProvider.ProofResult> }, h: string) => {
    const r = await p.getProof(h);
    if (!r.success || !r.data) throw new Error(`${name} proof builder refused: ${r.error}`);
    return { data: r.data, source: name };
  };
  const order: Array<['raw' | 'service', any]> =
    PROOF_SOURCE === 'raw' ? [['raw', raw]] : PROOF_SOURCE === 'service' ? [['service', service]] : [['raw', raw], ['service', service]];
  return {
    describe: order.map(([n]) => n).join(' then ') + (order.length === 1 ? ' only' : ''),
    async get(txHash) {
      let last: any;
      for (const [name, p] of order) {
        try { return await tryOne(name, p, txHash); }
        catch (e: any) { last = e; console.warn(`  ${name} proof builder failed: ${e.shortMessage ?? e.message}`); }
      }
      throw last;
    },
  };
}

/** Wait for the Attestcoin oracle to attest the block, reading the precompile directly. */
async function waitUntilAttested(info: chainInfo.PrecompileChainInfoProvider, height: number) {
  const deadline = Date.now() + ATTEST_TIMEOUT_MS;
  for (;;) {
    const latest = await info.getLatestAttestedHeightAndHash(CHAIN_KEY);
    if (Number(latest.height) >= height) return;
    if (Date.now() > deadline) throw new Error(`block ${height} was not attested within ${ATTEST_TIMEOUT_MS / 60000} minutes (attested height ${latest.height})`);
    await new Promise((r) => setTimeout(r, ATTEST_POLL_MS));
  }
}

function readCursor(): number | undefined {
  try { return JSON.parse(readFileSync(STATE_FILE, 'utf8')).fromBlock; } catch { return undefined; }
}
function readPending(): string[] {
  try { return JSON.parse(readFileSync(STATE_FILE, 'utf8')).pending ?? []; } catch { return []; }
}
function writeCursor(fromBlock: number, pending: string[] = []) {
  const tmp = STATE_FILE + '.tmp';
  writeFileSync(tmp, JSON.stringify({ fromBlock, pending, updatedAt: new Date().toISOString() }));
  renameSync(tmp, STATE_FILE);
}

const JOB_CREATED_TOPIC = ethers.id('JobCreated(bytes32,address,address,uint256,bytes32,bytes32,bytes32,bytes32,uint64)');

function decodeJob(receipt: ethers.TransactionReceipt) {
  const log = receipt.logs.find((l) => l.topics[0] === JOB_CREATED_TOPIC && l.address.toLowerCase() === need('SOURCE_ESCROW_ADDRESS').toLowerCase());
  if (!log) throw new Error('no JobCreated event in that transaction');
  const [amount, requiredMeasurement, modelHash, inputHash, envelopeHash, settleBy] = ethers.AbiCoder.defaultAbiCoder().decode(
    ['uint256', 'bytes32', 'bytes32', 'bytes32', 'bytes32', 'uint64'], log.data
  );
  return {
    jobId: log.topics[1],
    payer: ethers.getAddress('0x' + log.topics[2].slice(26)),
    provider: ethers.getAddress('0x' + log.topics[3].slice(26)),
    amount: amount as bigint,
    requiredMeasurement: requiredMeasurement as string,
    modelHash: modelHash as string,
    inputHash: inputHash as string,
    envelopeHash: envelopeHash as string,
    settleBy: settleBy as bigint,
  };
}

main().catch((e) => {
  console.error('\nworker stopped:', e.shortMessage ?? e.message ?? e);
  process.exit(1);
});
