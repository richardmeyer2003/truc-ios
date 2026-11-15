const assert = require('node:assert/strict');
const { test } = require('node:test');

const settle = () => new Promise(resolve=>setImmediate(resolve));
async function setup() {
  const { createWalkScanning } = await import('../src/walkathon.mjs');
  const handlers = new Map(), calls = [], results = [], feedback = [];
  const plugin = {
    addListener(name, listener) { handlers.set(name,listener); },
    async open(options) { this.options=options; },
    async close() { handlers.get('closed')({runID:this.options.runID}); },
    async feedback(result) { feedback.push(result); }
  };
  const scanner=createWalkScanning(plugin,true);
  const ctx={user:{id:'staff'},school:{id:'school'},role:'staff'};
  const open={id:'open-event',name:'Fictional Walk-a-thon',status:'open',min_lap_seconds:60};
  scanner.configure({async rpc(name,args) {
    if(name==='turc_walk_events')return {data:{events:[{...open,id:'draft',status:'draft'},open]}};
    calls.push({name,args});
    const next=results.shift(); if(next instanceof Error)throw next;
    return {data:next};
  }},()=>ctx,()=>{});
  await scanner.load();
  await scanner.handle('walk-camera');
  const bib={runID:plugin.options.runID,source:'qr',eventID:'scan-1',value:'wt1:00000000-0000-4000-8000-000000000001'};
  const emit=(event={})=>handlers.get('scan')({...bib,...event});
  return {scanner,plugin,ctx,calls,results,feedback,emit};
}

test('Walk-a-thon opens a QR-only run for an open event and uses its own lap endpoint',async()=>{
  const h=await setup();
  assert.equal(h.plugin.options.mode,'walkathon');
  h.emit({value:'turc:v1:'+'a'.repeat(64)});
  h.emit({source:'nfc'});
  assert.equal(h.calls.length,0);
  h.results.push({accepted:false,reason:'too_soon',remaining_seconds:32});h.emit();await settle();
  assert.deepEqual(h.calls.map(c=>[c.name,c.args.p_event,c.args.p_request]),[['turc_walk_scan','open-event','scan-1']]);
  assert.equal(h.feedback.at(-1).accepted,false);assert.match(h.feedback.at(-1).detail,/32s remaining/);
});

test('retry after a lost Walk-a-thon response sends the identical request',async()=>{
  const h=await setup();h.results.push(Error('Lost response'));h.emit();await settle();
  assert.equal(h.scanner.pending,true);assert.match(h.scanner.panel(),/Retry last scan/);
  h.results.push({accepted:true,name:'Sally S.',laps:2,replayed:true});await h.scanner.handle('walk-retry');
  assert.deepEqual(h.calls[0],h.calls[1]);assert.match(h.scanner.panel(),/Lap 2 counted/);assert.equal(h.scanner.pending,false);
});
