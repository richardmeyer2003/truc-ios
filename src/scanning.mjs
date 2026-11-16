import { scanPayload, scanFeedback, miles, uidPattern } from './scan-contract.mjs';
import { createWalkScanning } from './walkathon.mjs';
import { scanAccess } from './scan-access.mjs';

const esc = value => String(value ?? '').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const button = (text,action,id='') => `<button type="button" class="btn" data-action="${action}" data-id="${esc(id)}">${text}</button>`;
const allowed = context => context?.year && scanAccess(context).run;

export function createScanning(plugin,isNative) {
  const walk = createWalkScanning(plugin,isNative);
  let scanMode = 'menu';
  let client, getContext, changed, course=null, latest=null, badge=null, runID=null, queue=[], processing=false, pending=null;
  let generation=0, count=0, error='', settingsOpen=false, opening=false, badgeSequence=0, pairing=false;
  let confirmed=new Set();
  const contextKey = c => `${c?.user?.id}/${c?.school?.id}/${c?.year?.id}/${c?.role}`;
  const validContext = key => key===contextKey(getContext()) && allowed(getContext());
  async function rpc(name,args) { const {data,error} = await client.rpc(name,args); if(error) throw error; return data; }
  async function report(feedback) { if(runID) await plugin.feedback({runID,...feedback}).catch(()=>{}); }
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
          await report({accepted:false,pending:true,title:'Lap unconfirmed',detail:'Reconnect and use Retry last scan.'});
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
    const c=getContext(),access=scanAccess(c);
    if(!access.run&&!access.walk)return '<section class="panel club-panel"><h2>Scanning is unavailable</h2><p>Ask your school Admin to check your access.</p></section>';
    if(scanMode==='menu'||(scanMode==='walk'?!access.walk:!access.run))return `<div class="scan-choices">
      ${access.run?'<button type="button" class="scan-choice" data-action="scan-mode-turc"><span><strong>Run Club</strong><small>QR badges and NFC stickers</small></span><span aria-hidden="true">›</span></button>':''}
      ${access.walk?'<button type="button" class="scan-choice" data-action="scan-mode-walk"><span><strong>Walk-a-thon</strong><small>Event bib QR codes</small></span><span aria-hidden="true">›</span></button>':''}</div>`;
    const back=`<div class="scan-back">${button('‹ Scan options','scan-mode-menu')}</div>`;
    if(scanMode==='walk') return back+walk.panel();
    if(!c.year)return `${back}<section class="panel club-panel"><h2>Run Club</h2><p>An active school year is required before recording laps.</p></section>`;
    return `${back}<section class="panel club-panel scanner-panel"><h2>Run Club</h2>
    ${course?.configured?`<h3 class="scan-course-name">${esc(course.name)}</h3>`:''}
    <p>${course?.configured ? `${miles(course.distance_mm)} miles per lap · ${course.cooldown_seconds} second minimum lap interval` : 'An Admin must enter the measured lap distance before scanning.'}</p>
    ${error ? `<div class="club-error" role="alert">${esc(error)}</div>` : ''}
    ${pending ? `<div class="notice">One scan is unconfirmed. Retry before scanning more. This pending result is kept only while this app stays open.</div><div class="club-actions">${button('Retry last scan','scan-retry')}${button('Discard pending retry','scan-discard')}</div>` : ''}
    <div class="scanner-actions">${isNative&&course?.configured&&!pending ? button('Open QR camera','scan-qr')+button('Scan NFC stickers','scan-nfc') : !isNative ? '<p>Camera and NFC scanning are available in the installed TURC app.</p>' : ''}</div>
    ${latest ? `<div class="scanner-result" data-result="${latest.accepted?'counted':'rejected'}" role="status"><h3>${esc(latest.title)}</h3>${latest.student?`<p><strong>${esc(latest.student)}</strong></p>`:''}<p>${esc(latest.detail)}</p></div>` : ''}
    <p class="club-note">${count} confirmed ${count===1?'lap':'laps'} on this device. An internet connection is required.</p>
    ${c.role==='admin' ? button(settingsOpen?'Hide course settings':'Course settings','scan-settings') : ''}
    ${settingsOpen&&c.role==='admin' ? `<form id="scan-course" class="scanner-settings"><label>Course name<input name="name" required maxlength="80" value="${esc(course?.name||'School loop')}"></label><label>Measured lap distance (meters)<input name="meters" type="number" required min="0.001" max="1000000" step="0.001" value="${esc(course?.distance_mm?course.distance_mm/1000:'')}"></label><label>Minimum lap interval (seconds)<input name="cooldown" type="number" required min="0" max="3600" step="1" value="${esc(course?.cooldown_seconds??30)}"></label><button type="submit" class="btn">Save course</button><p class="club-note">Changes apply to future laps. Earlier laps keep their captured distance.</p></form>` : ''}</section>`;
  }
  async function loadCourse() {
    const c=getContext(),key=contextKey(c); if(!allowed(c)) return;
    try { const result=await rpc('turc_scan_course',{p_school:c.school.id}); if(!validContext(key))return; course=result; error=''; }
    catch(e) { if(validContext(key)){course=null;error=e.message;} }
  }
  async function showBadge(id,replace=false) {
    const sequence=++badgeSequence;
    const c=getContext(),key=contextKey(c),student=c.students.find(s=>s.id===id);
    if(c.role!=='admin'||!student) throw Error('Admin access required.');
    const result=replace?null:await rpc('turc_badge_assignment',{p_student:id});
    if(!validContext(key)||sequence!==badgeSequence)return;
    const image=result?await plugin.qrImage({token:result.token}):null; if(!validContext(key)||sequence!==badgeSequence)return;
    badge=result?{...result,context:key}:null;
    const dialog=document.getElementById('club-dialog');
    dialog.innerHTML=`<h2 id="club-dialog-title">Badge</h2><p>${esc(student.first_name+' '+student.last_name)}</p>${result?`<img class="badge-qr" src="${esc(image.dataURL)}" alt="Student badge QR code"><p id="badge-status" class="club-note">Sticker ID <b>${esc(result.tag_uid)}</b></p><div class="club-actions">${button('Share printable badge','badge-print')}${button('Replace sticker…','badge-replace',id)}</div>`:`<p id="badge-status" class="club-note">${replace?'Scan an unassigned replacement sticker. The current badge works until the new sticker is saved.':'Scan an NTAG215 sticker to assign it and create the student’s QR badge.'}</p><div class="club-actions">${button('Scan NFC sticker','badge-scan-uid',id)}</div>`}<div class="modal-actions">${button('Back to student','detail',id)}${button('Done','close')}</div>`;
    if(!dialog.open)dialog.showModal();
  }
  return {
    configure(c,get,onChange) { client=c; getContext=get; changed=onChange;
      walk.configure(c,get,onChange);
      if(isNative) {
        plugin.addListener('scan',event=>receive(event).catch(()=>{}));
        plugin.addListener('closed',event=>{if(runID===event.runID)runID=null;});
      }
    }, panel,permissions:scanAccess,loadCourse,
    get openEvents(){return walk.openEvents;},
    get inScanMode(){return scanMode!=='menu';},
    get hasUnconfirmed(){return Boolean(pending||processing||walk.pending);},
    loadHome(){return walk.load({quiet:true});},
    async loadPanel(){if(scanMode==='walk'&&!walk.pending)await walk.load();else if(scanMode==='turc'){await loadCourse();changed(true);}},
    clearBadge() {badgeSequence++;badge=null;},
    reset() {generation++;badgeSequence++;queue=[];pending=null;badge=null;course=null;latest=null;count=0;confirmed=new Set();error='';settingsOpen=false;runID=null;walk.reset();scanMode='menu';if(isNative)plugin.close().catch(()=>{});},
    handles(name) {return ['scan-qr','scan-nfc','scan-settings','scan-retry','scan-discard','scan-mode-menu','scan-mode-turc','scan-mode-walk','walk-camera','walk-select','walk-load','walk-retry','badge','badge-replace','badge-replace-confirm','badge-scan-uid','badge-print'].includes(name);},
    async handle(name,id) {
      const c=getContext(),access=scanAccess(c);
      if(name.startsWith('scan-mode-')) {
        const next=name.slice('scan-mode-'.length);
        if((next==='turc'&&!access.run)||(next==='walk'&&!access.walk))throw Error('Scanning is unavailable for this account.');
        if(next===scanMode)return;
        if(pending||processing||walk.pending)throw Error('Finish or retry the last scan before switching modes.');
        scanMode=next;changed(true);
        if(next==='walk')await walk.load();else if(next==='turc')await loadCourse();
        changed(true);return;
      }
      if(name.startsWith('walk-')) {if(scanMode==='walk')await walk.handle(name,id);return;}
      if(!allowed(c))throw Error('Run Club requires scanning access and an active school year.');
      if(name==='scan-settings'){settingsOpen=!settingsOpen;changed(true);return;}
      if(name==='scan-retry'){if(pending){queue.push(pending);pending=null;await drain();changed();}return;}
      if(name==='scan-discard'){pending=null;error='Retry discarded. A server-committed lap remains recorded; refresh totals before rescanning.';changed();return;}
      if(name==='scan-qr'||name==='scan-nfc') {
        if(opening)return;
        if(!isNative||pending)throw Error('Resolve the pending scan first.');
        opening=true;
        const key=contextKey(c);
        try{await loadCourse(); if(!validContext(key))return; if(!course?.configured)throw Error('Ask an Admin to configure the course.');
          runID=crypto.randomUUID(); await plugin.open({runID,school:c.school.name,mode:name==='scan-nfc'?'nfc':'qr'});
          if(!validContext(key))await plugin.close();
        }finally{opening=false;}return;
      }
      if(!isNative)throw Error('Open the installed TURC app to manage QR and NFC badges.');
      if(name==='badge')return showBadge(id);
      if(name==='badge-replace'){
        const dialog=document.getElementById('club-dialog');dialog.innerHTML=`<h2>Replace this sticker?</h2><p>After you scan and assign a new sticker UID, the previous sticker and printed QR will stop working. Lap history stays intact. Print the updated badge after assignment.</p><div class="club-actions">${button('Scan replacement sticker','badge-replace-confirm',id)}${button('Cancel','badge',id)}</div>`;return;
      }
      if(name==='badge-replace-confirm')return showBadge(id,true);
      if(name==='badge-scan-uid'){
        if(pairing)return;if(c.role!=='admin')throw Error('Admin access required.');
        const key=contextKey(c),sequence=badgeSequence;pairing=true;
        try{
          const read=await plugin.readTagUID();if(!validContext(key)||sequence!==badgeSequence)return;
          const uid=String(read.uid||'').toUpperCase();if(read.tagType!=='NTAG215'||!uidPattern.test(uid))throw Error('A valid NTAG215 UID was not read.');
          await rpc('turc_assign_tag',{p_student:id,p_uid:uid,p_request:crypto.randomUUID()});
          if(!validContext(key)||sequence!==badgeSequence)return;await showBadge(id);
        }finally{pairing=false;}return;
      }
      if(!badge||badge.context!==contextKey(c)||c.role!=='admin')throw Error('Reopen the runner badge.');
      if(name==='badge-print'){await plugin.shareBadgePDF({...badge,grade:badge.grade||'',classroom:badge.classroom||''});return;}
    },
    async saveCourse(form) {
      const c=getContext(),key=contextKey(c); if(c.role!=='admin')throw Error('Admin access required.');
      const values=new FormData(form),mm=Math.round(Number(values.get('meters'))*1000),cooldown=Number(values.get('cooldown'));
      if(!Number.isSafeInteger(mm)||mm<1||mm>1000000000||!Number.isInteger(cooldown)||cooldown<0||cooldown>3600)throw Error('Enter a valid distance and whole-second lap interval.');
      const result=await rpc('turc_scan_course',{p_school:c.school.id,p_name:String(values.get('name')),p_distance:mm,p_cooldown:cooldown});
      if(!validContext(key))return;course=result;settingsOpen=false;error='';changed(true);
    },
    async totals(id) {return rpc('turc_runner_totals',{p_student:id});}
  };
}
