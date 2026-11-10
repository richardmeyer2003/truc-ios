const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname,'../web/club.js'),'utf8');
const flush = async () => { for (let i=0;i<5;i++) await new Promise(resolve=>setImmediate(resolve)); };

async function setup() {
  const handlers = {}, windowHandlers = {}, intervals = [], writes = [];
  const data = {
    turc_accounts:[{user_id:'user-1',display_name:'Fictional Admin',active:true}],
    turc_memberships:[{id:'m1',user_id:'user-1',district_id:'d1',school_id:'school-1',role:'admin',active:true}],
    turc_schools:[{id:'school-1',district_id:'d1',name:'Fictional School',timezone:'America/Los_Angeles',active:true}],
    turc_school_years:[{id:'year-1',school_id:'school-1',label:'2026–27',active:true,row_version:1}],
    turc_students:[{id:'student-1',school_id:'school-1',external_student_id:'0001',first_name:'Maya',last_name:'Example',active:true,row_version:1}],
    turc_enrollments:[{id:'e1',school_id:'school-1',school_year_id:'year-1',student_id:'student-1',grade:'3',classroom:'Parker',row_version:1}]
  };
  const user = {id:'user-1',email:'fixture@example.invalid'};
  const control = {getUserCalls:0,gate:null,networkError:false,progress:[{student_id:'student-1',year_mm:4828032}]};
  const root = { _html:'', attrs:{}, set innerHTML(html){this._html=html;writes.push(html);},get innerHTML(){return this._html;},
    setAttribute(name,value){this.attrs[name]=value;},querySelectorAll(){return [];},contains(){return false;} };
  const dialog = {open:false,innerHTML:'',close(){this.open=false;},showModal(){this.open=true;}};
  const sync = {textContent:''}, status = {textContent:'',hidden:true}, rosterBody = {innerHTML:''};
  const document = {hidden:false,activeElement:null,addEventListener(name,fn){handlers[name]=fn;},
    getElementById(id){return {'club-root':root,'club-dialog':dialog,'club-sync':sync,'club-status':status,'club-roster-body':rosterBody}[id] || null;}};
  function from(table) {
    const filters=[];
    const result = () => ({data:control.networkError && table==='turc_students' ? null : structuredClone(data[table].filter(row=>filters.every(([k,v])=>row[k]===v))),
      error:control.networkError && table==='turc_students' ? {message:'NetworkError',status:503} : null});
    const query = {select(){return this;},eq(k,v){filters.push([k,v]);return this;},order(){return this;},
      range(start,end){const r=result();return Promise.resolve({...r,data:r.data?.slice(start,end+1)});},
      then(resolve,reject){return Promise.resolve(result()).then(resolve,reject);}};
    return query;
  }
  let authChanged;
  const client = {from,rpc:async()=>({data:structuredClone(control.progress)}),auth:{getSession:async()=>({data:{session:{user}}}),getUser:async()=>{control.getUserCalls++;if(control.gate)await control.gate;return {data:{user}};},
    onAuthStateChange(fn){authChanged=fn;},signOut:async()=>{authChanged('SIGNED_OUT',null);return {};},stopAutoRefresh(){}}};
  const storage = new Map();
  const sandbox = {document,navigator:{onLine:true},console,Date,URL,Blob,TextDecoder,
    setTimeout(){return 1;},clearTimeout(){},setInterval(fn){intervals.push(fn);return 1;},
    sessionStorage:{getItem:k=>storage.get(k),setItem:(k,v)=>storage.set(k,v)},localStorage:{removeItem(){}},
    TURC_SUPABASE:{url:'https://example.invalid',publishableKey:'fixture'},supabase:{createClient:()=>client},
    scrollX:0,scrollY:0,scrollTo(x,y){this.scrollX=x;this.scrollY=y;},addEventListener(name,fn){windowHandlers[name]=fn;}};
  sandbox.window = sandbox;
  vm.runInNewContext(fs.readFileSync(path.join(__dirname,'../web/progress.js'),'utf8'),sandbox);
  vm.runInNewContext(source,sandbox,{filename:'club.js'});
  await flush();
  const click = async(action,extra={})=>{handlers.click({target:{closest:()=>({dataset:{action,...extra}})}});await flush();};
  const timer = async()=>{intervals[0]();await flush();};
  const focusInput = () => {document.activeElement={matches:()=>true};};
  return {data,user,control,root,dialog,sync,writes,handlers,windowHandlers,sandbox,click,timer,focusInput};
}

test('initial opening screen is allowed; unchanged timer and manual refresh never replace the page',async()=>{
  const h=await setup(); assert(h.writes.some(html=>html.includes('Opening your club…')));
  await h.click('tab',{tab:'roster'}); const before=h.writes.length;
  await h.timer(); await h.click('refresh');
  assert.equal(h.writes.length,before); assert.equal(h.root.attrs['aria-busy'],'false'); assert.match(h.sync.textContent,/Updated/);
});
test('changed data updates quietly, preserving tab, search and scroll',async()=>{
  const h=await setup(); await h.click('tab',{tab:'roster'});
  h.handlers.input({target:{id:'club-search',value:'Maya'}}); h.sandbox.scrollX=12;h.sandbox.scrollY=410;
  h.data.turc_enrollments[0].classroom='Reed';h.data.turc_enrollments[0].row_version++;
  const before=h.writes.length; await h.timer();
  assert.equal(h.writes.length,before+1); assert.match(h.root.innerHTML,/School roster/); assert.match(h.root.innerHTML,/value="Maya"/);
  assert.match(h.root.innerHTML,/Reed/);assert(!h.writes.at(-1).includes('Opening your club…'));
  assert.equal(h.sandbox.scrollX,12);assert.equal(h.sandbox.scrollY,410);
});
test('typing, an open edit dialog and import mapping defer scheduled refreshes',async()=>{
  const h=await setup();await h.click('tab',{tab:'roster'});h.focusInput();
  let before=h.control.getUserCalls;await h.timer();assert.equal(h.control.getUserCalls,before);
  h.sandbox.document.activeElement=null;await h.click('edit',{id:'student-1'});const draft=h.dialog.innerHTML;
  await h.timer();assert.equal(h.control.getUserCalls,before);assert.equal(h.dialog.innerHTML,draft);
  await h.click('close');await h.click('tab',{tab:'import'});await h.timer();assert.equal(h.control.getUserCalls,before);
});
test('opening an edit dialog while a refresh is in flight preserves the draft',async()=>{
  const h=await setup();let finish;h.control.gate=new Promise(r=>finish=r);
  await h.timer();await h.click('edit',{id:'student-1'});const draft=h.dialog.innerHTML,before=h.writes.length;
  h.data.turc_students[0].first_name='Remote change';finish();await flush();
  assert.equal(h.writes.length,before);assert(h.dialog.open);assert.equal(h.dialog.innerHTML,draft);
});
test('typing after a refresh starts also defers the arriving update',async()=>{
  const h=await setup();let finish;h.control.gate=new Promise(r=>finish=r);
  await h.timer();h.focusInput();const before=h.writes.length;h.data.turc_students[0].first_name='Remote change';finish();await flush();
  assert.equal(h.writes.length,before);
});
test('network errors retain the roster and report status without loading or root replacement',async()=>{
  const h=await setup();await h.click('tab',{tab:'roster'});const before=h.writes.length;
  h.control.networkError=true;await h.timer();assert.equal(h.writes.length,before);assert.match(h.root.innerHTML,/Maya/);assert.match(h.sync.textContent,/Update paused/);
  h.control.networkError=false;await h.timer();assert.equal(h.writes.length,before);assert.match(h.sync.textContent,/Updated/);
});
test('returning to a tab and reconnecting use the same quiet refresh',async()=>{
  const h=await setup();const before=h.writes.length;
  h.windowHandlers.online();await flush();h.handlers.visibilitychange();await flush();assert.equal(h.writes.length,before);
  h.sandbox.document.hidden=true;const calls=h.control.getUserCalls;h.handlers.visibilitychange();await h.timer();assert.equal(h.control.getUserCalls,calls);
});
test('overlapping timer/visibility refreshes are coalesced',async()=>{
  const h=await setup();let finish;h.control.gate=new Promise(r=>finish=r);const calls=h.control.getUserCalls;
  await h.timer();h.handlers.visibilitychange();await h.timer();assert.equal(h.control.getUserCalls,calls+1);finish();await flush();
});
test('signing out during a refresh cannot restore private data',async()=>{
  const h=await setup();let finish;h.control.gate=new Promise(r=>finish=r);
  await h.timer();await h.click('signout');finish();await flush();assert.match(h.root.innerHTML,/Sign in to your club/);assert(!h.root.innerHTML.includes('Maya'));
});
test('revoked access is applied even if typing begins during the request',async()=>{
  const h=await setup();let finish;h.control.gate=new Promise(r=>finish=r);await h.timer();h.focusInput();
  h.data.turc_memberships=[];finish();await flush();assert.match(h.root.innerHTML,/access is being set up/);assert(!h.root.innerHTML.includes('Maya'));
});
test('a downgraded role clears previous privileged data even if the roster request fails',async()=>{
  const h=await setup();await h.click('tab',{tab:'roster'});h.data.turc_memberships[0].role='staff';h.control.networkError=true;
  await h.timer();assert(!h.root.innerHTML.includes('Maya'));assert(!h.root.innerHTML.includes('Add runner'));assert.match(h.sync.textContent,/Update paused/);
});

test('school-year progress appears beside names and refreshes when mileage changes',async()=>{
  const h=await setup();await h.click('tab',{tab:'roster'});
  assert.match(h.root.innerHTML,/3.00 mi this year/);assert.match(h.root.innerHTML,/2.00 mi to 5 miles/);
  h.control.progress[0].year_mm=8046720;await h.timer();
  assert.match(h.root.innerHTML,/5.00 mi this year/);assert.match(h.root.innerHTML,/5.00 mi to 10 miles/);
  h.control.progress=[];await h.timer();assert.match(h.root.innerHTML,/Progress unavailable/);
  assert.doesNotMatch(h.root.innerHTML,/0.00 mi this year/);
});
