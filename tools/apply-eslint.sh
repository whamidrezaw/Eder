#!/usr/bin/env bash
#
# apply-eslint.sh — Phase E, Schritt 0: statische Prüfung einrichten
#
# Warum: node --check findet nur Syntaxfehler. Ein Tippfehler oder eine
# Variable, die es nicht mehr gibt, ist erst zur Laufzeit ein Fehler — genau
# so ist in C2 das "rawLogs is not defined" bis auf den Server durchgerutscht
# und hat dort einen 500er erzeugt. ESLint findet das in unter einer Sekunde.
#
# Dieses Skript richtet die Prüfung ein und lässt sie EINMAL laufen. Es hängt
# sie noch NICHT in die CI: erst sehen, was sie findet, dann aufräumen, dann
# erzwingen.
#
# Ausführen im Wurzelverzeichnis des Repos:
#     bash apply-eslint.sh
#
set -euo pipefail

BE="Edeka.lager/backend"
EL="Edeka.lager"
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
skip() { printf '  \033[90m·\033[0m %s\n' "$1"; }
die()  { printf '\n  \033[31m✗ %s\033[0m\n\n' "$1" >&2; exit 1; }

echo
echo "── Phase E, Schritt 0: ESLint ──────────────────────────────────"
echo

[ -f "$BE/package.json" ]     || die "'$BE/package.json' nicht gefunden."
[ -d "$EL/frontend/assets" ]  || die "'$EL/frontend/assets' nicht gefunden."

if command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
  [ -z "$(git status --porcelain)" ] || die "Arbeitsverzeichnis nicht sauber. Bitte erst committen."
  ok "Arbeitsverzeichnis sauber"
fi

# ── 1  Installieren ──────────────────────────────────────────────────
# Wichtig: ein echtes npm install, kein Eintrag von Hand in package.json.
# Sonst laufen package.json und package-lock.json auseinander und `npm ci`
# bricht in der CI ab — genau in Schritt 5, noch vor den Tests.
echo
echo "── ESLint installieren ─────────────────────────────────────────"
if [ -d "$BE/node_modules/eslint" ]; then
  skip "eslint ist bereits installiert"
else
  ( cd "$BE" && npm install --save-dev eslint ) >/dev/null 2>&1 \
    || die "npm install --save-dev eslint ist fehlgeschlagen (Netzwerk?)"
  ok "eslint installiert"
fi
( cd "$BE" && npx eslint --version | sed 's/^/  Version: /' )

git diff --name-only -- "$BE/package.json" "$BE/package-lock.json" 2>/dev/null | sed 's/^/  geändert: /' || true

# ── 2  Konfiguration ─────────────────────────────────────────────────
# Sie liegt in Edeka.lager/ und nicht in backend/: ESLint ignoriert alles,
# was außerhalb des Verzeichnisses der Konfigurationsdatei liegt. Von
# backend/ aus wäre frontend/ unerreichbar — und zwar lautlos, mit
# Exit-Code 0. Eine Prüfung, die nichts prüft und "sauber" meldet, wäre
# schlimmer als gar keine.
cat > "$EL/eslint.config.js" <<'EOF'
'use strict';
//
// Statische Prüfung für Backend (Node) und Frontend (Browser).
//
// Absichtlich NUR Fehlerregeln, keine Stilregeln: Diese Prüfung soll Käfer
// finden, nicht den vorhandenen Code umformatieren. Eingerückt wird weiter
// so, wie es ist.
//
// Die Datei liegt hier und nicht in backend/, weil ESLint nur Dateien
// unterhalb des Konfigurationsverzeichnisses betrachtet.

const NODE_GLOBALS = {
  require: 'readonly', module: 'writable', exports: 'writable',
  process: 'readonly', console: 'readonly',
  __dirname: 'readonly', __filename: 'readonly',
  Buffer: 'readonly', global: 'readonly', globalThis: 'readonly',
  setTimeout: 'readonly', clearTimeout: 'readonly',
  setInterval: 'readonly', clearInterval: 'readonly',
  setImmediate: 'readonly', queueMicrotask: 'readonly',
  URL: 'readonly', URLSearchParams: 'readonly',
  fetch: 'readonly', Response: 'readonly', Request: 'readonly',
  Headers: 'readonly', FormData: 'readonly', Blob: 'readonly',
  AbortController: 'readonly', AbortSignal: 'readonly',
  TextEncoder: 'readonly', TextDecoder: 'readonly',
  structuredClone: 'readonly', crypto: 'readonly',
  performance: 'readonly', atob: 'readonly', btoa: 'readonly'
};

const BROWSER_GLOBALS = {
  window: 'readonly', document: 'readonly', navigator: 'readonly',
  location: 'writable', history: 'readonly', screen: 'readonly',
  localStorage: 'readonly', sessionStorage: 'readonly',
  console: 'readonly', fetch: 'readonly',
  alert: 'readonly', confirm: 'readonly', prompt: 'readonly',
  setTimeout: 'readonly', clearTimeout: 'readonly',
  setInterval: 'readonly', clearInterval: 'readonly',
  requestAnimationFrame: 'readonly', cancelAnimationFrame: 'readonly',
  queueMicrotask: 'readonly', matchMedia: 'readonly',
  URL: 'readonly', URLSearchParams: 'readonly',
  Blob: 'readonly', File: 'readonly', FileReader: 'readonly',
  FormData: 'readonly', Headers: 'readonly',
  Event: 'readonly', CustomEvent: 'readonly', EventTarget: 'readonly',
  Element: 'readonly', HTMLElement: 'readonly', Node: 'readonly',
  Image: 'readonly', DOMParser: 'readonly', XMLHttpRequest: 'readonly',
  MutationObserver: 'readonly', IntersectionObserver: 'readonly',
  ResizeObserver: 'readonly', AbortController: 'readonly',
  getComputedStyle: 'readonly', crypto: 'readonly',
  performance: 'readonly', atob: 'readonly', btoa: 'readonly',
  TextEncoder: 'readonly', TextDecoder: 'readonly',
  structuredClone: 'readonly',
  // Selbst gehostete Bibliothek aus frontend/assets
  Chart: 'readonly'
};

// Nur Regeln, die echte Fehler anzeigen.
const FEHLERREGELN = {
  // Der Grund für diese ganze Einrichtung:
  'no-undef': 'error',
  'no-unused-vars': ['error', { args: 'none', varsIgnorePattern: '^_' }],

  'no-dupe-keys': 'error',
  'no-dupe-args': 'error',
  'no-dupe-else-if': 'error',
  'no-duplicate-case': 'error',
  'no-unreachable': 'error',
  'no-cond-assign': 'error',
  'no-self-assign': 'error',
  'no-self-compare': 'error',
  'no-unsafe-negation': 'error',
  'no-unsafe-optional-chaining': 'error',
  'no-fallthrough': 'error',
  'no-sparse-arrays': 'error',
  'valid-typeof': 'error',
  'use-isnan': 'error',
  'no-async-promise-executor': 'error',
  'no-promise-executor-return': 'error',
  'no-empty': ['error', { allowEmptyCatch: true }],
  'no-constant-condition': ['error', { checkLoops: false }],
  'no-template-curly-in-string': 'warn'
};

module.exports = [
  {
    ignores: [
      '**/node_modules/**',
      '**/*.bak',
      // Fremdcode, minifiziert — hier gibt es nichts zu prüfen.
      'frontend/assets/chart.umd.min.js'
    ]
  },
  {
    files: ['backend/**/*.js'],
    languageOptions: { ecmaVersion: 2023, sourceType: 'commonjs', globals: NODE_GLOBALS },
    rules: FEHLERREGELN
  },
  {
    files: ['frontend/assets/**/*.js'],
    // Klassisches Browser-Skript, kein Modul.
    languageOptions: { ecmaVersion: 2023, sourceType: 'script', globals: BROWSER_GLOBALS },
    rules: FEHLERREGELN
  }
];
EOF
ok "Edeka.lager/eslint.config.js"

# ── 3  npm-Skript ────────────────────────────────────────────────────
node - "$BE" <<'NODE_PKG'
const fs = require('fs');
const p  = process.argv[2] + '/package.json';
const pkg = JSON.parse(fs.readFileSync(p, 'utf8'));
pkg.scripts = pkg.scripts || {};
// Muss aus Edeka.lager/ heraus laufen, sonst liegen die Dateien außerhalb
// des Konfigurationsverzeichnisses und ESLint prüft lautlos nichts.
const soll = 'cd .. && ./backend/node_modules/.bin/eslint .';
if (pkg.scripts.lint === soll) {
  console.log('  \x1b[90m·\x1b[0m npm-Skript "lint" schon vorhanden');
} else {
  pkg.scripts.lint = soll;
  fs.writeFileSync(p, JSON.stringify(pkg, null, 2) + '\n');
  console.log('  \x1b[32m✓\x1b[0m npm-Skript "lint" eingetragen');
}
NODE_PKG

# ── Selbstprüfung: prüft die Prüfung überhaupt etwas? ────────────────
echo
echo "── Selbstprüfung ───────────────────────────────────────────────"
node --check "$EL/eslint.config.js" >/dev/null 2>&1 || die "Syntaxfehler in eslint.config.js"
ok "eslint.config.js ist syntaktisch gültig"

# Eine absichtlich kaputte Datei einschleusen und prüfen, dass sie auffällt.
# Ohne diese Probe wäre ein "0 Probleme" nicht von "nichts geprüft" zu
# unterscheiden — genau der Fall, der bei der falschen Platzierung eintritt.
PROBE="$BE/.eslint-probe.js"
cat > "$PROBE" <<'EOF'
const unbenutzteVariable = 1;
function probe() { return gibtEsNicht; }
module.exports = probe;
EOF
if ( cd "$BE" && npm run lint ) >/dev/null 2>&1; then
  rm -f "$PROBE"
  die "Die Probe wurde NICHT gefunden — ESLint prüft die falschen Dateien. Nichts erzwingen."
fi
TREFFER=$( ( cd "$BE" && npm run lint 2>&1 ) | grep -c "gibtEsNicht" || true )
rm -f "$PROBE"
[ "$TREFFER" -ge 1 ] || die "Die Probe wurde nicht wie erwartet gemeldet."
ok "Probe bestanden: eine eingeschleuste Fehlzeile wird erkannt"

# ── Der eigentliche Lauf ─────────────────────────────────────────────
echo
echo "── Befund im vorhandenen Code ──────────────────────────────────"
echo
( cd "$BE" && npm run lint ) 2>&1 | grep -v "^> " || true

echo
echo "── Danach ──────────────────────────────────────────────────────"
echo
echo "  Was oben steht, ist der Befund — kein Fehlschlag des Skripts."
echo "  Erwartet werden mindestens die beiden ungenutzten require-Zeilen,"
echo "  die der app.js/server.js-Split aus Batch B hinterlassen hat."
echo
echo "  Die CI-Stufe ist bewusst noch NICHT eingetragen. Reihenfolge:"
echo "    1. Befund ansehen        <- jetzt"
echo "    2. aufräumen (Teil von E4)"
echo "    3. erst dann in der CI erzwingen"
echo
echo "  Eine Lücke bleibt und sollte benannt sein: die Inline-Skripte in"
echo "  den fünf HTML-Dateien werden nicht geprüft. ESLint liest kein HTML"
echo "  ohne zusätzliches Plugin. Das ist weiterhin die größte ungeprüfte"
echo "  Fläche des Projekts."
echo
echo "    git add -A && git commit -m 'ESLint eingerichtet'"
echo
echo "  Rückgängig:  git checkout . && git clean -fd"
echo
