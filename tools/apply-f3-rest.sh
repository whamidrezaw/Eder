#!/usr/bin/env bash
#
# apply-f3-rest.sh — Phase F, Schritte B2 + B3: die übrigen vier Seiten, dann
#                    die CSP wieder schließen
#
# B2  analytics, reports, users, index: 46 Inline-Handler → data-action.
#     Die /* exported */-Markierungen aus Schritt A fallen weg — sie sagen
#     "wird aus Inline-Handlern aufgerufen", und das stimmt dann nicht mehr.
#
# B3  app.js: script-src-attr von 'unsafe-inline' auf ausdrücklich 'none'.
#
# Beides MUSS zusammen passieren. Sind alle Handler weg, verlangt
# csp-markup.test.js von selbst, dass die CSP sie wieder verbietet — genau
# dafür wurde er als Gleichung gebaut. B2 ohne B3 wäre rot.
#
# Vier Stellen, die ein blinder Umbau gebrochen hätte:
#   · onclick="if(event.target===this) closeDrawer()" — schließt nur beim
#     Klick auf den abgedunkelten Hintergrund selbst. Per Delegation fände
#     closest() diesen Hintergrund von JEDEM Klick im Dialog aus; ohne die
#     Bedingung schlösse jeder Klick in ein Formularfeld den Dialog.
#   · setFilter('all', this) — "this" ist der Knopf, der als aktiv markiert
#     wird. Er wird weitergereicht.
#   · index.html lädt shared.js bewusst nicht — dort gibt es keine Registry,
#     also direkte Anbindung.
#   · Zwei Eingabefelder mit unbekannter id (Benutzersuche, Anmeldung):
#     statt eine id zu raten, ersetzt ein data-Merkmal das Attribut.
#
# Ausführen im Wurzelverzeichnis des Repos:
#     bash apply-f3-rest.sh
#
set -euo pipefail

BE="Edeka.lager/backend"
FE="Edeka.lager/frontend"
SELBST="$(basename "$0")"
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
die()  { printf '\n  \033[31m✗ %s\033[0m\n\n' "$1" >&2; exit 1; }

echo
echo "── Phase F, Schritte B2 + B3: übrige Seiten, CSP schließen ─────"
echo

for f in analytics.html reports.html users.html index.html \
         assets/analytics.js assets/reports.js assets/users.js assets/index.js assets/shared.js; do
  [ -f "$FE/$f" ] || die "'$FE/$f' nicht gefunden."
done
[ -f "$BE/app.js" ] || die "'$BE/app.js' nicht gefunden."
T="$BE/test/unit/inline-handler.test.js"
[ -f "$T" ] || die "Schritt B1 fehlt ($T). Bitte zuerst apply-f2-dashboard.sh."
grep -q "function aktionAusfuehren" "$FE/assets/shared.js" || die "Der Aktionsverteiler fehlt in shared.js — Schritt B1 fehlt."

if command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
  BRANCH=$(git rev-parse --abbrev-ref HEAD)
  [ "$BRANCH" != "main" ] || die "Du bist auf main. Bitte auf phase-f wechseln."
  SCHMUTZ=$(git status --porcelain | grep -v -- "$SELBST" || true)
  [ -z "$SCHMUTZ" ] || { printf '%s\n' "$SCHMUTZ" | sed 's/^/     /'; die "Arbeitsverzeichnis nicht sauber (siehe oben)."; }
  ok "Branch '$BRANCH', Arbeitsverzeichnis sauber (ohne $SELBST)"
fi

# ── 1  Test erweitern — bei Abbruch wird die alte Fassung zurückgelegt ─
T_ALT=$(mktemp)
cp "$T" "$T_ALT"
FERTIG=0
aufraeumen() {
  if [ "$FERTIG" != "1" ]; then
    cp "$T_ALT" "$T"
    printf '  \033[90m·\033[0m Abbruch: Test auf den vorigen Stand zurückgesetzt\n' >&2
  fi
  rm -f "$T_ALT"
}
trap aufraeumen EXIT

echo
echo "── Test erweitern ──────────────────────────────────────────────"
node - "$T" <<'NODE_T'
const fs = require('fs');
const p = process.argv[2];
const t = fs.readFileSync(p, 'utf8');
if (/'index\.html'/.test(t)) { console.log('  \x1b[90m·\x1b[0m schon auf alle Seiten erweitert'); process.exit(0); }
const alt = "const UMGESTELLT = ['dashboard.html', 'assets/dashboard.js', 'assets/shared.js'];";
if (!t.includes(alt)) { console.log('  \x1b[31m✗ Liste UMGESTELLT sieht anders aus\x1b[0m'); process.exit(1); }
const neu = [
  'const UMGESTELLT = [',
  "  'dashboard.html', 'analytics.html', 'reports.html', 'users.html', 'index.html',",
  "  'assets/dashboard.js', 'assets/analytics.js', 'assets/reports.js',",
  "  'assets/users.js', 'assets/index.js', 'assets/shared.js'",
  '];'
].join('\n');
fs.writeFileSync(p, t.replace(alt, neu));
console.log('  \x1b[32m✓\x1b[0m inline-handler.test.js prüft jetzt alle fünf Seiten');
NODE_T

echo
echo "── Vorher: ROT erwartet ────────────────────────────────────────"
echo
( cd "$BE" && node --test --test-reporter=spec test/unit/inline-handler.test.js ) 2>&1 \
  | grep -E "^(✔|✖) |[0-9]+ Inline-Handler:" | awk '!seen[$0]++' | head -4 || true

# ── 2  Umbau (alles oder nichts) ─────────────────────────────────────
echo
echo "── Umbau (alles oder nichts) ───────────────────────────────────"
node - "$FE" "$BE" <<'NODE_F3'
const fs = require('fs'), path = require('path');
const FE = process.argv[2], BE = process.argv[3];
const dateien = {
  'analytics.html':      path.join(FE, 'analytics.html'),
  'reports.html':        path.join(FE, 'reports.html'),
  'users.html':          path.join(FE, 'users.html'),
  'index.html':          path.join(FE, 'index.html'),
  'assets/analytics.js': path.join(FE, 'assets', 'analytics.js'),
  'assets/reports.js':   path.join(FE, 'assets', 'reports.js'),
  'assets/users.js':     path.join(FE, 'assets', 'users.js'),
  'assets/index.js':     path.join(FE, 'assets', 'index.js'),
  'app.js':              path.join(BE, 'app.js'),
  'eslint.config.js':    path.join(BE, '..', 'eslint.config.js')
};
const alt = {}, neu = {};
for (const [k, f] of Object.entries(dateien)) { alt[k] = fs.readFileSync(f, 'utf8'); neu[k] = alt[k]; }
const fehler = [], meldungen = [];

function ersetze(k, suche, durch, n) {
  const ist = neu[k].split(suche).length - 1;
  if (ist !== n) { fehler.push(`${k}: "${suche}" ${ist}× statt ${n}×`); return; }
  neu[k] = neu[k].split(suche).join(durch);
}
function anhaengen(k, zeilen) { neu[k] = neu[k].replace(/\s*$/, '') + '\n' + zeilen.join('\n') + '\n'; }

const EXPORTED = /^\/\/ Diese Funktionen werden aus Inline-Handlern im HTML aufgerufen, das\n\/\/ ESLint nicht liest\. Bis Schritt B sie per addEventListener anbindet,\n\/\/ sagt die folgende Zeile ESLint, dass sie benutzt werden\.\n\/\* exported [^*]*\*\/\n/;
function ohneExported(k) {
  if (!EXPORTED.test(neu[k])) { fehler.push(`${k}: /* exported */-Block nicht gefunden`); return; }
  neu[k] = neu[k].replace(EXPORTED, '');
}

// ── analytics ─────────────────────────────────────────────────────
if (/registriereAktionen\(/.test(neu['assets/analytics.js'])) {
  meldungen.push('\x1b[90m·\x1b[0m analytics: schon umgestellt');
} else {
  for (const [s, d, n] of [
    ['onclick="toggleSidebar()"',               'data-action="seitenleisteUmschalten"', 1],
    ['onclick="toggleTheme()"',                 'data-action="themaWechseln"', 1],
    ['onclick="handleSendReport()"',            'data-action="berichtSendenUndAktualisieren"', 1],
    ["onclick=\"switchTab('today')\"",          'data-action="tabWechseln" data-tab="today"', 1],
    ["onclick=\"switchTab('trend')\"",          'data-action="tabWechseln" data-tab="trend"', 1],
    ["onclick=\"downloadReportFile('excel', {})\"", 'data-action="exportLive" data-typ="excel"', 1],
    ["onclick=\"downloadReportFile('pdf', {})\"",   'data-action="exportLive" data-typ="pdf"', 1],
    [' onchange="loadTrend()"',                 '', 1]
  ]) ersetze('analytics.html', s, d, n);
  ersetze('assets/analytics.js', "onclick=\"downloadReportFile('excel', {logId:'${r._id}'})\"",
          'data-action="exportBericht" data-typ="excel" data-log-id="${escapeHtml(r._id)}"', 1);
  ersetze('assets/analytics.js', "onclick=\"downloadReportFile('pdf', {logId:'${r._id}'})\"",
          'data-action="exportBericht" data-typ="pdf" data-log-id="${escapeHtml(r._id)}"', 1);
  anhaengen('assets/analytics.js', [
    '',
    '// ── Aktionen (Phase F, Schritt B2) ───────────────────────────────',
    'registriereAktionen({',
    '  // handleSendReport sendet und lädt danach "Heute" neu. Schlägt das',
    '  // Senden fehl, zeigt sendReportNow die Meldung selbst und wirft weiter —',
    '  // hier abgefangen, sonst "Uncaught (in promise)".',
    '  berichtSendenUndAktualisieren: function () { return handleSendReport().catch(function () {}); },',
    '  tabWechseln:   function (el) { switchTab(el.dataset.tab); },',
    '  exportLive:    function (el) { return downloadReportFile(el.dataset.typ, {}); },',
    '  exportBericht: function (el) { return downloadReportFile(el.dataset.typ, { logId: el.dataset.logId }); }',
    '});',
    "document.getElementById('period-select').addEventListener('change', function () { loadTrend(); });"
  ]);
  meldungen.push('\x1b[32m✓\x1b[0m analytics: 10 Handler');
}

// ── reports ───────────────────────────────────────────────────────
if (/registriereAktionen\(/.test(neu['assets/reports.js'])) {
  meldungen.push('\x1b[90m·\x1b[0m reports: schon umgestellt');
} else {
  for (const [s, d, n] of [
    ['onclick="if(event.target===this) closeDrawer()"', 'data-action="drawerHintergrund"', 1],
    ['onclick="toggleSidebar()"',             'data-action="seitenleisteUmschalten"', 1],
    ['onclick="toggleTheme()"',               'data-action="themaWechseln"', 1],
    ['onclick="openAdminTools()"',            'data-action="adminWerkzeugeOeffnen"', 1],
    [' onchange="loadHistory()"',             '', 1],
    ['onclick="closeDrawer()"',               'data-action="drawerSchliessen"', 1],
    ['onclick="closeAdminTools()"',           'data-action="adminWerkzeugeSchliessen"', 1],
    ["onclick=\"adminResetLogs('daily')\"",   'data-action="logsLoeschen" data-bereich="daily"', 1],
    ["onclick=\"adminResetLogs('weekly')\"",  'data-action="logsLoeschen" data-bereich="weekly"', 1],
    ["onclick=\"adminResetLogs('monthly')\"", 'data-action="logsLoeschen" data-bereich="monthly"', 1],
    ["onclick=\"adminResetLogs('all')\"",     'data-action="logsLoeschen" data-bereich="all"', 1],
    ['onclick="adminCloseDay()"',             'data-action="tagAbschliessen"', 1],
    ['onclick="closeConfirm()"',              'data-action="bestaetigungSchliessen"', 1]
  ]) ersetze('reports.html', s, d, n);
  ersetze('assets/reports.js', "onclick=\"openDrawer('${row._id}', '${row.date}')\"",
          'data-action="berichtOeffnen" data-log-id="${escapeHtml(row._id)}" data-datum="${escapeHtml(row.date)}"', 1);
  anhaengen('assets/reports.js', [
    '',
    '// ── Aktionen (Phase F, Schritt B2) ───────────────────────────────',
    'registriereAktionen({',
    '  adminWerkzeugeOeffnen:    function () { openAdminTools(); },',
    '  adminWerkzeugeSchliessen: function () { closeAdminTools(); },',
    '  // Bisher onclick="if(event.target===this) closeDrawer()": nur ein Klick',
    '  // auf den abgedunkelten Hintergrund selbst schließt. closest() fände den',
    '  // Hintergrund auch von jedem Klick IM Drawer aus — daher die Bedingung.',
    '  drawerHintergrund:      function (el, e) { if (e.target === el) closeDrawer(); },',
    '  drawerSchliessen:       function () { closeDrawer(); },',
    '  logsLoeschen:           function (el) { adminResetLogs(el.dataset.bereich); },',
    '  tagAbschliessen:        function () { adminCloseDay(); },',
    '  bestaetigungSchliessen: function () { closeConfirm(); },',
    '  berichtOeffnen:         function (el) { return openDrawer(el.dataset.logId, el.dataset.datum); }',
    '});',
    "document.getElementById('limit-select').addEventListener('change', function () { loadHistory(); });"
  ]);
  meldungen.push('\x1b[32m✓\x1b[0m reports: 14 Handler');
}

// ── users ─────────────────────────────────────────────────────────
if (/registriereAktionen\(/.test(neu['assets/users.js'])) {
  meldungen.push('\x1b[90m·\x1b[0m users: schon umgestellt');
} else {
  for (const [s, d, n] of [
    ['onclick="if(event.target===this)closeUserModal()"', 'data-action="benutzerDialogHintergrund"', 1],
    ['onclick="toggleSidebar()"',                 'data-action="seitenleisteUmschalten"', 1],
    [' oninput="filterUsers()"',                  ' data-benutzersuche', 1],
    ['onclick="openCreateModal()"',               'data-action="benutzerNeu"', 1],
    ['onclick="toggleTheme()"',                   'data-action="themaWechseln"', 1],
    ["onclick=\"setFilter('all',this)\"",         'data-action="filterSetzen" data-filter="all"', 1],
    ["onclick=\"setFilter('admin',this)\"",       'data-action="filterSetzen" data-filter="admin"', 1],
    ["onclick=\"setFilter('lagerist',this)\"",    'data-action="filterSetzen" data-filter="lagerist"', 1],
    ["onclick=\"setFilter('active',this)\"",      'data-action="filterSetzen" data-filter="active"', 1],
    ["onclick=\"setFilter('inactive',this)\"",    'data-action="filterSetzen" data-filter="inactive"', 1],
    ['onclick="closeLogPanel()"',                 'data-action="protokollSchliessen"', 1],
    ['onclick="closeUserModal()"',                'data-action="benutzerDialogSchliessen"', 2],
    ['onclick="saveUser()"',                      'data-action="benutzerSpeichern"', 1],
    ['onclick="closeConfirm()"',                  'data-action="bestaetigungSchliessen"', 1],
    ['onclick="runConfirm()"',                    'data-action="bestaetigen"', 1]
  ]) ersetze('users.html', s, d, n);
  for (const [s, d] of [
    ["onclick=\"openLogPanel('${u._id}')\"",           'data-action="protokollOeffnen" data-id="${escapeHtml(u._id)}"'],
    ["onclick=\"openEditModal('${u._id}')\"",          'data-action="benutzerBearbeiten" data-id="${escapeHtml(u._id)}"'],
    ["onclick=\"confirmToggle('${u._id}')\"",          'data-action="benutzerUmschalten" data-id="${escapeHtml(u._id)}"'],
    ["onclick=\"confirmDeletePermanent('${u._id}')\"", 'data-action="benutzerLoeschen" data-id="${escapeHtml(u._id)}"']
  ]) ersetze('assets/users.js', s, d, 1);
  ohneExported('assets/users.js');
  anhaengen('assets/users.js', [
    '',
    '// ── Aktionen (Phase F, Schritt B2) ───────────────────────────────',
    'registriereAktionen({',
    '  benutzerNeu:               function () { openCreateModal(); },',
    '  // Bisher setFilter(\'all\', this) — der Knopf selbst wird gebraucht, um',
    '  // ihn als aktiven Reiter zu markieren.',
    '  filterSetzen:              function (el) { setFilter(el.dataset.filter, el); },',
    '  protokollOeffnen:          function (el) { openLogPanel(el.dataset.id); },',
    '  protokollSchliessen:       function () { closeLogPanel(); },',
    '  // Nur der Klick auf den Hintergrund selbst schließt — nicht einer in',
    '  // ein Formularfeld des Dialogs (siehe Kommentar in reports.js).',
    '  benutzerDialogHintergrund: function (el, e) { if (e.target === el) closeUserModal(); },',
    '  benutzerDialogSchliessen:  function () { closeUserModal(); },',
    '  benutzerSpeichern:         function () { return saveUser(); },',
    '  benutzerBearbeiten:        function (el) { openEditModal(el.dataset.id); },',
    '  benutzerUmschalten:        function (el) { confirmToggle(el.dataset.id); },',
    '  benutzerLoeschen:          function (el) { confirmDeletePermanent(el.dataset.id); },',
    '  bestaetigungSchliessen:    function () { closeConfirm(); },',
    '  bestaetigen:               function () { runConfirm(); }',
    '});',
    "// Die id des Suchfelds war im Quelltext nicht sichtbar; statt sie zu",
    "// raten, trägt das Feld jetzt das Merkmal data-benutzersuche.",
    "document.querySelector('[data-benutzersuche]').addEventListener('input', function () { filterUsers(); });"
  ]);
  meldungen.push('\x1b[32m✓\x1b[0m users: 20 Handler, /* exported */ entfernt');
}

// ── index ─────────────────────────────────────────────────────────
if (/data-fehler-zuruecksetzen/.test(neu['assets/index.js'])) {
  meldungen.push('\x1b[90m·\x1b[0m index: schon umgestellt');
} else {
  ersetze('index.html', 'oninput="clearError()"', 'data-fehler-zuruecksetzen', 2);
  ohneExported('assets/index.js');
  const kopfAlt = "// Ein Kommentar vor 'use strict' ist unschaedlich: die Direktive muss die\n// erste ANWEISUNG sein, nicht die erste Zeile.\n";
  ersetze('assets/index.js', kopfAlt,
    "// Anders als die übrigen Seiten hat diese Datei KEIN 'use strict' — die\n" +
    "// Anmeldeseite lief schon immer im nicht-strikten Modus. Das bleibt so, bis\n" +
    "// es jemand bewusst prüft: eine Verlagerung ändert kein Verhalten.\n", 1);
  anhaengen('assets/index.js', [
    '',
    '// ── Anbindung (Phase F, Schritt B2) ──────────────────────────────',
    '// Bisher oninput="clearError()" an beiden Eingabefeldern. Diese Seite lädt',
    '// shared.js bewusst nicht — es gibt hier keine Registry, also direkt.',
    "document.querySelectorAll('[data-fehler-zuruecksetzen]').forEach(function (el) {",
    "  el.addEventListener('input', function () { clearError(); });",
    '});'
  ]);
  meldungen.push('\x1b[32m✓\x1b[0m index: 2 Handler, /* exported */ entfernt, Kopfkommentar berichtigt');
}

// ── B3: app.js — script-src-attr wieder zu ────────────────────────
if (/scriptSrcAttr: \["'none'"\]/.test(neu['app.js'])) {
  meldungen.push("\x1b[90m·\x1b[0m app.js: script-src-attr schon 'none'");
} else {
  const block = /\n([ \t]*)\/\/ VORÜBERGEHEND bis Phase F\.\n[\s\S]*?\n[ \t]*scriptSrcAttr: \["'unsafe-inline'"\],/;
  if (!block.test(neu['app.js'])) {
    fehler.push("app.js: der vorübergehende scriptSrcAttr-Block wurde nicht gefunden");
  } else {
    neu['app.js'] = neu['app.js'].replace(block, (_m, e) => [
      '',
      e + "// script-src-attr ausdrücklich 'none': kein onclick=\"…\" im Markup wird",
      e + "// ausgeführt. Bis Phase F stand hier vorübergehend 'unsafe-inline', weil",
      e + '// das Frontend seine Knöpfe mit solchen Attributen baute; seit Phase F',
      e + '// hängt jeder Knopf an data-action (shared.js). Ausdrücklich gesetzt statt',
      e + '// der Voreinstellung von helmet überlassen: eine neue Version soll das',
      e + '// nicht still ändern können. csp-markup.test.js hält CSP und Markup',
      e + '// zusammen.',
      e + "scriptSrcAttr: [\"'none'\"],"
    ].join('\n'));
    meldungen.push("\x1b[32m✓\x1b[0m app.js: script-src-attr 'none'");
  }
}

// ── eslint.config.js: auch "async function" als Name aus shared.js ─
// Das Muster aus Schritt A kannte nur function/const/let/var. shared.js
// deklariert aber etwa downloadReportFile als "async function". Solange der
// Aufruf nur in einem onclick-String stand, sah ESLint ihn nie; jetzt ist er
// echter Code, und ohne diese Korrektur meldet ESLint no-undef.
{
  const k = 'eslint.config.js';
  if (neu[k].includes('async\\s+function')) {
    meldungen.push('\x1b[90m·\x1b[0m eslint.config.js: erkennt async function schon');
  } else {
    const suche = '(?:function|const|let|var)\\s+';
    const L = neu[k].split('\n');
    const i = L.findIndex(z => z.includes(suche));
    if (i === -1 || neu[k].split(suche).length - 1 !== 1) {
      fehler.push('eslint.config.js: das sharedGlobals-Muster nicht genau einmal gefunden');
    } else {
      const e = L[i].match(/^\s*/)[0];
      L[i] = L[i].replace(suche, '(?:async\\s+function\\*?|function\\*?|const|let|var)\\s+');
      L.splice(i, 0,
        e + '// Auch "async function" und "function*": shared.js deklariert etwa',
        e + '// downloadReportFile so. Die erste Fassung übersah das — sichtbar erst,',
        e + '// als ein Aufruf aus einem onclick-String zu echtem Code wurde.');
      neu[k] = L.join('\n');
      meldungen.push('\x1b[32m✓\x1b[0m eslint.config.js: erkennt jetzt auch async function');
    }
  }
}

// ── Prüfung vor dem Schreiben ─────────────────────────────────────
for (const k of Object.keys(dateien)) {
  if (!k.endsWith('.js') || neu[k] === alt[k]) continue;
  try { new Function(neu[k]); } catch (e) { fehler.push(`${k} wäre ungültig: ${e.message}`); }
}
const KOMMENTAR = /^\s*(\/\/|\/\*|\*|<!--)/;
for (const k of Object.keys(dateien)) {
  if (k === 'app.js') continue;
  neu[k].split('\n').forEach((z, i) => {
    if (KOMMENTAR.test(z)) return;
    for (const m of z.matchAll(/\s(on[a-z]+)\s*=\s*["']/gi)) fehler.push(`${k}:${i + 1} enthält noch ${m[1]}=`);
  });
}

if (fehler.length) {
  console.log('\n  \x1b[31mEs wurde NICHTS geändert:\x1b[0m');
  fehler.forEach(x => console.log('  \x1b[31m✗\x1b[0m ' + x));
  console.log('');
  process.exit(1);
}
for (const [k, f] of Object.entries(dateien)) {
  if (neu[k] === alt[k]) continue;
  if (!fs.existsSync(f + '.f3.bak')) fs.writeFileSync(f + '.f3.bak', alt[k]);
  fs.writeFileSync(f, neu[k]);
}
meldungen.forEach(m => console.log('  ' + m));
NODE_F3

FERTIG=1

for f in "$FE"/assets/{analytics,reports,users,index,shared}.js "$BE/app.js"; do
  node --check "$f" >/dev/null 2>&1 || die "Syntaxfehler in $f — rückgängig mit: git checkout ."
done
ok "syntaktisch gültig"

lauf() {
  local aus
  aus=$( cd "$BE" && npm run "$1" 2>&1 || true )
  printf '%s\n' "$aus" | grep -E "^(ℹ|#) (tests|pass|fail) " | sed "s/^/    [$1] /" >&2 || true
  printf '%s\n' "$aus" | grep -E "^(ℹ|#) fail " | awk '{print $3}' | tail -1 || true
}

echo
echo "── Nachher: GRÜN erwartet ──────────────────────────────────────"
echo
( cd "$BE" && node --test --test-reporter=spec test/unit/inline-handler.test.js test/integration/csp-markup.test.js ) 2>&1 \
  | grep -E "^(✔|✖) " || true
echo
U=$(lauf test:unit); I=$(lauf test:integration)
echo "  Unit: fail=${U:-?}   Integration: fail=${I:-?}"
[ "${U:-1}" = "0" ] && [ "${I:-1}" = "0" ] || die "Tests nicht grün — rückgängig mit: git checkout ."
ok "alle Tests grün"

set +e
LINT_AUS=$( cd "$BE" && npm run lint 2>&1 ); LINT=$?
set -e
[ "$LINT" -eq 0 ] && ok "Lint sauber" || { printf '%s\n' "$LINT_AUS" | grep -vE "^>|^$"; die "Lint meldet etwas — rückgängig mit: git checkout ."; }

echo
echo "── Danach ──────────────────────────────────────────────────────"
echo
echo "  Erwartet: 81 Unit- und 85 Integrationstests grün."
echo "  Die CSP verbietet jetzt wieder jeden Inline-Handler."
echo
echo "  IM BROWSER — App NEU STARTEN (app.js hat sich geändert), dann Strg+F5:"
echo "   analytics  Reiter Heute/Verlauf, Excel/PDF live, Zeitraum wechseln"
echo "   reports    Bericht öffnen; im Drawer IN den Inhalt klicken (bleibt"
echo "              offen!), dann auf den dunklen Rand klicken (schließt)"
echo "   users      Filter-Reiter (der aktive wird markiert), Suche tippen,"
echo "              neuer Benutzer: IN ein Feld klicken (Dialog bleibt offen!)"
echo "   index      abmelden, falsches Passwort eingeben, dann tippen —"
echo "              die Fehlermeldung verschwindet"
echo "   Konsole: KEINE Zeile mit script-src-attr, KEINE mit [Aktionen]."
echo
echo "    mkdir -p tools && mv $SELBST tools/"
echo "    git add -A && git commit -m 'Phase F Schritte B2+B3: alle Seiten ohne Inline-Handler, CSP zu'"
echo "    git push"
echo
echo "  Rückgängig:  git checkout ."
echo
