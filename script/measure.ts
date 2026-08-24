/**
 * Measure how much of the Attestcoin verifier's traffic is real application use.
 *
 * The page at site/index.html cites this. It is here so the claim is reproducible by anyone with
 * a terminal, rather than something the README asserts.
 *
 *   npx tsx script/measure.ts [windowBlocks]
 *
 * Two things worth knowing before you read the output:
 *
 * The RPC enforces a 10 second server-side timeout on eth_getLogs and log density varies wildly,
 * so a fixed window size fails unpredictably. Ranges that time out are split and retried.
 *
 * A range that still cannot be read is counted as UNSCANNED, never as zero. The first version of
 * this recorded a failed window as "0 events", which would have produced a confidently wrong
 * picture showing no activity where there was plenty.
 */
import { ethers } from 'ethers';

const RPC = process.env.CREDITCOIN_RPC_URL ?? 'https://rpc.cc3-testnet.creditcoin.network';
const VERIFIER = '0x0000000000000000000000000000000000000FD2';
const WINDOW = Number(process.argv[2] ?? 100_000);
const START_STEP = 2000;
const MIN_STEP = 125;
const SECONDS_PER_BLOCK = 15.02; // measured over 50,000 blocks

const provider = new ethers.JsonRpcProvider(RPC);
const found = new Map<string, number>();
const unscanned: Array<[number, number]> = [];
let events = 0;

async function scan(from: number, to: number): Promise<void> {
  try {
    const logs = await provider.getLogs({ address: VERIFIER, fromBlock: from, toBlock: to });
    events += logs.length;
    for (const l of logs) if (!found.has(l.transactionHash)) found.set(l.transactionHash, l.blockNumber);
  } catch {
    const span = to - from + 1;
    if (span <= MIN_STEP) {
      unscanned.push([from, to]);
      return;
    }
    const mid = from + Math.floor(span / 2);
    await scan(from, mid - 1);
    await scan(mid, to);
  }
}

async function pool<T, R>(items: T[], n: number, fn: (t: T) => Promise<R>): Promise<R[]> {
  const out: R[] = new Array(items.length);
  let i = 0;
  await Promise.all(Array.from({ length: n }, async () => {
    for (;;) {
      const k = i++;
      if (k >= items.length) return;
      try { out[k] = await fn(items[k]); } catch { out[k] = null as any; }
      if (k % 1000 === 0) process.stderr.write(`  ${k}/${items.length}\n`);
    }
  }));
  return out;
}

async function main() {
  const head = await provider.getBlockNumber();
  const start = head - WINDOW;
  console.error(`scanning ${WINDOW} blocks (~${(WINDOW * SECONDS_PER_BLOCK / 86400).toFixed(1)} days)`);

  for (let from = start; from <= head; from += START_STEP) {
    await scan(from, Math.min(from + START_STEP - 1, head));
  }

  const unscannedBlocks = unscanned.reduce((a, [f, t]) => a + (t - f + 1), 0);
  console.error(`found ${events} events in ${found.size} transactions, ${unscannedBlocks} blocks unscanned`);

  const txs = (await pool([...found.keys()], 20, async (h) => {
    const t = await provider.getTransaction(h);
    return t?.to ? { to: ethers.getAddress(t.to), from: ethers.getAddress(t.from), block: found.get(h)! } : null;
  })).filter(Boolean) as Array<{ to: string; from: string; block: number }>;

  const by = new Map<string, { calls: number; senders: Set<string> }>();
  for (const t of txs) {
    let e = by.get(t.to);
    if (!e) { e = { calls: 0, senders: new Set() }; by.set(t.to, e); }
    e.calls++;
    e.senders.add(t.from);
  }

  const rows = [...by.entries()]
    .map(([contract, v]) => ({ contract, calls: v.calls, pct: +((v.calls / txs.length) * 100).toFixed(2), senders: v.senders.size }))
    .sort((a, b) => b.calls - a.calls);

  const top2 = rows.slice(0, 2).reduce((a, r) => a + r.calls, 0);
  const oneSender = rows.filter((r) => r.senders === 1).length;
  const mostUsers = [...rows].sort((a, b) => b.senders - a.senders)[0];

  console.log('');
  console.log(`window                       ${start} to ${head} (${WINDOW} blocks, ~${(WINDOW * SECONDS_PER_BLOCK / 86400).toFixed(1)} days)`);
  console.log(`blocks that could not be read ${unscannedBlocks}${unscannedBlocks ? '  <-- COVERAGE IS INCOMPLETE' : '  (complete coverage)'}`);
  console.log(`verifier events              ${events}`);
  console.log(`transactions carrying a proof ${txs.length}`);
  console.log(`distinct contracts           ${rows.length}`);
  console.log(`share from the top 2          ${((top2 / txs.length) * 100).toFixed(2)}%`);
  console.log(`contracts with one sender     ${oneSender} of ${rows.length}`);
  console.log(`most distinct senders         ${mostUsers.contract} with ${mostUsers.senders}`);
  console.log('');
  console.table(rows.slice(0, 15));
}

main().catch((e) => { console.error('measurement failed:', e.shortMessage ?? e.message ?? e); process.exit(1); });
