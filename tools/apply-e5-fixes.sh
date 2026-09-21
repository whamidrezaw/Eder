#!/usr/bin/env bash
#
# apply-e5-fixes.sh — Phase E5, Schritt 2
#
#   E5.1  app.js       nur noch JSON; req.body ist nie mehr undefined
#   E5.2  index.html   Login-Formular mit method="post"
#   E5.3  npm audit fix (OHNE --force) — erst NACHDEM E5.1/E5.2 grün sind
#
# Zwei getrennte Nachweise: zuerst die Codeänderung gegen alle Tests, dann
# die Abhängigkeiten gegen alle Tests. Scheitert etwas, ist klar, woran.
#
# Ausführen im Wurzelverzeichnis des Repos:
#     bash apply-e5-fixes.sh
#
set -euo pipefail

BE="Edeka.lager/backend"
FE="Edeka.lager/frontend"
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
skip() { printf '  \033[90m·\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
die()  { printf '\n  \033[31m✗ %s\033[0m\n\n' "$1" >&2; exit 1; }

# Führt ein npm-Testskript aus, zeigt tests/pass/fail und gibt NUR die Zahl
# der Fehlschläge auf stdout aus. Wichtig: der Exit-Code von npm wird hier
# abgefangen. Unter "set -euo pipefail" würde ein einziger roter Test das
# Skript sonst an der Zuweisung lautlos beenden — genau dann, wenn eine
# Erklärung am nötigsten wäre.
lauf() {
  local aus
  aus=$( cd "$BE" && npm run "$1" 2>&1 || true )
  printf '%s\n' "$aus" | grep -E "^ℹ (tests|pass|fail)" | sed "s/^/    [$1] /" >&2 || true
  printf '%s\n' "$aus" | grep -E "^ℹ fail" | awk '{print $3}' || true
}

echo
echo "── Phase E5, Schritt 2 ─────────────────────────────────────────"
echo

[ -f "$BE/app.js" ]         || die "'$BE/app.js' nicht gefunden."
[ -f "$FE/index.html" ]     || die "'$FE/index.html' nicht gefunden."
[ -f "$BE/test/integration/request-bodies.test.js" ] \
  || die "E5-Tests fehlen. Bitte zuerst apply-e5-tests.sh ausführen."

if command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
  BRANCH=$(git rev-parse --abbrev-ref HEAD)
  [ "$BRANCH" != "main" ] || die "Du bist auf main. Bitte auf phase-e wechseln."
  [ -z "$(git status --porcelain)" ] || die "Arbeitsverzeichnis nicht sauber. Bitte erst committen."
  ok "Branch '$BRANCH', Arbeitsverzeichnis sauber"
fi

# ── Sicherung: braucht irgendein Frontend urlencoded? ────────────────
# Die Entscheidung "urlencoded entfernen" beruht darauf, dass das Frontend
# ausschließlich JSON schickt. Hier wird das geprüft, BEVOR etwas geändert
# wird — nicht angenommen.
echo
echo "── Braucht das Frontend urlencoded? ────────────────────────────"
URLENC=$(grep -rniE "x-www-form-urlencoded" "$FE" --include='*.html' --include='*.js' \
          --exclude='chart.umd.min.js' 2>/dev/null || true)
FORMAPI=$(grep -rniE "<form[^>]*action=[\"']?/api" "$FE" --include='*.html' 2>/dev/null || true)
if [ -n "$URLENC" ] || [ -n "$FORMAPI" ]; then
  echo "$URLENC"; echo "$FORMAPI"
  die "Das Frontend verwendet urlencoded oder schickt ein Formular direkt an /api.
     Dann darf der Parser NICHT entfernt werden. Bitte die Zeilen oben schicken."
fi
ok "kein x-www-form-urlencoded, kein Formular mit action=/api"
USP=$(grep -rnE "URLSearchParams" "$FE" --include='*.html' --include='*.js' \
       --exclude='chart.umd.min.js' 2>/dev/null || true)
if [ -n "$USP" ]; then
  warn "URLSearchParams kommt vor — zur Kontrolle, meist nur für Abfrage-URLs:"
  printf '%s\n' "$USP" | sed 's/^/      /'
fi

# ── Quelltext ────────────────────────────────────────────────────────
echo
echo "── Quelltext (alles oder nichts) ───────────────────────────────"
node - "$BE" "$FE" <<'NODE_E5'
const fs = require('fs'), path = require('path');
const BE = process.argv[2], FE = process.argv[3];
const pfad = d => d.startsWith('frontend/') ? path.join(FE, d.slice(9)) : path.join(BE, d);
const plan = [], fehler = [], dateien = new Map();

function hole(d) {
  if (!dateien.has(d)) {
    const f = pfad(d);
    if (!fs.existsSync(f)) return null;
    const t = fs.readFileSync(f, 'utf8');
    dateien.set(d, { original: t, aktuell: t });
  }
  return dateien.get(d);
}
function umgebung(text, muster, n = 8) {
  const L = text.split('\n'), i = L.findIndex(l => muster.test(l));
  if (i === -1) return '      (keine ähnliche Zeile gefunden)';
  return L.slice(Math.max(0, i - 2), i + n).map((l, k) => `      ${i - 1 + k}| ${l}`).join('\n');
}
function patch({ name, datei, schonDa, suche, ersetze, hinweis, naehe }) {
  const e = hole(datei);
  if (!e) { fehler.push({ name, datei, hinweis: 'Datei nicht gefunden', ausschnitt: '' }); return; }
  if (schonDa && schonDa.test(e.aktuell)) { plan.push({ name, geaendert: false }); return; }
  const neu = e.aktuell.replace(suche, ersetze);
  if (neu === e.aktuell) { fehler.push({ name, datei, hinweis, ausschnitt: naehe ? umgebung(e.aktuell, naehe) : '' }); return; }
  e.aktuell = neu;
  plan.push({ name, geaendert: true });
}

// ── E5.1  nur JSON, req.body nie undefined ────────────────────────
patch({
  name: 'E5.1  app.js: nur JSON, req.body nie mehr undefined',
  datei: 'app.js',
  schonDa: /req\.body === undefined/,
  suche: /\/\/ ── Body Parsing ─+[^\n]*\r?\napp\.use\(express\.json\(\{ limit: '10kb' \}\)\);\r?\napp\.use\(express\.urlencoded\(\{ extended: true, limit: '10kb' \}\)\);/,
  ersetze: () => [
    '// ── Body Parsing ─────────────────────────────────────────────────',
    '// Nur JSON. Das Frontend schickt ausschließlich JSON — api() in',
    '// shared.js und das Login-Formular in index.html. Der frühere',
    '// urlencoded-Parser wurde von niemandem gebraucht, verarbeitete aber',
    '// jeden solchen Körper VOR jeder Anmeldung mit qs. body-parser 2 nutzt',
    '// qs auch bei extended:false; nur das Entfernen nimmt qs aus dem Weg.',
    "app.use(express.json({ limit: '10kb' }));",
    '',
    '// In Express 5 bleibt req.body undefined, wenn kein Parser den Körper',
    '// gelesen hat — in Express 4 war es {}. Routen wie /login zerlegen',
    '// req.body direkt und stürzten dann mit einem TypeError ab: aus einem',
    '// Fehler des Aufrufers (400) wurde ein Serverfehler (500), samt',
    '// Stacktrace im Log und ohne Anmeldung auslösbar. Hier wird der',
    '// Express-4-Zustand wiederhergestellt, für alle Routen auf einmal.',
    'app.use((req, res, next) => {',
    '  if (req.body === undefined) req.body = {};',
    '  next();',
    '});'
  ].join('\n'),
  hinweis: 'Der Body-Parsing-Block in app.js sieht anders aus als erwartet.',
  naehe: /express\.(json|urlencoded)/
});

// ── E5.2  Login-Formular per POST ─────────────────────────────────
// Ohne method nimmt der Browser GET. Lädt das Skript nicht, landet das
// Passwort in der URL. Mit POST geht es schlimmstenfalls im Körper einer
// Anfrage an /index.html ins Leere (404) — nie in Verlauf oder Log.
// Bewusst OHNE action: sonst versuchte der Browser ohne Skript einen
// urlencoded-Login, den es nicht mehr gibt.
patch({
  name: 'E5.2  index.html: Login-Formular mit method="post"',
  datei: 'frontend/index.html',
  schonDa: /<form\b[^>]*\bid="login-form"[^>]*\bmethod="post"/i,
  suche: /(<form\b[^>]*\bid="login-form")/,
  ersetze: '$1 method="post"',
  hinweis: 'Das Formular mit id="login-form" wurde nicht gefunden.',
  naehe: /login-form/
});

// ── Abschlussprüfung, noch vor dem Schreiben ──────────────────────
{
  const a = dateien.get('app.js');
  if (a) {
    const nurCode = a.aktuell.split('\n').filter(l => !/^\s*\/\//.test(l)).join('\n');
    if (/express\.urlencoded\(/.test(nurCode)) {
      fehler.push({ name: 'Abschlussprüfung', datei: 'app.js',
                    hinweis: 'express.urlencoded( steht noch im Code', ausschnitt: umgebung(a.aktuell, /urlencoded\(/) });
    }
  }
}

if (fehler.length) {
  console.log('\n  \x1b[31mEs wurde NICHTS geändert:\x1b[0m\n');
  for (const f of fehler) {
    console.log(`  \x1b[31m✗\x1b[0m ${f.name}  (${f.datei})`);
    console.log(`     ${f.hinweis}`);
    if (f.ausschnitt) console.log('     Umgebung in deiner Datei:\n' + f.ausschnitt);
    console.log('');
  }
  process.exit(1);
}
for (const p of plan) console.log(p.geaendert ? `  \x1b[32m✓\x1b[0m ${p.name}` : `  \x1b[90m·\x1b[0m ${p.name} — schon angewendet`);
for (const [d, e] of dateien) {
  if (e.aktuell === e.original) continue;
  const f = pfad(d);
  if (!fs.existsSync(f + '.e5.bak')) fs.writeFileSync(f + '.e5.bak', e.original);
  fs.writeFileSync(f, e.aktuell);
  console.log(`  \x1b[90m→\x1b[0m geschrieben: ${d}`);
}
NODE_E5

node --check "$BE/app.js" >/dev/null 2>&1 || die "Syntaxfehler in app.js — rückgängig mit: git checkout ."
ok "app.js syntaktisch gültig"
( cd "$BE" && npm run lint ) >/dev/null 2>&1 && ok "Lint sauber" \
  || { ( cd "$BE" && npm run lint ) 2>&1 | grep -v '^>' ; die "Lint meldet etwas — siehe oben"; }

# ── Nachweis 1: der Code ─────────────────────────────────────────────
echo
echo "── Nachweis 1: Codeänderung gegen alle Tests ───────────────────"
echo
( cd "$BE" && node --test test/integration/request-bodies.test.js ) 2>&1 \
  | grep -vE "^\s*(at |node:internal)" || true
echo
U1=$(lauf test:unit)
I1=$(lauf test:integration)
echo "  Unit: fail=${U1:-?}   Integration: fail=${I1:-?}"
if [ "${U1:-1}" != "0" ] || [ "${I1:-1}" != "0" ]; then
  die "Nach der Codeänderung ist nicht alles grün. Die Abhängigkeiten werden
     NICHT angefasst — erst die Ausgabe oben klären. Rückgängig: git checkout ."
fi
ok "alles grün — erst jetzt werden die Abhängigkeiten angefasst"

# ── E5.3  npm audit fix ──────────────────────────────────────────────
echo
echo "── Nachweis 2: Abhängigkeiten ──────────────────────────────────"
echo
echo "  npm audit fix — OHNE --force. --force würde exceljs auf 3.4.0"
echo "  zurückstufen und die Excel-Ausgabe brechen, um eine uuid-Lücke zu"
echo "  schließen, die diese App gar nicht erreicht."
echo
# Der Exit-Code ist ungleich 0, solange etwas übrig bleibt — und uuid
# bleibt absichtlich. Deshalb wird er hier nicht als Fehler gewertet.
( cd "$BE" && npm audit fix ) 2>&1 | tail -4 || true
echo
# Nicht node_modules zählt, sondern das Manifest — genau daran ist die
# ESLint-Einrichtung in der CI gescheitert.
if git diff --quiet -- "$BE/package-lock.json"; then
  warn "package-lock.json unverändert — npm audit fix hat nichts geschrieben (Netz?)"
else
  git diff --stat -- "$BE/package-lock.json" "$BE/package.json" | sed 's/^/  /'
  ok "package-lock.json aktualisiert"
fi

echo
U2=$(lauf test:unit)
I2=$(lauf test:integration)
echo "  Unit: fail=${U2:-?}   Integration: fail=${I2:-?}"
if [ "${U2:-1}" != "0" ] || [ "${I2:-1}" != "0" ]; then
  echo
  die "Nach npm audit fix ist etwas rot. Die Codeänderung war grün, es liegt
     also an einem aktualisierten Paket. Nur die Abhängigkeiten zurück:
       cd $BE && git checkout -- package-lock.json package.json && npm ci"
fi
ok "auch nach der Aktualisierung alles grün"

# ── Was bleibt ───────────────────────────────────────────────────────
echo
echo "── Verbleibende Befunde (nur Produktion) ───────────────────────"
( cd "$BE" && npm audit --omit=dev ) 2>&1 | grep -E "^(# |[a-z@][a-z0-9@/._-]+ +[<>=0-9.| -]+$|Severity|[0-9]+ vulnerabilit)" || true
# npm audit endet mit Exit 1, sobald überhaupt etwas übrig ist — und uuid
# bleibt absichtlich. Deshalb erst einsammeln, dann auswerten.
AUDIT_JSON=$( cd "$BE" && npm audit --omit=dev --json 2>/dev/null || true )
HOCH=$( printf '%s' "$AUDIT_JSON" | node -e "
  let s=''; process.stdin.on('data', d => s += d).on('end', () => {
    try { const v = JSON.parse(s).metadata.vulnerabilities || {}; console.log((v.high||0) + (v.critical||0)); }
    catch { console.log('?'); }
  });" || echo '?' )
echo
if [ "$HOCH" = "0" ]; then
  ok "keine hohen oder kritischen Befunde mehr in den Produktionsabhängigkeiten"
else
  warn "noch $HOCH hohe/kritische Befunde — bitte die Liste oben schicken"
fi

echo
echo "── Danach ──────────────────────────────────────────────────────"
echo
echo "  Erwartet: 65 Unit- und 84 Integrationstests grün, und nur noch"
echo "  uuid als bekannter, bewusst stehengelassener Befund."
echo
echo "  Im Browser: normal anmelden — unverändert. Das Formular trägt jetzt"
echo "  method=\"post\", die Anmeldung läuft aber weiterhin über JavaScript."
echo
echo "    git mv apply-e5-tests.sh apply-e5-fixes.sh tools/"
echo "    git add -A && git commit -m 'E5: robuste Anfragekörper, kein urlencoded, npm audit fix'"
echo "    git push"
echo
echo "  Rückgängig (alles):  git checkout . && git clean -fd && (cd $BE && npm ci)"
echo
