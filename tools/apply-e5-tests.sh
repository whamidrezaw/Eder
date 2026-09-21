#!/usr/bin/env bash
#
# apply-e5-tests.sh — Phase E5, Schritt 1: nur Tests
#
#   · Ein Request ohne JSON-Körper führt heute zu 500 statt 400 — auch am
#     Login, der ohne Anmeldung erreichbar ist.
#   · urlencoded-Körper werden vor jeder Anmeldung von qs verarbeitet.
#     body-parser 2 benutzt qs auch bei extended:false; nur das Entfernen
#     nimmt qs aus dem Weg.
#   · Das Login-Formular hat kein method. Scheitert JavaScript, schickt der
#     Browser es per GET ab — mit dem Passwort in der URL.
#
# Ausführen im Wurzelverzeichnis des Repos:
#     bash apply-e5-tests.sh
#
set -euo pipefail

BE="Edeka.lager/backend"
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
skip() { printf '  \033[90m·\033[0m %s\n' "$1"; }
die()  { printf '\n  \033[31m✗ %s\033[0m\n\n' "$1" >&2; exit 1; }

echo
echo "── Phase E5, Schritt 1: Beweise ────────────────────────────────"
echo

[ -d "$BE/test/integration" ] || die "'$BE/test' fehlt."

if command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
  BRANCH=$(git rev-parse --abbrev-ref HEAD)
  [ "$BRANCH" != "main" ] || die "Du bist auf main. Bitte auf phase-e wechseln."
  [ -z "$(git status --porcelain)" ] || die "Arbeitsverzeichnis nicht sauber. Bitte erst committen."
  ok "Branch '$BRANCH', Arbeitsverzeichnis sauber"
fi

ZIEL="$BE/test/integration/request-bodies.test.js"
[ -f "$ZIEL" ] && cp "$ZIEL" "$ZIEL.bak"

cat > "$ZIEL" <<'EOF'
'use strict';
//
// Phase E5 — Anfragekörper.
//
// In Express 5 ist req.body undefined, wenn kein Parser den Körper gelesen
// hat (in Express 4 war es {}). Routen wie /login zerlegen req.body aber
// direkt — und stürzen dann mit einem TypeError ab. Aus einem Fehler des
// Aufrufers (400) wird ein Serverfehler (500), samt Stacktrace im Log, und
// das ohne jede Anmeldung.
//
// Rote Tests sind mit "── ROT ──" markiert.
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const jwt    = require('jsonwebtoken');
const db     = require('../helpers/db');
const { start, stop } = require('../helpers/http');
const { makeUser, DEFAULT_PASSWORD } = require('../helpers/factories');

let base;
test.before(async () => { await db.connect(); base = await start(); });
test.after (async () => { await stop(); await db.disconnect(); });
test.beforeEach(async () => { await db.wipe(); });

// Rohe Anfrage mit frei wählbarem Content-Type. req() aus dem Harness
// wandelt jeden Körper in JSON um — genau das darf hier nicht passieren.
async function roh(pfad, { method = 'POST', typ, body, token } = {}) {
  const headers = {};
  if (typ)   headers['Content-Type'] = typ;
  if (token) headers.Authorization = `Bearer ${token}`;
  const res  = await fetch(base + pfad, { method, headers, body });
  const text = await res.text();
  let json = null;
  try { json = JSON.parse(text); } catch { /* kein JSON */ }
  return { status: res.status, body: json, text };
}

// ── Leitplanke: der normale Weg bleibt unberührt ──────────────────

test('ein Login mit JSON funktioniert wie bisher', async () => {
  await makeUser({ username: 'anna' });
  const r = await roh('/api/auth/login', {
    typ: 'application/json',
    body: JSON.stringify({ username: 'anna', password: DEFAULT_PASSWORD })
  });
  assert.equal(r.status, 200, r.text);
  assert.ok(r.body && r.body.token, 'kein Token');
});

// ── Befund 1: 500 statt 400 ───────────────────────────────────────

// ── ROT ──
test('ein Login mit text/plain ergibt 400, nicht 500', async () => {
  const r = await roh('/api/auth/login', { typ: 'text/plain', body: 'irgendwas' });
  assert.equal(r.status, 400,
    `${r.status}: ${r.text} — ein Fehler des Aufrufers wird als Serverfehler ` +
    `gemeldet, samt Stacktrace im Log, und das ohne Anmeldung.`);
});

// ── ROT ──
test('ein Login ganz ohne Körper ergibt 400, nicht 500', async () => {
  const r = await roh('/api/auth/login', {});
  assert.equal(r.status, 400, `${r.status}: ${r.text}`);
});

// ── ROT ──
test('auch Routen hinter der Anmeldung stürzen ohne Körper nicht ab', async () => {
  // Beweist, dass die Korrektur ALLGEMEIN greift und nicht nur am Login.
  // change-password zerlegt req.body genauso direkt.
  const u = await makeUser({ username: 'anna' });
  const token = jwt.sign({ id: u._id.toString() }, process.env.JWT_SECRET, { expiresIn: '1h' });

  const r = await roh('/api/auth/change-password', { method: 'PUT', token });
  assert.equal(r.status, 400, `${r.status}: ${r.text}`);
});

// ── Befund 2: urlencoded wird vor der Anmeldung geparst ───────────

// ── ROT ──
test('ein urlencoded-Körper wird nicht mehr ausgewertet', async () => {
  // Mit RICHTIGEN Zugangsdaten: kommt ein Token zurück, wurde der Körper
  // gelesen — eindeutiger geht der Nachweis nicht. Das Frontend schickt
  // ausschließlich JSON; dieser Weg wird von niemandem gebraucht, öffnet
  // aber qs für jede Anfrage vor der Anmeldung.
  await makeUser({ username: 'anna' });
  const r = await roh('/api/auth/login', {
    typ: 'application/x-www-form-urlencoded',
    body: `username=anna&password=${encodeURIComponent(DEFAULT_PASSWORD)}`
  });
  assert.equal(r.body && r.body.token, undefined,
    'über einen urlencoded-Körper wurde ein Token ausgegeben — qs hat ihn verarbeitet');
  assert.equal(r.status, 400, `${r.status}: ${r.text}`);
});

// ── Befund 3: das Passwort in der URL ─────────────────────────────

// ── ROT ──
test('das Login-Formular schickt per POST, nie per GET', async () => {
  // Ohne method nimmt der Browser GET. Lädt das Skript nicht oder bricht es
  // vor preventDefault() ab, landet index.html?username=…&password=… in
  // Verlauf, Serverlog und Referer. Mit method="post" steht das Passwort
  // schlimmstenfalls im Körper einer Anfrage, die ins Leere geht.
  const r = await roh('/index.html', { method: 'GET' });
  assert.equal(r.status, 200, 'index.html nicht erreichbar');

  const formTag = (r.text.match(/<form\b[^>]*\bid=["']login-form["'][^>]*>/i) || [])[0];
  assert.ok(formTag, 'kein <form id="login-form"> in index.html gefunden');
  assert.match(formTag, /\bmethod\s*=\s*["']post["']/i,
    `Formular ohne method="post": ${formTag}`);
});
EOF
ok "test/integration/request-bodies.test.js (6 Tests)"

# ── tools/README.md nachziehen ───────────────────────────────────────
if [ -f tools/README.md ] && ! grep -q 'apply-e2e3-fixes.sh' tools/README.md; then
  node -e "
    const fs = require('fs'); const p = 'tools/README.md';
    const t = fs.readFileSync(p, 'utf8');
    const anker = '| \`apply-e1-tests.sh\`, \`apply-e1-fixes.sh\` | Optimistische Sperre für Bestandsänderungen |';
    if (!t.includes(anker)) { console.log('  \x1b[90m·\x1b[0m tools/README.md: Anker fehlt, übersprungen'); process.exit(0); }
    const neu = anker + '\n| \`apply-e2e3-tests.sh\`, \`apply-e2e3-fixes.sh\` | Mengenbegrenzung je Benutzer, CORS nur auf Liste |';
    fs.writeFileSync(p, t.replace(anker, neu));
    console.log('  \x1b[32m✓\x1b[0m tools/README.md um E2/E3 ergänzt');
  "
else
  skip "tools/README.md schon aktuell"
fi

echo
echo "── Selbstprüfung ───────────────────────────────────────────────"
node --check "$ZIEL" >/dev/null 2>&1 || die "Syntaxfehler in $ZIEL"
ok "syntaktisch gültig"
( cd "$BE" && npm run lint ) >/dev/null 2>&1 && ok "Lint sauber" \
  || { ( cd "$BE" && npm run lint ) 2>&1 | grep -v '^>' ; die "Lint meldet etwas — siehe oben"; }

echo
echo "── Tests ───────────────────────────────────────────────────────"
echo
# Ungefiltert — die Meldungen zeigen, aus welchem Grund ein Test rot ist.
( cd "$BE" && node --test test/integration/request-bodies.test.js ) 2>&1 \
  | grep -vE "^\s*(at |node:internal)" || true
echo
echo "  Gesamtlauf Integration:"
( cd "$BE" && npm run test:integration ) 2>&1 | grep -E "^ℹ (tests|pass|fail)" || true

echo
echo "── Erwartung ───────────────────────────────────────────────────"
echo
echo "  6 neue Tests:  5 ROT, 1 GRÜN (JSON-Login als Leitplanke)"
echo "  Integration insgesamt 84, davon 5 rot. Die bisherigen 78 bleiben grün."
echo
echo "  Zwischen den Tests erscheinen [ERROR]-Zeilen mit"
echo "  'Cannot destructure property'. Das ist kein Defekt des Tests,"
echo "  sondern der Befund selbst: genau diese Stacktraces landen heute"
echo "  im Log, wann immer jemand einen Login ohne JSON schickt."
echo
echo "  Bitte NICHT pushen, solange Tests rot sind."
echo "  Rückgängig:  git checkout . && git clean -fd"
echo
