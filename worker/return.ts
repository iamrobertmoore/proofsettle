/** Conventional, explicitly trusted Sepolia return leg. This is not Attestcoin writability. */
import { Contract, JsonRpcProvider, Wallet } from 'ethers';

export async function releasePayment(jobId: string, settlement: Contract, source: JsonRpcProvider) {
  const key = process.env.RETURN_RELAYER_PRIVATE_KEY || process.env.DEPLOYER_PRIVATE_KEY || process.env.WORKER_PRIVATE_KEY;
  if (!key) throw new Error('Return relayer key missing. Creditcoin settlement exists but Sepolia is not released.');
  const signer = new Wallet(key, source);
  const escrow = new Contract(process.env.SOURCE_ESCROW_ADDRESS!, [
    'function settlementRelayer() view returns(address)',
    'function jobs(bytes32) view returns(address payer,address provider,uint256 amount,uint64 createdAt,bool refunded)',
    'function finalized(bytes32) view returns(bool)',
    'function finalize(bytes32,uint256,uint256)',
    'function withdrawable(address) view returns(uint256)',
    'function withdrawFor(address)',
  ], signer);
  if ((await escrow.settlementRelayer()).toLowerCase() !== signer.address.toLowerCase()) throw new Error('Wrong return relayer key');
  const s = await settlement.settlements(jobId);
  if (s.settledAt === 0n) throw new Error('Cannot release an unsettled job');
  // Wait for a 30-second Creditcoin confirmation lag before the conventional relayer acts.
  const provider = settlement.runner!.provider!;
  const tip = await provider.getBlock('latest');
  if (!tip || BigInt(tip.timestamp) < s.settledAt + 30n) throw new Error('Settlement is still confirming; retry return leg shortly');
  const job = await escrow.jobs(jobId);
  if (job.refunded) throw new Error('Source payment has already been refunded');
  if (job.payer.toLowerCase() !== s.payer.toLowerCase() || job.provider.toLowerCase() !== s.provider.toLowerCase() || job.amount !== s.amount) throw new Error('Return leg source/destination accounting mismatch');
  if (s.paidToProvider + s.returnedToPayer !== job.amount) throw new Error('Return split does not conserve the payment');
  const transactions: string[] = [];
  if (!(await escrow.finalized(jobId))) {
    const tx = await escrow.finalize(jobId, s.paidToProvider, s.returnedToPayer);
    await tx.wait(); transactions.push(tx.hash);
    console.log(`  SEPOLIA FINALIZED ${tx.hash}`);
  }
  for (const recipient of new Set<string>([job.provider, job.payer])) {
    if (await escrow.withdrawable(recipient) > 0n) {
      const tx = await escrow.withdrawFor(recipient);
      await tx.wait(); transactions.push(tx.hash);
      console.log(`  SEPOLIA PAID ${recipient} ${tx.hash}`);
    }
  }
  return transactions;
}
