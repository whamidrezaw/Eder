// Diese Funktionen werden aus Inline-Handlern im HTML aufgerufen, das
// ESLint nicht liest. Bis Schritt B sie per addEventListener anbindet,
// sagt die folgende Zeile ESLint, dass sie benutzt werden.
/* exported setFilter, filterUsers, openLogPanel, openCreateModal, openEditModal, runConfirm, confirmToggle, confirmDeletePermanent */
// Ausgelagert aus users.html (Phase F, Schritt A).
// Inhalt unveraendert — nur der Ort hat sich geaendert, damit ESLint und
// der vm-Harness diesen Code ueberhaupt sehen koennen.
// Ein Kommentar vor 'use strict' ist unschaedlich: die Direktive muss die
// erste ANWEISUNG sein, nicht die erste Zeile.
'use strict';
/* Auth-Guard, currentUser, escapeHtml, api(), showToast(), logout(),
   fmtDate/fmtTime/fmtRelative, animVal, parseUA, injectSidebar, Theme —
   alles kommt jetzt aus assets/shared.js. Diese Datei hatte das früher
   alles noch einmal selbst (mit teils abweichendem Verhalten) definiert;
   siehe Review-Hinweise für Details. */

/* ── STATE ── */
let allUsers = [];
let editingId = null;
let confirmCb = null;
let currentFilter = 'all';

/* ── LOAD ── */
async function loadUsers() {
  showSkeleton();
  try {
    allUsers = await api('/api/users');
    renderKPIs();
    renderTable(filterList());
  } catch (e) {
    showToast('⚠️ ' + e.message, 'err');
  }
}

function showSkeleton() {
  const tbody = document.getElementById('users-tbody');
  tbody.innerHTML = Array(5).fill('').map(() => `
    <tr>
      <td><div style="display:flex;align-items:center;gap:10px">
        <div class="skeleton" style="width:36px;height:36px;border-radius:50%"></div>
        <div><div class="skeleton" style="width:120px;height:13px;margin-bottom:5px"></div>
        <div class="skeleton" style="width:80px;height:11px"></div></div></div></td>
      <td><div class="skeleton" style="width:70px;height:22px;border-radius:12px"></div></td>
      <td><div class="skeleton" style="width:60px;height:22px;border-radius:12px"></div></td>
      <td><div class="skeleton" style="width:80px;height:14px"></div></td>
      <td><div class="skeleton" style="width:90px;height:14px"></div></td>
      <td><div class="skeleton" style="width:60px;height:28px;border-radius:8px"></div></td>
      <td><div class="skeleton" style="width:80px;height:13px"></div></td>
      <td></td>
    </tr>`).join('');
}

/* ── KPIs ── */
function renderKPIs() {
  const admins = allUsers.filter(u => u.role === 'admin').length;
  const lager = allUsers.filter(u => u.role === 'lagerist').length;
  animVal('kpi-total', allUsers.length);
  animVal('kpi-admins', admins);
  animVal('kpi-lager', lager);
  const last = allUsers.filter(u => u.lastLogin).sort((a, b) => new Date(b.lastLogin) - new Date(a.lastLogin))[0];
  document.getElementById('kpi-last').textContent = last ? last.name : '—';
  document.getElementById('kpi-last-sub').textContent = last ? fmtRelative(last.lastLogin) : 'Noch keine Logins';
}

/* ── FILTER ── */
function filterList() {
  const q = document.getElementById('search-input').value.toLowerCase();
  return allUsers.filter(u => {
    const matchQ = !q || u.name.toLowerCase().includes(q) || u.username.toLowerCase().includes(q);
    let matchF = true;
    if (currentFilter === 'admin') matchF = u.role === 'admin';
    else if (currentFilter === 'lagerist') matchF = u.role === 'lagerist';
    else if (currentFilter === 'active') matchF = u.isActive !== false;
    else if (currentFilter === 'inactive') matchF = u.isActive === false;
    return matchQ && matchF;
  });
}

function setFilter(f, el) {
  currentFilter = f;
  document.querySelectorAll('.filter-tab').forEach(b => b.classList.remove('active'));
  el.classList.add('active');
  renderTable(filterList());
}

function filterUsers() { renderTable(filterList()); }

/* ── TABLE ── */
function renderTable(users) {
  const tbody = document.getElementById('users-tbody');
  document.getElementById('table-meta').textContent = `${users.length} Benutzer`;
  if (!users.length) {
    tbody.innerHTML = `<tr><td colspan="8"><div class="empty-state">
      <div class="empty-icon">👤</div>
      <div class="empty-title">Keine Benutzer gefunden</div>
      <div class="empty-desc">Versuchen Sie einen anderen Suchbegriff oder Filter.</div>
    </div></td></tr>`;
    return;
  }
  // FIX: Backend liefert für User nie ein `id`-Feld, nur `_id` (Mongoose
  // gibt den `id`-Virtual bei diesem Schema nicht automatisch mit aus).
  // Vorher stand hier u.id — das war für jede Zeile `undefined`, wodurch
  // Bearbeiten/Sperren/Löschen/Login-Verlauf faktisch nicht funktionierten.
  const isOwnId = id => currentUser.id && currentUser.id === id;
  tbody.innerHTML = users.map(u => {
    const ini = escapeHtml(u.name.split(' ').map(n => n[0]).join('').slice(0, 2).toUpperCase());
    const bg = u.role === 'admin' ? 'var(--edeka-red)' : 'var(--edeka-yellow)';
    const clr = u.role === 'admin' ? '#fff' : 'var(--edeka-dark)';
    const active = u.isActive !== false;
    const cnt = u.loginHistory?.length || 0;
    const hasTg = !!(u.telegramChatId);
    return `<tr>
      <td>
        <div class="user-cell">
          <div class="user-cell-avatar" style="background:${bg};color:${clr}">${ini}</div>
          <div>
            <div class="user-cell-name">${escapeHtml(u.name)}${isOwnId(u._id) ? ' <span style="font-size:10px;color:var(--color-text-faint)">(Sie)</span>' : ''}</div>
            <div class="user-cell-sub">@${escapeHtml(u.username)}</div>
          </div>
        </div>
      </td>
      <td>
        <span class="badge badge-${u.role === 'admin' ? 'admin' : 'lagerist'}">
          <span class="badge-dot"></span>${u.role === 'admin' ? '🔑 Admin' : '📦 Lagerist'}
        </span>
      </td>
      <td>
        <span class="badge badge-${active ? 'active' : 'inactive'}">
          <span class="badge-dot"></span>${active ? 'Aktiv' : 'Deaktiviert'}
        </span>
      </td>
      <td>
        <span class="tg-badge ${hasTg ? 'has-tg' : 'no-tg'}">
          ${hasTg ? '✈️ ' + escapeHtml(u.telegramChatId) : '— nicht gesetzt'}
        </span>
      </td>
      <td style="font-size:12px">${u.lastLogin ? fmtRelative(u.lastLogin) : '<span style="color:var(--color-text-faint)">Nie</span>'}</td>
      <td>
        <button class="btn btn-ghost" style="padding:5px 10px;font-size:12px"
          onclick="openLogPanel('${u._id}')" ${cnt === 0 ? 'disabled style="opacity:0.4"' : ''}>
          ${cnt} Einträge
        </button>
      </td>
      <td style="font-size:12px;color:var(--color-text-muted)">${fmtDate(u.createdAt)}</td>
      <td>
        <div class="row-acts">
          <button class="row-act" onclick="openEditModal('${u._id}')" title="Bearbeiten">✏️</button>
          ${!isOwnId(u._id) ? `
          <button class="row-act ${active ? 'warning' : 'success'}"
            onclick="confirmToggle('${u._id}')"
            title="${active ? 'Deaktivieren' : 'Aktivieren'}">${active ? '🔒' : '🔓'}</button>
          <button class="row-act danger"
            onclick="confirmDeletePermanent('${u._id}')"
            title="Endgültig löschen">🗑️</button>` : ''}
        </div>
      </td>
    </tr>`;
  }).join('');
}

/* ── LOG PANEL ── */
function openLogPanel(uid) {
  const u = allUsers.find(u => u._id === uid);
  if (!u) return;
  document.getElementById('log-panel-name').textContent = u.name;
  document.getElementById('log-panel-sub').textContent = `@${u.username} · ${u.loginHistory?.length || 0} Einträge`;
  const hist = u.loginHistory || [];
  document.getElementById('log-panel-body').innerHTML = !hist.length
    ? `<div style="text-align:center;padding:40px;color:var(--color-text-muted)">Kein Verlauf</div>`
    : [...hist].reverse().map(e => `
      <div class="log-entry">
        <div style="min-width:64px">
          <div class="log-time">${fmtTime(e.timestamp)}</div>
          <div class="log-date-txt">${fmtDate(e.timestamp)}</div>
        </div>
        <div style="flex:1;min-width:0">
          <div>
            <span class="log-action-tag ${e.action === 'logout' ? 'log-logout' : 'log-login'}">
              ${e.action === 'logout' ? '⬆ Logout' : '⬇ Login'}
            </span>
          </div>
          <div class="log-device">${escapeHtml(parseUA(e.userAgent))}</div>
          <div class="log-ip">${escapeHtml(e.ip || '')}</div>
        </div>
      </div>`).join('');
  document.getElementById('log-panel').classList.add('open');
}

function closeLogPanel() { document.getElementById('log-panel').classList.remove('open'); }

/* ── MODAL ── */
function openCreateModal() {
  editingId = null;
  document.getElementById('modal-title').textContent = 'Neuer Benutzer';
  ['f-name','f-username','f-password','f-telegram','f-newpass'].forEach(id => {
    const el = document.getElementById(id);
    if (el) el.value = '';
  });
  document.getElementById('f-role').value = 'lagerist';
  document.getElementById('f-role').disabled = false;
  document.getElementById('f-role-hint').style.display = 'none';
  document.getElementById('f-active').value = 'true';
  document.getElementById('f-username').disabled = false;
  document.getElementById('f-pass-group').style.display = '';
  document.getElementById('f-reset-section').style.display = 'none';
  document.getElementById('user-modal').classList.add('open');
  setTimeout(() => document.getElementById('f-name').focus(), 120);
}

function openEditModal(uid) {
  const u = allUsers.find(u => u._id === uid);
  if (!u) return;
  editingId = uid;
  document.getElementById('modal-title').textContent = 'Benutzer bearbeiten';
  document.getElementById('f-name').value = u.name;
  document.getElementById('f-username').value = u.username;
  document.getElementById('f-username').disabled = true;
  document.getElementById('f-role').value = u.role;
  // Ein Admin kann seine eigene Rolle hier nicht ändern (siehe
  // routes/users.js) — sonst könnte man sich versehentlich selbst aus der
  // Verwaltung aussperren, da die Rolle sofort beim nächsten Request greift.
  const editingSelf = currentUser.id && currentUser.id === u._id;
  document.getElementById('f-role').disabled = editingSelf;
  document.getElementById('f-role-hint').style.display = editingSelf ? '' : 'none';
  document.getElementById('f-active').value = String(u.isActive !== false);
  document.getElementById('f-telegram').value = u.telegramChatId || '';
  document.getElementById('f-pass-group').style.display = 'none';
  document.getElementById('f-reset-section').style.display = '';
  document.getElementById('f-newpass').value = '';
  document.getElementById('user-modal').classList.add('open');
  setTimeout(() => document.getElementById('f-name').focus(), 120);
}

function closeUserModal() {
  document.getElementById('user-modal').classList.remove('open');
  editingId = null;
}

async function saveUser() {
  const btn = document.getElementById('save-user-btn');
  btn.disabled = true; btn.textContent = '…';
  try {
    if (editingId) {
      const payload = {
        name: document.getElementById('f-name').value.trim(),
        isActive: document.getElementById('f-active').value === 'true',
        telegramChatId: document.getElementById('f-telegram').value.trim() || null
      };
      if (!document.getElementById('f-role').disabled) {
        payload.role = document.getElementById('f-role').value;
      }
      await api(`/api/users/${editingId}`, 'PUT', payload);
      const np = document.getElementById('f-newpass').value.trim();
      if (np) await api(`/api/users/${editingId}/reset-password`, 'PUT', { newPassword: np });
      showToast('✅ Benutzer aktualisiert', 'ok');
    } else {
      const p = {
        name: document.getElementById('f-name').value.trim(),
        username: document.getElementById('f-username').value.trim(),
        password: document.getElementById('f-password').value,
        role: document.getElementById('f-role').value,
        telegramChatId: document.getElementById('f-telegram').value.trim() || null
      };
      if (!p.name || !p.username || !p.password) { showToast('⚠️ Pflichtfelder ausfüllen', 'err'); return; }
      if (p.password.length < 6) { showToast('⚠️ Passwort min. 6 Zeichen', 'err'); return; }
      await api('/api/users', 'POST', p);
      showToast('✅ Benutzer erstellt', 'ok');
    }
    closeUserModal();
    await loadUsers();
  } catch (e) { showToast('❌ Fehler: ' + e.message, 'err'); }
  finally { btn.disabled = false; btn.textContent = 'Speichern'; }
}

/* ── CONFIRM ── */
function showConfirm(icon, title, msg, cb) {
  document.getElementById('confirm-icon').textContent = icon;
  document.getElementById('confirm-title').textContent = title;
  document.getElementById('confirm-msg').textContent = msg;
  confirmCb = cb;
  document.getElementById('confirm-overlay').classList.add('open');
}

function runConfirm() {
  document.getElementById('confirm-overlay').classList.remove('open');
  if (confirmCb) { confirmCb(); confirmCb = null; }
}

function closeConfirm() {
  document.getElementById('confirm-overlay').classList.remove('open');
  confirmCb = null;
}

// FIX: nimmt jetzt nur noch die id und schlägt den Namen selbst in allUsers
// nach — vorher wurde der Name per u.name.replace(/'/g, "\\'") in ein
// onclick="...('${name}')"-Attribut eingebettet. Das war unvollständig
// escaped (Anführungszeichen & Zeilenumbrüche nicht behandelt) und damit
// ein Stored-XSS-Vektor über den Benutzernamen.
function confirmToggle(uid) {
  const u = allUsers.find(x => x._id === uid);
  if (!u) return;
  const active = u.isActive !== false;
  showConfirm(
    active ? '🔒' : '🔓',
    active ? `${u.name} deaktivieren?` : `${u.name} aktivieren?`,
    active ? 'Der Benutzer kann sich nicht mehr anmelden.' : 'Der Benutzer kann sich wieder anmelden.',
    async () => {
      try {
        await api(`/api/users/${uid}`, active ? 'DELETE' : 'PUT', active ? null : { isActive: true });
        showToast(active ? '🔒 Deaktiviert' : '🔓 Aktiviert', 'ok');
        loadUsers();
      } catch (e) { showToast('❌ Fehler: ' + e.message, 'err'); }
    }
  );
}

function confirmDeletePermanent(uid) {
  const u = allUsers.find(x => x._id === uid);
  if (!u) return;
  showConfirm(
    '🗑️',
    `${u.name} endgültig löschen?`,
    'Dieser Benutzer wird komplett aus der Datenbank entfernt. Dieser Vorgang kann nicht rückgängig gemacht werden.',
    async () => {
      try {
        await api(`/api/users/${uid}?permanent=true`, 'DELETE');
        showToast('🗑️ Benutzer endgültig gelöscht', 'ok');
        loadUsers();
      } catch (e) { showToast('❌ Fehler: ' + e.message, 'err'); }
    }
  );
}

/* ── KEYBOARD ── */
document.addEventListener('keydown', e => {
  if (e.key === 'Escape') { closeUserModal(); closeLogPanel(); closeConfirm(); }
  if (e.key === 'Enter' && document.getElementById('user-modal').classList.contains('open')) {
    const active = document.activeElement?.tagName;
    if (active !== 'SELECT' && active !== 'BUTTON') saveUser();
  }
});

/* ── CLICK OUTSIDE LOG PANEL ── */
document.addEventListener('click', e => {
  const panel = document.getElementById('log-panel');
  if (panel.classList.contains('open') && !panel.contains(e.target) && !e.target.closest('[onclick*="openLogPanel"]'))
    closeLogPanel();
});

/* ── INIT ── */
loadUsers();

