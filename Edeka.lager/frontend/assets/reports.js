// Ausgelagert aus reports.html (Phase F, Schritt A).
// Inhalt unveraendert — nur der Ort hat sich geaendert, damit ESLint und
// der vm-Harness diesen Code ueberhaupt sehen koennen.
// Ein Kommentar vor 'use strict' ist unschaedlich: die Direktive muss die
// erste ANWEISUNG sein, nicht die erste Zeile.
'use strict';

let historyRows = [];

function fmtNum(n) {
  return Number(n ?? 0).toLocaleString('de-DE', { maximumFractionDigits: 1 });
}

function fmtDateOnly(dateStr) {
  return new Date(dateStr + 'T12:00:00').toLocaleDateString('de-DE', {
    weekday: 'short', day: '2-digit', month: '2-digit', year: 'numeric'
  });
}

async function loadHistory() {
  const limit = document.getElementById('limit-select').value;
  try {
    historyRows = await api(`/api/reports/history?limit=${limit}`);
    renderHistory();
  } catch (e) {
    showToast('⚠️ ' + e.message, 'err');
  }
}
window.loadHistory = loadHistory;

function renderHistory() {
  const tbody = document.getElementById('history-tbody');
  const empty = document.getElementById('history-empty');

  document.getElementById('history-meta').textContent = `${historyRows.length} Tag(e)`;

  if (historyRows.length === 0) {
    tbody.innerHTML = '';
    empty.style.display = 'flex';
    return;
  }
  empty.style.display = 'none';

  tbody.innerHTML = historyRows.map(row => `
    <tr>
      <td>${fmtDateOnly(row.date)}</td>
      <td><span class="type-tag ${row.type === 'auto-midnight' ? 'type-auto' : 'type-manual'}">
        ${row.type === 'auto-midnight' ? '🌙 Automatisch' : '✋ Manuell'}
      </span></td>
      <td>${fmtNum(row.totalStock)}</td>
      <td>${row.totalConsumed > 0 ? '−' + fmtNum(row.totalConsumed) : '—'}</td>
      <td>${row.productCount}</td>
      <td>${row.reportsToday}</td>
      <td>
        <div class="row-acts">
          <button class="row-act" title="Details" onclick="openDrawer('${row._id}', '${row.date}')">👁️</button>
        </div>
      </td>
    </tr>
  `).join('');
}

// ── Drawer ───────────────────────────────────────────────────────
async function openDrawer(logId, dateStr) {
  document.getElementById('drawer-title').textContent = fmtDateOnly(dateStr);
  document.getElementById('drawer-body').innerHTML = '<div class="skeleton" style="height:200px"></div>';
  document.getElementById('drawer-overlay').classList.add('open');

  document.getElementById('drawer-excel-btn').onclick = () => downloadReportFile('excel', { logId });
  document.getElementById('drawer-pdf-btn').onclick   = () => downloadReportFile('pdf',   { logId });

  try {
    const log = await api(`/api/reports/${logId}`);
    renderDrawerBody(log);
  } catch (e) {
    document.getElementById('drawer-body').innerHTML = `<p style="color:var(--color-error)">${escapeHtml(e.message)}</p>`;
  }
}
window.openDrawer = openDrawer;

function closeDrawer() {
  document.getElementById('drawer-overlay').classList.remove('open');
}
window.closeDrawer = closeDrawer;

function renderDrawerBody(log) {
  const categories = [...new Set(log.snapshot.map(p => p.category))];
  const html = categories.map(cat => {
    const items = log.snapshot.filter(p => p.category === cat);
    const rows = items.map(p => `
      <div class="drawer-row">
        <span>${escapeHtml(p.emoji || '📦')} ${escapeHtml(p.productName)}${p.isBio ? ' 🌱' : ''} <span style="color:var(--color-text-faint)">(${escapeHtml(p.unit)})</span></span>
        <span style="font-variant-numeric:tabular-nums">${fmtNum(p.closingStock)}${p.consumed > 0 ? ` <span style="color:var(--color-text-muted)">(−${fmtNum(p.consumed)})</span>` : ''}</span>
      </div>
    `).join('');
    return `<div class="drawer-section-title">${escapeHtml(cat)}</div>${rows}`;
  }).join('');

  const totalStock    = log.snapshot.reduce((s, p) => s + (p.closingStock || 0), 0);
  const totalConsumed = log.snapshot.reduce((s, p) => s + (p.consumed || 0), 0);

  document.getElementById('drawer-body').innerHTML = `
    <div class="kpi-grid" style="grid-template-columns: 1fr 1fr; margin-bottom:0">
      <div class="kpi-card">
        <div class="kpi-top"><span class="kpi-label">Bestand</span></div>
        <div class="kpi-val">${fmtNum(totalStock)}</div>
      </div>
      <div class="kpi-card">
        <div class="kpi-top"><span class="kpi-label">Verbrauch</span></div>
        <div class="kpi-val">${fmtNum(totalConsumed)}</div>
      </div>
    </div>
    ${html}
  `;
}

// ── Admin ───────────────────────────────────────────────────────
function openAdminTools() { document.getElementById('admin-modal').classList.add('open'); }
window.openAdminTools = openAdminTools;
function closeAdminTools() { document.getElementById('admin-modal').classList.remove('open'); }
window.closeAdminTools = closeAdminTools;

let _confirmAction = null;
function openConfirm({ title, msg, icon = '⚠️', onConfirm }) {
  document.getElementById('confirm-title').textContent = title;
  document.getElementById('confirm-msg').textContent = msg;
  document.getElementById('confirm-icon').textContent = icon;
  _confirmAction = onConfirm;
  document.getElementById('confirm-overlay').classList.add('open');
}
function closeConfirm() {
  document.getElementById('confirm-overlay').classList.remove('open');
  _confirmAction = null;
}
window.closeConfirm = closeConfirm;
document.getElementById('confirm-action-btn').addEventListener('click', () => {
  if (_confirmAction) _confirmAction();
  closeConfirm();
});

function adminResetLogs(scope) {
  closeAdminTools();
  const labels = { daily: 'die heutigen Logs', weekly: 'die letzten 7 Tage', monthly: 'die letzten 30 Tage', all: 'ALLE Logs' };
  openConfirm({
    title: 'Logs löschen?',
    msg: `Du löschst ${labels[scope]}. Das kann nicht rückgängig gemacht werden.`,
    icon: '🗑️',
    onConfirm: async () => {
      try {
        const res = await api('/api/reports/reset-logs', 'POST', { scope });
        showToast(`✅ ${res.deletedCount} Log(s) gelöscht`, 'ok');
        loadHistory();
      } catch (e) {
        showToast('⚠️ ' + e.message, 'err');
      }
    }
  });
}
window.adminResetLogs = adminResetLogs;

function adminCloseDay() {
  closeAdminTools();
  openConfirm({
    title: 'Gestern manuell abschließen?',
    msg: 'Das setzt die Gestern-Basis für alle Produkte neu. Nur verwenden, falls die automatische Mitternacht-Schließung nicht gelaufen ist.',
    icon: '🌙',
    onConfirm: async () => {
      try {
        const res = await api('/api/reports/close-day', 'POST', {});
        showToast(`✅ ${res.date} abgeschlossen (${res.count} Produkte)`, 'ok');
        loadHistory();
      } catch (e) {
        showToast('⚠️ ' + e.message, 'err');
      }
    }
  });
}
window.adminCloseDay = adminCloseDay;

// ── Init ───────────────────────────────────────────────────────────
document.addEventListener('DOMContentLoaded', () => {
  if (currentUser.role === 'admin') {
    document.getElementById('admin-tools-btn').style.display = '';
  }
  loadHistory();
});

