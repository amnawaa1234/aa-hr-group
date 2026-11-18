// ===== AA HR Group — shared app code =====
(function () {
  const cfg = window.AAHR_CONFIG || {};
  const sb = window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY);

  // ---------- colour theme ----------
  const THEMES = {
    emerald: 'Emerald & Gold',
    navy: 'Navy & Gold',
    burgundy: 'Burgundy & Gold',
    plum: 'Royal Plum',
    charcoal: 'Charcoal & Amber',
  };
  function applyTheme(t) {
    if (!THEMES[t]) t = 'emerald';
    document.documentElement.dataset.theme = t;
    try { localStorage.setItem('aahr_theme', t); } catch (_) {}
    return t;
  }
  // Use the last known theme straight away (no flash), then refresh from the database.
  let cachedTheme = null;
  try { cachedTheme = localStorage.getItem('aahr_theme'); } catch (_) {}
  applyTheme(cachedTheme || cfg.THEME);
  sb.from('app_settings').select('value').eq('key', 'theme').maybeSingle()
    .then(({ data }) => { if (data) applyTheme(data.value); });

  const ROLE_LABEL = { staff: 'Staff', director: 'Director', admin: 'HR & Admin' };

  const NAV = [
    { id: 'dashboard', href: 'dashboard.html', label: 'Dashboard', icon: 'M3 12l9-9 9 9M5 10v10h5v-6h4v6h5V10' },
    { id: 'apply', href: 'apply.html', label: 'Apply Leave', icon: 'M12 5v14M5 12h14' },
    { id: 'my-leaves', href: 'my-leaves.html', label: 'My Applications', icon: 'M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01' },
    { id: 'approvals', href: 'approvals.html', label: 'Approvals', icon: 'M9 12l2 2 4-4M21 12a9 9 0 11-18 0 9 9 0 0118 0z', roles: ['director'] },
    { id: 'all-leaves', href: 'all-leaves.html', label: 'All Applications', icon: 'M4 4h16v16H4zM4 9h16M9 4v16', roles: ['director', 'admin'] },
    { id: 'staff', href: 'staff.html', label: 'Staff', icon: 'M17 20h5v-2a4 4 0 00-5-3.87M9 20H2v-2a4 4 0 015-3.87m6-4a4 4 0 11-8 0 4 4 0 018 0zm6 2a3 3 0 11-6 0 3 3 0 016 0z', roles: ['admin'] },
    { id: 'settings', href: 'settings.html', label: 'Settings', icon: 'M12 15a3 3 0 100-6 3 3 0 000 6zM19.4 15a1.65 1.65 0 00.33 1.82l.06.06a2 2 0 11-2.83 2.83l-.06-.06a1.65 1.65 0 00-1.82-.33 1.65 1.65 0 00-1 1.51V21a2 2 0 11-4 0v-.09A1.65 1.65 0 009 19.4a1.65 1.65 0 00-1.82.33l-.06.06a2 2 0 11-2.83-2.83l.06-.06A1.65 1.65 0 004.6 15a1.65 1.65 0 00-1.51-1H3a2 2 0 110-4h.09A1.65 1.65 0 004.6 9a1.65 1.65 0 00-.33-1.82l-.06-.06a2 2 0 112.83-2.83l.06.06A1.65 1.65 0 009 4.6a1.65 1.65 0 001-1.51V3a2 2 0 114 0v.09a1.65 1.65 0 001 1.51 1.65 1.65 0 001.82-.33l.06-.06a2 2 0 112.83 2.83l-.06.06A1.65 1.65 0 0019.4 9a1.65 1.65 0 001.51 1H21a2 2 0 110 4h-.09a1.65 1.65 0 00-1.51 1z', roles: ['admin'] },
  ];

  const icon = (d, size = 18) =>
    `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="${d}"/></svg>`;

  // ---------- formatting ----------
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  function fmtDate(d) {
    if (!d) return '-';
    const [y, m, day] = String(d).slice(0, 10).split('-');
    return `${+day} ${MONTHS[+m - 1]} ${y}`;
  }
  function fmtDateTime(ts) {
    if (!ts) return '-';
    const d = new Date(ts);
    return d.toLocaleString('en-MY', { day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' });
  }
  const fmtDays = (n) => (n === null || n === undefined ? '∞' : (+n % 1 === 0 ? String(+n) : (+n).toFixed(1)));
  const statusBadge = (s) => `<span class="badge badge-${esc(s)}">${esc(s.charAt(0).toUpperCase() + s.slice(1))}</span>`;
  const refNo = (a) => `LV-${String(a.created_at).slice(0, 4)}-${String(a.id).padStart(4, '0')}`;
  const initials = (name) => (name || '?').trim().split(/\s+/).slice(0, 2).map((w) => w[0]).join('').toUpperCase();
  // Accounts created with Staff ID only get an internal @aahr.local email — don't show it
  const realEmail = (e) => (e && !e.endsWith('@aahr.local') ? e : '');
  const today = () => {
    const d = new Date();
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  };
  const dateRange = (a) =>
    a.start_date === a.end_date
      ? fmtDate(a.start_date) + (a.half_day ? ` (${a.half_day})` : '')
      : `${fmtDate(a.start_date)} – ${fmtDate(a.end_date)}`;

  // ---------- UI helpers ----------
  function toast(msg, type = 'success') {
    let wrap = document.getElementById('toasts');
    if (!wrap) {
      wrap = document.createElement('div');
      wrap.id = 'toasts';
      document.body.appendChild(wrap);
    }
    const t = document.createElement('div');
    t.className = `toast toast-${type}`;
    t.textContent = msg;
    wrap.appendChild(t);
    setTimeout(() => t.classList.add('hide'), 3800);
    setTimeout(() => t.remove(), 4300);
  }

  function modal({ title, body, actions = [] }) {
    const el = document.createElement('div');
    el.className = 'modal-backdrop';
    el.innerHTML = `<div class="modal" role="dialog" aria-modal="true">
      <div class="modal-head"><h3>${esc(title)}</h3><button class="icon-btn" data-close aria-label="Close">&times;</button></div>
      <div class="modal-body"></div><div class="modal-foot"></div></div>`;
    const bodyEl = el.querySelector('.modal-body');
    if (typeof body === 'string') bodyEl.innerHTML = body; else bodyEl.appendChild(body);
    const close = () => el.remove();
    el.querySelector('[data-close]').onclick = close;
    el.addEventListener('click', (e) => { if (e.target === el) close(); });
    const foot = el.querySelector('.modal-foot');
    actions.forEach((a) => {
      const b = document.createElement('button');
      b.className = `btn ${a.class || 'btn-light'}`;
      b.textContent = a.label;
      b.onclick = async () => {
        if (!a.onClick) return close();
        b.disabled = true;
        try { if ((await a.onClick(el)) !== false) close(); } finally { b.disabled = false; }
      };
      foot.appendChild(b);
    });
    document.body.appendChild(el);
    return el;
  }

  function errMsg(error) {
    return (error && (error.message || error.error_description)) || 'Something went wrong.';
  }

  // ---------- auth & layout ----------
  async function getProfile() {
    const { data: { session } } = await sb.auth.getSession();
    if (!session) return null;
    const { data } = await sb.from('profiles').select('*').eq('id', session.user.id).maybeSingle();
    return data;
  }

  async function signOut() {
    await sb.auth.signOut();
    location.href = 'index.html';
  }

  async function pendingCount() {
    const { count } = await sb.from('leave_applications').select('id', { count: 'exact', head: true }).eq('status', 'pending');
    return count || 0;
  }

  /** Call at the top of every protected page. Returns the current profile. */
  async function init({ active, roles } = {}) {
    // "Remember me" unticked → end the session once the browser was closed
    let remember = '1';
    try { remember = localStorage.getItem('aahr_remember') ?? '1'; } catch (_) {}
    if (remember === '0' && !sessionStorage.getItem('aahr_active')) await sb.auth.signOut();
    const profile = await getProfile();
    if (!profile || !profile.active) {
      if (profile && !profile.active) await sb.auth.signOut();
      location.replace('index.html');
      return new Promise(() => {});
    }
    if (roles && !roles.includes(profile.role)) {
      location.replace('dashboard.html');
      return new Promise(() => {});
    }
    renderShell(active, profile);
    if (profile.role === 'director') {
      pendingCount().then((n) => {
        const b = document.querySelector('[data-nav="approvals"] .nav-count');
        if (b && n) { b.textContent = n; b.hidden = false; }
      });
    }
    return profile;
  }

  function renderShell(active, p) {
    const page = document.getElementById('page');
    const nav = NAV.filter((n) => !n.roles || n.roles.includes(p.role))
      .map((n) => `<a href="${n.href}" data-nav="${n.id}" class="nav-link${n.id === active ? ' active' : ''}">${icon(n.icon)}<span>${n.label}</span><b class="nav-count" hidden></b></a>`)
      .join('');
    const shell = document.createElement('div');
    shell.className = 'shell';
    shell.innerHTML = `
      <aside class="sidebar" id="sidebar">
        <a href="dashboard.html" class="brand"><span class="brand-mark">AA</span><span class="brand-text"><strong>AA HR Group</strong><small>HR &amp; Admin</small></span></a>
        <nav class="nav">${nav}</nav>
        <div class="sidebar-foot">
          <div class="me"><span class="avatar">${esc(initials(p.full_name))}</span><span class="me-text"><strong>${esc(p.full_name)}</strong><small>${ROLE_LABEL[p.role]}</small></span></div>
          <button class="btn btn-ghost btn-block" id="logoutBtn">${icon('M9 21H5a2 2 0 01-2-2V5a2 2 0 012-2h4M16 17l5-5-5-5M21 12H9', 16)} Sign out</button>
        </div>
      </aside>
      <div class="sidebar-scrim" id="scrim"></div>
      <main class="main">
        <header class="topbar">
          <button class="icon-btn menu-btn" id="menuBtn" aria-label="Menu">${icon('M3 6h18M3 12h18M3 18h18', 22)}</button>
          <div class="topbar-title">${esc(document.title.split('·')[0].trim())}</div>
          <div class="topbar-right"><span class="role-chip">${ROLE_LABEL[p.role]}</span></div>
        </header>
        <div class="content"></div>
      </main>`;
    shell.querySelector('.content').appendChild(page);
    page.hidden = false;
    document.body.prepend(shell);
    shell.querySelector('#logoutBtn').onclick = signOut;
    const toggle = () => document.body.classList.toggle('nav-open');
    shell.querySelector('#menuBtn').onclick = toggle;
    shell.querySelector('#scrim').onclick = toggle;
  }

  async function attachmentUrl(path) {
    const { data, error } = await sb.storage.from('attachments').createSignedUrl(path, 600);
    if (error) { toast(errMsg(error), 'error'); return null; }
    return data.signedUrl;
  }

  /** Director approve / reject dialog. Calls onDone() after a successful decision. */
  async function decide(app, decision, onDone) {
    const approve = decision === 'approved';
    const { data: bal } = await sb.rpc('leave_balances', { p_user: app.user_id, p_year: +app.start_date.slice(0, 4) });
    const b = (bal || []).find((x) => x.leave_type_id === app.leave_type_id);
    const balLine = !b ? '' : b.entitled === null
      ? 'No day limit for this leave type.'
      : `Balance: <strong>${fmtDays(b.balance)}</strong> of ${fmtDays(b.entitled)} days (incl. pending applications)`;
    const name = app.profiles?.full_name || 'this staff';
    modal({
      title: approve ? 'Approve leave' : 'Reject leave',
      body: `<dl class="details" style="margin-bottom:16px">
          <dt>Staff</dt><dd>${esc(name)}</dd>
          <dt>Leave</dt><dd>${esc(app.leave_types?.name || '')} · ${fmtDays(app.days)} day(s)</dd>
          <dt>Dates</dt><dd>${dateRange(app)}</dd>
          <dt>Reason</dt><dd>${esc(app.reason)}</dd>
        </dl>
        ${balLine ? `<div class="alert alert-info">${balLine}</div>` : ''}
        <label for="decRemarks">Remarks ${approve ? '(optional)' : '<span style="color:var(--danger)">*</span>'}</label>
        <textarea id="decRemarks" placeholder="${approve ? 'Optional note to staff' : 'Reason for rejection'}"></textarea>`,
      actions: [
        { label: 'Cancel' },
        {
          label: approve ? 'Approve' : 'Reject',
          class: approve ? 'btn-success' : 'btn-danger',
          onClick: async (el) => {
            const remarks = el.querySelector('#decRemarks').value.trim();
            if (!approve && !remarks) { toast('Please give a reason for rejection.', 'error'); return false; }
            const { error } = await sb.rpc('decide_leave', { p_id: app.id, p_decision: decision, p_remarks: remarks || null });
            if (error) { toast(errMsg(error), 'error'); return false; }
            toast(`Leave ${decision} for ${name}.`);
            onDone && onDone();
          },
        },
      ],
    });
  }

  async function cancelLeave(app, onDone) {
    modal({
      title: 'Cancel application',
      body: `Cancel your ${esc(app.leave_types?.name || 'leave')} application for <strong>${dateRange(app)}</strong>?`,
      actions: [
        { label: 'Keep it' },
        {
          label: 'Cancel application', class: 'btn-danger',
          onClick: async () => {
            const { error } = await sb.rpc('cancel_leave', { p_id: app.id });
            if (error) { toast(errMsg(error), 'error'); return false; }
            toast('Application cancelled.');
            onDone && onDone();
          },
        },
      ],
    });
  }

  function downloadCsv(filename, rows) {
    const csv = rows.map((r) => r.map((v) => `"${String(v ?? '').replace(/"/g, '""')}"`).join(',')).join('\r\n');
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob(['\ufeff' + csv], { type: 'text/csv;charset=utf-8' }));
    a.download = filename;
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 1000);
  }

  window.AAHR = {
    sb, init, decide, THEMES, applyTheme, cancelLeave, downloadCsv, signOut, getProfile, toast, modal, errMsg, icon, attachmentUrl,
    esc, realEmail, fmtDate, fmtDateTime, fmtDays, statusBadge, refNo, initials, today, dateRange, ROLE_LABEL,
  };
})();
