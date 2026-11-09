/* Connected TURC roster. Student data is held in memory, never in browser storage. */
(async function () {
  'use strict';
  const root = document.getElementById('club-root');
  const dialog = document.getElementById('club-dialog');
  const esc = v => String(v ?? '').replace(/[&<>"']/g, c => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' }[c]));
  const brand = '<svg viewBox="0 0 40 40" fill="none" aria-hidden="true"><rect x="1" y="1" width="38" height="38" rx="12" fill="currentColor"/><path d="M11 25 20 12l8 1-8 13-8 1m9-7h9" stroke="#e4edba" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/></svg><span>TURC</span>';
  const s = { user:null, account:null, memberships:[], schools:[], years:[], students:[], school:null, year:null, role:null,
    tab:'overview', loading:true, error:'', syncError:'', updated:null, parsed:null, mapping:null, preview:null, importErrors:[], fileName:'', search:'', busy:false };
  let epoch = 0, toastTimer, signInPending = false, refreshing = false, sessionRemovalPending = false;
  const action = (label, name, cls = '', extra = '') => `<button type="button" class="btn ${cls}" data-action="${name}" ${extra}>${label}</button>`;
  function message(text) { const el = document.getElementById('club-status'); el.textContent = text; el.hidden = false; clearTimeout(toastTimer); toastTimer = setTimeout(() => { el.hidden = true; }, 5500); }
  function errorText(error) {
    if (!navigator.onLine || /Failed to fetch|NetworkError|Load failed/i.test(error?.message || '')) return 'Connection unavailable. Your roster has not been changed. Reconnect and try again.';
    if (error?.code === '42501') return 'Your account does not have access to this operation. Refresh your club or contact your administrator.';
    if (error?.code === '40001') return 'The roster or school year changed after your preview. Refresh and create a new preview.';
    if (/Invalid login credentials/i.test(error?.message || '')) return 'Email or password was not recognized. Use your TURC app account, which is separate from the Supabase dashboard.';
    return error?.message || 'Something went wrong. Please try again.';
  }
  function roleFor(school, memberships = s.memberships, user = s.user) {
    const own = memberships.filter(m => m.user_id === user.id && m.active);
    if (own.some(m => m.role === 'admin' && (m.school_id === school.id || (!m.school_id && m.district_id === school.district_id)))) return 'admin';
    if (own.some(m => m.role === 'staff' && m.school_id === school.id)) return 'staff';
    if (own.some(m => m.role === 'parent' && m.school_id === school.id)) return 'parent';
    return null;
  }
  function resetImport() { s.parsed = null; s.mapping = null; s.preview = null; s.importErrors = []; s.fileName = ''; }
  function clearPrivateState() {
    window.TURC_SCANNER?.reset();
    epoch++; Object.assign(s, { user:null, account:null, memberships:[], schools:[], years:[], students:[], school:null, year:null, role:null,
      tab:'overview', loading:false, error:'', syncError:'', updated:null, search:'', busy:false }); resetImport();
    if (dialog.open) dialog.close(); dialog.innerHTML = '';
  }
  const platform = window.TURC_PLATFORM;
  try {
    if (window.Capacitor?.isNativePlatform?.() && !platform) throw Error('Secure sign-in could not load. Please reinstall the latest TURC build.');
    if (platform) await platform.ready();
  }
  catch (error) { s.loading = false; s.error = errorText(error); render(); return; }
  const config = window.TURC_SUPABASE;
  if (!window.supabase || !config?.url || !config?.publishableKey) {
    s.loading = false; s.error = 'The club connection could not load. Refresh this page or contact your administrator.'; render(); return;
  }
  const client = window.supabase.createClient(config.url, config.publishableKey, {
    auth: { storageKey:'turc-auth-v1', persistSession:true, autoRefreshToken:true, detectSessionInUrl:false,
      ...(platform?.authStorage ? {storage:platform.authStorage} : {}) }
  });
  platform?.attachClient(client).catch(() => message('Automatic reconnect paused. Use Refresh to update your roster.'));
  window.TURC_SCANNER?.configure(client,()=>s,(force=false)=>{ if(s.tab==='scanner'&&(force||canRefresh()))renderQuietly(); });
  async function rows(queryFactory) {
    let result = [], start = 0;
    while (true) {
      const { data, error } = await queryFactory().range(start, start + 999);
      if (error) throw error; result = result.concat(data || []);
      if (!data || data.length < 1000) return result;
      start += 1000;
    }
  }
  async function activate(session) {
    if (!session) { clearPrivateState(); render(); return; }
    const firstOpen = !s.user, token = ++epoch; s.loading = true; s.error = ''; s.syncError = ''; render();
    try {
      const { data: verified, error: authError } = await client.auth.getUser(); if (authError) throw authError;
      if (token !== epoch) return; s.user = verified.user;
      const [accounts, memberships, schools] = await Promise.all([
        client.from('turc_accounts').select('user_id,display_name,active').eq('user_id',s.user.id),
        rows(() => client.from('turc_memberships').select('id,user_id,district_id,school_id,role,active').eq('user_id',s.user.id).order('id')),
        rows(() => client.from('turc_schools').select('id,district_id,name,timezone,active').order('name').order('id'))
      ]);
      if (accounts.error) throw accounts.error;
      if (token !== epoch) return;
      s.account = accounts.data?.[0] || null; s.memberships = memberships;
      s.schools = schools.filter(school => roleFor(school));
      const previous = s.school?.id || sessionStorage.getItem('turc-school');
      s.school = s.schools.find(x => x.id === previous) || s.schools[0] || null;
      s.students = []; s.year = null; s.years = []; s.role = s.school ? roleFor(s.school) : null;
      if (s.school) await fetchRoster(token);
      if (token !== epoch) return; s.loading = false; render(); if (firstOpen) window.scrollTo(0,0);
    } catch (error) { if (token !== epoch) return; s.loading = false; s.students = []; s.error = errorText(error); render(); }
  }
  async function readRoster(school) {
    const years = await rows(() => client.from('turc_school_years').select('id,school_id,label,active,row_version').eq('school_id',school.id).order('starts_on',{ascending:false}).order('id'));
    const year = years.find(y => y.active) || null;
    const [students, enrollments] = await Promise.all([
      rows(() => client.from('turc_students').select('id,school_id,external_student_id,first_name,last_name,active,row_version').eq('school_id',school.id).order('last_name').order('id')),
      year ? rows(() => client.from('turc_enrollments').select('id,student_id,grade,classroom,row_version').eq('school_id',school.id).eq('school_year_id',year.id).order('id')) : []
    ]);
    const byId = new Map(enrollments.map(x => [x.student_id,x]));
    return { years, year, students:students.map(x => ({ ...x, enrollment:byId.get(x.id) || null })) };
  }
  async function fetchRoster(token) {
    const school = s.school, roster = await readRoster(school);
    if (token !== epoch) return;
    Object.assign(s,roster); s.updated = new Date();
    sessionStorage.setItem('turc-school',school.id);
  }
  function canRefresh() {
    return !s.busy && !s.loading && !dialog.open && s.tab !== 'import'
      && !document.activeElement?.matches('input,textarea,select,[contenteditable="true"]');
  }
  function syncText() {
    if (s.syncError) return 'Update paused · Showing your last loaded roster. Refresh to retry.';
    return `${s.updated ? 'Updated '+s.updated.toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'})+' · ' : ''}${navigator.onLine ? 'Online' : 'Offline'}`;
  }
  function updateSyncStatus() {
    const status = document.getElementById('club-sync'); if (status) status.textContent = syncText();
  }
  function renderQuietly() {
    const x = window.scrollX, y = window.scrollY, focused = document.activeElement;
    const focus = focused && root.contains(focused) ? {id:focused.id, action:focused.dataset?.action, record:focused.dataset?.id, tab:focused.dataset?.tab} : null;
    const scroll = Array.from(root.querySelectorAll('.table-wrap')).map(el => ({left:el.scrollLeft,top:el.scrollTop}));
    render();
    root.querySelectorAll('.table-wrap').forEach((el,i) => { if (scroll[i]) { el.scrollLeft = scroll[i].left; el.scrollTop = scroll[i].top; } });
    const target = focus?.id ? document.getElementById(focus.id) : focus?.action
      ? Array.from(root.querySelectorAll('[data-action]')).find(el => el.dataset.action === focus.action && el.dataset.id === focus.record && el.dataset.tab === focus.tab) : null;
    target?.focus({preventScroll:true}); window.scrollTo(x,y);
  }
  async function refresh({ background = false } = {}) {
    if (!s.user || refreshing || !canRefresh()) return;
    // Read into a snapshot; a failed refresh must not clear the displayed roster.
    const token = epoch; refreshing = true;
    try {
      const {data:verified,error:authError} = await client.auth.getUser(); if (authError) throw authError;
      if (token !== epoch) return;
      if (!verified.user || verified.user.id !== s.user.id) { clearPrivateState(); render(); return; }
      const [accounts,memberships,allSchools] = await Promise.all([
        client.from('turc_accounts').select('user_id,display_name,active').eq('user_id',verified.user.id),
        rows(() => client.from('turc_memberships').select('id,user_id,district_id,school_id,role,active').eq('user_id',verified.user.id).order('id')),
        rows(() => client.from('turc_schools').select('id,district_id,name,timezone,active').order('name').order('id'))
      ]);
      if (accounts.error) throw accounts.error;
      if (token !== epoch) return;
      const account = accounts.data?.[0] || null;
      const schools = allSchools.filter(school => roleFor(school,memberships,verified.user));
      const school = schools.find(x => x.id === s.school?.id) || schools[0] || null;
      const role = school ? roleFor(school,memberships,verified.user) : null;
      const scopeChanged = school?.id !== s.school?.id || role !== s.role || !account;
      if (scopeChanged) {
        window.TURC_SCANNER?.reset();
        resetImport(); s.search = ''; if (dialog.open) dialog.close(); dialog.innerHTML = '';
        Object.assign(s,{user:verified.user,account,memberships,schools,school,role,years:[],year:null,students:[]});
        renderQuietly();
      }
      const roster = account && school ? await readRoster(school) : {years:[],year:null,students:[]};
      if (token !== epoch) return;
      // A form/dialog may have opened while the network request was in flight.
      // Scope revocation is applied immediately; ordinary updates wait.
      if (!scopeChanged && !canRefresh()) return;
      const next = {user:verified.user,account,memberships,schools,school,role,...roster};
      const visible = value => JSON.stringify({account:value.account,schools:value.schools,school:value.school,role:value.role,
        years:value.years,year:value.year,students:value.students});
      const changed = visible(next) !== visible(s);
      Object.assign(s,next); s.updated = new Date(); s.syncError = '';
      if (school) sessionStorage.setItem('turc-school',school.id);
      if (changed || scopeChanged) renderQuietly(); else updateSyncStatus();
    } catch (error) {
      if (token !== epoch) return;
      if ([401,403].includes(error?.status) || error?.code === '42501' || error?.name === 'AuthSessionMissingError') {
        clearPrivateState(); s.error = 'Your access changed or your session expired. Sign in again to continue.'; render();
      } else {
        s.syncError = errorText(error); updateSyncStatus(); if (!background) message(s.syncError);
      }
    } finally { refreshing = false; }
  }
  function renderAuth() {
    root.innerHTML = `<main class="club-auth"><a class="club-brand" href="/">${brand}</a><section class="panel"><div class="eyebrow">YOUR SCHOOL CLUBHOUSE</div>
      <h1>A little movement.<br>A shared beginning.</h1><p>Sign in to your school’s connected roster. Your runners stay with your club, across devices.</p>
      ${s.error ? `<div class="club-error" role="alert">${esc(s.error)}</div>` : ''}
      ${sessionRemovalPending ? `<div class="club-actions">${action('Retry sign-out','signout','outline')}</div>` : ''}
      <form id="club-login"><label>Email address<input name="email" type="email" autocomplete="username" required maxlength="254"></label>
      <label>Password<input name="password" type="password" autocomplete="current-password" required></label><button class="btn" type="submit">Sign in to your club →</button></form>
      <div class="club-note">Use the TURC account created by your administrator. Supabase and GitHub dashboard accounts do not automatically sign you into TURC.</div></section>
      <div class="club-auth-footer"><a data-website href="https://turc-school-run-club.richer2003.chatgpt.site/club" target="_blank" rel="noopener noreferrer">Open TURC website ↗</a></div><div class="club-note">Proof of concept · Fictional student records only.</div></main>`;
  }
  function render() {
    root.setAttribute('aria-busy',String(s.loading));
    if (s.loading) { root.innerHTML = `<main class="club-auth"><a class="club-brand" href="/">${brand}</a><section class="panel club-progress"><h1>Opening your club…</h1><p>Loading your authorized school roster.</p></section></main>`; return; }
    if (!s.user) { renderAuth(); return; }
    if (!s.account || !s.school) {
      root.innerHTML = `<main class="club-auth"><a class="club-brand" href="/">${brand}</a><section class="panel"><div class="eyebrow">YOU’RE SIGNED IN</div><h1>Your club access is being set up.</h1>
        <p>${esc(s.user.email)} is signed in, but no active school membership is available. Your administrator needs to assign your school and role.</p>
        ${s.error ? `<div class="club-error" role="alert">${esc(s.error)}</div>` : ''}<div class="club-actions">${action('Check my access','refresh')}${action('Sign out','signout','outline')}</div></section></main>`; return;
    }
    if (s.role !== 'admin' && s.tab === 'import') s.tab = 'roster';
    if (!['admin','staff'].includes(s.role) && s.tab === 'scanner') s.tab = 'roster';
    const tabs = [['overview',s.role === 'parent' ? 'My club' : 'Overview'],['roster',s.role === 'parent' ? 'My runners' : 'Runners'],...(['admin','staff'].includes(s.role) ? [['scanner','Scan']] : []),...(s.role === 'admin' ? [['import','Import']] : []),['account','Account']];
    root.innerHTML = `<div class="club-layout"><header class="club-header"><a class="club-brand" href="/">${brand}</a><div class="club-account"><div><b>${esc(s.account.display_name)}</b><small>${s.role === 'admin' ? 'Administrator' : s.role === 'staff' ? 'School staff' : 'Parent / family'}</small></div>${action('Sign out','signout','outline')}</div></header>
      <div class="club-context"><div><div class="eyebrow">EVERY RUNNER BELONGS</div><h1>${s.tab === 'roster' ? (s.role === 'parent' ? 'Your little runners.' : 'A place for every runner.') : s.tab === 'import' ? 'A fresh start, together.' : s.tab === 'account' ? 'Your club. Your account.' : 'Welcome to your club.'}</h1><p>${esc(s.school.name)} · ${s.year ? esc(s.year.label) : 'No active school year'}</p></div>
      <label>School<select id="club-school" aria-label="School">${s.schools.map(x => `<option value="${esc(x.id)}" ${x.id === s.school.id ? 'selected' : ''}>${esc(x.name)}</option>`).join('')}</select></label></div>
      <nav class="club-tabs" aria-label="Club navigation">${tabs.map(([id,label]) => `<button class="club-tab" data-action="tab" data-tab="${id}" ${s.tab === id ? 'aria-current="page"' : ''}>${label}</button>`).join('')}</nav>
      ${s.error ? `<div class="club-error" role="alert">${esc(s.error)}</div>` : ''}${s.tab === 'overview' ? overview() : s.tab === 'roster' ? roster() : s.tab === 'import' ? importView() : s.tab === 'scanner' ? (window.TURC_SCANNER?.panel() || '') : accountView()}
      <footer class="club-footer"><span>Connected prototype · Fictional students only<br>Native QR + NFC scanning · Shared school lap records.</span><span><span id="club-sync" role="status">${esc(syncText())}</span> ${action('Refresh','refresh','outline')}</span></footer></div>`;
    if (s.busy) root.querySelectorAll('button,input,select').forEach(el => { el.disabled = true; });
  }
  function overview() {
    const active = s.students.filter(x => x.active).length, classrooms = new Set(s.students.map(x => x.enrollment?.classroom).filter(Boolean)).size;
    return `<section class="welcome-card"><div><div class="eyebrow">A SCHOOL OF POSSIBILITIES</div><h2>${s.role === 'parent' ? 'Every little step has a cheering section.' : 'Your runners, one shared roster.'}</h2><p>${s.role === 'admin' ? 'Bring your fictional school roster into the club. Review changes before anything is saved.' : s.role === 'parent' ? 'See the runners linked to your account. Their school history stays together.' : 'Your assigned school’s active runners are ready to view on this device.'}</p></div>${action(s.role === 'admin' ? 'Import your roster →' : 'Meet your runners →',s.role === 'admin' ? 'open-import' : 'open-roster','light')}</section>
      <div class="club-stats"><section class="stat"><div class="stat-label">${s.role === 'parent' ? 'Linked runners' : 'Active runners'}</div><strong>${active}</strong><small>From your shared school roster</small></section><section class="stat"><div class="stat-label">Classrooms</div><strong>${classrooms}</strong><small>In the active school year</small></section><section class="stat"><div class="stat-label">School year</div><strong style="font-size:25px">${s.year ? esc(s.year.label) : 'Not set'}</strong><small>Year-specific enrollment records</small></section></div>
      <section class="panel club-panel"><h2>One club, across your devices.</h2><p>Roster changes are saved centrally. Open TURC on another device with the same account to see the same runners.</p><div class="notice">This milestone connects accounts and student rosters. Badge pairing, lap scanning, mileage, and awards have not been connected yet.</div></section>`;
  }
  function rosterRows() {
    const q = s.search.toLowerCase(); const list = s.students.filter(x => [x.first_name,x.last_name,x.external_student_id,x.enrollment?.grade,x.enrollment?.classroom].join(' ').toLowerCase().includes(q));
    return list.map(x => `<tr><td><div class="club-person"><span class="avatar">${esc(x.first_name[0]+x.last_name[0])}</span><div><b>${esc(x.first_name+' '+x.last_name)}</b><small>${esc(x.external_student_id)}</small></div></div></td><td>${esc(x.enrollment?.grade || '—')}</td><td>${esc(x.enrollment?.classroom || '—')}</td><td><span class="chip ${x.active ? '' : 'gray'}">${x.active ? 'Active' : 'Archived'}</span></td><td>${action('View','detail','outline',`data-id="${esc(x.id)}"`)}</td></tr>`).join('') || '<tr><td colspan="5" class="club-empty">No runners match this search.</td></tr>';
  }
  function roster() {
    return `<section class="panel club-panel"><div class="club-section-title"><div><h2>${s.role === 'parent' ? 'Your runners' : 'School roster'}</h2><p class="club-note">${s.role === 'parent' ? 'Only children linked to your account appear here.' : 'Student IDs stay consistent as runners move through school years.'}</p></div>${s.role === 'admin' ? `<div class="club-actions">${action('Add runner','add')}${action('Export CSV','export','outline')}</div>` : ''}</div>
      <div class="toolbar"><input id="club-search" class="search" aria-label="Search runners" placeholder="Search runners or classrooms" value="${esc(s.search)}"><div class="club-counter">${s.students.length} authorized runner${s.students.length === 1 ? '' : 's'}</div></div>
      ${s.students.length ? `<div class="table-wrap"><table class="club-table club-roster-table"><thead><tr><th>RUNNER / ID</th><th>GRADE</th><th>CLASSROOM</th><th>STATUS</th><th></th></tr></thead><tbody id="club-roster-body">${rosterRows()}</tbody></table></div>` : `<div class="club-empty"><h2>${s.role === 'parent' ? 'A runner to cheer for.' : 'Your first runners start here.'}</h2><p>${s.role === 'parent' ? 'Ask your school administrator to link your fictional child’s profile.' : 'No student records are available for this school yet.'}</p>${s.role === 'admin' ? action('Import a fictional roster','open-import') : ''}</div>`}</section>`;
  }
  function importView() {
    if (!s.year) return '<section class="panel club-panel"><h2>Set up your school year first.</h2><p>An active school year is required before importing students. Ask your administrator to complete school setup.</p></section>';
    const fields = [['student_id','Student ID *'],['first_name','First name *'],['last_name','Last name *'],['grade','Grade'],['classroom','Classroom / teacher']];
    let body = `<div class="club-upload"><label for="club-file">Choose your fictional student CSV</label><input id="club-file" type="file" accept=".csv,text/csv"><p class="club-note">Up to 1,000 students · 1 MB maximum · Student ID, First Name, Last Name required</p></div>${action('Download example CSV','sample','outline')}`;
    if (s.parsed && !s.preview) body = `<div class="club-summary"><span class="chip">${esc(s.fileName)}</span><span class="chip">${s.parsed.rows.length} students</span></div><h2>Match your columns.</h2><p>Required fields are marked *. Unmapped optional fields keep their existing values. Mapped blank values clear that optional field.</p>
      <form id="club-map"><div class="club-field-grid club-mapping" style="margin:22px 0">${fields.map(([key,label]) => `<label>${label}<select name="${key}" aria-label="Map ${label.replace(' *','')}"><option value="">${key === 'grade' || key === 'classroom' ? 'Leave unchanged' : 'Choose a column'}</option>${s.parsed.headers.map((h,i) => `<option value="${i}" ${s.mapping[key] === String(i) ? 'selected' : ''}>${esc(h)}</option>`).join('')}</select></label>`).join('')}</div><div class="club-actions"><button type="submit" class="btn">Review import →</button>${action('Choose another file','reset-import','outline')}</div></form>`;
    if (s.preview) body = `<div class="notice">Nothing has been saved yet. Confirming applies these changes to ${esc(s.school.name)} for ${esc(s.year.label)}. Students missing from this file are kept.</div><div class="club-summary"><span class="chip">${s.preview.summary.new} new</span><span class="chip">${s.preview.summary.updated} updates</span><span class="chip">${s.preview.summary.unchanged} unchanged</span></div>
      <div class="table-wrap"><table class="club-table"><thead><tr><th>CHANGE</th><th>STUDENT ID</th><th>NAME</th><th>GRADE</th><th>CLASSROOM</th></tr></thead><tbody>${s.preview.rows.slice(0,100).map(r => `<tr><td><span class="chip">${esc(r.action)}</span></td><td>${esc(r.values.student_id)}</td><td>${esc(r.values.first_name+' '+r.values.last_name)}</td><td>${'grade' in r.values ? esc(r.values.grade || 'Clear') : 'Keep existing'}</td><td>${'classroom' in r.values ? esc(r.values.classroom || 'Clear') : 'Keep existing'}</td></tr>`).join('')}</tbody></table></div><p class="club-note">${s.preview.rows.length > 100 ? 'Showing the first 100 rows. All '+s.preview.rows.length+' rows will be imported. ' : ''}Preview expires after 30 minutes. A changed roster requires a new preview.</p><div class="club-actions">${action('Confirm import','commit')}${action('Cancel preview','reset-import','outline')}</div>`;
    const errors = s.importErrors.length ? `<div class="club-error" role="alert"><b>No students were imported.</b><ul>${s.importErrors.slice(0,25).map(e => `<li>Row ${esc(e.row)}: ${esc(e.message)}</li>`).join('')}</ul>${s.importErrors.length > 25 ? `${s.importErrors.length-25} more errors. Correct the file and try again.` : ''}</div>` : '';
    return `<section class="panel club-panel"><h2>${s.preview ? 'A final look before they join.' : 'Bring your school together.'}</h2><p>Preview your roster, check the details, then save it to your shared club.</p>${errors}${body}</section>`;
  }
  function accountView() {
    return `<section class="panel club-panel"><h2>${esc(s.account.display_name)}</h2><dl class="club-detail"><div><dt>Email</dt><dd>${esc(s.user.email)}</dd></div><div><dt>Role</dt><dd>${esc(s.role)}</dd></div><div><dt>School</dt><dd>${esc(s.school.name)}</dd></div><div><dt>School timezone</dt><dd>${esc(s.school.timezone)}</dd></div></dl><p>Access is assigned by your administrator and checked by the shared database. A school or role cannot be claimed by changing this page.</p><div class="notice">This is a proof of concept. Only upload fictional student information.</div>${action('Sign out of this device','signout','outline')}</section>`;
  }
  async function runnerDetail(id) {
    window.TURC_SCANNER?.clearBadge();
    const x = s.students.find(r => r.id === id); if (!x) return;
    const token=epoch;
    dialog.innerHTML = `<h2>${esc(x.first_name+' '+x.last_name)}</h2><dl class="club-detail"><div><dt>Student ID</dt><dd>${esc(x.external_student_id)}</dd></div><div><dt>School year</dt><dd>${esc(s.year?.label || 'Not set')}</dd></div><div><dt>Grade</dt><dd>${esc(x.enrollment?.grade || 'Not set')}</dd></div><div><dt>Classroom</dt><dd>${esc(x.enrollment?.classroom || 'Not set')}</dd></div></dl><p id="runner-totals">Loading saved lap totals…</p><div class="modal-actions">${s.role === 'admin' && s.year ? action('Edit runner','edit','',`data-id="${esc(id)}"`)+action('QR / NFC badge','badge','outline',`data-id="${esc(id)}"`) : ''}${action('Close','close','outline')}</div>`;
    dialog.showModal();
    if(window.TURC_SCANNER) {
      try { const totals=await window.TURC_SCANNER.totals(id); const node=document.getElementById('runner-totals'); if(token===epoch&&node&&dialog.open)node.textContent=`Today: ${totals.today_laps} laps · ${(totals.today_mm/1609344).toFixed(2)} miles. School year: ${(totals.year_mm/1609344).toFixed(2)} miles. Lifetime at school: ${(totals.lifetime_mm/1609344).toFixed(2)} miles.`; }
      catch { const node=document.getElementById('runner-totals'); if(token===epoch&&node)node.textContent='Lap totals could not load. Reconnect and reopen this runner.'; }
    }
  }
  function editRunner(id) {
    if (s.role !== 'admin' || !s.year) { message('An Admin and active school year are required.'); return; }
    const x = s.students.find(r => r.id === id);
    const fields = [['student_id','Student ID',x?.external_student_id || '',80],['first_name','First name',x?.first_name || '',100],['last_name','Last name',x?.last_name || '',100],['grade','Grade',x?.enrollment?.grade || '',40],['classroom','Classroom / teacher',x?.enrollment?.classroom || '',120]];
    dialog.innerHTML = `<h2>${x ? 'A runner’s next chapter.' : 'Welcome a new runner.'}</h2><p>Review the proposed change before it is saved.</p><form id="club-edit" data-id="${esc(id || '')}"><div class="club-field-grid">${fields.map(([key,label,value,max]) => `<label>${label}<input name="${key}" value="${esc(value)}" maxlength="${max}" ${['student_id','first_name','last_name'].includes(key) ? 'required' : ''} ${key === 'student_id' && x ? 'readonly' : ''}></label>`).join('')}</div><div class="modal-actions">${action('Cancel','close','outline')}<button type="submit" class="btn">Review change →</button></div></form>`;
    if (!dialog.open) dialog.showModal();
  }
  async function previewRows(data) {
    const requestEpoch = epoch, schoolId = s.school.id, yearId = s.year.id;
    s.busy = true; s.error = ''; s.importErrors = []; render();
    try {
      const { data: result, error } = await client.rpc('turc_preview_roster_import',{ p_school:schoolId,p_year:yearId,p_rows:data });
      if (requestEpoch !== epoch) return;
      if (error) throw error; s.preview = result.valid ? result : null; s.importErrors = result.errors || [];
    } catch (error) { if (requestEpoch === epoch) s.error = errorText(error); } finally { if (requestEpoch === epoch) { s.busy = false; render(); } }
  }
  async function downloadCSV(name, data) {
    const text = '\uFEFF'+data.map(row => row.map(TurcCSV.cell).join(',')).join('\r\n');
    if (platform?.isNative) { await platform.shareCSV(name,text); return; }
    const blob = new Blob([text],{type:'text/csv;charset=utf-8'});
    const url = URL.createObjectURL(blob), a = document.createElement('a'); a.href = url; a.download = name; a.click(); setTimeout(() => URL.revokeObjectURL(url),1000);
  }
  async function handleAction(target) {
    const name = target.dataset.action;
    if (s.busy && !['signout','close'].includes(name)) return;
    if(window.TURC_SCANNER?.handles(name)){await window.TURC_SCANNER.handle(name,target.dataset.id);return;}
    if (name === 'signout') {
      sessionRemovalPending = true;
      clearPrivateState(); render();
      const { error } = await client.auth.signOut({scope:'local'});
      if (error) {
        client.auth.stopAutoRefresh();
        try {
          if (platform?.authStorage) {
            for (const key of ['turc-auth-v1','turc-auth-v1-code-verifier','turc-auth-v1-user']) await platform.authStorage.removeItem(key);
          } else localStorage.removeItem('turc-auth-v1');
          sessionRemovalPending = false;
          s.error = 'Signed out locally. The server could not confirm session revocation.';
        } catch { s.error = 'Your roster is cleared, but secure session removal failed. Retry sign-out before closing the app.'; }
        render();
      } else { sessionRemovalPending = false; render(); }
      return;
    }
    if (name === 'refresh') { await refresh(); return; }
    if (name === 'close') { window.TURC_SCANNER?.clearBadge(); dialog.close(); dialog.innerHTML = ''; return; }
    if (name === 'tab') { s.tab = target.dataset.tab; s.error = ''; if(s.tab==='scanner')await window.TURC_SCANNER?.loadCourse(); render(); window.scrollTo(0,0); return; }
    if (name === 'open-import' || name === 'open-roster') { s.tab = name === 'open-import' ? 'import' : 'roster'; s.error = ''; render(); window.scrollTo(0,0); return; }
    if (name === 'reset-import') { resetImport(); s.error = ''; render(); return; }
    if (name === 'detail') { await runnerDetail(target.dataset.id); return; }
    if (name === 'add' || name === 'edit') { editRunner(target.dataset.id); return; }
    if (name === 'sample') { await downloadCSV('turc-fictional-roster.csv',[['Student ID','First Name','Last Name','Grade','Classroom'],['000101','Maya','Example','3','Ms. Parker'],['000102','Oliver','Example','4','Mr. Brooks']]); return; }
    if (name === 'export' && s.role === 'admin') { await downloadCSV('turc-roster.csv',[['Student ID','First Name','Last Name','Grade','Classroom','Status'],...s.students.map(x => [x.external_student_id,x.first_name,x.last_name,x.enrollment?.grade || '',x.enrollment?.classroom || '',x.active ? 'Active' : 'Archived'])]); return; }
    if (name === 'commit' && s.preview) {
      const job = s.preview.job_id, requestEpoch = epoch; s.busy = true; s.error = ''; render();
      try {
        const { data, error } = await client.rpc('turc_commit_roster_import',{p_job:job}); if (error) throw error;
        if (requestEpoch !== epoch) return;
        resetImport(); s.tab = 'roster'; message(`${data.new} new runners · ${data.updated} updated · ${data.unchanged} unchanged. Saved to your club.`);
        await fetchRoster(requestEpoch); if (requestEpoch === epoch) window.scrollTo(0,0);
      } catch (error) { if (requestEpoch === epoch) { s.error = errorText(error); if (error.code === '40001' || error.code === '22023') s.preview = null; } }
      finally { if (requestEpoch === epoch) { s.busy = false; render(); } }
    }
  }
  document.addEventListener('click',event => { const target = event.target.closest('[data-action]'); if (target) handleAction(target).catch(e => { s.error = errorText(e); s.busy = false; if(dialog.open){ const node=document.createElement('p');node.className='club-error';node.textContent=s.error;dialog.append(node); } else render(); }); });
  document.addEventListener('input',event => { if (event.target.id === 'club-search') { s.search = event.target.value; const body = document.getElementById('club-roster-body'); if (body) body.innerHTML = rosterRows(); } });
  document.addEventListener('change',async event => {
    if (event.target.id === 'club-school') {
      window.TURC_SCANNER?.reset();
      const school = s.schools.find(x => x.id === event.target.value); if (!school) return;
      if (dialog.open) dialog.close(); resetImport(); s.school = school; s.search = ''; await activate({user:s.user});
    }
    if (event.target.id === 'club-file') {
      const file = event.target.files?.[0]; if (!file) return;
      const requestEpoch = epoch;
      try { if (file.size > 1048576) throw Error('Choose a CSV no larger than 1 MB.'); const text = new TextDecoder('utf-8',{fatal:true}).decode(await file.arrayBuffer()); if (requestEpoch !== epoch) return; s.parsed = TurcCSV.parse(text); s.mapping = TurcCSV.suggest(s.parsed.headers); s.fileName = file.name; s.error = ''; s.preview = null; s.importErrors = []; }
      catch (error) { s.error = errorText(error); resetImport(); } render();
    }
  });
  document.addEventListener('submit',async event => {
    const form = event.target; if (!['club-login','club-map','club-edit','scan-course'].includes(form.id)) return; event.preventDefault();
    try {
      if(form.id==='scan-course'){await window.TURC_SCANNER.saveCourse(form);return;}
      if (form.id === 'club-login') {
        if (signInPending) return; signInPending = true; const button = form.querySelector('button'); button.disabled = true; button.textContent = 'Signing in…';
        const values = new FormData(form); const {data,error} = await client.auth.signInWithPassword({email:String(values.get('email')).trim(),password:String(values.get('password'))});
        values.delete('password'); form.reset(); if (error) throw error; await activate(data.session);
      } else if (form.id === 'club-map') {
        s.mapping = Object.fromEntries(new FormData(form)); await previewRows(TurcCSV.mapRows(s.parsed,s.mapping));
      } else {
        const values = Object.fromEntries(new FormData(form)), x = s.students.find(r => r.id === form.dataset.id);
        if (!x && s.students.some(r => r.external_student_id === values.student_id.trim())) throw Error('This Student ID already exists. Open that runner to edit their record.');
        if (x) { values._expected_version = x.row_version; values._expected_enrollment_version = x.enrollment?.row_version || 0; }
        dialog.close(); dialog.innerHTML = ''; resetImport(); s.tab = 'import'; await previewRows([values]);
      }
    } catch (error) { s.error = errorText(error); if (dialog.open) { const errorNode = document.createElement('p'); errorNode.className = 'club-error'; errorNode.textContent = s.error; dialog.append(errorNode); } else render(); }
    finally { signInPending = false; }
  });
  client.auth.onAuthStateChange((event,session) => {
    if (event === 'SIGNED_OUT') { clearPrivateState(); render(); }
    else if (event === 'SIGNED_IN' && !signInPending && s.user?.id !== session?.user?.id) setTimeout(() => activate(session),0);
  });
  client.auth.getSession().then(({data,error}) => { if (error) { s.loading = false; s.error = errorText(error); render(); } else activate(data.session); });
  window.addEventListener('online',() => { if (s.user) refresh({background:true}); });
  window.addEventListener('turc:resume',() => { if (s.user) refresh({background:true}); });
  document.addEventListener('visibilitychange',() => { if (!document.hidden && s.user) refresh({background:true}); });
  setInterval(() => { if (!document.hidden && s.user && s.tab !== 'account') refresh({background:true}); },30000);
})();
