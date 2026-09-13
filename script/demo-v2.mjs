/** Publish only disposable keys for deliberately public synthetic examples. Never a wallet key. */
import 'dotenv/config';
import {readFileSync,writeFileSync,existsSync}from'node:fs';
import{randomBytes}from'node:crypto';
import{ethers}from'ethers';
import{seal,withTrailer}from'../enclave/envelope.mjs';
const d=JSON.parse(readFileSync('site/deployments.json')),en=JSON.parse(readFileSync('site/enclave.json'));
const mode=process.argv[2]??'accepted';if(!['accepted','wrong-build','rejected'].includes(mode))throw Error('Unknown mode');
const file=`site/demo-${mode}.json`;
if(existsSync(file)){console.log('Existing example',file,JSON.parse(readFileSync(file)).sourceTx);process.exit()}
const p=new ethers.JsonRpcProvider(process.env.SOURCE_CHAIN_RPC_URL,11155111,{batchMaxCount:1});
const w=new ethers.Wallet(process.env.DEPLOYER_PRIVATE_KEY,p);
const abi=JSON.parse(readFileSync('out/ComputeJobEscrow.sol/ComputeJobEscrow.json')).abi,iface=new ethers.Interface(abi);
const record={months_of_history:6,inflows_per_month:14,inflow_regularity:0.75,avg_monthly_inflow_usd:300,balance_volatility:0.4,supplier_on_time_ratio:0.8,prior_loans_repaid:0,prior_loans_defaulted:0,_nonce:'0x'+randomBytes(32).toString('hex')};
const raw=Buffer.from(JSON.stringify(record));
const {envelope,ephemeralPrivateKey,ephemeralRaw}=seal(Buffer.from(en.encryptionPublicKey.slice(2),'hex'),raw,Buffer.from('proofsettle.input.v1'));
const measurement=mode==='wrong-build'?ethers.id('proofsettle.deliberately-unaccepted-build.v2'):en.measurement;
const modelHash=mode==='rejected'?ethers.id('proofsettle.deliberately-unsupported-model'):en.modelHash;
const data=iface.encodeFunctionData('createJob',[d.provider,measurement,modelHash,ethers.keccak256(raw)])+withTrailer(envelope).toString('hex');
const tx=await w.sendTransaction({to:d.sourceEscrow,data,value:ethers.parseEther('0.001'),gasLimit:300000});
console.log(mode,'payment submitted',tx.hash);
const r=await tx.wait();const log=r.logs.map(x=>{try{return iface.parseLog(x)}catch{return null}}).find(x=>x?.name==='JobCreated');if(!log)throw Error('No job');
const out={version:2,label:'Public synthetic example; this disposable answer key is intentionally published.',mode,sourceTx:tx.hash,jobId:log.args.jobId,sourceBlock:r.blockNumber,record,returnKey:{k:'0x'+ephemeralPrivateKey.export({format:'der',type:'pkcs8'}).toString('hex'),raw:'0x'+Buffer.from(ephemeralRaw).toString('hex')},requiredMeasurement:measurement,modelHash,inputHash:ethers.keccak256(raw)};
writeFileSync(file,JSON.stringify(out,null,2)+'\n');if(mode==='accepted'){writeFileSync('site/demo.json',JSON.stringify(out,null,2)+'\n');d.exampleJobId=out.jobId;writeFileSync('site/deployments.json',JSON.stringify(d,null,2)+'\n')}
console.log('Saved',file,out.jobId);p.destroy();
