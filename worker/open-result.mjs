/**
 * Open the answer a settlement carried, from the command line, with the one-time key that
 * seal-input.mjs printed. Reads the settlement transaction off Creditcoin, takes the rider from
 * the end of its calldata, opens it (or parses a plain refusal), and checks that the canonical
 * result hashes to the resultHash the contract recorded.
 *
 *   node worker/open-result.mjs <jobId> <ephemeralPrivateKey pkcs8 hex>
 *
 * Environment: CREDITCOIN_RPC_URL, SETTLEMENT_ADDRESS (from .env).
 */
import 'dotenv/config';
import { createPrivateKey } from 'node:crypto';
import { ethers } from 'ethers';
import { open, fromTrailer } from '../enclave/envelope.mjs';
import { canonical, hashOf } from '../enclave/model.mjs';

const [, , jobId, keyHex] = process.argv;
if (!/^0x[0-9a-fA-F]{64}$/.test(jobId ?? '')) throw new Error('first argument must be the job id');
if (!/^0x[0-9a-fA-F]+$/.test(keyHex ?? '')) throw new Error('second argument must be the one-time private key, pkcs8 hex, from seal-input.mjs');

const rpc = process.env.CREDITCOIN_RPC_URL ?? 'https://rpc.cc3-testnet.creditcoin.network';
const settlementAddress = process.env.SETTLEMENT_ADDRESS;
if (!settlementAddress) throw new Error('SETTLEMENT_ADDRESS is not set');
const provider = new ethers.JsonRpcProvider(rpc, undefined, { staticNetwork: true });
const settlement = new ethers.Contract(settlementAddress, [
  'function settlements(bytes32) view returns (bytes32 queryId,address provider,address payer,uint256 amount,uint256 paidToProvider,uint256 returnedToPayer,bytes32 resultHash,address enclave,uint8 outcome,uint16 scoreBps,uint256 settledAt)',
  'event JobSettled(bytes32 indexed jobId,address indexed provider,address indexed enclave,uint8 outcome,uint16 scoreBps,uint256 paidToProvider,uint256 returnedToPayer,bytes32 resultHash,bytes32 requiredMeasurement,bytes32 queryId)',
], provider);

const s = await settlement.settlements(jobId);
if (s.settledAt === 0n) { console.log(`job ${jobId} has not settled`); process.exit(2); }
// Blockscout's indexed query first; the node's eth_getLogs times out past ~10,000 blocks.
const topic0 = settlement.interface.getEvent('JobSettled').topicHash;
let txHash = null;
try {
  const j = await (await fetch(`https://creditcoin-testnet.blockscout.com/api?module=logs&action=getLogs&fromBlock=0&toBlock=latest&address=${settlementAddress}&topic0=${topic0}&topic1=${jobId}&topic0_1_opr=and`)).json();
  txHash = (j.result ?? []).at(-1)?.transactionHash ?? null;
} catch {}
if (!txHash) {
  const head = await provider.getBlockNumber();
  const logs = await settlement.queryFilter(settlement.filters.JobSettled(jobId), Math.max(0, head - 8000), 'latest');
  txHash = logs.at(-1)?.transactionHash ?? null;
}
if (!txHash) throw new Error('settled, but no JobSettled event found on Blockscout or in the last 8,000 blocks');
const tx = await provider.getTransaction(txHash);
const log = { transactionHash: txHash };
const rider = fromTrailer(Buffer.from(tx.data.slice(2), 'hex'));
if (!rider) { console.log('the settlement carried no readable result'); process.exit(3); }

let result;
if (rider[0] === 0x01) {
  const key = createPrivateKey({ key: Buffer.from(keyHex.slice(2), 'hex'), format: 'der', type: 'pkcs8' });
  const { plaintext } = open(key, rider, Buffer.from('proofsettle.result.v1' + jobId.toLowerCase()));
  result = JSON.parse(plaintext.toString('utf8'));
} else if (rider[0] === 0x02) {
  result = JSON.parse(rider.subarray(1).toString('utf8'));
} else throw new Error(`unknown rider type ${rider[0]}`);

const hashOk = hashOf(result).toLowerCase() === s.resultHash.toLowerCase();
console.log(`settlement    ${log.transactionHash}`);
console.log(`outcome       ${['Rejected', 'Accepted', 'Partial'][Number(s.outcome)]}, enclave ${s.enclave}`);
console.log(`result hash   ${s.resultHash}  ${hashOk ? '(matches keccak256 of the canonical result)' : 'DOES NOT MATCH the opened result'}`);
console.log(`rider         ${rider[0] === 1 ? 'sealed to the one-time key, opened here' : 'plain refusal'}`);
console.log(canonical(result).length > 400 ? JSON.stringify(result, null, 2) : canonical(result));
process.exit(hashOk ? 0 : 1);
