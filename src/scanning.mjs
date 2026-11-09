import { scanPayload, scanFeedback, miles } from './scan-contract.mjs';

const esc = value => String(value ?? '').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const button = (text,action,id='') => `<button type="button" class="btn" data-action="${action}" data-id="${esc(id)}">${text}</button>`;
const allowed = context => context?.school && context?.year && ['admin','staff'].includes(context.role);

export function createScanning(plugin,isNative) {
  let client, getContext, changed, course=null, latest=null, badge=null, runID=null, queue=[], processing=false, pending=null;
  let generation=0, count=0, error='', settingsOpen=false, opening=false;
  let confirmed=new Set();
  const contextKey = c => `${c?.user?.id}/${c?.school?.id}/${c?.year?.id}/${c?.role}`;
  const validContext = key => key===contextKey(getContext()) && allowed(getContext());
  async function rpc(name,args) { const {data,error} = await client.rpc(name,args); if(error) throw error; return data; }
  async function report(feedback) { if(runID) await plugin.feedback({runID,...feedback}); }
  async function drain() {
    if(processing) return; processing=true;
    try {
      while(queue.length) {
        const item=queue.shift(); if(!validContext(item.context)||item.generation!==generation) continue;
        try {
          const result=await rpc('turc_submit_scan',item.payload);
          if(!validContext(item.context)||item.generation!==generation) continue;
          latest=scanFeedback(result); if(result.accepted&&!confirmed.has(item.payload.p_event)){count++;confirmed.add(item.payload.p_event);}
          error=''; await report(latest); changed();
        } catch(e) {
          if(!validContext(item.context)||item.generation!==generation) continue;
          if(e.code==='42501'||[401,403].includes(e.status)){
            pending=null;queue=[];latest=null;course=null;error='Scanning access changed. Refresh your club before continuing.';
            await plugin.close();runID=null;changed();break;
          }
          // Preserve the exact event for retry if the server may already have committed it.
          pending=item; queue=[];
          error='The lap is unconfirmed. Retry this scan to check its original result. Do not count it as accepted.';
          await report({accepted:false,title:'Lap unconfirmed',detail:'Reconnect, close the scanner, and use Retry last scan. The same event will not count twice.'});
          await plugin.close(); runID=null; changed(); break;
        }
      }
    } finally { processing=false; }
  }
  async function receive(event) {
    const c=getContext(); if(!allowed(c)||event.runID!==runID||pending) return;
    if(queue.length>=20) { await report({accepted:false,title:'Please pause scanning',detail:'The connection is catching up. This badge was not submitted; scan it again.'}); return; }
    let device=localStorage.getItem('turc-device-id');
    if(!device || !/^[a-f0-9-]{36}$/i.test(device)) { device=crypto.randomUUID(); localStorage.setItem('turc-device-id',device); }
    try { queue.push({payload:scanPayload(event,c.school.id,device),context:contextKey(c),generation}); await drain(); }
    catch { await report({accepted:false,title:'Not a TURC badge',detail:'No lap added.'}); }
  }
  function panel() {
    const c=getContext();
    if(!allowed(c)) return '<section class="panel club-panel"><h2>School scanning access required</h2><p>An Admin or Staff membership and active school year are required.</p></section>';
    return `<section class="welcome-card"><div><div class="eyebrow">EVERY LAP COUNTS</div><h2>Ready. Set. Keep moving.</h2><p>Scan QR badges with the native camera, or tap NTAG215 stickers with NFC. Both use your school’s shared lap records.</p></div></section>
    <section class="panel club-panel scanner-panel"><h2>${course?.configured ? esc(course.name) : 'Set up your course'}</h2>
    <p>${course?.configured ? `${miles(course.distance_mm)} miles per lap · ${course.cooldown_seconds} second minimum lap interval` : 'An Admin must enter the measured lap distance before scanning.'}</p>
    ${error ? `<div class="club-error" role="alert">${esc(error)}</div>` : ''}
    ${pending ? `<div class="notice">One scan is unconfirmed. Retry before scanning more. This pending result is kept only while this app stays open.</div><div class="club-actions">${button('Retry last scan','scan-retry')}${button('Discard pending retry','scan-discard')}</div>` : ''}
    <div class="scanner-actions">${isNative&&course?.configured&&!pending ? button('Open QR camera','scan-qr')+button('Scan NFC stickers','scan-nfc') : !isNative ? '<p>Camera and NFC scanning are available in the installed iPhone app.</p>' : ''}</div>
    ${latest ? `<div class="scanner-result" role="status"><h3>${esc(latest.title)}</h3><p>${esc(latest.detail)}</p></div>` : ''}
    <p class="club-note">${count} confirmed ${count===1?'lap':'laps'} in this scanner visit. Connection required. The first accepted lap opens today’s school session automatically.</p>
    <p class="club-note">QR stays open between runners. NFC uses iOS’s time-limited reader sheet; tap NFC again when it ends. Your signing method must support NFC Tag Reading.</p>
    ${c.role==='admin' ? button(settingsOpen?'Hide course settings':'Course settings','scan-settings') : ''}
    ${settingsOpen&&c.role==='admin' ? `<form id="scan-course" class="scanner-settings"><label>Course name<input name="name" required maxlength="80" value="${esc(course?.name||'School loop')}"></label><label>Measured lap distance (meters)<input name="meters" type="number" required min="0.001" max="1000000" step="0.001" value="${esc(course?.distance_mm?course.distance_mm/1000:'')}"></label><label>Minimum lap interval (seconds)<input name="cooldown" type="number" required min="0" max="3600" step="1" value="${esc(course?.cooldown_seconds??30)}"></label><button type="submit" class="btn">Save course</button><p class="club-note">Changes apply to future laps. Earlier laps keep their captured distance.</p></form>` : ''}</section>`;
  }
  async function loadCourse() {
    const c=getContext(),key=contextKey(c); if(!allowed(c)) return;
    try { const result=await rpc('turc_scan_course',{p_school:c.school.id}); if(!validContext(key))return; course=result; error=''; }
    catch(e) { if(validContext(key))error=e.message; }
  }
  async function showBadge(id,replace=false) {
    const c=getContext(),key=contextKey(c),student=c.students.find(s=>s.id===id);
    if(c.role!=='admin'||!student) throw Error('Admin access required.');
    const request=crypto.randomUUID();
    const result=await rpc('turc_runner_badge',{p_student:id,p_replace:replace,p_request:request});
    if(!validContext(key))return;
    const image=await plugin.qrImage({token:result.token}); if(!validContext(key))return;
    badge={...result,context:key};
    const dialog=document.getElementById('club-dialog');
    dialog.innerHTML=`<h2>${esc(student.first_name+' '+student.last_name)}</h2><p>QR and NFC use the same badge credential. Student details are not stored on the sticker.</p><img class="badge-qr" src="${image.dataURL}" alt="TURC runner QR badge"><p id="badge-status" class="club-note">${result.nfc_verified?'NFC write/read previously verified.':'QR is ready. NFC sticker has not been paired.'}</p><div class="club-actions">${button('Write / verify NFC sticker','badge-write')}${button('Share QR image','badge-share')}${button('Replace lost badge…','badge-replace',id)}${button('Close','close')}</div><p class="club-note">NFC writing replaces the presented sticker’s NDEF contents. Use an intended TURC sticker. Replacement disables both the old QR and NFC credential.</p>`;
    if(!dialog.open)dialog.showModal();
  }
  return {
    configure(c,get,onChange) { client=c; getContext=get; changed=onChange;
      if(isNative) {
        plugin.addListener('scan',event=>receive(event).catch(()=>{}));
        plugin.addListener('closed',event=>{if(runID===event.runID)runID=null;});
      }
    }, panel,loadCourse,
    reset() {generation++;queue=[];pending=null;badge=null;course=null;latest=null;count=0;confirmed=new Set();error='';settingsOpen=false;runID=null;if(isNative)plugin.close().catch(()=>{});},
    handles(name) {return ['scan-qr','scan-nfc','scan-settings','scan-retry','scan-discard','badge','badge-replace','badge-replace-confirm','badge-write','badge-share'].includes(name);},
    async handle(name,id) {
      const c=getContext(); if(!allowed(c)) throw Error('School scanning access required.');
      if(name==='scan-settings'){settingsOpen=!settingsOpen;changed();return;}
      if(name==='scan-retry'){if(pending){queue.push(pending);pending=null;await drain();changed();}return;}
      if(name==='scan-discard'){pending=null;error='Retry discarded. A server-committed lap remains recorded; refresh totals before rescanning.';changed();return;}
      if(name==='scan-qr'||name==='scan-nfc') {
        if(opening)return;
        if(!isNative||pending)throw Error('Resolve the pending scan first.');
        opening=true;
        try{await loadCourse(); if(!course?.configured)throw Error('Ask an Admin to configure the course.');
          runID=crypto.randomUUID(); await plugin.open({runID,school:c.school.name,mode:name==='scan-nfc'?'nfc':'qr'});
        }finally{opening=false;}return;
      }
      if(!isNative)throw Error('Open the installed iPhone app to manage QR and NFC badges.');
      if(name==='badge')return showBadge(id);
      if(name==='badge-replace'){
        const dialog=document.getElementById('club-dialog');dialog.innerHTML=`<h2>Replace this badge?</h2><p>The runner’s existing QR and NFC sticker will stop working. Their lap history stays intact. A replacement sticker must be written again.</p><div class="club-actions">${button('Replace badge','badge-replace-confirm',id)}${button('Cancel','badge',id)}</div>`;return;
      }
      if(name==='badge-replace-confirm')return showBadge(id,true);
      if(!badge||badge.context!==contextKey(c)||c.role!=='admin')throw Error('Reopen the runner badge.');
      if(name==='badge-share'){await plugin.shareQR({token:badge.token});return;}
      if(name==='badge-write'){
        const b=badge;const status=document.getElementById('badge-status');status.textContent='Hold the intended NTAG215 sticker near the top of your iPhone. Keep it still.';
        const result=await plugin.writeBadge({token:b.token});if(!validContext(b.context)||badge!==b)return;
        if(!result.verified)throw Error('The NFC write could not be verified.');
        await rpc('turc_confirm_nfc',{p_badge:b.id});if(!validContext(b.context))return;
        const node=document.getElementById('badge-status');if(node)node.textContent='NFC sticker written, read back, and paired successfully.';
      }
    },
    async saveCourse(form) {
      const c=getContext(),key=contextKey(c); if(c.role!=='admin')throw Error('Admin access required.');
      const values=new FormData(form),mm=Math.round(Number(values.get('meters'))*1000),cooldown=Number(values.get('cooldown'));
      if(!Number.isSafeInteger(mm)||mm<1||mm>1000000000||!Number.isInteger(cooldown)||cooldown<0||cooldown>3600)throw Error('Enter a valid distance and whole-second lap interval.');
      const result=await rpc('turc_scan_course',{p_school:c.school.id,p_name:String(values.get('name')),p_distance:mm,p_cooldown:cooldown});
      if(!validContext(key))return;course=result;settingsOpen=false;error='';changed();
    },
    async totals(id) {return rpc('turc_runner_totals',{p_student:id});}
  };
}
