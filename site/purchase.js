/** Presentation for one real order. Status transitions are called only by the payment/readback code. */
export function createJourney() {
  const $=s=>document.querySelector(s);
  document.body.classList.add('purchase-page');
  document.title='ProofSettle — Start a private compute job';
  $('.hero .eyebrow').textContent='BUYER WORKSPACE · SEPOLIA + CREDITCOIN TESTNET';
  $('h1').innerHTML='Your order.<br><span class="hl">Private from start to answer.</span>';
  $('.hero .lede').textContent='Choose a synthetic applicant, approve one testnet payment, and follow your own order through private delivery and provider payout.';
  $('.journey-note').remove();
  const stepper=document.createElement('ol');stepper.className='order-stepper';stepper.setAttribute('aria-label','Purchase progress');stepper.innerHTML='<li data-order-step="1" aria-current="step"><b>1</b> Prepare order</li><li data-order-step="2"><b>2</b> Seal & pay</li><li data-order-step="3"><b>3</b> Track delivery</li>';
  $('.hero').after(stepper);
  const prepare=document.createElement('div');prepare.id='prepare-order';stepper.after(prepare);prepare.append($('#s1'),$('#s2'),$('#s3'));
  $('#s1 .snum').textContent='THE SERVICE';$('#s1 h2').textContent='Private applicant scoring';
  $('#s1 > p:not(.snum)').textContent='A deterministic model runs inside Google Confidential Space. The provider supplies the model and compute; you choose the input and acceptable build.';
  const badge=document.createElement('p');badge.id='service-status';badge.className='service-status';badge.setAttribute('role','status');badge.textContent='Checking the workload identity before enabling payment…';$('#s1 > p:not(.snum)').after(badge);
  const identity=document.createElement('details');identity.className='order-details';identity.innerHTML='<summary>Inspect the workload’s identity and encryption keys</summary>';$('#s1 .panel').before(identity);identity.append($('#s1 .panel'));
  $('#s2 .snum').textContent='YOUR INPUT';$('#s2 h2').textContent='Choose a synthetic applicant';
  $('#s2 > p:not(.snum)').textContent='These records are synthetic. A different applicant creates a different order. The model’s answer will be delivered privately to this browser.';
  const fields=document.createElement('details');fields.className='order-details';fields.innerHTML='<summary>Inspect or edit the applicant’s eight features</summary>';$('#fields').before(fields);fields.append($('#fields'),$('#input-hash').parentElement);
  $('#s3 .snum').textContent='YOUR REQUIREMENT';$('#s3 h2').textContent='Accept only the build you choose';
  $('#s3 > p:not(.snum)').textContent='The default is the currently attested build. Choosing a different build changes what the Creditcoin contract will accept, even when the payment is valid.';
  const review=document.createElement('button');review.id='review-order';review.className='btn btn-primary';review.textContent='Review order →';prepare.append(review);
  const pay=$('#s4');pay.hidden=true;$('#s4 .snum').textContent='REVIEW & APPROVE';$('#s4 h2').textContent='Seal the record and fund this order';
  $('#s4 > p:not(.snum)').textContent='Your browser seals the input before it leaves your device. The wallet transaction locks test ETH in escrow and records the requirements for this order.';
  const summary=document.createElement('div');summary.id='order-summary';summary.className='order-summary';pay.querySelector('.panel').prepend(summary);
  const commitments=document.createElement('details');commitments.className='order-details';commitments.innerHTML='<summary>Inspect the exact order commitments and contract</summary>';$('#pay-kv').before(commitments);commitments.append($('#pay-kv'));
  const warning=document.createElement('p');warning.className='order-warning';warning.id='order-warning';summary.after(warning);
  const back=document.createElement('button');back.className='btn btn-ghost';back.type='button';back.textContent='← Edit order';back.addEventListener('click',()=>go(1));$('#connect').before(back);
  $('#pay').textContent='Seal input & pay 0.001 test ETH';
  const keyNote=document.createElement('p');keyNote.className='micro';keyNote.textContent='Keep this browser profile: it holds the private answer key. A new order typically takes several minutes; network timing varies.';$('#pay-checks').after(keyNote);
  const track=$('#s5');track.hidden=true;$('#s5 .snum').textContent='YOUR ORDER';$('#s5 h2').textContent='From your payment to your private answer';
  $('#s5 > p:not(.snum):not(.note)').textContent='This page follows your actual transaction. You can return using this order’s link in the same browser; the answer key stays on this device.';
  const status=document.createElement('div');status.className='order-tracker';status.innerHTML='<div class="order-clock"><span id="order-reference">Awaiting payment</span><span id="order-elapsed"></span></div><h3 id="order-headline">Waiting for wallet approval</h3><p id="order-explanation">Approve the Sepolia transaction in your wallet to create this order.</p><div class="delivery-stages"><div data-stage="payment"><b>1</b><strong>Funded order</strong><small>Sepolia escrow</small></div><div data-stage="proof"><b>2</b><strong>Block attested</strong><small>Attestcoin → Creditcoin</small></div><div data-stage="answer"><b>3</b><strong>Private answer</strong><small>Signed delivery, opened here</small></div><div data-stage="payout"><b>4</b><strong>Provider paid</strong><small>Original Sepolia ETH</small></div></div><div id="order-links" class="order-links"></div>';
  track.querySelector('.panel').before(status);
  const audit=document.createElement('details');audit.className='order-details';audit.innerHTML='<summary>Inspect this order’s proof and delivery checks</summary>';$('#settle-checks').before(audit);audit.append($('#settle-checks'));audit.before($('#result'));
  const next=document.createElement('div');next.id='order-next';next.className='order-next';next.hidden=true;next.innerHTML='<a class="btn btn-primary" href="desk.html">Start another order</a><a class="btn btn-ghost" href="desk.html?mode=wrong-build">Test a different build</a><p class="micro">The refusal test makes a new 0.001 test-ETH payment. A refused order stays locked until its 30-day timeout refund.</p>';track.append(next);
  let step=1,started=0,complete=false,txHash='';
  function go(n){step=n;prepare.hidden=n!==1;pay.hidden=n!==2;track.hidden=n!==3;stepper.querySelectorAll('li').forEach((el,i)=>{if(i+1===n)el.setAttribute('aria-current','step');else el.removeAttribute('aria-current');el.classList.toggle('done',i+1<n)});stepper.scrollIntoView({behavior:matchMedia('(prefers-reduced-motion: reduce)').matches?'auto':'smooth',block:'start'});}
  review.addEventListener('click',()=>{if([...$('#fields').querySelectorAll('input')].every(e=>e.reportValidity()))go(2)});
  const timer=setInterval(()=>{if(!started||complete)return;const secs=Math.floor((Date.now()-started)/1000);$('#order-elapsed').textContent=`${Math.floor(secs/60)}m ${String(secs%60).padStart(2,'0')}s elapsed`;},1000);
  window.addEventListener('pagehide',()=>clearInterval(timer),{once:true});
  const link=(label,url)=>{if([...$('#order-links').querySelectorAll('a')].some(a=>a.href===url))return;const a=document.createElement('a');a.textContent=label+' ↗';a.href=url;a.target='_blank';a.rel='noopener';$('#order-links').append(a)};
  const progress=(stage,title,body)=>{if(step!==3)go(3);$('#order-headline').textContent=title;$('#order-explanation').textContent=body;const node=track.querySelector(`[data-stage="${stage}"]`);if(node)node.classList.add('complete');};
  return {
    review(state){
      const en=state.enclave;if(!en||!state.record)return;
      review.disabled=!state.requiredMeasurement||!/^0x[0-9a-f]{64}$/i.test(state.requiredMeasurement);
      summary.innerHTML='';for(const [label,value] of [['Service','Private applicant scoring'],['Model',en.modelName||'Published model'],['Required build',state.requiredMeasurement===en.measurement?en.build:'Different build — refusal expected'],['Input',`${state.record.months_of_history} months of history · ${state.record.inflows_per_month} inflows / month`],['Price','0.001 Sepolia test ETH + wallet gas'],['Delivery','Encrypted answer, opened only with this browser’s key']]){const row=document.createElement('div');const k=document.createElement('span');k.textContent=label;const v=document.createElement('strong');v.textContent=value;row.append(k,v);summary.append(row)}
      warning.textContent=state.requiredMeasurement!==en.measurement?'Refusal test: the serving enclave cannot satisfy this build. A real test payment will be locked and can be reclaimed after 30 days.':'Creditcoin authorizes the payment split only after both proofs pass. The fixed trusted return relayer releases the original ETH on Sepolia.';
    },
    identity(ok){badge.textContent=ok?'Workload identity verified · input encryption ready':'Workload verification needs attention · payment is blocked';badge.classList.toggle('ok',ok);if(!ok)identity.open=true;},
    approving(){go(3);progress(null,'Approve this order in your wallet.','Your record is sealed in this browser. Confirm the 0.001 Sepolia test-ETH payment and gas in the wallet popup.');},
    cancelled(){go(2);},
    sent(hash){txHash=hash;started=Date.now();go(3);$('#order-reference').textContent='Order '+hash.slice(0,10)+'…'+hash.slice(-6);progress(null,'Payment sent. Waiting for confirmation.','The wallet transaction has been submitted. This is your new order, not a saved example.');link('Your Sepolia payment','https://sepolia.etherscan.io/tx/'+hash);},
    resume(hash){this.sent(hash);$('#order-explanation').textContent='Resuming your existing order. Elapsed time starts from this page load. No new payment is being made.';},
    funded(block){progress('payment','Your order is funded. Waiting for Attestcoin.','Sepolia has recorded your payment and requirements. Attestcoin must attest this source block before Creditcoin can verify it. This can take several minutes.');},
    proven(){progress('proof','Payment block attested. Waiting for verified delivery.','Attestcoin has attested the payment block. The worker submits its proof and the enclave’s signed answer for Creditcoin to check together.');},
    settled(hash){if(hash)link('Your Creditcoin settlement','https://creditcoin-testnet.blockscout.com/tx/'+hash);},
    answer(){progress('answer','Your private answer has arrived.','The browser decrypted the delivered answer and matched it to the recorded result. Provider payout is checked separately below.');next.hidden=false;},
    paid(hash){progress('payout','Order complete. Answer delivered; provider paid.','Your browser opened the answer. Sepolia records the matching split and the provider’s ETH withdrawal. A fixed trusted return relayer carries out that return step.');if(hash)link('Provider ETH withdrawal','https://sepolia.etherscan.io/tx/'+hash);complete=true;next.hidden=false;},
    refused(r){if(!r.reason.startsWith('EnclaveNotAccepted')){progress(null,'Settlement transaction refused.',r.reason+' No successful settlement has been recorded for this order.');link('Your on-chain refusal','https://creditcoin-testnet.blockscout.com/tx/'+r.hash);audit.open=true;complete=true;next.hidden=false;return;}progress(null,'Order refused. Your build requirement was enforced.','The payment was valid, but the serving enclave did not match the build you required. Creditcoin refused settlement. The test ETH remains in escrow until the 30-day refund timeout.');track.classList.add('order-refused');link('Your on-chain refusal','https://creditcoin-testnet.blockscout.com/tx/'+r.hash);complete=true;next.hidden=false;},
    failed(message){progress(null,'Your order needs attention.',message+' Use the order link to resume; do not pay again for this order.');audit.open=true;},
    payoutPending(stopped=false){if(!complete)$('#order-explanation').textContent='The private answer is delivered. The trusted return relayer is still completing the original ETH payout; '+(stopped?'reload this order link to check again.':'this page will keep checking.');},
    declined(){progress('answer','The service could not complete this request.','The enclave signed a service refusal. Creditcoin authorized the buyer’s refund split; the original ETH return is a separate step.');next.hidden=false;}
  };
}
