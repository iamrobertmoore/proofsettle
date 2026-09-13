/** Wallet-free live checks, separate from mocked integration tests. Public synthetic data only. */
import{readFileSync}from'node:fs';
import{createPrivateKey}from'node:crypto';
import{ethers}from'ethers';
import{fromTrailer,open}from'../enclave/envelope.mjs';
import{hashOf}from'../enclave/model.mjs';
const d=JSON.parse(readFileSync('site/deployments.json')),demo=JSON.parse(readFileSync('site/demo.json')),abi=JSON.parse(readFileSync('site/abis.json')),en=JSON.parse(readFileSync('site/enclave.json'));
const cc=new ethers.JsonRpcProvider(process.env.CREDITCOIN_RPC_URL??'https://rpc.cc3-testnet.creditcoin.network',102031,{staticNetwork:true,batchMaxCount:1}),sep=new ethers.JsonRpcProvider(process.env.SOURCE_CHAIN_RPC_URL??'https://ethereum-sepolia-rpc.publicnode.com',11155111,{staticNetwork:true,batchMaxCount:1});
const eq=(a,b)=>String(a).toLowerCase()===String(b).toLowerCase();
const check=(ok,label)=>{if(!ok)throw Error(label);console.log('PASS  '+label)};
const si=new ethers.Interface(abi.ComputeJobEscrow),di=new ethers.Interface(abi.ComputeSettlement);
const settle=new ethers.Contract(d.settlement,abi.ComputeSettlement,cc),escrow=new ethers.Contract(d.sourceEscrow,abi.ComputeJobEscrow,sep);
const event=(r,iface,addr,name)=>{for(const l of r?.logs??[]){if(!eq(l.address,addr))continue;try{const x=iface.parseLog(l);if(x?.name===name)return x.args}catch{}}};
try{
const[pr,sr,tx,s]=await Promise.all([sep.getTransactionReceipt(demo.sourceTx),cc.getTransactionReceipt(demo.settlementTx),cc.getTransaction(demo.settlementTx),settle.settlements(demo.jobId)]);
const j=event(pr,si,d.sourceEscrow,'JobCreated');check(pr?.status===1&&j&&eq(j.jobId,demo.jobId),'payment receipt pins the source escrow and job');
check(s.settledAt>0n&&s.amount===j.amount&&eq(s.provider,j.provider)&&eq(s.payer,j.payer),'Creditcoin settlement matches the source parties and payment');
check(sr?.status===1&&eq(tx?.to,d.settlement),'settlement transaction succeeded at the published contract');
const att=di.decodeFunctionData('settle',tx.data)[5];
const request=ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(['bytes32','bytes32','bytes32'],[j.modelHash,j.inputHash,j.envelopeHash]));
check(eq(request,att.requestHash),'signed request matches proven model, input and encrypted envelope');
const rider=fromTrailer(Buffer.from(tx.data.slice(2),'hex'));check(rider&&eq(ethers.keccak256(rider),att.deliveryHash),'actual delivered ciphertext matches its signed commitment');
const digest=await settle.resultDigest(demo.jobId,att.resultHash,att.outcome,att.scoreBps,att.requestHash,att.deliveryHash);
const signer=ethers.recoverAddress(digest,{v:att.v,r:att.r,s:att.s});check(eq(signer,en.signer)&&eq(signer,s.enclave),'v2 signature recovers to the published enrolled enclave');
check(await settle.consumedQueries(s.queryId),'Attestcoin query is consumed exactly once');
const pk=createPrivateKey({key:Buffer.from(demo.returnKey.k.slice(2),'hex'),type:'pkcs8',format:'der'});
const result=JSON.parse(open(pk,rider,Buffer.from('proofsettle.result.v1'+demo.jobId)).plaintext.toString());
check(eq(hashOf(result),s.resultHash)&&eq(result.inputHash,j.inputHash)&&eq(result.modelHash,j.modelHash),'public synthetic answer opens and matches result, model and input commitments');
console.log('      synthetic result:',result.decision,'probability',result.probability);
const[fr,wr]=await Promise.all([sep.getTransactionReceipt(demo.finalizeTx),sep.getTransactionReceipt(demo.payoutTx)]);
const f=event(fr,si,d.sourceEscrow,'JobFinalized'),w=event(wr,si,d.sourceEscrow,'PaymentWithdrawn');
check(fr?.status===1&&f&&eq(f.jobId,demo.jobId)&&f.paidToProvider===s.paidToProvider&&f.returnedToPayer===s.returnedToPayer,'trusted return leg finalized the exact Creditcoin split');
check(wr?.status===1&&w&&eq(w.recipient,s.provider)&&w.amount===s.paidToProvider&&await escrow.finalized(demo.jobId),'original 0.001 Sepolia ETH was withdrawn to the provider');
const rr=await cc.getTransactionReceipt(demo.refusal.tx),rt=await cc.getTransaction(demo.refusal.tx);check(rr?.status===0&&eq(rt?.to,d.settlement),'wrong-build refusal is a mined reverted transaction');
let reason;try{await cc.call({to:rt.to,from:rt.from,data:rt.data,blockTag:rr.blockNumber-1})}catch(e){try{reason=di.parseError(e.data??e.info?.error?.data)?.name}catch{}}
check(reason==='EnclaveNotAccepted','historical replay reproduces EnclaveNotAccepted');
if(demo.rejected){const r=demo.rejected;const ss=await settle.settlements(r.jobId);const receipt=await sep.getTransactionReceipt(r.payoutTx);const w=event(receipt,si,d.sourceEscrow,'PaymentWithdrawn');check(ss.outcome===0n&&ss.paidToProvider===0n&&ss.returnedToPayer===ss.amount&&receipt?.status===1&&w&&eq(w.recipient,ss.payer)&&w.amount===ss.amount,'unsupported-model service rejection refunds the original payment');}
console.log('\nLIVE EVIDENCE VERIFIED. Return relayer, hardware and registrar trust remain explicit.');
}finally{cc.destroy();sep.destroy()}
