/** Cross-language fixtures from the real server: accepted, wrong model, missing input. */
import { spawn } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { seal } from './envelope.mjs';
import { keccak256, toHex } from './crypto.mjs';
const PORT=8099, chainId=102031, settlement='0x2Be9B8640ED32815d3B9e8C92AbcD3F15F07396f';
const child=spawn(process.execPath,['enclave/server.mjs'],{env:{...process.env,PORT:String(PORT),ATTESTATION_TOKEN_PATH:'/nonexistent',ATTESTATION_LAUNCHER_SOCKET:'/nonexistent'},stdio:'ignore'});
try {
 for(let i=0;i<50;i++){try{if((await fetch(`http://127.0.0.1:${PORT}/health`)).ok)break;}catch{}await new Promise(r=>setTimeout(r,100));}
 const id=await (await fetch(`http://127.0.0.1:${PORT}/identity`)).json();
 const plaintext=Buffer.from(JSON.stringify({months_of_history:6,inflows_per_month:14,inflow_regularity:0.75,avg_monthly_inflow_usd:300,balance_volatility:0.4,supplier_on_time_ratio:0.8,prior_loans_repaid:0,prior_loans_defaulted:0,_nonce:'test-fixture-only'}));
 const {envelope}=seal(Buffer.from(id.encryptionPublicKey.slice(2),'hex'),plaintext,Buffer.from('proofsettle.input.v1'));
 const base={modelHash:id.modelHash,inputHash:toHex(keccak256(plaintext)),ciphertext:toHex(envelope)};
 const cases=[{name:'accepted',...base},{name:'wrong model',...base,modelHash:'0x'+'ee'.repeat(32)},{name:'missing input',...base,ciphertext:undefined}];
 const jobs=[];
 for(const [i,job] of cases.entries()){
  const request={...job,jobId:'0x'+String(i+1).padStart(64,'0'),settlementAddress:settlement,chainId};
  const res=await fetch(`http://127.0.0.1:${PORT}/run`,{method:'POST',body:JSON.stringify(request)});
  if(!res.ok)throw new Error(await res.text());
  jobs.push({...request,...await res.json()});
 }
 writeFileSync('test/fixtures/enclave-signatures.json',JSON.stringify({chainId,settlement,signer:id.signer,attested:id.attested,jobs},null,2)+'\n');
 console.log('Wrote three fixtures from the real enclave server. No hardware attestation is claimed.');
}finally{child.kill();}
