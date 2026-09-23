'use strict';
const fs   = require('node:fs');
const path = require('node:path');
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


// Namen, die assets/shared.js global bereitstellt. Bewusst aus der Datei
// gelesen statt als Liste gepflegt: eine Liste waere beim naechsten Umbau
// in shared.js still veraltet und wuerde entweder falsche Fehler melden
// oder echte verdecken.
function sharedGlobals() {
  const datei = path.join(__dirname, 'frontend', 'assets', 'shared.js');
  if (!fs.existsSync(datei)) return {};
  const quelle = fs.readFileSync(datei, 'utf8');
  const namen = new Set();
  for (const m of quelle.matchAll(/^window\.([A-Za-z_$][\w$]*)\s*=/gm)) namen.add(m[1]);
  for (const m of quelle.matchAll(/^(?:function|const|let|var)\s+([A-Za-z_$][\w$]*)/gm)) namen.add(m[1]);
  return Object.fromEntries([...namen].map(n => [n, 'readonly']));
}

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
    languageOptions: { ecmaVersion: 2023, sourceType: 'script', globals: { ...BROWSER_GLOBALS, ...sharedGlobals() } },
    rules: FEHLERREGELN
  }
];
