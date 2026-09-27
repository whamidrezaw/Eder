#!/usr/bin/env bash
#
# apply-f2-dashboard.sh — Phase F, Schritt B1: Dashboard ohne Inline-Handler
#
# Ersetzt alle 22 Inline-Handler des Dashboards und der gemeinsamen
# Seitenleiste durch data-action. Ein Element trägt data-action="name", EIN
# Listener auf dem Dokument (in shared.js) ruft die registrierte Funktion.
#
#   shared.js        registriereAktionen / aktionAusfuehren, Seitenleiste
#   dashboard.js     Tabellenzeilen (±, Bestandsfeld, Bearbeiten, Löschen)
#                    und die Registrierung aller Dashboard-Aktionen
#   dashboard.html   14 statische Handler
#   csp-markup.test  Kommentarzeilen zählen nicht mehr als Handler
#
# Vier Stellen, an denen ein blinder Umbau gebrochen hätte, alle am echten
# Quelltext geprüft:
#   · onsubmit="return submitProductForm(event)" — unkritisch, die Funktion
#     ruft selbst als Erstes evt.preventDefault().
#   · onblur — blur steigt nicht auf. Ein Listener am Dokument hört es nie;
#     deshalb focusout.
#   · sendReportNow().then(refreshAll) — bei Fehler blieb die Ablehnung
#     unbehandelt. Jetzt fängt der Verteiler jede Ablehnung ab.
#   · dashboard.js:112 enthält onclick="..." in einem KOMMENTAR, der eine
#     alte XSS-Korrektur erklärt. Der CSP-Test zählte ihn als Handler und
#     hätte die CSP für immer offen gehalten.
#
# Ausführen im Wurzelverzeichnis des Repos:
#     bash apply-f2-dashboard.sh
#
set -euo pipefail

BE="Edeka.lager/backend"
FE="Edeka.lager/frontend"
SELBST="$(basename "$0")"
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
die()  { printf '\n  \033[31m✗ %s\033[0m\n\n' "$1" >&2; exit 1; }

echo
echo "── Phase F, Schritt B1: Dashboard ohne Inline-Handler ──────────"
echo

for f in "$FE/dashboard.html" "$FE/assets/dashboard.js" "$FE/assets/shared.js" \
         "$BE/test/integration/csp-markup.test.js" "$BE/test/helpers/browser.js"; do
  [ -f "$f" ] || die "'$f' nicht gefunden."
done

if command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
  BRANCH=$(git rev-parse --abbrev-ref HEAD)
  [ "$BRANCH" != "main" ] || die "Du bist auf main. Bitte auf phase-f wechseln."
  SCHMUTZ=$(git status --porcelain | grep -v -- "$SELBST" || true)
  [ -z "$SCHMUTZ" ] || { printf '%s\n' "$SCHMUTZ" | sed 's/^/     /'; die "Arbeitsverzeichnis nicht sauber (siehe oben)."; }
  ok "Branch '$BRANCH', Arbeitsverzeichnis sauber (ohne $SELBST)"
fi

# ── 1  Tests, mit Aufräumen bei Abbruch ──────────────────────────────
T1="$BE/test/unit/aktionen.test.js"
T2="$BE/test/unit/inline-handler.test.js"
T1_DA=0; [ -f "$T1" ] && T1_DA=1
T2_DA=0; [ -f "$T2" ] && T2_DA=1
FERTIG=0
aufraeumen() {
  [ "$FERTIG" = "1" ] && return
  [ "$T1_DA" = "0" ] && rm -f "$T1"
  [ "$T2_DA" = "0" ] && rm -f "$T2"
  printf '  \033[90m·\033[0m Abbruch: angelegte Testdateien wieder entfernt\n' >&2
}
trap aufraeumen EXIT

echo
echo "── Tests schreiben ─────────────────────────────────────────────"
mkdir -p "$BE/test/unit"
cat > "$T1" <<'EOF'
'use strict';
//
// Der Aktionsverteiler in shared.js ersetzt onclick="…" im Markup.
//
// Ein Element trägt data-action="name"; EIN Listener am Dokument ruft
// aktionAusfuehren, und die sucht die registrierte Funktion. Geprüft wird
// hier die Verteilung selbst — ohne Browser, im vm-Harness.
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const { ladeShared } = require('../helpers/browser');

function element(action, daten = {}) {
  const el = { dataset: Object.assign({ action }, daten) };
  el.closest = (sel) => (sel === '[data-action]' ? el : null);
  return el;
}
const kindVon    = (eltern) => ({ closest: (sel) => eltern.closest(sel) });
const ohneAktion = () => ({ closest: () => null });

function aufbau() {
  const { sandbox } = ladeShared({ token: 'test-token' });
  assert.equal(typeof sandbox.registriereAktionen, 'function', 'registriereAktionen fehlt in shared.js');
  assert.equal(typeof sandbox.aktionAusfuehren,    'function', 'aktionAusfuehren fehlt in shared.js');
  return sandbox;
}

function mitKonsole(art, fn) {
  const zeilen = [];
  const alt = console[art];
  console[art] = (...a) => zeilen.push(a.map(String).join(' '));
  try { fn(); } finally { console[art] = alt; }
  return zeilen;
}

test('ein Klick auf ein Element mit data-action ruft die registrierte Funktion', () => {
  const s = aufbau();
  const aufrufe = [];
  s.registriereAktionen({ probe: (el) => aufrufe.push(el.dataset.id) });
  assert.equal(s.aktionAusfuehren({ target: element('probe', { id: 'p1' }) }), true);
  assert.deepEqual(aufrufe, ['p1']);
});

test('ein Klick auf ein Kind-Element im Knopf kommt ebenfalls an', () => {
  // Etwa das SVG im Abmelde-Knopf: das Ziel ist das Icon, nicht der Knopf.
  const s = aufbau();
  const aufrufe = [];
  s.registriereAktionen({ probe: () => aufrufe.push(1) });
  s.aktionAusfuehren({ target: kindVon(element('probe')) });
  assert.equal(aufrufe.length, 1);
});

test('ein Klick ohne data-action tut nichts', () => {
  const s = aufbau();
  assert.equal(s.aktionAusfuehren({ target: ohneAktion() }), false);
});

test('eine unbekannte Aktion wird gemeldet statt still zu scheitern', () => {
  const s = aufbau();
  let ergebnis;
  const warnungen = mitKonsole('warn', () => {
    ergebnis = s.aktionAusfuehren({ target: element('gibtEsNicht') });
  });
  assert.equal(ergebnis, false);
  assert.ok(warnungen.some(w => w.includes('gibtEsNicht')),
    'ein Tippfehler in data-action verschwände sonst spurlos');
});

test('eine abgelehnte async-Aktion wird abgefangen, nicht "Uncaught (in promise)"', async () => {
  const s = aufbau();
  let unbehandelt = null;
  const wache = (e) => { unbehandelt = e; };
  process.on('unhandledRejection', wache);
  const fehler = [];
  const alt = console.error;
  console.error = (...a) => fehler.push(a.map(String).join(' '));
  try {
    s.registriereAktionen({ kaputt: async () => { throw new Error('absichtlich'); } });
    s.aktionAusfuehren({ target: element('kaputt') });
    await new Promise(r => { setTimeout(r, 30); });
  } finally {
    console.error = alt;
    process.off('unhandledRejection', wache);
  }
  assert.equal(unbehandelt, null, 'die Ablehnung blieb unbehandelt');
  assert.ok(fehler.some(f => f.includes('absichtlich')), 'der Fehler wurde nicht protokolliert');
});

test('dieselbe Funktion zweimal registrieren ist still, eine andere unter gleichem Namen nicht', () => {
  const s = aufbau();
  const eins = () => {};
  const warnungen = mitKonsole('warn', () => {
    s.registriereAktionen({ doppelt: eins });
    s.registriereAktionen({ doppelt: eins });
    s.registriereAktionen({ doppelt: () => {} });
  });
  assert.equal(warnungen.length, 1, `erwartet eine Warnung, bekam ${warnungen.length}`);
});

test('die Seitenleiste bringt ihre Aktionen selbst mit', () => {
  // Sie werden auf JEDER Seite gebraucht, deshalb registriert shared.js sie.
  const s = aufbau();
  assert.equal(typeof s.aktionIstRegistriert, 'function');
  for (const name of ['berichtSenden', 'abmelden', 'themaWechseln', 'seitenleisteUmschalten']) {
    assert.ok(s.aktionIstRegistriert(name), `${name} fehlt`);
  }
});
EOF
cat > "$T2" <<'EOF'
'use strict';
//
// Umgestellte Seiten enthalten keinen Inline-Handler mehr.
//
// Die Liste wächst Seite für Seite. Stehen alle Seiten darin, gibt es
// nirgends mehr einen Inline-Handler — und csp-markup.test.js verlangt dann
// von selbst, dass die CSP wieder schließt.
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const fs     = require('node:fs');
const path   = require('node:path');

const FE = path.join(__dirname, '../../../frontend');

const UMGESTELLT = ['dashboard.html', 'assets/dashboard.js', 'assets/shared.js'];

// Kommentarzeilen sind keine Handler — dashboard.js erklärt in einem
// Kommentar, warum dort KEIN onclick="..." mehr steht.
const KOMMENTAR = /^\s*(\/\/|\/\*|\*|<!--)/;

test('umgestellte Seiten enthalten keinen Inline-Handler mehr', () => {
  const funde = [];
  for (const rel of UMGESTELLT) {
    fs.readFileSync(path.join(FE, rel), 'utf8').split('\n').forEach((zeile, i) => {
      if (KOMMENTAR.test(zeile)) return;
      for (const m of zeile.matchAll(/\s(on[a-z]+)\s*=\s*["']/gi)) funde.push(`${rel}:${i + 1} ${m[1]}`);
    });
  }
  assert.deepEqual(funde, [], `${funde.length} Inline-Handler:\n    ` + funde.join('\n    '));
});
EOF
for f in "$T1" "$T2"; do node --check "$f" >/dev/null 2>&1 || die "Syntaxfehler in $f"; done
ok "test/unit/aktionen.test.js (7 Tests)"
ok "test/unit/inline-handler.test.js (1 Test)"

echo
echo "── Vorher: ROT erwartet ────────────────────────────────────────"
echo
( cd "$BE" && node --test --test-reporter=spec test/unit/aktionen.test.js test/unit/inline-handler.test.js ) 2>&1 \
  | grep -E "^(✔|✖) |Inline-Handler:|fehlt in shared" | awk '!seen[$0]++' | head -14 || true

# ── 2  Umbau (alles oder nichts) ─────────────────────────────────────
echo
echo "── Umbau (alles oder nichts) ───────────────────────────────────"
node - "$FE" "$BE" <<'NODE_F2'
const fs = require('fs'), path = require('path');
const FE = process.argv[2], BE = process.argv[3];
const P = {
  html:   path.join(FE, 'dashboard.html'),
  dash:   path.join(FE, 'assets', 'dashboard.js'),
  shared: path.join(FE, 'assets', 'shared.js'),
  csp:    path.join(BE, 'test', 'integration', 'csp-markup.test.js')
};
const alt = {}, neu = {};
for (const [k, f] of Object.entries(P)) { alt[k] = fs.readFileSync(f, 'utf8'); neu[k] = alt[k]; }
const fehler = [], meldungen = [];

// Genau n Vorkommen ersetzen — sonst ist die Vorlage nicht die erwartete.
function ersetze(k, suche, durch, n) {
  const ist = neu[k].split(suche).length - 1;
  if (ist !== n) { fehler.push(`${path.basename(P[k])}: "${suche}" ${ist}× statt ${n}×`); return; }
  neu[k] = neu[k].split(suche).join(durch);
}

// ── shared.js ─────────────────────────────────────────────────────
if (/function aktionAusfuehren/.test(neu.shared)) {
  meldungen.push('\x1b[90m·\x1b[0m shared.js: schon umgestellt');
} else {
  const anker = '\n// 9. csv_export';
  if (neu.shared.split(anker).length - 1 !== 1) {
    fehler.push('shared.js: Abschnitt "// 9. csv_export" nicht genau einmal gefunden');
  } else {
    const block = [
      '',
      '// 8c. aktionen',
      '// Ersetzt onclick="…" im Markup. Ein Element trägt data-action="name", und',
      '// EIN Listener am Dokument ruft die registrierte Funktion — auch für Zeilen,',
      '// die erst später gerendert werden, ohne erneutes Anbinden.',
      '//',
      '// Warum nicht einfach onclick: helmet setzt script-src-attr \'none\', und das',
      '// Ziel von Phase F ist, diese Sperre wieder zu schließen. Nebenbei landet',
      '// kein Wert mehr in einem JS-String im HTML — genau der Weg, über den früher',
      '// ein Kategoriename Code ausführen konnte (siehe Kommentar in dashboard.js).',
      'const _aktionen = Object.create(null);',
      '',
      'function registriereAktionen(tabelle) {',
      '  for (const name of Object.keys(tabelle)) {',
      '    const fn = tabelle[name];',
      '    if (_aktionen[name] && _aktionen[name] !== fn) {',
      '      console.warn(\'[Aktionen] "\' + name + \'" wird überschrieben\');',
      '    }',
      '    _aktionen[name] = fn;',
      '  }',
      '}',
      '',
      'function aktionIstRegistriert(name) {',
      '  return typeof _aktionen[name] === \'function\';',
      '}',
      '',
      '// Getrennt vom Listener, damit Tests sie ohne Browser aufrufen können.',
      'function aktionAusfuehren(ereignis) {',
      '  const ziel = ereignis && ereignis.target;',
      '  const el = ziel && typeof ziel.closest === \'function\' ? ziel.closest(\'[data-action]\') : null;',
      '  if (!el) return false;',
      '  const name = el.dataset ? el.dataset.action : undefined;',
      '  const fn = _aktionen[name];',
      '  if (typeof fn !== \'function\') {',
      '    // Ein Tippfehler in data-action soll auffallen, nicht still scheitern.',
      '    console.warn(\'[Aktionen] unbekannte Aktion:\', name);',
      '    return false;',
      '  }',
      '  try {',
      '    const ergebnis = fn(el, ereignis);',
      '    // Async-Aktionen: eine Ablehnung wird protokolliert statt als',
      '    // "Uncaught (in promise)" in der Konsole zu landen.',
      '    if (ergebnis && typeof ergebnis.then === \'function\') {',
      '      ergebnis.then(null, function (err) { console.error(\'[Aktionen] \' + name + \':\', err); });',
      '    }',
      '  } catch (err) {',
      '    console.error(\'[Aktionen] \' + name + \':\', err);',
      '  }',
      '  return true;',
      '}',
      '',
      'document.addEventListener(\'click\', aktionAusfuehren);',
      '',
      '// Die Seitenleiste erscheint auf JEDER Seite, also gehören ihre Aktionen',
      '// hierher. sendReportNow zeigt eine Fehlermeldung selbst und wirft dann',
      '// weiter — hier gibt es niemanden mehr, der darauf reagieren müsste.',
      'registriereAktionen({',
      '  berichtSenden:          function () { return sendReportNow().catch(function () {}); },',
      '  abmelden:               function () { logout(); },',
      '  themaWechseln:          function () { toggleTheme(); },',
      '  seitenleisteUmschalten: function () { toggleSidebar(); }',
      '});',
      '',
      'window.registriereAktionen  = registriereAktionen;',
      'window.aktionIstRegistriert = aktionIstRegistriert;',
      'window.aktionAusfuehren     = aktionAusfuehren;',
      ''
    ].join('\n');
    neu.shared = neu.shared.replace(anker, block + anker);
    ersetze('shared', 'onclick="sendReportNow()"', 'data-action="berichtSenden"', 1);
    ersetze('shared', 'onclick="logout()"',        'data-action="abmelden"',      1);
    meldungen.push('\x1b[32m✓\x1b[0m shared.js: Aktionsverteiler und Seitenleiste');
  }
}

// ── dashboard.js ──────────────────────────────────────────────────
if (/registriereAktionen\(/.test(neu.dash)) {
  meldungen.push('\x1b[90m·\x1b[0m dashboard.js: schon umgestellt');
} else {
  const ID = '${escapeHtml(p._id)}';
  ersetze('dash', 'onclick="adjustStock(\'${p._id}\', -${step})"',
          'data-action="bestandAendern" data-id="' + ID + '" data-delta="-${step}"', 1);
  ersetze('dash', 'onclick="adjustStock(\'${p._id}\', ${step})"',
          'data-action="bestandAendern" data-id="' + ID + '" data-delta="${step}"', 1);
  ersetze('dash', 'onclick="openEditModal(\'${p._id}\')"',
          'data-action="produktBearbeiten" data-id="' + ID + '"', 1);
  ersetze('dash', 'onclick="confirmDeleteProduct(\'${p._id}\')"',
          'data-action="produktLoeschen" data-id="' + ID + '"', 1);

  // Bestandsfeld: die beiden Attributzeilen werden zu einer Markierung.
  const feld = /\n([ \t]*)onkeydown="if\(event\.key==='Enter'\)\{this\.blur\(\);\}"\n[ \t]*onblur="setStock\('\$\{p\._id\}', this\.value\)">/;
  if (!feld.test(neu.dash)) {
    fehler.push('dashboard.js: das Bestandsfeld (onkeydown/onblur) sieht anders aus');
  } else {
    neu.dash = neu.dash.replace(feld, (_m, einzug) => '\n' + einzug + 'data-bestand-id="' + ID + '">');
  }

  neu.dash = neu.dash.replace(/\s*$/, '') + '\n' + [
    '',
    '// ── Aktionen (Phase F, Schritt B1) ───────────────────────────────',
    '// Ersetzen die Inline-Handler in dashboard.html und in den Tabellenzeilen.',
    '// Der Listener sitzt in shared.js am Dokument; hier steht nur, welcher',
    '// Name was tut.',
    'registriereAktionen({',
    '  adminWerkzeugeOeffnen:    function () { openAdminTools(); },',
    '  adminWerkzeugeSchliessen: function () { closeAdminTools(); },',
    '  bestandZuruecksetzen:     function (el) { adminResetStock(el.dataset.mitGestern === \'true\'); },',
    '  // Bisher onclick="sendReportNow().then(refreshAll)": schlug der Bericht',
    '  // fehl, blieb die Ablehnung unbehandelt. Die Meldung zeigt sendReportNow',
    '  // selbst — hier nur: bei Erfolg die Ansicht auffrischen.',
    '  berichtSendenUndAktualisieren: async function () {',
    '    try { await sendReportNow(); } catch { return; }',
    '    await refreshAll();',
    '  },',
    '  produktNeu:             function () { openAddModal(); },',
    '  produktModalSchliessen: function () { closeProductModal(); },',
    '  bestaetigungSchliessen: function () { closeConfirm(); },',
    '  bestandAendern:         function (el) { adjustStock(el.dataset.id, Number(el.dataset.delta)); },',
    '  produktBearbeiten:      function (el) { openEditModal(el.dataset.id); },',
    '  produktLoeschen:        function (el) { confirmDeleteProduct(el.dataset.id); }',
    '});',
    '',
    'document.getElementById(\'search-input\').addEventListener(\'input\', function () { renderTable(); });',
    'document.getElementById(\'unit-filter-select\').addEventListener(\'change\', function () { renderTable(); });',
    '// submitProductForm ruft als Erstes selbst evt.preventDefault() — das',
    '// "return" aus dem alten onsubmit war nie nötig.',
    'document.getElementById(\'product-form\').addEventListener(\'submit\', submitProductForm);',
    '',
    '// Bestandsfeld: blur steigt nicht auf, focusout schon — nur so erreicht es',
    '// einen Listener am Dokument. Enter verlässt das Feld wie bisher und löst',
    '// damit das Speichern aus.',
    'document.addEventListener(\'keydown\', function (e) {',
    '  if (e.key === \'Enter\' && e.target && e.target.matches && e.target.matches(\'.step-val[data-bestand-id]\')) {',
    '    e.target.blur();',
    '  }',
    '});',
    'document.addEventListener(\'focusout\', function (e) {',
    '  if (e.target && e.target.matches && e.target.matches(\'.step-val[data-bestand-id]\')) {',
    '    setStock(e.target.dataset.bestandId, e.target.value);',
    '  }',
    '});',
    ''
  ].join('\n');
  meldungen.push('\x1b[32m✓\x1b[0m dashboard.js: Tabellenzeilen und Registrierung');
}

// ── dashboard.html ────────────────────────────────────────────────
if (/data-action="produktNeu"/.test(neu.html)) {
  meldungen.push('\x1b[90m·\x1b[0m dashboard.html: schon umgestellt');
} else {
  const tabelle = [
    ['onclick="toggleSidebar()"',                 'data-action="seitenleisteUmschalten"', 1],
    ['onclick="toggleTheme()"',                   'data-action="themaWechseln"', 1],
    ['onclick="openAdminTools()"',                'data-action="adminWerkzeugeOeffnen"', 1],
    ['onclick="sendReportNow().then(refreshAll)"', 'data-action="berichtSendenUndAktualisieren"', 1],
    [' oninput="renderTable()"',                  '', 1],
    [' onchange="renderTable()"',                 '', 1],
    ['onclick="openAddModal()"',                  'data-action="produktNeu"', 1],
    ['onclick="closeProductModal()"',             'data-action="produktModalSchliessen"', 2],
    [' onsubmit="return submitProductForm(event)"', '', 1],
    ['onclick="closeAdminTools()"',               'data-action="adminWerkzeugeSchliessen"', 1],
    ['onclick="adminResetStock(false)"',          'data-action="bestandZuruecksetzen" data-mit-gestern="false"', 1],
    ['onclick="adminResetStock(true)"',           'data-action="bestandZuruecksetzen" data-mit-gestern="true"', 1],
    ['onclick="closeConfirm()"',                  'data-action="bestaetigungSchliessen"', 1]
  ];
  for (const [s, d, n] of tabelle) ersetze('html', s, d, n);
  meldungen.push('\x1b[32m✓\x1b[0m dashboard.html: 14 statische Handler');
}

// ── csp-markup.test.js: Kommentarzeilen überspringen ──────────────
if (/Kommentarzeilen sind keine Handler/.test(neu.csp)) {
  meldungen.push('\x1b[90m·\x1b[0m csp-markup.test.js: schon angepasst');
} else {
  const anker = /(\n([ \t]*)\/\/ on…=" bzw\. on…=' — also Attribute[^\n]*)/;
  if (!anker.test(neu.csp)) {
    fehler.push('csp-markup.test.js: Kommentar über der Suche nicht gefunden');
  } else {
    neu.csp = neu.csp.replace(anker, (_m, zeile, e) =>
      '\n' + e + '// Kommentarzeilen sind keine Handler. dashboard.js erklärt in einem' +
      '\n' + e + '// Kommentar, warum dort KEIN onclick="..." mehr steht — ohne diese' +
      '\n' + e + '// Zeile zählte genau diese Erklärung als Handler und hielte die CSP' +
      '\n' + e + '// für immer offen.' +
      '\n' + e + 'if (/^\\s*(\\/\\/|\\/\\*|\\*|<!--)/.test(zeile)) return;' + zeile);
    meldungen.push('\x1b[32m✓\x1b[0m csp-markup.test.js: Kommentarzeilen zählen nicht mehr');
  }
}

// ── Prüfung vor dem Schreiben ─────────────────────────────────────
for (const k of ['dash', 'shared', 'csp']) {
  if (neu[k] === alt[k]) continue;
  try { new Function(neu[k]); }
  catch (e) { fehler.push(`${path.basename(P[k])} wäre ungültig: ${e.message}`); }
}
const KOMMENTAR = /^\s*(\/\/|\/\*|\*|<!--)/;
for (const k of ['html', 'dash', 'shared']) {
  neu[k].split('\n').forEach((z, i) => {
    if (KOMMENTAR.test(z)) return;
    for (const m of z.matchAll(/\s(on[a-z]+)\s*=\s*["']/gi)) {
      fehler.push(`${path.basename(P[k])}:${i + 1} enthält noch ${m[1]}=`);
    }
  });
}

if (fehler.length) {
  console.log('\n  \x1b[31mEs wurde NICHTS geändert:\x1b[0m');
  fehler.forEach(x => console.log('  \x1b[31m✗\x1b[0m ' + x));
  console.log('');
  process.exit(1);
}
for (const [k, f] of Object.entries(P)) {
  if (neu[k] === alt[k]) continue;
  if (!fs.existsSync(f + '.f2.bak')) fs.writeFileSync(f + '.f2.bak', alt[k]);
  fs.writeFileSync(f, neu[k]);
}
meldungen.forEach(m => console.log('  ' + m));
NODE_F2

FERTIG=1

for f in "$FE/assets/shared.js" "$FE/assets/dashboard.js" "$BE/test/integration/csp-markup.test.js"; do
  node --check "$f" >/dev/null 2>&1 || die "Syntaxfehler in $f — rückgängig mit: git checkout . && git clean -fd"
done
ok "syntaktisch gültig"

# ── 3  Grün ──────────────────────────────────────────────────────────
lauf() {
  local aus
  aus=$( cd "$BE" && npm run "$1" 2>&1 || true )
  printf '%s\n' "$aus" | grep -E "^(ℹ|#) (tests|pass|fail) " | sed "s/^/    [$1] /" >&2 || true
  printf '%s\n' "$aus" | grep -E "^(ℹ|#) fail " | awk '{print $3}' | tail -1 || true
}

echo
echo "── Nachher: GRÜN erwartet ──────────────────────────────────────"
echo
( cd "$BE" && node --test --test-reporter=spec test/unit/aktionen.test.js test/unit/inline-handler.test.js ) 2>&1 \
  | grep -E "^(✔|✖) " || true
echo
U=$(lauf test:unit); I=$(lauf test:integration)
echo "  Unit: fail=${U:-?}   Integration: fail=${I:-?}"
[ "${U:-1}" = "0" ] && [ "${I:-1}" = "0" ] || die "Tests nicht grün — rückgängig mit: git checkout . && git clean -fd"
ok "alle Tests grün"

set +e
LINT_AUS=$( cd "$BE" && npm run lint 2>&1 ); LINT=$?
set -e
if [ "$LINT" -eq 0 ]; then
  ok "Lint sauber"
else
  printf '%s\n' "$LINT_AUS" | grep -vE "^>|^$"
  die "Lint meldet etwas (siehe oben) — rückgängig mit: git checkout . && git clean -fd"
fi

echo
echo "── Danach ──────────────────────────────────────────────────────"
echo
echo "  Erwartet: 81 Unit- und 85 Integrationstests grün."
echo
echo "  IM BROWSER — das ist der eigentliche Nachweis, Strg+F5 nicht vergessen:"
echo "   1. Seitenleiste: Theme, Bericht senden, Abmelden"
echo "   2. Suche tippen, Einheiten-Filter wechseln"
echo "   3. + Produkt hinzufügen, speichern (die Seite darf NICHT neu laden)"
echo "   4. ± in einer Zeile, eine Zahl ins Feld tippen und Enter"
echo "   5. ✏️ Bearbeiten, 🗑️ Löschen — und Abbrechen im Bestätigungsdialog"
echo "   6. ⚙️ Admin-Werkzeuge öffnen und schließen"
echo "   Konsole offen lassen: jede Zeile mit [Aktionen] bitte schicken."
echo
echo "    mkdir -p tools && mv $SELBST tools/"
echo "    git add -A && git commit -m 'Phase F Schritt B1: Dashboard ohne Inline-Handler'"
echo "    git push"
echo
echo "  Rückgängig:  git checkout . && git clean -fd"
echo
