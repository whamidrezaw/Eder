#!/usr/bin/env bash
#
# apply-g1-haertung.sh — Phase G, Schritt 1: Härtung
#
# Drei Befunde, am echten Repo gemessen (27.09.2026), jeder mit einem Test,
# der zuerst rot ist:
#
#   1. script-src erlaubt noch 'unsafe-inline'. Die App braucht es nicht mehr:
#      keine <script>-Blöcke im Markup (10 von 10 Skripten per src), keine
#      javascript:-Adressen, kein eval. Offen blieb es trotzdem — und damit
#      der Weg, auf dem eingeschleustes HTML doch Code ausführen könnte.
#      → script-src 'self'. Ein neuer Test hält CSP und Markup zusammen, wie
#        csp-markup.test.js es für die Handler tut.
#
#   2. Vier Schließen-Knöpfe (✕) sind <div>s. Mit der Tastatur nicht
#      erreichbar: wer ohne Maus arbeitet, kam aus dem Dialog nicht heraus.
#      Und "✕" liest ein Bildschirmleser als "Multiplikationszeichen".
#      → <button type="button" aria-label="Schließen">. Aussehen unverändert:
#        shared.css setzt button { border: none; background: none } und
#        * { padding: 0 } — deshalb sieht der Knopf in users.html heute schon
#        genau so aus.
#
#   3. tools/sicherung.sh löscht mit rm -rf, ohne ZIEL zu prüfen.
#      → Wächter nach security-and-hardening: Symlinks auflösen, absoluter
#        Pfad, mindestens drei Ebenen tief, kein Systemordner, richtiger
#        Eigentümer — sonst Abbruch, bevor irgendetwas passiert.
#
# Dazu zwei Berichte, die nichts ändern: Geheimnisse in der Git-Geschichte des
# öffentlichen Repos, und npm audit.
#
# Unabhängig von Schritt D4: dessen liegengebliebene Dateien
# (apply-d4-zugang.sh, tools/duckdns.sh) werden in Ruhe gelassen.
#
# Legt den Branch phase-g an, falls du auf main bist.
#
# Ausführen im Wurzelverzeichnis des Repos:
#     bash apply-g1-haertung.sh
#
set -euo pipefail

BE="Edeka.lager/backend"
FE="Edeka.lager/frontend"
SELBST="$(basename "$0")"
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
die()  { printf '\n  \033[31m✗ %s\033[0m\n\n' "$1" >&2; exit 1; }

echo
echo "── Phase G, Schritt 1: Härtung ─────────────────────────────────"
echo

for f in "$BE/app.js" "$BE/test/helpers/http.js" "$FE/dashboard.html" "$FE/reports.html" "$FE/users.html" tools/sicherung.sh; do
  [ -f "$f" ] || die "'$f' nicht gefunden — im Wurzelverzeichnis des Repos (cd ~/Eder)?"
done

if command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
  # Die Reste des noch ausstehenden Schritts D4 bleiben unberührt.
  SCHMUTZ=$(git status --porcelain | grep -v -- "$SELBST" | grep -vE '(^\?\? apply-d4-zugang\.sh$|^\?\? tools/duckdns\.sh$)' || true)
  [ -z "$SCHMUTZ" ] || { printf '%s\n' "$SCHMUTZ" | sed 's/^/     /'; die "Arbeitsverzeichnis nicht sauber (siehe oben)."; }
  BRANCH=$(git rev-parse --abbrev-ref HEAD)
  if [ "$BRANCH" = "main" ]; then
    if git show-ref --verify --quiet refs/heads/phase-g; then git checkout -q phase-g; else git checkout -q -b phase-g; fi
    BRANCH=phase-g
  fi
  ok "Branch '$BRANCH', Arbeitsverzeichnis sauber (Reste von D4 unberührt)"
fi

# ── 1  Tests, mit Aufräumen bei Abbruch ──────────────────────────────
NEU=( "$BE/test/integration/csp-skripte.test.js"
      "$BE/test/unit/schliessen-knoepfe.test.js"
      "$BE/test/unit/sicherung-pfad.test.js" )
DA=(); for f in "${NEU[@]}"; do [ -f "$f" ] && DA+=(1) || DA+=(0); done
FERTIG=0
aufraeumen() {
  [ "$FERTIG" = "1" ] && return
  for i in "${!NEU[@]}"; do [ "${DA[$i]}" = "0" ] && rm -f "${NEU[$i]}"; done
  printf '  \033[90m·\033[0m Abbruch: angelegte Testdateien wieder entfernt\n' >&2
}
trap aufraeumen EXIT

echo
echo "── Tests schreiben ─────────────────────────────────────────────"
cat > "$BE/test/integration/csp-skripte.test.js" <<'EOF'
'use strict';
//
// script-src und Markup passen zusammen — das Gegenstück zu csp-markup.test.js.
//
// 'unsafe-inline' in script-src erlaubt zweierlei, das eingeschleustes HTML
// ausnutzen könnte: <script>-Blöcke im Markup und javascript:-Adressen. Seit
// Phase F braucht die App beides nicht. Solange das so bleibt, darf die CSP
// es nicht erlauben. Kommt je wieder ein Inline-Skript dazu, wird dieser Test
// rot — und man entscheidet bewusst, statt die Tür still offen zu lassen.
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const fs     = require('node:fs');
const path   = require('node:path');
const { start, stop, req } = require('../helpers/http');

const FE = path.join(__dirname, '../../../frontend');
const KOMMENTAR = /^\s*(\/\/|\/\*|\*|<!--)/;

function dateien(dir) {
  const out = [];
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) out.push(...dateien(p));
    else if (/\.(html|js)$/.test(e.name) && e.name !== 'chart.umd.min.js') out.push(p);
  }
  return out;
}

function inlineSkripte() {
  const funde = [];
  for (const p of dateien(FE)) {
    const rel = path.relative(FE, p);
    const text = fs.readFileSync(p, 'utf8');
    if (p.endsWith('.html')) {
      for (const m of text.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)) {
        if (!/\bsrc\s*=/i.test(m[1]) && m[2].trim()) funde.push(`${rel}: <script> ohne src`);
      }
    }
    text.split('\n').forEach((zeile, i) => {
      if (!KOMMENTAR.test(zeile) && /javascript:/i.test(zeile)) funde.push(`${rel}:${i + 1}: javascript:-Adresse`);
    });
  }
  return funde;
}

test.before(async () => { await start(); });
test.after (async () => { await stop(); });

test('script-src erlaubt Inline-Skripte genau dann, wenn die App welche hat', async () => {
  const funde = inlineSkripte();
  const r = await req('/index.html');
  const csp = r.headers.get('content-security-policy') || '';
  // "script-src " mit Leerzeichen: script-src-attr ist eine andere Direktive.
  const scriptSrc = csp.split(';').map(s => s.trim()).find(s => s.startsWith('script-src ')) || '';
  const erlaubt = /'unsafe-inline'/.test(scriptSrc);
  if (funde.length) {
    assert.ok(erlaubt, `Inline-Skripte vorhanden, aber die CSP verbietet sie:\n    ${funde.join('\n    ')}`);
  } else {
    assert.equal(erlaubt, false,
      `Die App hat keine Inline-Skripte — script-src darf 'unsafe-inline' nicht mehr erlauben: "${scriptSrc}"`);
  }
});
EOF

cat > "$BE/test/unit/schliessen-knoepfe.test.js" <<'EOF'
'use strict';
//
// Die Schließen-Knöpfe der Dialoge sind echte Knöpfe.
//
// Ein <div> ist mit der Tastatur nicht erreichbar — kein Tab, kein Enter. Wer
// ohne Maus arbeitet, kam aus dem Dialog nicht heraus. "✕" allein liest ein
// Bildschirmleser als "Multiplikationszeichen"; aria-label gibt ihm den
// Namen. type="button", weil ein Knopf in einem <form> das Formular sonst
// abschickt und die Seite neu lädt.
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const fs     = require('node:fs');
const path   = require('node:path');

const FE = path.join(__dirname, '../../../frontend');

test('Schließen-Knöpfe sind <button type="button"> mit aria-label', () => {
  const funde = [];
  let anzahl = 0;
  for (const f of fs.readdirSync(FE).filter(x => x.endsWith('.html'))) {
    const text = fs.readFileSync(path.join(FE, f), 'utf8');
    for (const m of text.matchAll(/<([a-z]+)\b([^>]*\bclass="[^"]*\bmodal-close\b[^"]*"[^>]*)>/gi)) {
      anzahl++;
      const [, tag, attr] = m;
      const wo = `${f}: <${tag}${attr.slice(0, 50)}…>`;
      if (tag.toLowerCase() !== 'button') { funde.push(`${wo} ist kein <button>`); continue; }
      if (!/\btype="button"/.test(attr))      funde.push(`${wo} ohne type="button"`);
      if (!/\baria-label="[^"]+"/.test(attr)) funde.push(`${wo} ohne aria-label`);
    }
  }
  assert.ok(anzahl > 0, 'keinen einzigen Schließen-Knopf gefunden — Klassenname geändert?');
  assert.deepEqual(funde, [], `${funde.length} Befund(e):\n    ` + funde.join('\n    '));
});
EOF

cat > "$BE/test/unit/sicherung-pfad.test.js" <<'EOF'
'use strict';
//
// tools/sicherung.sh löscht alte Sicherungen und abgebrochene Reste mit
// rm -rf. Vorher muss ZIEL ein eigener, echter Ordner sein: Symlinks
// aufgelöst, absolut, mindestens drei Ebenen tief, kein Systemordner.
// (agent-skills, security-and-hardening: "Destructive filesystem operations
// resolve symlinks, then verify allowlisted root, minimum depth, and
// ownership before running.")
//
// Geprüft wird nur der Wächter. Der Container heißt so, dass es ihn nicht
// gibt: ein erlaubter Pfad scheitert danach an "läuft nicht" — ohne dass das
// Skript irgendetwas anlegt oder löscht.
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const fs     = require('node:fs');
const os     = require('node:os');
const path   = require('node:path');
const { spawnSync } = require('node:child_process');

const SKRIPT = path.join(__dirname, '../../../../tools/sicherung.sh');

function lauf(ziel) {
  return spawnSync('bash', [SKRIPT], {
    env: { PATH: process.env.PATH, ZIEL: ziel, CONTAINER: `gibt-es-nicht-${process.pid}`, BESITZER: 'root' },
    encoding: 'utf8', timeout: 20000
  });
}
const abgelehnt = (r) => r.status !== 0 && /ZIEL/.test(r.stderr) && !/läuft nicht/.test(r.stderr);
const tmp = () => fs.mkdtempSync(path.join(os.tmpdir(), 'sicherung-'));

test('Wurzel, Systemordner, relative Pfade und Umwege über .. werden abgelehnt', () => {
  for (const ziel of ['/', '/etc', '/home', '/usr/local/x', 'sicherungen', '/tmp/../etc/cron.d']) {
    const r = lauf(ziel);
    assert.ok(abgelehnt(r), `"${ziel}" wurde nicht abgelehnt: ${(r.stderr || r.stdout).trim()}`);
  }
});

test('ein Symlink wird aufgelöst — zeigt er auf /etc, wird abgelehnt', () => {
  const t = tmp();
  try {
    fs.mkdirSync(path.join(t, 'a'));
    fs.symlinkSync('/etc', path.join(t, 'a', 'b'));
    assert.ok(abgelehnt(lauf(path.join(t, 'a', 'b'))), 'Symlink auf /etc durchgelassen');
  } finally { fs.rmSync(t, { recursive: true, force: true }); }
});

test('eine Datei statt eines Ordners wird abgelehnt', () => {
  const t = tmp();
  try {
    fs.mkdirSync(path.join(t, 'x'));
    fs.writeFileSync(path.join(t, 'x', 'datei'), '');
    assert.ok(abgelehnt(lauf(path.join(t, 'x', 'datei'))), 'Datei als ZIEL durchgelassen');
  } finally { fs.rmSync(t, { recursive: true, force: true }); }
});

test('ein eigener, tief genug liegender Ordner wird durchgelassen — und nichts angelegt', () => {
  const t = tmp();
  const ziel = path.join(t, 'edeka', 'sicherungen');
  try {
    const r = lauf(ziel);
    assert.notEqual(r.status, 0);
    assert.match(r.stderr, /läuft nicht/, `am Wächter gescheitert statt am fehlenden Container: ${r.stderr.trim()}`);
    assert.ok(!fs.existsSync(ziel), 'der Wächter darf nichts anlegen');
  } finally { fs.rmSync(t, { recursive: true, force: true }); }
});
EOF
for f in "${NEU[@]}"; do node --check "$f" >/dev/null 2>&1 || die "Syntaxfehler in $f"; done
ok "3 Testdateien (6 Tests)"

echo
echo "── Vorher: ROT erwartet ────────────────────────────────────────"
echo
( cd "$BE" && node --test --test-reporter=spec "${NEU[@]#$BE/}" ) 2>&1 | grep -E "^(✔|✖) " | awk '!seen[$0]++' | head -10 || true

# ── 2  Umbau (alles oder nichts) ─────────────────────────────────────
echo
echo "── Umbau (alles oder nichts) ───────────────────────────────────"
node - "$BE" "$FE" <<'NODE_G1'
const fs = require('fs'), path = require('path'), os = require('os');
const { spawnSync } = require('child_process');
const BE = process.argv[2], FE = process.argv[3];
const P = {
  app:       path.join(BE, 'app.js'),
  dashboard: path.join(FE, 'dashboard.html'),
  reports:   path.join(FE, 'reports.html'),
  users:     path.join(FE, 'users.html'),
  sicherung: path.join('tools', 'sicherung.sh')
};
const alt = {}, neu = {};
for (const [k, f] of Object.entries(P)) { alt[k] = fs.readFileSync(f, 'utf8'); neu[k] = alt[k]; }
const fehler = [], meldungen = [];

// ── 1  script-src ohne 'unsafe-inline' ────────────────────────────
const zeileAlt = `      scriptSrc:   ["'self'", "'unsafe-inline'"],`;
if (neu.app.includes(`scriptSrc:   ["'self'"],`)) {
  meldungen.push("\x1b[90m·\x1b[0m app.js: script-src ist schon nur 'self'");
} else if (neu.app.split(zeileAlt).length - 1 !== 1) {
  fehler.push('app.js: die Zeile scriptSrc sieht anders aus als erwartet');
} else {
  neu.app = neu.app.replace(zeileAlt, () => [
    "      // Nur Skripte von hier. 'unsafe-inline' ist weg: seit Phase F hat die",
    '      // App weder <script>-Blöcke im Markup noch javascript:-Adressen.',
    '      // Eingeschleustes HTML kann damit keinen Code mehr ausführen.',
    '      // test/integration/csp-skripte.test.js hält CSP und Markup zusammen.',
    `      scriptSrc:   ["'self'"],`
  ].join('\n'));
  meldungen.push("\x1b[32m✓\x1b[0m app.js: script-src nur noch 'self'");
}

// ── 2  Schließen-Knöpfe ───────────────────────────────────────────
const DIV = /<div class="modal-close" data-action="([^"]+)">✕<\/div>/g;
const BTN = (a, z) => `<button type="button" class="modal-close" data-action="${a}" aria-label="Schließen">${z}</button>`;
for (const [k, n] of [['dashboard', 2], ['reports', 2]]) {
  const ist = (neu[k].match(DIV) || []).length;
  if (ist === 0 && /class="modal-close"[^>]*aria-label/.test(neu[k])) { meldungen.push(`\x1b[90m·\x1b[0m ${k}.html: schon umgestellt`); continue; }
  if (ist !== n) { fehler.push(`${k}.html: ${ist} statt ${n} Schließen-<div>s`); continue; }
  neu[k] = neu[k].replace(DIV, (_m, a) => BTN(a, '✕'));
  meldungen.push(`\x1b[32m✓\x1b[0m ${k}.html: ${n} Schließen-Knöpfe als <button>`);
}
const U_ALT = '<button class="modal-close" data-action="benutzerDialogSchliessen">×</button>';
if (neu.users.includes('aria-label="Schließen"')) {
  meldungen.push('\x1b[90m·\x1b[0m users.html: schon umgestellt');
} else if (neu.users.split(U_ALT).length - 1 !== 1) {
  fehler.push('users.html: der Schließen-Knopf sieht anders aus als erwartet');
} else {
  neu.users = neu.users.replace(U_ALT, () => BTN('benutzerDialogSchliessen', '×'));
  meldungen.push('\x1b[32m✓\x1b[0m users.html: Schließen-Knopf mit type und aria-label');
}

// ── 3  Wächter in tools/sicherung.sh ──────────────────────────────
const S_ANKER = `[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" = "true" ] \\`;
if (neu.sicherung.includes('Wächter vor jedem Löschen')) {
  meldungen.push('\x1b[90m·\x1b[0m sicherung.sh: Wächter schon vorhanden');
} else if (neu.sicherung.split(S_ANKER).length - 1 !== 1 || !neu.sicherung.includes('\nfehler() {')) {
  fehler.push('tools/sicherung.sh: Anker (docker inspect / fehler) nicht wie erwartet');
} else {
  neu.sicherung = neu.sicherung.replace(S_ANKER, () => [
    '# ── Wächter vor jedem Löschen ────────────────────────────────────────',
    '# Weiter unten löscht dieses Skript alte Sicherungen und abgebrochene Reste',
    '# mit rm -rf. Vorher muss ZIEL ein eigener, echter Ordner sein: Symlinks',
    '# aufgelöst, absolut, mindestens drei Ebenen tief, kein Systemordner, und',
    '# falls es ihn schon gibt, ein Verzeichnis von root oder $BESITZER.',
    '# (test/unit/sicherung-pfad.test.js)',
    'case "$ZIEL" in /*) ;; *) fehler "ZIEL muss ein absoluter Pfad sein: \'$ZIEL\'" ;; esac',
    'ZIEL=$(realpath -m -- "$ZIEL")',
    '[ "$(printf \'%s\' "$ZIEL" | tr -cd \'/\' | wc -c)" -ge 3 ] || fehler "ZIEL liegt zu weit oben im Dateisystem: \'$ZIEL\'"',
    'case "$ZIEL/" in',
    '  /bin/*|/boot/*|/dev/*|/etc/*|/lib/*|/lib64/*|/proc/*|/run/*|/sbin/*|/sys/*|/usr/*|/var/lib/*|/var/log/*)',
    '    fehler "ZIEL liegt in einem Systemordner: \'$ZIEL\'" ;;',
    'esac',
    'if [ -e "$ZIEL" ]; then',
    '  [ -d "$ZIEL" ] || fehler "ZIEL ist kein Verzeichnis: \'$ZIEL\'"',
    '  EIGNER=$(stat -c %U -- "$ZIEL")',
    '  [ "$EIGNER" = root ] || [ "$EIGNER" = "$BESITZER" ] || fehler "ZIEL gehört \'$EIGNER\' — erwartet root oder $BESITZER: \'$ZIEL\'"',
    'fi',
    '',
    S_ANKER
  ].join('\n'));
  meldungen.push('\x1b[32m✓\x1b[0m tools/sicherung.sh: Wächter vor jedem Löschen');
}

// ── Prüfung vor dem Schreiben ─────────────────────────────────────
if (neu.app !== alt.app) {
  try { new Function('require', 'module', 'exports', '__dirname', 'process', neu.app); }
  catch (e) { fehler.push(`app.js wäre ungültig: ${e.message}`); }
}
if (neu.sicherung !== alt.sicherung) {
  const t = path.join(os.tmpdir(), `sicherung-${process.pid}.sh`);
  fs.writeFileSync(t, neu.sicherung);
  const r = spawnSync('bash', ['-n', t], { encoding: 'utf8' });
  fs.unlinkSync(t);
  if (r.status !== 0) fehler.push(`tools/sicherung.sh wäre ungültig: ${r.stderr.trim()}`);
}
if (fehler.length) {
  console.log('\n  \x1b[31mEs wurde NICHTS geändert:\x1b[0m');
  fehler.forEach(x => console.log('  \x1b[31m✗\x1b[0m ' + x));
  console.log('');
  process.exit(1);
}
for (const [k, f] of Object.entries(P)) {
  if (neu[k] === alt[k]) continue;
  if (!fs.existsSync(f + '.g1.bak')) fs.writeFileSync(f + '.g1.bak', alt[k]);
  fs.writeFileSync(f, neu[k]);
}
meldungen.forEach(m => console.log('  ' + m));
NODE_G1

FERTIG=1
node --check "$BE/app.js" >/dev/null 2>&1 || die "Syntaxfehler in app.js — rückgängig: git checkout . && git clean -fd -- Edeka.lager"
bash -n tools/sicherung.sh || die "Syntaxfehler in tools/sicherung.sh — rückgängig: git checkout . && git clean -fd -- Edeka.lager"
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
( cd "$BE" && node --test --test-reporter=spec "${NEU[@]#$BE/}" test/integration/csp-markup.test.js ) 2>&1 | grep -E "^(✔|✖) " || true
echo
U=$(lauf test:unit); I=$(lauf test:integration)
echo "  Unit: fail=${U:-?}   Integration: fail=${I:-?}"
[ "${U:-1}" = "0" ] && [ "${I:-1}" = "0" ] || die "Tests nicht grün — rückgängig: git checkout . && git clean -fd -- Edeka.lager"
ok "alle Tests grün"

set +e
LINT_AUS=$( cd "$BE" && npm run lint 2>&1 ); LINT=$?
set -e
[ "$LINT" -eq 0 ] && ok "Lint sauber" || { printf '%s\n' "$LINT_AUS" | grep -vE "^>|^$"; die "Lint meldet etwas — rückgängig: git checkout . && git clean -fd -- Edeka.lager"; }

# ── 3  Berichte — ändern nichts ──────────────────────────────────────
echo
echo "── Berichte (ändern nichts) ────────────────────────────────────"
# Das Repo ist öffentlich: alles, was je committet wurde, ist lesbar — auch
# wenn es später gelöscht wurde. Werte werden hier absichtlich nie gezeigt.
MUSTER='^\+[^+].*\b(JWT_SECRET|TOKEN|PASSWORD|PASSWD|SECRET|API_KEY|MONGODB_URI)\b[[:space:]]*[=:][[:space:]]*["'"'"']?[A-Za-z0-9+/_.:@-]{12,}'
HARMLOS='test-only|beispiel|example|change[_-]?me|your[_-]|<|\$\{|process\.env|xxxx|placeholder|dein|127\.0\.0\.1:1/'
TREFFER=$(git log --all -p --no-color 2>/dev/null | grep -E "$MUSTER" | grep -viE "$HARMLOS" | wc -l || true)
COMMITS=$(git rev-list --all 2>/dev/null | wc -l)
if [ "${TREFFER:-0}" -eq 0 ]; then ok "Textsuche in der Git-Geschichte: keine Geheimnisse ($COMMITS Commits)"
else warn "Git-Geschichte: $TREFFER verdächtige Zeile(n) — bitte melden (Werte bewusst nicht gezeigt)"; fi
if git log --all --name-only --format='' 2>/dev/null | grep -qE '(^|/)\.env$'; then warn ".env war einmal als eigene Datei committet — bitte melden"
else ok ".env wurde nie als eigene Datei committet"; fi
# Archive sind binär — die Textsuche oben sieht nicht hinein. So blieb
# Edeka_lager_fixed.zip (mit einer .env darin) bis zum 28.09. unentdeckt.
ARCHIVE=$(git log --all --name-only --format='' 2>/dev/null | grep -iE '\.(zip|tar|tgz|gz|bz2|xz|7z|rar)$' | sort -u | tr '\n' ' ' || true)
if [ -n "$ARCHIVE" ]; then warn "Archive in der Git-Geschichte: ${ARCHIVE}— Inhalt hier NICHT geprüft, siehe apply-s1-geheimnis.sh"
else ok "keine Archive in der Git-Geschichte"; fi
if AUDIT=$( cd "$BE" && npm audit --omit=dev --audit-level=high 2>&1 ); then
  ok "npm audit: keine hohen oder kritischen Lücken in den Laufzeit-Abhängigkeiten"
else
  printf '%s\n' "$AUDIT" | tail -n 6 | sed 's/^/    /'
  warn "npm audit meldet hohe oder kritische Lücken — bitte melden"
fi

echo
echo "── Danach ──────────────────────────────────────────────────────"
echo
echo "  Erwartet: 99 Unit- und 91 Integrationstests grün."
echo
echo "  Commit mit ausdrücklichen Pfaden — die Reste von D4 bleiben draußen:"
echo "    mkdir -p tools && mv $SELBST tools/"
echo "    git add Edeka.lager tools/sicherung.sh tools/$SELBST"
echo "    git commit -m 'Phase G Schritt 1: script-src ohne unsafe-inline, echte Schließen-Knöpfe, Löschschutz der Sicherung'"
echo "    git push -u origin phase-g"
echo
echo "  Rückgängig:  git checkout . && git clean -fd -- Edeka.lager"
echo "  (nur Edeka.lager: ein nacktes git clean -fd löschte auch die wartenden"
echo "   Dateien von D4, apply-d4-zugang.sh und tools/duckdns.sh)"
echo
