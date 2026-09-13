/** Deploy the request/delivery-binding release to the existing testnets. Resumable public log. */
import 'dotenv/config';
import {readFileSync,writeFileSync,existsSync,mkdirSync,copyFileSync,chmodSync} from 'node:fs';
import {ethers} from 'ethers';
const root=new URL('../',import.meta.url);
const at=p=>new URL(p,root);
const env=process.env;
const sep=new ethers.JsonRpcProvider(env.SOURCE_CHAIN_RPC_URL, undefined, {batchMaxCount:1}),cc=new ethers.JsonRpcProvider(env.CREDITCOIN_RPC_URL, undefined, {batchMaxCount:1});
if(Number((await sep.getNetwork()).chainId)!==11155111||Number((await cc.getNetwork()).chainId)!==102031)throw Error('Testnet chain guard');
const sw=new ethers.Wallet(env.DEPLOYER_PRIVATE_KEY,sep);
const cw=new ethers.Wallet(env.DEPLOYER_PRIVATE_KEY,cc);
for (const p of [sep,cc]) p.on('debug',e=>{ if(e.action==='sendRpcPayload') console.log('RPC', [e.payload].flat().map(x=>x.method).join(',')); });
console.log('Testnet balances',ethers.formatEther(await sep.getBalance(await sw.getAddress())),'ETH',ethers.formatEther(await cc.getBalance(await cw.getAddress())),'CTC');
mkdirSync(at('site/releases/v1'),{recursive:true});
for(const f of ['deployments.json','enclave.json']) if(!existsSync(at('site/releases/v1/'+f)))copyFileSync(at('site/'+f),at('site/releases/v1/'+f));
if(!existsSync(at('.env.pre-v2'))){copyFileSync(at('.env'),at('.env.pre-v2'));chmodSync(at('.env.pre-v2'),0o600);}
const path=at('site/release-v2.json');
let release=existsSync(path)?JSON.parse(readFileSync(path)): {version:2,createdAt:new Date().toISOString(),registry:env.ENCLAVE_REGISTRY_ADDRESS,decoder:env.DECODER_ADDRESS,transactions:{}};
const save=()=>writeFileSync(path,JSON.stringify(release,null,2)+'\n');
async function deploy(name,key,signer,args=[]){
 if(release[key])return release[key];
 const a=JSON.parse(readFileSync(at(`out/${name}.sol/${name}.json`)));
 let code=a.bytecode.object;
 for(const libs of Object.values(a.bytecode.linkReferences??{}))for(const offsets of Object.values(libs))for(const o of offsets){const start=2+o.start*2;code=code.slice(0,start)+env.DECODER_ADDRESS.slice(2)+code.slice(start+o.length*2);}
 console.log('Deploying',name);
 const c=await new ethers.ContractFactory(a.abi,code,signer).deploy(...args,{gasLimit:6000000});
 release.transactions[key]=c.deploymentTransaction().hash;release[key]=await c.getAddress();save();
 await c.waitForDeployment();console.log(key,release[key],release.transactions[key]);return release[key];
}
const escrow=await deploy('ComputeJobEscrow','sourceEscrow',sw);
const credit=await deploy('ComputeCredit','computeCredit',cw);
const settlement=await deploy('ComputeSettlement','settlement',cw,[Number(env.SOURCE_CHAIN_KEY??1),release.registry,credit,escrow]);
const c=new ethers.Contract(credit,['function minter() view returns(address)','function setMinter(address)'],cw);
if(await c.minter()===ethers.ZeroAddress){let tx=await c.setMinter(settlement);await tx.wait();release.transactions.minter=tx.hash;save();}
if((await c.minter()).toLowerCase()!==settlement.toLowerCase())throw Error('Minter mismatch');
const s=new ethers.Contract(settlement,['function SOURCE_ESCROW() view returns(address)','function SIGNING_DOMAIN() view returns(string)'],cc);
if((await s.SOURCE_ESCROW()).toLowerCase()!==escrow.toLowerCase()||await s.SIGNING_DOMAIN()!=='proofsettle.result.v2')throw Error('Deployment binding mismatch');
let text=readFileSync(at('.env'),'utf8');
for(const [key,value]of Object.entries({SOURCE_ESCROW_ADDRESS:escrow,COMPUTE_CREDIT_ADDRESS:credit,SETTLEMENT_ADDRESS:settlement})){const re=new RegExp('^'+key+'=.*$','m');text=re.test(text)?text.replace(re,key+'='+value):text+'\n'+key+'='+value+'\n';}
writeFileSync(at('.env'),text,{mode:0o600});
const d=JSON.parse(readFileSync(at('site/deployments.json')));Object.assign(d,{version:2,sourceEscrow:escrow,computeCredit:credit,settlement});writeFileSync(at('site/deployments.json'),JSON.stringify(d,null,2)+'\n');
console.log('Verified deployment wiring; addresses saved.');
