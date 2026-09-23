#!/usr/bin/env bash
#
# apply-f1-extract.sh — Phase F, Schritt A: Inline-Skripte auslagern
#
# Reine Verlagerung, KEINE Verhaltensänderung. Der Inhalt jedes
# Inline-<script>-Blocks wandert unverändert nach assets/<seite>.js, die
# Seite lädt ihn per <script src>. Klassische Skripte laufen in
# Dokumentreihenfolge, ob inline oder extern — die Ausführung bleibt gleich.
#
# Der Gewinn ist sofort sichtbar: ESLint sieht diesen Code zum ersten Mal.
# Bisher lagen mehrere tausend Zeilen in den HTML-Dateien, die kein Werkzeug
# je gelesen hat. Genau dort steckte "rawLogs is not defined".
#
# Was dieses Skript NICHT tut: Inline-Handler (onclick=…) anfassen. Das ist
# Schritt B, Seite für Seite.
#
# Ausführen im Wurzelverzeichnis des Repos:
#     bash apply-f1-extract.sh
#
set -euo pipefail

BE="Edeka.lager/backend"
EL="Edeka.lager"
FE="Edeka.lager/frontend"
SELBST="$(basename "$0")"
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
die()  { printf '\n  \033[31m✗ %s\033[0m\n\n' "$1" >&2; exit 1; }

echo
echo "── Phase F, Schritt A: Inline-Skripte auslagern ────────────────"
echo

[ -d "$FE" ]                  || die "'$FE' nicht gefunden."
[ -f "$EL/eslint.config.js" ] || die "'$EL/eslint.config.js' nicht gefunden."

if command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
  BRANCH=$(git rev-parse --abbrev-ref HEAD)
  [ "$BRANCH" != "main" ] || die "Du bist auf main. Bitte auf phase-f wechseln."
  # Das laufende Skript zählt nicht als Schmutz — sonst müsste es sich erst
  # selbst committen, bevor es laufen darf.
  SCHMUTZ=$(git status --porcelain | grep -v -- "$SELBST" || true)
  [ -z "$SCHMUTZ" ] || { printf '%s\n' "$SCHMUTZ" | sed 's/^/     /'; die "Arbeitsverzeichnis nicht sauber (siehe oben)."; }
  ok "Branch '$BRANCH', Arbeitsverzeichnis sauber (ohne $SELBST)"
fi

# ── 1  Strukturtest ──────────────────────────────────────────────────
# Der Test wird VOR der Transaktion geschrieben, damit er vorher rot gezeigt
# werden kann. Bricht das Skript danach ab, darf er nicht als Rest liegen
# bleiben — sonst verweigert der nächste Lauf wegen "unsauber" den Start.
# Deshalb: merken, ob die Datei schon da war, und bei Abbruch nur das
# entfernen, was dieser Lauf selbst angelegt hat.
TESTDATEI="$BE/test/unit/frontend-struktur.test.js"
TEST_WAR_DA=0; [ -f "$TESTDATEI" ] && TEST_WAR_DA=1
FERTIG=0
aufraeumen() {
  if [ "$FERTIG" != "1" ] && [ "$TEST_WAR_DA" = "0" ] && [ -f "$TESTDATEI" ]; then
    rm -f "$TESTDATEI"
    printf '  \033[90m·\033[0m Abbruch: angelegte Testdatei wieder entfernt — nichts bleibt zurück\n' >&2
  fi
}
trap aufraeumen EXIT

echo
echo "── Test schreiben ──────────────────────────────────────────────"
mkdir -p "$BE/test/unit"
cat > "$TESTDATEI" <<'EOF'
'use strict';
//
// Die HTML-Seiten enthalten keinen ausführbaren Code mehr.
//
// Solange Logik in einem Inline-<script> steckt, sieht sie weder ESLint
// noch der vm-Harness: mehrere tausend Zeilen ohne jede Prüfung. Genau
// dort lag "rawLogs is not defined", das erst im Betrieb als 500 auffiel.
//
// Dieser Test hält den Zustand fest, sobald er erreicht ist — er verhindert
// den Rückfall, nicht mehr und nicht weniger.
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const fs     = require('node:fs');
const path   = require('node:path');

const FE = path.join(__dirname, '../../../frontend');

function htmlDateien(dir) {
  const out = [];
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) out.push(...htmlDateien(p));
    else if (e.name.endsWith('.html')) out.push(p);
  }
  return out;
}

test('keine HTML-Seite enthält noch einen Inline-Skriptblock', () => {
  const offen = [];
  for (const datei of htmlDateien(FE)) {
    const text = fs.readFileSync(datei, 'utf8');
    let anzahl = 0;
    for (const m of text.matchAll(/<script(\s[^>]*)?>([\s\S]*?)<\/script>/gi)) {
      if (/\bsrc\s*=/.test(m[1] || '')) continue;   // lädt eine Datei — in Ordnung
      if (m[2].trim() === '') continue;             // leerer Block
      anzahl++;
    }
    if (anzahl > 0) offen.push(`${path.basename(datei)}: ${anzahl}`);
  }
  assert.deepEqual(offen, [],
    'Seiten mit Inline-Skript (Datei: Anzahl):\n    ' + offen.join('\n    '));
});
EOF
ok "test/unit/frontend-struktur.test.js"
node --check "$BE/test/unit/frontend-struktur.test.js" >/dev/null 2>&1 || die "Syntaxfehler im Testfile"

echo
echo "── Vorher: ROT erwartet ────────────────────────────────────────"
echo
( cd "$BE" && node --test --test-reporter=spec test/unit/frontend-struktur.test.js ) 2>&1 \
  | grep -E "^(✔|✖)|^\s+[a-z].*\.html: [0-9]+|Seiten mit Inline" | head -12 || true

# ── 2  Auslagern ─────────────────────────────────────────────────────
echo
echo "── Auslagern (alles oder nichts) ───────────────────────────────"
node - "$FE" "$EL" <<'NODE_F1'
const fs = require('fs'), path = require('path');
const FE = process.argv[2], EL = process.argv[3];
const BLOCK = /<script(\s[^>]*)?>([\s\S]*?)<\/script>/gi;

const plan = [], fehler = [], meldungen = [], warnungen = [];
const seiten = fs.readdirSync(FE).filter(n => n.endsWith('.html')).sort();
if (seiten.length === 0) { console.log('  keine HTML-Seiten gefunden'); process.exit(1); }

for (const name of seiten) {
  const datei = path.join(FE, name);
  const html  = fs.readFileSync(datei, 'utf8');
  const stamm = name.replace(/\.html$/, '');
  const ziel  = path.join(FE, 'assets', stamm + '.js');

  const inline = [];
  for (const m of html.matchAll(BLOCK)) {
    if (/\bsrc\s*=/.test(m[1] || '')) continue;
    if (m[2].trim() === '') continue;
    inline.push(m);
  }

  if (inline.length === 0) {
    meldungen.push(`\x1b[90m·\x1b[0m ${name}: kein Inline-Block`);
    continue;
  }
  if (inline.length > 1) {
    // Zusammenkleben waere keine reine Verlagerung: ein use-strict im ersten
    // Block wuerde ploetzlich auch fuer den zweiten gelten.
    fehler.push(`${name}: ${inline.length} Inline-Bloecke — bitte melden, statt sie zusammenzukleben`);
    continue;
  }
  if (/type\s*=\s*["']module["']/i.test(inline[0][1] || '')) {
    fehler.push(`${name}: der Inline-Block ist ein Modul — anderes Ladeverhalten, bitte melden`);
    continue;
  }
  if (fs.existsSync(ziel)) {
    fehler.push(`assets/${stamm}.js existiert bereits, obwohl ${name} noch einen Inline-Block hat`);
    continue;
  }

  // index.html laedt shared.js bewusst nicht: die Anmeldeseite braucht weder
  // api() noch die Seitenleiste, und der Waechter in shared.js wuerde von dort
  // ohnehin nur wieder auf index.html leiten. Fehlt der Tag, gilt der Pfad,
  // den alle anderen Seiten benutzen.
  const sharedTag = html.match(/<script[^>]+src=["']([^"']*\/)?shared\.js["'][^>]*>/i);
  const prefix = sharedTag ? (sharedTag[1] || 'assets/') : '/assets/';

  plan.push({
    name, datei, ziel, stamm,
    quelle: inline[0][2],
    ganz:   inline[0][0],
    html,
    ohneShared: !sharedTag,
    neuerTag: '<script src="' + prefix + stamm + '.js"></script>'
  });
}

// ── Seiten ohne shared.js: benutzen sie trotzdem Namen daraus? ─────
// Das waere schon heute kaputt — nur hat es bisher niemand gesehen, weil
// kein Knopf funktionierte. Deshalb melden, nicht abbrechen.
{
  const sharedDatei = path.join(FE, 'assets', 'shared.js');
  const sharedNamen = new Set();
  if (fs.existsSync(sharedDatei)) {
    const q = fs.readFileSync(sharedDatei, 'utf8');
    for (const m of q.matchAll(/^window\.([A-Za-z_$][\w$]*)\s*=/gm)) sharedNamen.add(m[1]);
    for (const m of q.matchAll(/^(?:function|const|let|var)\s+([A-Za-z_$][\w$]*)/gm)) sharedNamen.add(m[1]);
  }
  for (const p of plan.filter(x => x.ohneShared)) {
    const eigene = new Set();
    for (const m of p.quelle.matchAll(/^\s*(?:async\s+)?(?:function|const|let|var)\s+([A-Za-z_$][\w$]*)/gm)) eigene.add(m[1]);
    const fremd = [...sharedNamen].filter(n => !eigene.has(n) && new RegExp('\\b' + n + '\\s*[(.]').test(p.quelle));
    if (fremd.length) {
      warnungen.push(`${p.name} laedt shared.js nicht, benutzt aber: ${fremd.join(', ')} — das kann heute schon nicht funktionieren`);
    }
  }
}

// ── eslint.config.js gehoert in DIESELBE Transaktion ───────────────
// Sonst kann die Auslagerung gelingen und die Konfiguration scheitern —
// und das Repo bleibt halb umgebaut zurueck.
const cfgPfad = path.join(EL, 'eslint.config.js');
let cfgNeu = null;
{
  const t = fs.readFileSync(cfgPfad, 'utf8');
  if (/sharedGlobals/.test(t)) {
    meldungen.push('\x1b[90m·\x1b[0m eslint.config.js: schon erweitert');
  } else {
    const ankerExport = /\nmodule\.exports = \[/;
    const ankerStrict = /^'use strict';/m;
    const altGlobals  = "languageOptions: { ecmaVersion: 2023, sourceType: 'script', globals: BROWSER_GLOBALS },";
    if (!ankerExport.test(t))      fehler.push('eslint.config.js: Anker module.exports fehlt');
    else if (!ankerStrict.test(t)) fehler.push('eslint.config.js: Anker use-strict fehlt');
    else if (!t.includes(altGlobals)) fehler.push('eslint.config.js: der Frontend-Block sieht anders aus als erwartet');
    else {
      const funktion = [
        '',
        '// Namen, die assets/shared.js global bereitstellt. Bewusst aus der Datei',
        '// gelesen statt als Liste gepflegt: eine Liste waere beim naechsten Umbau',
        '// in shared.js still veraltet und wuerde entweder falsche Fehler melden',
        '// oder echte verdecken.',
        'function sharedGlobals() {',
        "  const datei = path.join(__dirname, 'frontend', 'assets', 'shared.js');",
        '  if (!fs.existsSync(datei)) return {};',
        "  const quelle = fs.readFileSync(datei, 'utf8');",
        '  const namen = new Set();',
        '  for (const m of quelle.matchAll(/^window\\.([A-Za-z_$][\\w$]*)\\s*=/gm)) namen.add(m[1]);',
        '  for (const m of quelle.matchAll(/^(?:function|const|let|var)\\s+([A-Za-z_$][\\w$]*)/gm)) namen.add(m[1]);',
        "  return Object.fromEntries([...namen].map(n => [n, 'readonly']));",
        '}',
        '',
        'module.exports = ['
      ].join('\n');
      cfgNeu = t
        .replace(ankerExport, '\n' + funktion)
        .replace(ankerStrict, "'use strict';\nconst fs   = require('node:fs');\nconst path = require('node:path');")
        .replace(altGlobals, "languageOptions: { ecmaVersion: 2023, sourceType: 'script', globals: { ...BROWSER_GLOBALS, ...sharedGlobals() } },");
    }
  }
}

if (fehler.length) {
  console.log('\n  \x1b[31mEs wurde NICHTS geaendert:\x1b[0m');
  fehler.forEach(f => console.log('  \x1b[31m✗\x1b[0m ' + f));
  console.log('');
  process.exit(1);
}

for (const p of plan) {
  const kopf =
    `// Ausgelagert aus ${p.name} (Phase F, Schritt A).\n` +
    '// Inhalt unveraendert — nur der Ort hat sich geaendert, damit ESLint und\n' +
    '// der vm-Harness diesen Code ueberhaupt sehen koennen.\n' +
    "// Ein Kommentar vor 'use strict' ist unschaedlich: die Direktive muss die\n" +
    '// erste ANWEISUNG sein, nicht die erste Zeile.\n';
  fs.writeFileSync(p.ziel, kopf + p.quelle.replace(/^\n/, '') + '\n');
  fs.writeFileSync(p.datei + '.f1.bak', p.html);
  fs.writeFileSync(p.datei, p.html.replace(p.ganz, p.neuerTag));
  meldungen.push(`\x1b[32m✓\x1b[0m ${p.name} → assets/${p.stamm}.js (${p.quelle.split('\n').length} Zeilen)`);
}
if (cfgNeu !== null) {
  fs.writeFileSync(cfgPfad + '.f1.bak', fs.readFileSync(cfgPfad, 'utf8'));
  fs.writeFileSync(cfgPfad, cfgNeu);
  meldungen.push('\x1b[32m✓\x1b[0m eslint.config.js liest die Namen aus shared.js');
}
meldungen.forEach(m => console.log('  ' + m));
warnungen.forEach(w => console.log('  \x1b[33m!\x1b[0m ' + w));

let abweichung = 0;
for (const p of plan) {
  const ohneKopf = fs.readFileSync(p.ziel, 'utf8').split('\n').slice(5).join('\n').replace(/\n$/, '');
  if (ohneKopf !== p.quelle.replace(/^\n/, '')) abweichung++;
}
if (abweichung) { console.log(`  \x1b[31m✗ ${abweichung} Datei(en) weichen vom Original ab\x1b[0m`); process.exit(1); }
if (plan.length) console.log('  \x1b[32m✓\x1b[0m Inhalt Zeichen fuer Zeichen identisch');
NODE_F1

echo
echo "── ESLint ──────────────────────────────────────────────────────"
# Ab hier ist die Transaktion geschrieben. Ein späterer Abbruch (etwa rote
# Tests) wird mit "git checkout . && git clean -fd" zurückgenommen — dann soll
# der Test nicht still verschwinden, sondern mit dem Rest zusammen gehen.
FERTIG=1
node --check "$EL/eslint.config.js" >/dev/null 2>&1 || die "Syntaxfehler in eslint.config.js — rückgängig mit: git checkout ."
ok "eslint.config.js syntaktisch gültig"
node -e "
  const c = require('./$EL/eslint.config.js');
  const fe = c.find(b => b.files && b.files.some(f => f.includes('frontend/assets')));
  const n = Object.keys(fe.languageOptions.globals).length;
  console.log('  \x1b[32m✓\x1b[0m ' + n + ' bekannte Namen im Frontend-Block');
" || die "eslint.config.js lässt sich nicht laden"

for f in "$FE"/assets/*.js; do
  case "$f" in *chart.umd.min.js) continue;; esac
  node --check "$f" >/dev/null 2>&1 || die "Syntaxfehler in $f — rückgängig mit: git checkout . && git clean -fd"
done
ok "alle assets/*.js syntaktisch gültig"

# ── 4  Grün, dann der eigentliche Gewinn ─────────────────────────────
lauf() {
  local aus
  aus=$( cd "$BE" && npm run "$1" 2>&1 || true )
  printf '%s\n' "$aus" | grep -E "^(ℹ|#) (tests|pass|fail) " | sed "s/^/    [$1] /" >&2 || true
  printf '%s\n' "$aus" | grep -E "^(ℹ|#) fail " | awk '{print $3}' | tail -1 || true
}

echo
echo "── Nachher: GRÜN erwartet ──────────────────────────────────────"
echo
( cd "$BE" && node --test --test-reporter=spec test/unit/frontend-struktur.test.js ) 2>&1 \
  | grep -E "^(✔|✖)" || true
echo
U=$(lauf test:unit); I=$(lauf test:integration)
echo "  Unit: fail=${U:-?}   Integration: fail=${I:-?}"
[ "${U:-1}" = "0" ] && [ "${I:-1}" = "0" ] || die "Tests nicht grün — bitte die Ausgabe schicken. Rückgängig: git checkout . && git clean -fd"
ok "alle Tests grün"

echo
echo "── Der eigentliche Gewinn: ESLint sieht diesen Code zum ersten Mal ──"
echo
# Den Exit-Code von npm selbst einsammeln. Nach einer Pipeline liefert $?
# den Status des LETZTEN Glieds — ein grep ohne Treffer endet mit 1 und
# haette hier "Befunde" gemeldet, obwohl der Lint sauber war.
set +e
LINT_AUS=$( cd "$BE" && npm run lint 2>&1 ); LINT=$?
set -e
printf '%s\n' "$LINT_AUS" | grep -vE "^>|^$" || true
echo
if [ "$LINT" -eq 0 ]; then
  ok "Lint sauber — nichts zu triagieren, du kannst pushen"
else
  warn "Lint meldet Befunde (siehe oben). Das ist das ERGEBNIS dieses Schritts,"
  echo "     kein Fehlschlag: dieser Code wurde noch nie geprüft."
  echo "     Die Auslagerung selbst ist in Ordnung — alle Tests sind grün."
  printf '     \033[33mBitte noch NICHT pushen\033[0m, sonst wird die CI rot.\n'
  echo "     Schick mir die Liste; wir gehen sie zusammen durch."
fi

echo
echo "── Danach ──────────────────────────────────────────────────────"
echo
echo "  Im Browser (App neu starten, Strg+F5): die Seiten müssen sich"
echo "  genau wie vorher verhalten. Es wurde kein Verhalten geändert,"
echo "  nur der Ort des Codes."
echo
echo "  Wenn Lint sauber war:"
echo "    git mv $SELBST tools/"
echo "    git add -A && git commit -m 'Phase F Schritt A: Inline-Skripte ausgelagert'"
echo "    git push"
echo
echo "  Rückgängig:  git checkout . && git clean -fd"
echo
