/**
 * ProofSettle off-chain worker.
 *
 * Watches ComputeJobEscrow on Ethereum Sepolia, waits for the Attestcoin oracle to attest the
 * block containing each payment, pulls the inclusion proof from the prover service, obtains the
 * enclave's signed verdict, and submits both to ComputeSettlement on Creditcoin.
 *
 * The worker is deliberately not trusted with anything. It cannot forge a payment, because the
 * proof is verified on chain by the Attestcoin precompile. It cannot forge a verdict, because the
 * verdict is inside the enclave's signature. Its only power is to submit or to fail to submit, and
 * a failure is visible because the job never settles.
 *
 * Usage:
 *   npx tsx worker/settle.ts watch            follow new jobs as they appear
 *   npx tsx worker/settle.ts once <txHash>    settle a single known payment
 */
import 'dotenv/config';
import { Contract, EventLog, JsonRpcProvider, Wallet, ethers } from 'ethers';
import { chainInfo, proofProvider } from '@gluwa/usc-sdk';

import escrowAbi from '../out/ComputeJobEscrow.sol/ComputeJobEscrow.json' with { type: 'json' };
import settlementAbi from '../out/ComputeSettlement.sol/ComputeSettlement.json' with { type: 'json' };
import { signResult, Outcome } from './enclave-client.js';

const need = (k: string): string => {
  const v = process.env[k];
  if (!v) throw new Error(`${k} is not set. Copy .env.example to .env and fill it in.`);
  return v;
};

const CC_RPC = process.env.CREDITCOIN_RPC_URL ?? 'https://rpc.cc3-testnet.creditcoin.network';
const SEPOLIA_RPC = process.env.SOURCE_CHAIN_RPC_URL ?? 'https://ethereum-sepolia-rpc.publicnode.com';
const PROVER = process.env.PROOF_BUILDER_URL ?? 'https://prover.cc3-testnet.creditcoin.network';
const CHAIN_KEY = Number(process.env.SOURCE_CHAIN_KEY ?? 1);

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

  const cc = new JsonRpcProvider(CC_RPC);
  const sepolia = new JsonRpcProvider(SEPOLIA_RPC);
  const wallet = new Wallet(need('WORKER_PRIVATE_KEY'), cc);

  const escrow = new Contract(need('SOURCE_ESCROW_ADDRESS'), (escrowAbi as any).abi, sepolia);
  const settlement = new Contract(need('SETTLEMENT_ADDRESS'), (settlementAbi as any).abi, wallet);

  const info = new chainInfo.PrecompileChainInfoProvider(cc);
  const prover = new proofProvider.service.ProofBuilder(CHAIN_KEY, PROVER);

  console.log('ProofSettle worker');
  console.log(`  creditcoin  ${CC_RPC}`);
  console.log(`  sepolia     ${SEPOLIA_RPC}`);
  console.log(`  escrow      ${await escrow.getAddress()}`);
  console.log(`  settlement  ${await settlement.getAddress()}`);
  console.log(`  worker      ${wallet.address}`);

  // Fail loudly rather than silently doing nothing all day.
  const bal = await cc.getBalance(wallet.address);
  if (bal === 0n) throw new Error('Worker has zero CTC on Creditcoin. Fund it before starting.');
  console.log(`  balance     ${ethers.formatEther(bal)} CTC\n`);

  if (mode === 'once') {
    const txHash = process.argv[3]!;
    await settleOne(txHash, { cc, sepolia, settlement, info, prover });
    return;
  }

  let fromBlock = Number(process.env.WORKER_FROM_BLOCK ?? (await sepolia.getBlockNumber()));
  const seen = new Set<string>();
  console.log(`watching from Sepolia block ${fromBlock}\n`);

  for (;;) {
    try {
      const head = await sepolia.getBlockNumber();
      if (head >= fromBlock) {
        const events = await escrow.queryFilter(escrow.filters.JobCreated(), fromBlock, head);
        for (const ev of events) {
          if (!(ev instanceof EventLog)) continue;
          if (seen.has(ev.transactionHash)) continue;
          seen.add(ev.transactionHash);
          console.log(`\nJobCreated in ${ev.transactionHash} (block ${ev.blockNumber})`);
          try {
            await settleOne(ev.transactionHash, { cc, sepolia, settlement, info, prover });
          } catch (e: any) {
            // One job failing must not stop the worker. Report it, keep going, leave it unsettled
            // and visible rather than swallowed.
            console.error(`  job failed: ${e.shortMessage ?? e.message ?? e}`);
          }
        }
        fromBlock = head + 1;
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
  prover: proofProvider.service.ProofBuilder;
}

async function settleOne(txHash: string, ctx: Ctx) {
  const { sepolia, settlement, info, prover } = ctx;

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
    console.log('  already settled, skipping');
    return;
  }

  // 1. Ask the enclave to run the job and sign the outcome. The worker never sees the signing key
    // and cannot alter the verdict without invalidating the signature.
  const att = await signResult({
    jobId: job.jobId,
    modelHash: job.modelHash,
    inputHash: job.inputHash,
    settlementAddress: await settlement.getAddress(),
    chainId: Number((await ctx.cc.getNetwork()).chainId),
  });
  console.log(`  enclave verdict: ${Outcome[att.outcome]} score ${att.scoreBps}bps result ${att.resultHash}`);

  // 2. Wait for the Attestcoin oracle. Measured cadence is a batch of 10 Sepolia blocks every
  //    113 to 123 seconds, so this normally resolves in 7 to 9 minutes.
  const latest = await info.getLatestAttestedHeightAndHash(CHAIN_KEY);
  console.log(`  attested height ${latest.height}, need ${tx.blockNumber} (${tx.blockNumber - latest.height} to go)`);
  await prover.waitUntilHeightAttested(CHAIN_KEY, tx.blockNumber, ATTEST_POLL_MS, ATTEST_TIMEOUT_MS);
  console.log('  attested');

  // 3. Pull the inclusion proof.
  const proof = await prover.getProof(txHash);
  if (!proof.success || !proof.data) throw new Error(`prover refused: ${proof.error}`);
  const d = proof.data;
  console.log(`  proof: block ${d.headerNumber} txIndex ${d.txIndex}, ${d.merkleProof.siblings.length} siblings, ${d.continuityProof.roots.length} continuity roots`);

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
    outcome: att.outcome,
    scoreBps: att.scoreBps,
    v: att.v,
    r: att.r,
    s: att.s,
  };

  let gasLimit: bigint;
  try {
    const est = await settlement.settle.estimateGas(
      CHAIN_KEY, d.headerNumber, d.txBytes, merkleProof, continuityProof, attestation
    );
    gasLimit = (est * 135n) / 100n;
    console.log(`  gas estimate ${est}, limit ${gasLimit}`);
  } catch (e: any) {
    // pallet-evm does not always propagate revert reasons during estimation. The examples repo
    // documents the same behaviour, so a failed estimate is not a failed call.
    gasLimit = BigInt(21_000 + d.continuityProof.roots.length * 5_000 + 400_000);
    console.warn(`  gas estimation failed (${e.shortMessage ?? e.message}), using ${gasLimit}`);
  }

  const sent = await settlement.settle(
    CHAIN_KEY, d.headerNumber, d.txBytes, merkleProof, continuityProof, attestation, { gasLimit }
  );
  console.log(`  submitted ${sent.hash}`);
  const rc = await sent.wait();

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
}

const JOB_CREATED_TOPIC = ethers.id('JobCreated(bytes32,address,address,uint256,bytes32,bytes32,bytes32)');

function decodeJob(receipt: ethers.TransactionReceipt) {
  const log = receipt.logs.find((l) => l.topics[0] === JOB_CREATED_TOPIC);
  if (!log) throw new Error('no JobCreated event in that transaction');
  const [amount, requiredMeasurement, modelHash, inputHash] = ethers.AbiCoder.defaultAbiCoder().decode(
    ['uint256', 'bytes32', 'bytes32', 'bytes32'], log.data
  );
  return {
    jobId: log.topics[1],
    payer: ethers.getAddress('0x' + log.topics[2].slice(26)),
    provider: ethers.getAddress('0x' + log.topics[3].slice(26)),
    amount: amount as bigint,
    requiredMeasurement: requiredMeasurement as string,
    modelHash: modelHash as string,
    inputHash: inputHash as string,
  };
}

main().catch((e) => {
  console.error('\nworker stopped:', e.shortMessage ?? e.message ?? e);
  process.exit(1);
});
