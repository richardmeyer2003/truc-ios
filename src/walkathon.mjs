import { scanAccess } from './scan-access.mjs';
import { scannerAppearance } from './scan-contract.mjs';

export const walkCodePattern = /^wt1:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const escape = value => String(value ?? '').replace(/[&<>"']/g, char => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'})[char]);
const action = (label, name, id = '') => `<button type="button" class="btn outline" data-action="${name}" data-id="${escape(id)}">${label}</button>`;

export function createWalkScanning(plugin, scannerAvailable) {
  let client, context, changed;
  let events = [], selected = null, runID = null, pending = null, feedback = null, nextScan = null;
  let generation = 0, sending = false, opening = false, loading = false, error = '', request = null;
  const scope = () => {
    const c = context();
    const access=scanAccess(c);
    return access.walk||access.leaderboard ? `${c.user.id}:${c.school.id}:${access.walk}:${access.leaderboard}` : null;
  };
  const active = (key, version) => key && key === scope() && version === generation;
  async function rpc(name, args) {
    const {data,error} = await client.rpc(`turc_walk_${name}`,args);
    if (error) throw error;
    return data;
  }
  function load({quiet=false}={}) {
    const key = scope(), version = generation;
    if (!key) return Promise.resolve();
    if (request?.key===key && request.version===version) return request.task;
    const before=JSON.stringify({events,error});
    loading = true; error = '';
    if (!quiet) changed(true);
    const task=(async()=>{
      try {
        const data = await rpc('events',{p_school:context().school.id});
        if (!active(key,version)) return;
        events = (data?.events||[]).filter(event=>event.status==='open');
        selected = events.find(event=>event.id===selected?.id) || (events.length===1?events[0]:null);
      } catch (failure) {
        if (!active(key,version)) return;
        events = []; selected = null;
        error = failure.code==='42501'?'Walk-a-thon access changed. Refresh your school.':'Could not load events. Check your connection and refresh.';
      } finally {
        if (request?.key===key&&request.version===version) request=null;
        if (active(key,version)) { loading = false; if(!quiet||before!==JSON.stringify({events,error})) changed(true); }
      }
    })();
    request={key,version,task};
    return task;
  }

  async function show(result) {
    feedback = result;
    if (runID) {
      try { await plugin.feedback({runID,...result}); } catch (_) { /* The sheet may have just closed. */ }
    }
  }

  async function submit(item) {
    if (sending || !scanAccess(context()).walk || !active(item.scope,item.generation)) return;
    sending = true;
    try {
      const result = await rpc('scan',item.payload);
      if (!active(item.scope,item.generation)) return;
      pending = null;
      if (result.accepted) await show({accepted:true,title:'Lap counted',student:result.name,detail:`${result.laps} event ${result.laps===1?'lap':'laps'}`});
      else if (result.reason==='too_soon') await show({accepted:false,title:'Too soon',detail:`${result.remaining_seconds}s remaining. Lap did not count.`});
      else if (result.reason==='event_not_open') {
        await show({accepted:false,title:'Scanning closed',detail:'This Walk-a-thon is no longer accepting laps.'});
        selected = null;
        if (runID) await plugin.close();
        await load();
      } else await show({accepted:false,title:'Bib not registered',detail:'Check that this bib belongs to the selected event.'});
    } catch (failure) {
      if (!active(item.scope,item.generation)) return;
      if (failure.code==='42501' || [401,403].includes(failure.status)) {
        pending = null; events = []; selected = null;
        await show({accepted:false,title:'Scanning access changed',detail:'Refresh your event list before scanning again.'});
      } else {
        pending = item;
        await show({accepted:false,pending:true,title:'Lap unconfirmed',detail:'Reconnect and use Retry last scan.'});
      }
      if (runID) { try { await plugin.close(); } catch (_) {} }
    } finally {
      sending = false;
      if (active(item.scope,item.generation)) changed(true);
      const next = nextScan;
      nextScan = null;
      if (next) receive(next);
    }
  }

  function receive(event) {
    const key = scope();
    if (!key || !scanAccess(context()).walk || !runID || event.runID!==runID || !selected || pending) return;
    // The native sheet can emit again as soon as it displays the previous result.
    if (sending) { nextScan=event; return; }
    if (event.source!=='qr' || !walkCodePattern.test(event.value)) {
      void show({accepted:false,title:'Use a Walk-a-thon bib',detail:'This scanner accepts Walk-a-thon QR codes.'}); return;
    }
    const payload = {p_event:selected.id,p_code:event.value,p_request:event.eventID};
    void submit({scope:key,generation,payload});
  }

  return {
    configure(api, getContext, onChange) {
      client = api; context = getContext; changed = onChange;
      if (scannerAvailable) {
        plugin.addListener('scan',receive);
        plugin.addListener('closed',event=>{ if (event.runID===runID) runID=null; });
      }
    },
    reset() { generation++; runID=null; pending=null; nextScan=null; events=[]; selected=null; feedback=null; error=''; loading=false; request=null; },
    load,
    get openEvents() { return events.slice(); },
    panel() {
      return `<section class="panel club-panel scanner-panel"><h2>Walk-a-thon</h2>
        <p>Scan the QR code on each event bib.</p>
        ${error?`<p class="club-error" role="alert">${escape(error)}</p>`:''}
        ${loading?'<p role="status">Loading events…</p>':events.length?'':'<p>No open Walk-a-thons for this school.</p>'}
        <div class="club-actions" aria-label="Open Walk-a-thon events">${events.map(event=>`<button type="button" class="btn ${event.id===selected?.id?'':'outline'}" aria-pressed="${event.id===selected?.id}" data-action="walk-select" data-id="${escape(event.id)}">${escape(event.name)}</button>`).join('')}</div>
        ${selected?`<p class="club-note">${escape(selected.name)} · ${selected.min_lap_seconds}s minimum lap time</p>`:''}
        ${pending?`<div class="notice">The last lap is unconfirmed. Retry before continuing.</div>${action('Retry last scan','walk-retry')}`:''}
        <div class="club-actions">${scannerAvailable&&selected&&!pending&&!loading?action('Scan Walk-a-thon QR','walk-camera'):''}${!pending?action('Refresh events','walk-load'):''}</div>
        ${feedback?`<div class="scanner-result" data-result="${feedback.accepted?'counted':'rejected'}" role="status"><h3>${escape(feedback.title)}</h3>${feedback.student?`<p><strong>${escape(feedback.student)}</strong></p>`:''}<p>${escape(feedback.detail)}</p></div>`:''}</section>`;
    },
    async handle(name, id) {
      if (!scope()||!scanAccess(context()).walk) throw Error('Walk-a-thon scanning is unavailable for this account.');
      if (opening) return;
      if (name==='walk-retry') { if (pending) await submit(pending); return; }
      if (pending || sending) throw Error('Finish or retry the last Walk-a-thon scan first.');
      if (name==='walk-load') return load();
      if (name==='walk-select') { selected=events.find(event=>event.id===id)||null; feedback=null; changed(true); return; }
      if (name!=='walk-camera' || opening || runID || !scannerAvailable || !selected) return;
      const key=scope(), version=generation, eventID=selected.id;
      opening = true;
      try {
        await load();
        if (!active(key,version) || selected?.id!==eventID) return;
        runID = crypto.randomUUID();
        try { await plugin.open({runID,school:selected.name,mode:'walkathon',...scannerAppearance()}); }
        catch (failure) { runID=null; throw failure; }
        if (!active(key,version)) await plugin.close();
      } finally { opening=false; }
    },
    get pending() { return Boolean(pending || sending); }
  };
}
