#!/usr/bin/env bash
#
# apply-f1-lint.sh — Phase F, Schritt A, Nachtrag: die ersten Lint-Befunde
#
# Nach dem Auslagern hat ESLint diesen Code zum ersten Mal gelesen und
# zehnmal "no-unused-vars" gemeldet. Zwei Sorten:
#
#   1. Funktionen, die NUR aus Inline-Handlern im HTML aufgerufen werden
#      (onclick="openCreateModal()"). ESLint liest kein HTML. Sie sind
#      benutzt — nur unsichtbar. Für jede wird hier NACHGEPRÜFT, dass sie
#      wirklich irgendwo aufgerufen wird; erst dann bekommt sie ein
#      /* exported … */. Wird sie nirgends aufgerufen, ist sie tot und wird
#      gemeldet, nicht versteckt.
#
#   2. Ein catch (err), das den Fehler verwirft — in der Anmeldeseite.
#      Derselbe Fehlertyp wie in E4 bei middleware/auth.js: der Nutzer sieht
#      eine allgemeine Meldung, der eigentliche Fehler verschwindet spurlos.
#
# Das /* exported */ ist vorübergehend: Schritt B bindet diese Funktionen
# per addEventListener an, dann sieht ESLint den Aufruf selbst.
#
# Ausführen im Wurzelverzeichnis des Repos:
#     bash apply-f1-lint.sh
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
echo "── Phase F, Schritt A: erste Lint-Befunde ──────────────────────"
echo

[ -d "$FE/assets" ] || die "'$FE/assets' nicht gefunden."
[ -x "$BE/node_modules/.bin/eslint" ] || die "ESLint nicht installiert (npm ci im Backend?)."

if command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
  BRANCH=$(git rev-parse --abbrev-ref HEAD)
  [ "$BRANCH" != "main" ] || die "Du bist auf main. Bitte auf phase-f wechseln."
  SCHMUTZ=$(git status --porcelain | grep -v -- "$SELBST" || true)
  [ -z "$SCHMUTZ" ] || { printf '%s\n' "$SCHMUTZ" | sed 's/^/     /'; die "Arbeitsverzeichnis nicht sauber (siehe oben)."; }
  ok "Branch '$BRANCH', Arbeitsverzeichnis sauber (ohne $SELBST)"
fi

echo
echo "── Befunde einlesen ────────────────────────────────────────────"
# ESLint endet mit 1, wenn es etwas findet — das ist hier der Normalfall.
BEFUND_JSON=$( cd "$EL" && ./backend/node_modules/.bin/eslint --format json frontend/assets 2>/dev/null || true )
[ -n "$BEFUND_JSON" ] || die "ESLint hat keine auswertbare Ausgabe geliefert."

node - "$FE" "$BEFUND_JSON" <<'NODE_LINT'
const fs = require('fs'), path = require('path');
const FE = process.argv[2];
let ergebnis;
try { ergebnis = JSON.parse(process.argv[3]); }
catch { console.log('  \x1b[31m✗ ESLint-Ausgabe ist kein JSON\x1b[0m'); process.exit(1); }

const exportiere = new Map();   // Datei -> Set(Namen)
const catches    = [];          // { datei, zeile, name }
const tot        = [];
const unbekannt  = [];

// Alle Stellen, an denen ein Name aufgerufen werden könnte: jede HTML-Seite
// und jede JS-Datei im Frontend (auch die Template-Strings darin).
function alleQuellen() {
  const out = [];
  const lauf = (dir) => {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, e.name);
      if (e.isDirectory()) lauf(p);
      else if (/\.(html|js)$/.test(e.name) && e.name !== 'chart.umd.min.js') out.push(p);
    }
  };
  lauf(FE);
  return out.map(p => ({ p, text: fs.readFileSync(p, 'utf8') }));
}
const quellen = alleQuellen();

function wirdAufgerufen(name) {
  const aufruf = new RegExp('\\b' + name + '\\s*\\(', 'g');
  const def    = new RegExp('function\\s+' + name + '\\s*\\(');
  const fund = [];
  for (const q of quellen) {
    q.text.split('\n').forEach((z, i) => {
      if (def.test(z)) return;               // die Definition selbst zählt nicht
      if (aufruf.test(z)) fund.push(`${path.basename(q.p)}:${i + 1}`);
      aufruf.lastIndex = 0;
    });
  }
  return fund;
}

let anzahl = 0;
for (const datei of ergebnis) {
  const zeilen = fs.readFileSync(datei.filePath, 'utf8').split('\n');
  for (const m of datei.messages) {
    anzahl++;
    const wo = `${path.basename(datei.filePath)}:${m.line}`;
    if (m.ruleId !== 'no-unused-vars') { unbekannt.push(`${wo}  ${m.ruleId}: ${m.message}`); continue; }
    const name = (m.message.match(/^'([^']+)'/) || [])[1];
    const zeile = zeilen[m.line - 1] || '';

    if (name && new RegExp('catch\\s*\\(\\s*' + name + '\\s*\\)').test(zeile)) {
      catches.push({ datei: datei.filePath, zeile: m.line, name });
      continue;
    }
    if (name && new RegExp('function\\s+' + name + '\\s*\\(').test(zeile)) {
      const fund = wirdAufgerufen(name);
      if (fund.length) {
        if (!exportiere.has(datei.filePath)) exportiere.set(datei.filePath, new Map());
        exportiere.get(datei.filePath).set(name, fund);
      } else {
        tot.push(`${wo}  ${name}() — wird nirgends aufgerufen`);
      }
      continue;
    }
    unbekannt.push(`${wo}  ${m.message}`);
  }
}
console.log(`  ${anzahl} Befund(e) eingelesen`);

// ── Änderungen planen, alles oder nichts ──────────────────────────
const neu = new Map();
const lade = (f) => { if (!neu.has(f)) neu.set(f, fs.readFileSync(f, 'utf8')); return neu.get(f); };
const fehler = [];

// Catch-Blöcke zuerst: sie verschieben keine Zeilennummern VOR sich, und
// von unten nach oben bleiben die Nummern der übrigen gültig.
for (const c of catches.sort((a, b) => b.zeile - a.zeile)) {
  const L = lade(c.datei).split('\n');
  const z = L[c.zeile - 1];
  const tag = path.basename(c.datei, '.js');
  const log = `console.error('[${tag}] Unerwarteter Fehler:', ${c.name});`;
  if (new RegExp('console\\.error\\([^)]*' + c.name).test(L.slice(c.zeile - 1, c.zeile + 3).join('\n'))) continue;
  if (/\{\s*$/.test(z)) {
    // Mehrzeiliger Block: eigene Zeile, eingerückt wie die erste Anweisung darin.
    const naechste = L[c.zeile] || '';
    const einzug = /^\s*\}/.test(naechste)
      ? (z.match(/^\s*/)[0] + '  ')
      : naechste.match(/^\s*/)[0];
    L.splice(c.zeile, 0, einzug + log);
  } else {
    // Einzeiler: direkt hinter die öffnende Klammer.
    const neuZ = z.replace(new RegExp('(catch\\s*\\(\\s*' + c.name + '\\s*\\)\\s*\\{)'), '$1 ' + log);
    if (neuZ === z) { fehler.push(`${path.basename(c.datei)}:${c.zeile} — catch-Block nicht erkennbar`); continue; }
    L[c.zeile - 1] = neuZ;
  }
  neu.set(c.datei, L.join('\n'));
}

// /* exported */ vor 'use strict' — oder an eine bestehende Liste anhängen.
for (const [f, namen] of exportiere) {
  let t = lade(f);
  const liste = [...namen.keys()];
  const vorhanden = t.match(/\/\* exported ([^*]*)\*\//);
  if (vorhanden) {
    const alt = vorhanden[1].split(',').map(s => s.trim()).filter(Boolean);
    const alle = [...new Set([...alt, ...liste])];
    t = t.replace(vorhanden[0], `/* exported ${alle.join(', ')} */`);
  } else {
    // Ganz oben in die Datei — dort stehen ESLint-Direktiven üblicherweise.
    // Kein Anker nötig: ein Kommentar am Dateianfang stört 'use strict' nie,
    // ob die Datei eines hat oder nicht. (Die erste Fassung hängte sich an
    // 'use strict' — und scheiterte an index.js, das offenbar keines hat.)
    const kopf =
      '// Diese Funktionen werden aus Inline-Handlern im HTML aufgerufen, das\n' +
      '// ESLint nicht liest. Bis Schritt B sie per addEventListener anbindet,\n' +
      '// sagt die folgende Zeile ESLint, dass sie benutzt werden.\n' +
      `/* exported ${liste.join(', ')} */\n`;
    t = kopf + t;
  }
  neu.set(f, t);
}

if (fehler.length) {
  console.log('\n  \x1b[31mEs wurde NICHTS geändert:\x1b[0m');
  fehler.forEach(x => console.log('  \x1b[31m✗\x1b[0m ' + x));
  process.exit(1);
}

// Nachweis vor dem Schreiben: jede Datei muss weiter parsen.
for (const [f, t] of neu) {
  try { new Function(t); }
  catch (e) { console.log(`  \x1b[31m✗ ${path.basename(f)} wäre ungültig: ${e.message} — nichts geschrieben\x1b[0m`); process.exit(1); }
}

for (const [f, t] of neu) {
  const orig = fs.readFileSync(f, 'utf8');
  if (t === orig) continue;
  if (!fs.existsSync(f + '.lint.bak')) fs.writeFileSync(f + '.lint.bak', orig);
  fs.writeFileSync(f, t);
}

// ── Bericht ───────────────────────────────────────────────────────
for (const [f, namen] of exportiere) {
  console.log(`  \x1b[32m✓\x1b[0m ${path.basename(f)}: als aus dem HTML aufgerufen markiert`);
  for (const [n, fund] of namen) console.log(`      ${n.padEnd(24)} aufgerufen in ${fund.slice(0, 2).join(', ')}${fund.length > 2 ? ' …' : ''}`);
}
for (const c of catches) {
  console.log(`  \x1b[32m✓\x1b[0m ${path.basename(c.datei)}:${c.zeile}: catch (${c.name}) protokolliert den Fehler jetzt`);
}
if (tot.length) {
  console.log('\n  \x1b[33m!\x1b[0m Wirklich unbenutzt — NICHT versteckt, bitte melden:');
  tot.forEach(x => console.log('      ' + x));
}
if (unbekannt.length) {
  console.log('\n  \x1b[33m!\x1b[0m Andere Befunde — unverändert gelassen, bitte melden:');
  unbekannt.forEach(x => console.log('      ' + x));
}
NODE_LINT

for f in "$FE"/assets/*.js; do
  case "$f" in *chart.umd.min.js) continue;; esac
  node --check "$f" >/dev/null 2>&1 || die "Syntaxfehler in $f — rückgängig mit: git checkout ."
done
ok "alle assets/*.js syntaktisch gültig"

lauf() {
  local aus
  aus=$( cd "$BE" && npm run "$1" 2>&1 || true )
  printf '%s\n' "$aus" | grep -E "^(ℹ|#) (tests|pass|fail) " | sed "s/^/    [$1] /" >&2 || true
  printf '%s\n' "$aus" | grep -E "^(ℹ|#) fail " | awk '{print $3}' | tail -1 || true
}

echo
echo "── Tests ───────────────────────────────────────────────────────"
U=$(lauf test:unit); I=$(lauf test:integration)
echo "  Unit: fail=${U:-?}   Integration: fail=${I:-?}"
[ "${U:-1}" = "0" ] && [ "${I:-1}" = "0" ] || die "Tests nicht grün — rückgängig mit: git checkout ."
ok "alle Tests grün"

echo
echo "── Lint ────────────────────────────────────────────────────────"
set +e
LINT_AUS=$( cd "$BE" && npm run lint 2>&1 ); LINT=$?
set -e
printf '%s\n' "$LINT_AUS" | grep -vE "^>|^$" || true
if [ "$LINT" -eq 0 ]; then
  ok "Lint sauber"
  echo
  echo "── Danach ──────────────────────────────────────────────────────"
  echo
  echo "  Beide Skripte in tools/ ablegen. mv statt git mv: dieses Skript ist"
  echo "  noch nicht versioniert — mv plus git add -A erfasst beide Fälle."
  echo
  echo "    mkdir -p tools && mv apply-f1-extract.sh $SELBST tools/ 2>/dev/null; true"
  echo "    git add -A && git commit -m 'Phase F Schritt A: erste Lint-Befunde behoben'"
  echo "    git push -u origin phase-f"
  echo
  echo "  -u einmalig: der Branch phase-f existiert auf GitHub noch nicht."
else
  echo
  warn "Lint noch nicht sauber — die Liste oben schicken, NICHT pushen."
fi
echo
echo "  Rückgängig:  git checkout ."
echo
