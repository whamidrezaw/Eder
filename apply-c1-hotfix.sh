#!/usr/bin/env bash
#
# apply-c1-hotfix.sh — C1 Hotfix
#
# Mongoose 9 weist eine Aggregations-Pipeline als Update auf Query-Ebene ab,
# solange nicht ausdrücklich { updatePipeline: true } gesetzt ist:
#
#   MongooseError: Cannot pass an array to query updates unless the
#   `updatePipeline` option is set.
#
# Der Fehler fliegt in lib/query.js, noch vor jeder Datenbankrundreise —
# deshalb war er zu 100 % reproduzierbar und nie „manchmal“.
#
# Die Option erklärt nur die Absicht. An der Semantik der Pipeline ändert
# sich nichts: yesterdayStock wird weiterhin atomar aus currentStock
# gelesen, in einer einzigen Operation.
#
# Ausführen im Wurzelverzeichnis des Repos:
#     bash apply-c1-hotfix.sh
#
set -euo pipefail

BE="Edeka.lager/backend"
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
skip() { printf '  \033[90m·\033[0m %s\n' "$1"; }
die()  { printf '\n  \033[31m✗ %s\033[0m\n\n' "$1" >&2; exit 1; }

echo
echo "── C1 Hotfix: updatePipeline ───────────────────────────────────"
echo

[ -f "$BE/services/dailyClose.js" ] || die "'$BE/services/dailyClose.js' nicht gefunden."

if command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
  [ -z "$(git status --porcelain)" ] || die "Arbeitsverzeichnis nicht sauber. Bitte erst committen."
  ok "Arbeitsverzeichnis sauber"
fi

node - "$BE" <<'NODE_HOTFIX'
const fs = require('fs');
const p  = process.argv[2] + '/services/dailyClose.js';
const t  = fs.readFileSync(p, 'utf8');

if (/updatePipeline/.test(t)) {
  console.log('  \x1b[90m·\x1b[0m schon angewendet');
  process.exit(0);
}

const anker = /await Product\.updateMany\(\r?\n(\s*)\{ isActive: true \},\r?\n(\s*)\[\{ \$set: \{ yesterdayStock: '\$currentStock' \} \}\]\r?\n(\s*)\);/;

if (!anker.test(t)) {
  const zeilen = t.split('\n');
  const i = zeilen.findIndex(l => /updateMany/.test(l));
  console.error('\n  \x1b[31m✗ Anker nicht gefunden — nichts geändert.\x1b[0m');
  console.error('    Umgebung in deiner Datei:');
  console.error(zeilen.slice(Math.max(0, i - 2), i + 6)
    .map((l, k) => `      ${Math.max(1, i - 1) + k}| ${l}`).join('\n'));
  console.error('\n    Schick mir diesen Ausschnitt.\n');
  process.exit(1);
}

// Ersetzen über eine Funktion, nicht über einen Ersetzungsstring: so hat
// das $ in '$currentStock' keine Sonderbedeutung und der Einzug bleibt.
const neu = t.replace(anker, (_treffer, e1, e2, e3) =>
  'await Product.updateMany(\n' +
  e1 + '{ isActive: true },\n' +
  e2 + "[{ $set: { yesterdayStock: '$currentStock' } }],\n" +
  e2 + '// Mongoose 9 verlangt diese Option, sobald das Update eine Pipeline\n' +
  e2 + '// (also ein Array) ist — sie unterscheidet einen bewussten\n' +
  e2 + '// Pipeline-Update von einem versehentlich übergebenen Array.\n' +
  e2 + '{ updatePipeline: true }\n' +
  e3 + ');');

fs.writeFileSync(p + '.hotfix.bak', t);
fs.writeFileSync(p, neu);

console.log('  \x1b[32m✓\x1b[0m { updatePipeline: true } in closeDay ergänzt');
NODE_HOTFIX

echo
echo "── Selbstprüfung ───────────────────────────────────────────────"
node --check "$BE/services/dailyClose.js" >/dev/null 2>&1 \
  || die "Syntaxfehler in services/dailyClose.js — rückgängig mit: git checkout ."
ok "services/dailyClose.js ist syntaktisch gültig"

echo
echo "  Alle Stellen im Backend, die ein Array als Update übergeben:"
if grep -rn --include='*.js' --exclude-dir=node_modules --exclude-dir=test \
     -E '\[\{ *\$set' "$BE" 2>/dev/null | sed 's/^/    /'; then :; else
  echo "    (keine gefunden)"
fi
echo "  Jede davon braucht { updatePipeline: true } als dritten Parameter."

echo
echo "── Tests ───────────────────────────────────────────────────────"
echo
( cd "$BE" && npm run test:integration ) || true

echo
echo "── Danach ──────────────────────────────────────────────────────"
echo
echo "  Erwartet: 42 / 42 grün."
echo
echo "  Beim nächsten 'npm start' läuft catchUpIfNeeded() zum ersten Mal"
echo "  wirklich durch — vorher ist es im Hintergrund an genau diesem"
echo "  Fehler gescheitert und nur .catch() hat den Server gerettet."
echo "  Es wird also den gestrigen Tag nachträglich schließen und die"
echo "  Basislinie auf die aktuellen Bestände setzen. Bei Testdaten ist"
echo "  das genau richtig; du solltest es nur erwarten und nicht als"
echo "  neuen Fehler lesen."
echo
echo "  Rückgängig:  git checkout ."
echo
