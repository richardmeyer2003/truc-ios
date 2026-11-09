const test=require('node:test');const assert=require('node:assert/strict');
const badge='turc:v1:'+'a'.repeat(64);
test('QR and NFC normalize to the same credential and retain event identity for retry',async()=>{
  const {scanPayload}=await import('../src/scan-contract.mjs');
  const event={value:badge,source:'qr',eventID:'11111111-1111-4111-8111-111111111111',observedAt:'2026-11-09T22:00:00Z'};
  const first=scanPayload(event,'school','device');
  assert.deepEqual(scanPayload(event,'school','device'),first);
  assert.equal(scanPayload({...event,source:'nfc'},'school','device').p_token,first.p_token);
  for(const value of ['https://example.com','000123','turc:v1:bad','<script>'])assert.throws(()=>scanPayload({...event,value},'school','device'));
});
test('feedback distinguishes accepted laps from cooldown and never claims rejection counted',async()=>{
  const {scanFeedback}=await import('../src/scan-contract.mjs');
  const ok=scanFeedback({accepted:true,name:'Maya Example',totals:{today_laps:2,today_mm:1609344,year_mm:3218688,lifetime_mm:4828032}});
  assert.equal(ok.title,'Maya Example · Lap 2');assert.match(ok.detail,/Today 1.00 mi · Year 2.00 mi · Lifetime 3.00 mi/);
  const no=scanFeedback({accepted:false,reason:'cooldown'});assert.equal(no.accepted,false);assert.equal(no.detail,'No lap added.');
});

async function harness(rpc) {
  const {createScanning}=await import('../src/scanning.mjs');
  const storage=new Map();global.localStorage={getItem:k=>storage.get(k),setItem:(k,v)=>storage.set(k,v)};
  const events={},feedback=[];let options;
  const plugin={addListener:async(name,fn)=>{events[name]=fn;},open:async o=>{options=o;},close:async()=>{},feedback:async f=>feedback.push(f)};
  let context={user:{id:'adult'},school:{id:'school',name:'Test school'},year:{id:'year'},role:'staff'};
  const scanner=createScanning(plugin,true);
  scanner.configure({rpc:async(name,args)=>name==='turc_scan_course'?{data:{configured:true,name:'Loop',distance_mm:100000,cooldown_seconds:30}}:rpc(name,args)},()=>context,()=>{});
  await scanner.handle('scan-qr');
  return {scanner,feedback,context:c=>{context=c;},scan:(id='11111111-1111-4111-8111-111111111111')=>events.scan({runID:options.runID,value:badge,source:'qr',eventID:id,observedAt:'2026-11-09T22:00:00Z'})};
}
test('uncertain transport result retries the identical event and counts its confirmation once',async()=>{
  const payloads=[];let attempts=0;
  const h=await harness(async(name,args)=>{payloads.push(args);if(++attempts===1)throw Error('Connection lost after commit');return {data:{accepted:true,replayed:true,name:'Maya',totals:{today_laps:1}}};});
  await h.scan();assert.match(h.scanner.panel(),/One scan is unconfirmed/);
  await h.scanner.handle('scan-retry');assert.deepEqual(payloads[0],payloads[1]);assert.match(h.scanner.panel(),/1 confirmed lap/);
});
test('live permission errors stop scanning without retaining a retry or privileged result',async()=>{
  const h=await harness(async()=>({error:{code:'42501',message:'Revoked'}}));
  await h.scan();assert.match(h.scanner.panel(),/Scanning access changed/);assert.doesNotMatch(h.scanner.panel(),/One scan is unconfirmed/);
});
test('sign-out or school change discards in-flight scan feedback',async()=>{
  let finish;const wait=new Promise(resolve=>finish=resolve);
  const h=await harness(async()=>{await wait;return {data:{accepted:true,name:'Private runner',totals:{today_laps:1}}};});
  const inFlight=h.scan();h.scanner.reset();h.context(null);finish();await inFlight;
  assert.deepEqual(h.feedback,[]);assert.doesNotMatch(h.scanner.panel(),/Private runner/);
});
