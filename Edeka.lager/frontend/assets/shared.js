/* ═══════════════════════════════════════════════════════════════
   EDEKA Lagerverwaltung — Shared JS (نسخه‌ی ۲)
   شامل: Auth check, User init, Theme toggle, Sidebar,
         API helper, Toast, Formatters,
         Categories/Units helpers (داینامیک), Send-Now report
   ═══════════════════════════════════════════════════════════════ */

'use strict';

// 1. auth_guard
const token = sessionStorage.getItem('token');
if (!token && !window.location.pathname.endsWith('index.html') && window.location.pathname !== '/') {
  window.location.href = '/index.html';
}

// 2. current_user
const currentUser = (() => {
  try { return JSON.parse(sessionStorage.getItem('user') || '{}'); }
  catch { return {}; }
})();

// 3. security_helper
function escapeHtml(str) {
  // Vorher: if (!str) return '' — damit wurden auch die Zahl 0 und false
  // zu einem leeren String. In einer Lagerverwaltung ist 0 ein häufiger
  // und wichtiger Wert: ein Bestand von 0 verschwand aus jeder Anzeige,
  // die durch diese Funktion lief.
  if (str === null || str === undefined) return '';
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#039;');
}
window.escapeHtml = escapeHtml;

// 4. api_request_helper
async function api(endpoint, method = 'GET', body = null) {
  const headers = { 'Authorization': `Bearer ${token}` };
  if (body) headers['Content-Type'] = 'application/json';

  const res = await fetch(endpoint, {
    method,
    headers,
    body: body ? JSON.stringify(body) : null
  });

  const data = await res.json().catch(() => ({}));

  // Nur ein 401 aus der Token-Prüfung beendet die Sitzung.
  //
  // Vorher führte JEDER 401 zum Abmelden. /api/auth/change-password läuft
  // aber selbst durch die Token-Prüfung und antwortet zusätzlich mit 401,
  // wenn das eingegebene aktuelle Passwort falsch ist — ein Tippfehler in
  // diesem Feld warf den Benutzer damit aus dem System.
  //
  // Unterschieden wird über das Feld code: 'BAD_CREDENTIALS' kennzeichnet
  // einen Fehler bei den Zugangsdaten. Ein 401 OHNE dieses Kennzeichen gilt
  // weiterhin als abgelaufene Sitzung — vergisst jemand später eine
  // Kennzeichnung, ist das Ergebnis das alte Verhalten und nicht eine
  // Sitzung, die nie endet.
  if (res.status === 401 && data.code !== 'BAD_CREDENTIALS') {
    logout();
    throw new Error('Session abgelaufen');
  }
  if (!res.ok) {
    const err = new Error(data.message || `API Fehler (${res.status})`);
    err.status = res.status;
    err.data = data;
    throw err;
  }
  return data;
}
window.api = api;

// 5. theme_management
function initTheme() {
  const saved = localStorage.getItem('theme');
  if (saved) {
    document.documentElement.setAttribute('data-theme', saved);
  }
}

function toggleTheme() {
  const current = document.documentElement.getAttribute('data-theme');
  const next = current === 'dark' ? 'light' : 'dark';
  document.documentElement.setAttribute('data-theme', next);
  localStorage.setItem('theme', next);
}
window.toggleTheme = toggleTheme;

// 6. ui_utils
function showToast(msg, type = 'info') {
  const wrap = document.getElementById('toast-wrap');
  if (!wrap) return;
  const t = document.createElement('div');
  t.className = 'toast';
  t.textContent = msg;
  if (type === 'err') t.style.border = '1px solid var(--color-error)';
  if (type === 'ok') t.style.border = '1px solid var(--color-success)';
  wrap.appendChild(t);
  setTimeout(() => {
    t.style.opacity = '0';
    t.style.transition = 'opacity 0.3s';
    setTimeout(() => t.remove(), 300);
  }, 2600);
}
window.showToast = showToast;

function logout() {
  sessionStorage.clear();

  // localStorage.clear() hat auch das gespeicherte Farbschema gelöscht:
  // nach jedem Abmelden stand das Thema wieder auf dem Standard, obwohl es
  // zum Gerät gehört und nicht zur Sitzung.
  //
  // Alles Übrige wird weiterhin entfernt — das war die Absicht hinter dem
  // ursprünglichen clear() und bleibt richtig, damit nichts vom vorigen
  // Benutzer auf einem gemeinsam genutzten Gerät zurückbleibt.
  const anzeigeEinstellungen = ['theme'];
  const gemerkt = {};
  anzeigeEinstellungen.forEach(schluessel => {
    const wert = localStorage.getItem(schluessel);
    if (wert !== null) gemerkt[schluessel] = wert;
  });
  localStorage.clear();
  Object.keys(gemerkt).forEach(schluessel => {
    localStorage.setItem(schluessel, gemerkt[schluessel]);
  });
  window.location.href = 'index.html';
}
window.logout = logout;

// 7. formatters
function fmtDate(d) {
  return new Date(d).toLocaleString('de-DE', {
    day: '2-digit', month: '2-digit', year: 'numeric',
    hour: '2-digit', minute: '2-digit'
  });
}
window.fmtDate = fmtDate;

function fmtTime(d) {
  return new Date(d).toLocaleTimeString('de-DE', { hour: '2-digit', minute: '2-digit' });
}
window.fmtTime = fmtTime;

function fmtRelative(dateInput) {
  const d = new Date(dateInput);
  const diff = Date.now() - d.getTime();
  const min = Math.floor(diff / 60000);
  const hr = Math.floor(min / 60);
  const day = Math.floor(hr / 24);

  if (min < 1) return 'Gerade eben';
  if (min < 60) return `vor ${min} Min.`;
  if (hr < 24) return `vor ${hr} Std.`;
  if (day < 7) return `vor ${day} Tagen`;
  return fmtDate(d);
}
window.fmtRelative = fmtRelative;

function animVal(id, target) {
  const el = document.getElementById(id);
  if (!el) return;
  const start = parseFloat(el.textContent) || 0;
  const diff = target - start;
  let step = 0;
  const t = setInterval(() => {
    step++;
    el.textContent = Math.round((start + diff * step / 12) * 10) / 10;
    if (step >= 12) { el.textContent = target; clearInterval(t); }
  }, 18);
}
window.animVal = animVal;

// 8. report_sending
// جایگزین sendTelegramReport قدیمی — الان snapshot هم ذخیره می‌کند، نه فقط ارسال تلگرام
async function sendReportNow() {
  showToast('📤 Bericht wird erstellt und gesendet...', 'info');
  try {
    const result = await api('/api/reports/send-now', 'POST');
    if (result.telegramError) {
      showToast('⚠️ Bericht gespeichert, Telegram-Versand fehlgeschlagen: ' + result.telegramError, 'err');
    } else {
      showToast('✅ Bericht gesendet und gespeichert!', 'ok');
    }
    return result;
  } catch (e) {
    showToast('⚠️ ' + e.message, 'err');
    throw e;
  }
}
window.sendReportNow = sendReportNow;

// 8b. bestandsschreiber
// Schreibt Bestände gebündelt und je Produkt nacheinander.
//
// Warum: das Formular nimmt eine ABSOLUTE Zählung, und die ± Knöpfe rechnen
// sie aus dem zuletzt bekannten Stand aus. Ohne Bündelung schickten drei
// Klicks in einer Sekunde dreimal dieselbe veraltete Version mit, bekamen
// 409 und behaupteten, jemand anderes habe geschrieben — obwohl es derselbe
// Nutzer war. Jetzt gilt:
//   · die Anzeige folgt dem Klick sofort (der Nutzer wartet auf nichts)
//   · nach kurzer Ruhe geht EINE Anfrage mit dem Endwert
//   · je Produkt läuft immer nur eine Anfrage; die nächste nimmt die
//     Version, die deren Antwort zurückgegeben hat
//   · ein 409 bedeutet damit wirklich: jemand anderes war schneller
//
// Alles von außen hereingereicht, damit test/unit/stock-writer.test.js das
// ohne Browser prüfen kann.
function createBestandsschreiber({ holeProdukt, zeichne, melde, frage, schreibe, verzoegerung = 400 }) {
  const zustaende = new Map();

  function zustand(id) {
    if (!zustaende.has(id)) {
      zustaende.set(id, { ziel: null, timer: null, laeuft: false, bestaetigt: undefined });
    }
    return zustaende.get(id);
  }

  function setzen(id, wert) {
    const p = holeProdukt(id);
    if (!p) return;
    const s = zustand(id);
    // Der zuletzt vom Server bestätigte Stand — die Anzeige läuft ihm voraus.
    if (s.bestaetigt === undefined) s.bestaetigt = p.currentStock;
    p.currentStock = wert;
    s.ziel = wert;
    zeichne();
    if (s.timer) clearTimeout(s.timer);
    s.timer = setTimeout(function () { s.timer = null; abarbeiten(id); }, verzoegerung);
  }

  function aendern(id, delta) {
    const p = holeProdukt(id);
    if (!p) return;
    setzen(id, Math.max(0, Math.round(((p.currentStock || 0) + delta) * 10) / 10));
  }

  async function abarbeiten(id) {
    const s = zustand(id);
    if (s.laeuft) return;            // die laufende Schleife holt sich das Ziel selbst
    s.laeuft = true;
    try {
      while (s.ziel !== null) {
        const wert = s.ziel;
        s.ziel = null;
        const p = holeProdukt(id);
        if (!p) break;
        if (wert === s.bestaetigt) continue;

        try {
          const neu   = await schreibe(id, wert, p.updatedAt);
          const offen = s.ziel;      // in der Zwischenzeit weitergeklickt?
          Object.assign(p, neu);
          s.bestaetigt = neu.currentStock;
          if (offen !== null) p.currentStock = offen;
          zeichne();
        } catch (e) {
          if (e && e.status === 409 && e.data && e.data.code === 'STOCK_CONFLICT') {
            p.currentStock = e.data.currentStock;
            p.updatedAt    = e.data.updatedAt;
            s.bestaetigt   = e.data.currentStock;
            s.ziel = null;
            zeichne();
            const weiter = frage(
              'Jemand anderes hat den Bestand inzwischen auf ' + e.data.currentStock + ' geändert.' +
              '\n\nDeine Zählung war ' + wert + '.' +
              '\n\nTrotzdem ' + wert + ' eintragen?'
            );
            if (weiter) { p.currentStock = wert; s.ziel = wert; zeichne(); }
          } else {
            s.ziel = null;
            if (s.bestaetigt !== undefined) p.currentStock = s.bestaetigt;
            melde('⚠️ ' + ((e && e.message) || 'Fehler'));
            zeichne();
          }
        }
      }
    } finally {
      s.laeuft = false;
    }
  }

  return { setzen, aendern };
}
window.createBestandsschreiber = createBestandsschreiber;

// 8c. aktionen
// Ersetzt onclick="…" im Markup. Ein Element trägt data-action="name", und
// EIN Listener am Dokument ruft die registrierte Funktion — auch für Zeilen,
// die erst später gerendert werden, ohne erneutes Anbinden.
//
// Warum nicht einfach onclick: helmet setzt script-src-attr 'none', und das
// Ziel von Phase F ist, diese Sperre wieder zu schließen. Nebenbei landet
// kein Wert mehr in einem JS-String im HTML — genau der Weg, über den früher
// ein Kategoriename Code ausführen konnte (siehe Kommentar in dashboard.js).
const _aktionen = Object.create(null);

function registriereAktionen(tabelle) {
  for (const name of Object.keys(tabelle)) {
    const fn = tabelle[name];
    if (_aktionen[name] && _aktionen[name] !== fn) {
      console.warn('[Aktionen] "' + name + '" wird überschrieben');
    }
    _aktionen[name] = fn;
  }
}

function aktionIstRegistriert(name) {
  return typeof _aktionen[name] === 'function';
}

// Getrennt vom Listener, damit Tests sie ohne Browser aufrufen können.
function aktionAusfuehren(ereignis) {
  const ziel = ereignis && ereignis.target;
  const el = ziel && typeof ziel.closest === 'function' ? ziel.closest('[data-action]') : null;
  if (!el) return false;
  const name = el.dataset ? el.dataset.action : undefined;
  const fn = _aktionen[name];
  if (typeof fn !== 'function') {
    // Ein Tippfehler in data-action soll auffallen, nicht still scheitern.
    console.warn('[Aktionen] unbekannte Aktion:', name);
    return false;
  }
  try {
    const ergebnis = fn(el, ereignis);
    // Async-Aktionen: eine Ablehnung wird protokolliert statt als
    // "Uncaught (in promise)" in der Konsole zu landen.
    if (ergebnis && typeof ergebnis.then === 'function') {
      ergebnis.then(null, function (err) { console.error('[Aktionen] ' + name + ':', err); });
    }
  } catch (err) {
    console.error('[Aktionen] ' + name + ':', err);
  }
  return true;
}

document.addEventListener('click', aktionAusfuehren);

// Die Seitenleiste erscheint auf JEDER Seite, also gehören ihre Aktionen
// hierher. sendReportNow zeigt eine Fehlermeldung selbst und wirft dann
// weiter — hier gibt es niemanden mehr, der darauf reagieren müsste.
registriereAktionen({
  berichtSenden:          function () { return sendReportNow().catch(function () {}); },
  abmelden:               function () { logout(); },
  themaWechseln:          function () { toggleTheme(); },
  seitenleisteUmschalten: function () { toggleSidebar(); }
});

window.registriereAktionen  = registriereAktionen;
window.aktionIstRegistriert = aktionIstRegistriert;
window.aktionAusfuehren     = aktionAusfuehren;

// 9. csv_export (für ältere Exporte; Excel/PDF läuft über /api/reports/export)
function downloadCSV(rows, filename) {
  const BOM = '\uFEFF';
  const csv = BOM + rows
    .map(r => r.map(v => '"' + String(v ?? '').replace(/"/g, '""') + '"').join(','))
    .join('\n');
  const blob = new Blob([csv], { type: 'text/csv;charset=utf-8' });
  const url  = URL.createObjectURL(blob);
  const a    = document.createElement('a');
  a.href     = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}
window.downloadCSV = downloadCSV;

// خروجی Excel/PDF را در تب جدید دانلود می‌کند (با توکن لاگین، چون export پشت auth است)
async function downloadReportFile(type, params = {}) {
  const qs = new URLSearchParams({ type, ...params }).toString();
  try {
    const res = await fetch(`/api/reports/export?${qs}`, {
      headers: { 'Authorization': `Bearer ${token}` }
    });
    if (!res.ok) {
      const data = await res.json().catch(() => ({}));
      throw new Error(data.message || `Export fehlgeschlagen (${res.status})`);
    }
    const blob = await res.blob();
    const disposition = res.headers.get('Content-Disposition') || '';
    const match = disposition.match(/filename=([^;]+)/);
    const filename = match ? match[1].trim() : `EDEKA_Lager.${type === 'excel' ? 'xlsx' : 'pdf'}`;

    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    a.click();
    URL.revokeObjectURL(url);
  } catch (e) {
    showToast('⚠️ ' + e.message, 'err');
  }
}
window.downloadReportFile = downloadReportFile;

// 10. dynamic_categories_units
// دسته‌بندی‌ها و واحدها دیگر هاردکد نیستند — اینجا کش می‌شوند تا در هر صفحه دوباره fetch نشوند
let _categoriesCache = null;
let _unitsCache = null;

async function loadCategories(force = false) {
  if (_categoriesCache && !force) return _categoriesCache;
  _categoriesCache = await api('/api/categories');
  return _categoriesCache;
}
window.loadCategories = loadCategories;

async function loadUnits(force = false) {
  if (_unitsCache && !force) return _unitsCache;
  _unitsCache = await api('/api/units');
  return _unitsCache;
}
window.loadUnits = loadUnits;

async function createCategory(name, emoji = '📦') {
  const cat = await api('/api/categories', 'POST', { name, emoji });
  _categoriesCache = null; // کش را باطل کن تا دفعه‌ی بعد تازه بیاید
  return cat;
}
window.createCategory = createCategory;

async function createUnit(name) {
  const unit = await api('/api/units', 'POST', { name });
  _unitsCache = null;
  return unit;
}
window.createUnit = createUnit;

// یک <select> را با گزینه‌ها پر می‌کند و یک گزینه‌ی "+ Neu…" در آخر اضافه می‌کند
function fillSelectWithAddOption(selectEl, items, { valueKey = 'name', labelFn = null, selected = null } = {}) {
  selectEl.innerHTML = '';
  items.forEach(item => {
    const opt = document.createElement('option');
    opt.value = item[valueKey];
    opt.textContent = labelFn ? labelFn(item) : item[valueKey];
    if (selected && item[valueKey] === selected) opt.selected = true;
    selectEl.appendChild(opt);
  });
  const addOpt = document.createElement('option');
  addOpt.value = '__add_new__';
  addOpt.textContent = '+ Neu…';
  selectEl.appendChild(addOpt);
}
window.fillSelectWithAddOption = fillSelectWithAddOption;

// 11. user_agent_parser
function parseUA(ua) {
  if (!ua) return 'Unbekannt';
  if (ua.includes('curl')) return '⌨️ Terminal';
  if (ua.includes('iPhone') || ua.includes('Android')) return '📱 Mobil';
  if (ua.includes('Chrome')) return '💻 Chrome';
  if (ua.includes('Firefox')) return '🦊 Firefox';
  if (ua.includes('Safari')) return '🧭 Safari';
  return '💻 Desktop';
}
window.parseUA = parseUA;

// 12. SIDEBAR INJECTION & LOGIC
function toggleSidebar() {
  const sidebar = document.getElementById('sidebar');
  const overlay = document.getElementById('sidebar-overlay');
  if (sidebar) sidebar.classList.toggle('open');
  if (overlay) overlay.classList.toggle('open');
}
window.toggleSidebar = toggleSidebar;

function closeSidebar() {
  const sidebar = document.getElementById('sidebar');
  const overlay = document.getElementById('sidebar-overlay');
  if (sidebar) sidebar.classList.remove('open');
  if (overlay) overlay.classList.remove('open');
}
window.closeSidebar = closeSidebar;

function injectSidebar() {
  const sidebar = document.getElementById('sidebar');
  if (!sidebar) return;

  const path = window.location.pathname;
  const isAdmin = currentUser.role === 'admin';

  sidebar.innerHTML = `
    <div class="sidebar-header">
      <div class="sidebar-logo-mark">🛒</div>
      <div class="sidebar-logo-text">
        <div class="sidebar-app-name">EDEKA Lager</div>
        <div class="sidebar-app-sub">Wir lieben Lebensmittel</div>
      </div>
    </div>

    <div class="nav-section-title">Hauptmenü</div>
    <a class="nav-item ${path.includes('dashboard') ? 'active' : ''}" href="dashboard.html">
      <span class="nav-icon">📦</span> Bestandsübersicht
    </a>
    <a class="nav-item ${path.includes('analytics') ? 'active' : ''}" href="analytics.html">
      <span class="nav-icon">📊</span> Analyse &amp; Berichte
    </a>
    <a class="nav-item ${path.includes('reports') ? 'active' : ''}" href="reports.html">
      <span class="nav-icon">📅</span> Tagesberichte
    </a>

    <div class="nav-section-title">Verwaltung</div>
    <button class="nav-item" data-action="berichtSenden" style="width:100%; text-align:left;">
      <span class="nav-icon">📤</span> Bericht jetzt senden
    </button>
    ${isAdmin ? `
      <a class="nav-item ${path.includes('users') ? 'active' : ''}" href="users.html">
        <span class="nav-icon">👥</span> Benutzerverwaltung
      </a>
    ` : ''}

    <div class="sidebar-footer">
      <div class="user-card">
        <div class="user-avatar" id="user-avatar">${(currentUser.name || 'A')[0].toUpperCase()}</div>
        <div class="user-info">
          <div class="user-name" id="user-name-display">${escapeHtml(currentUser.name || 'Administrator')}</div>
          <div class="user-role" id="user-role-display">${escapeHtml(currentUser.role || 'lagerist')}</div>
        </div>
        <button class="logout-btn" data-action="abmelden" title="Abmelden">
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4M16 17l5-5-5-5M21 12H9"/>
          </svg>
        </button>
      </div>
    </div>
  `;

  if (!document.getElementById('sidebar-overlay')) {
    const overlay = document.createElement('div');
    overlay.className = 'sidebar-overlay';
    overlay.id = 'sidebar-overlay';
    overlay.onclick = closeSidebar;
    document.body.appendChild(overlay);
  }
}

// 13. dom_init
document.addEventListener('DOMContentLoaded', () => {
  initTheme();
  injectSidebar();

  const elDate = document.getElementById('topbar-date');
  if (elDate) {
    elDate.textContent = new Date().toLocaleDateString('de-DE', {
      weekday: 'long', year: 'numeric', month: 'long', day: 'numeric'
    });
  }
});
