/**
 * A block provider for the raw proof builder that works against ordinary public RPCs.
 *
 * The SDK's SimpleBlockProvider fetches a block's receipts with eth_getBlockReceipts, which the
 * free public Sepolia endpoints do not serve. Without it the raw builder cannot run at all and the
 * hosted Proof Builder becomes the only path, which is the dependency this project wants to be
 * able to do without. So this tries the batch call first and, when the endpoint refuses, fetches
 * the receipts one transaction at a time with bounded concurrency. Slower, but the proof that comes
 * out is byte for byte the same, which worker/test/raw-proof.live.mjs checks against the hosted one.
 */
import { JsonRpcProvider } from 'ethers';
import { encoding, proofProvider } from '@gluwa/usc-sdk';

const CONCURRENCY = 8;

export class PatientBlockProvider extends proofProvider.raw.blockProvider.SimpleBlockProvider {
  private readonly provider: JsonRpcProvider;
  constructor(rpc: JsonRpcProvider) {
    // The SDK bundles its own ethers, so the provider types are nominally different. Same class.
    super(rpc as any);
    this.provider = rpc;
  }

  override async getBlockWithReceipts(blockNumber: number) {
    // The batch route, quietly: SimpleBlockProvider logs an error when the endpoint lacks the method.
    const muted = console.error;
    console.error = () => {};
    let fast: any = null;
    try { fast = await super.getBlockWithReceipts(blockNumber); } finally { console.error = muted; }
    if (fast) return fast;

    const rpc: any = this.provider;
    const hex = `0x${blockNumber.toString(16)}`;
    const blockRaw = await rpc.send('eth_getBlockByNumber', [hex, true]);
    if (!blockRaw) return null;
    const network = await rpc.getNetwork();

    const transactions = blockRaw.transactions.map((tx: any) => {
      const formatted = rpc._wrapTransactionResponse(tx, network);
      const auth = tx.authorizationList?.map((a: any) => ({ yParity: Number(a.yParity) })) ?? null;
      return new encoding.TransactionWithRaw(formatted, new encoding.RawTransactionResponse(auth));
    });

    // Receipts one at a time, in block order, a few in flight. Order matters: the receipts root
    // is a trie over receipts by index.
    const hashes: string[] = blockRaw.transactions.map((t: any) => t.hash);
    const raw: any[] = new Array(hashes.length);
    let next = 0;
    const worker = async () => {
      for (;;) {
        const i = next++;
        if (i >= hashes.length) return;
        for (let attempt = 0; ; attempt++) {
          try {
            const r = await rpc.send('eth_getTransactionReceipt', [hashes[i]]);
            if (!r) throw new Error(`no receipt for ${hashes[i]}`);
            raw[i] = r;
            break;
          } catch (e: any) {
            if (attempt >= 4) throw e;
            await new Promise((res) => setTimeout(res, 300 * (attempt + 1)));
          }
        }
      }
    };
    await Promise.all(Array.from({ length: Math.min(CONCURRENCY, hashes.length) }, worker));

    const block = rpc._wrapBlock(blockRaw, true);
    const receipts = raw.map((r) => rpc._wrapTransactionReceipt(r, network));
    return { block, transactions, receipts };
  }
}
