#!/usr/bin/env bash
#
# apply-batch-a2.sh — Abschluss von Batch A
#
#   A8  /export weist ein fehlerhaft formatiertes Datum mit 400 ab
#       (statt es als "keine Daten" mit 404 zu behandeln)
#   +   Aufräumen: *.bak aus der Versionsverwaltung heraushalten
#
# Ausführen im Wurzelverzeichnis des Repos:
#     bash apply-batch-a2.sh
#
# Idempotent. Bricht ab, ohne etwas zu ändern, wenn ein Anker fehlt.
#
set -euo pipefail

BE="Edeka.lager/backend"
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
skip() { printf '  \033[90m·\033[0m %s\n' "$1"; }
die()  { printf '\n  \033[31m✗ %s\033[0m\n\n' "$1" >&2; exit 1; }

echo
echo "── Batch A, Abschluss ──────────────────────────────────────────"
echo

[ -f "$BE/lib/validate.js" ] || die "'$BE/lib/validate.js' fehlt. Bitte zuerst apply-batch-a.sh ausführen."
[ -f "$BE/routes/reports.js" ] || die "'$BE/routes/reports.js' nicht gefunden."

if command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
  [ -z "$(git status --porcelain)" ] || die "Arbeitsverzeichnis nicht sauber. Bitte erst committen."
  ok "Arbeitsverzeichnis sauber"
fi

echo
echo "── A8: Datumsformat bei /export ────────────────────────────────"

node - "$BE" <<'NODE_A8'
const fs = require('fs');
const p  = process.argv[2] + '/routes/reports.js';
const t  = fs.readFileSync(p, 'utf8');

if (/Ein fehlerhaft formatiertes Datum/.test(t)) {
  console.log('  \x1b[90m·\x1b[0m schon angewendet');
  process.exit(0);
}

const anker = /(router\.get\('\/export',\s*auth,\s*async\s*\(\s*req\s*,\s*res\s*\)\s*=>\s*\{\r?\n)/;
if (!anker.test(t)) {
  const zeilen = t.split('\n');
  const i = zeilen.findIndex(l => /router\.get\('\/export'/.test(l));
  console.error('\n  \x1b[31m✗ Anker für /export nicht gefunden — nichts geändert.\x1b[0m');
  console.error('    Gefundene Umgebung:');
  console.error(zeilen.slice(Math.max(0, i - 1), i + 4).map((l, k) => `      ${i + k}| ${l}`).join('\n'));
  console.error('\n    Schick mir diesen Ausschnitt.\n');
  process.exit(1);
}

const einschub = `  {
    // Ein fehlerhaft formatiertes Datum ist ein kaputter Request (400),
    // kein leeres Ergebnis (404). Werden beide Fälle vermischt, bleibt ein
    // Fehler im Frontend für immer unsichtbar. reset-logs weist denselben
    // Wert ebenfalls mit 400 ab — zwei Routen, ein Parameter, eine Regel.
    // Fehlt das Datum ganz, bleibt das Verhalten unverändert.
    const rohDatum = req.query?.date;
    if (rohDatum !== undefined && rohDatum !== '' &&
        !require('../lib/validate').parseIsoDate(rohDatum)) {
      return res.status(400).json({ message: 'Ungültiges Datum. Erwartet wird JJJJ-MM-TT.' });
    }
  }
`;

if (!fs.existsSync(p + '.bak')) fs.writeFileSync(p + '.bak', t);
fs.writeFileSync(p, t.replace(anker, '$1' + einschub));
console.log('  \x1b[32m✓\x1b[0m Datumsprüfung in /export eingefügt');
NODE_A8

echo
echo "── Aufräumen ───────────────────────────────────────────────────"

GI=".gitignore"
if [ -f "$GI" ] && grep -qE '^\*\.bak$' "$GI"; then
  skip ".gitignore enthält *.bak bereits"
else
  printf '\n# Sicherungskopien der Fix-Skripte\n*.bak\n' >> "$GI"
  ok "*.bak zu .gitignore hinzugefügt"
fi

if command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
  if git ls-files --error-unmatch "$BE/server.js.bak" >/dev/null 2>&1; then
    git rm --cached -q "$BE/server.js.bak"
    ok "server.js.bak aus der Versionsverwaltung entfernt (Datei bleibt lokal)"
  else
    skip "keine .bak-Datei in der Versionsverwaltung"
  fi
fi

echo
echo "── Selbstprüfung ───────────────────────────────────────────────"
node --check "$BE/routes/reports.js" >/dev/null 2>&1 \
  || die "Syntaxfehler in routes/reports.js — rückgängig mit: git checkout ."
ok "routes/reports.js ist syntaktisch gültig"

echo
echo "── Tests ───────────────────────────────────────────────────────"
echo
( cd "$BE" && npm run test:unit ) || true
echo
( cd "$BE" && npm run test:integration ) || true

echo
echo "  Erwartet: 48 / 48 und 28 / 28 grün."
echo "  Rückgängig:  git checkout . && git clean -fd"
echo
