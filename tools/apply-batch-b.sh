#!/usr/bin/env bash
#
# apply-batch-b.sh — Batch B ("Proof first") für Eder / Edeka.lager
#
#   B0: server.js  ->  app.js + server.js   (rein strukturell, kein Verhalten geändert)
#       + additive Test-Exporte
#   B1: Unit-Tests  (node --test, keine DB)
#   B2: Integrationstests (echte Test-DB, _test-Guard, eingebautes fetch)
#       + GitHub-Actions-Workflow
#
# Ausführen im Wurzelverzeichnis des Repos (dort, wo der Ordner Edeka.lager liegt):
#     bash apply-batch-b.sh
#
# Das Skript ist idempotent: mehrfaches Ausführen ist gefahrlos.
# Es fasst KEINE Datenbank an und ändert KEINE Anwendungslogik.
#
set -euo pipefail

BE="Edeka.lager/backend"
say()  { printf '  %s\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
skip() { printf '  \033[90m·\033[0m %s\n' "$1"; }
die()  { printf '\n  \033[31m✗ %s\033[0m\n\n' "$1" >&2; exit 1; }

echo
echo "── Batch B: Testfundament ──────────────────────────────────────"
echo

# ── Guard 0: richtiges Verzeichnis ───────────────────────────────────
[ -d "$BE" ] || die "Ordner '$BE' nicht gefunden. Bitte im Wurzelverzeichnis des Repos ausführen."
[ -f "$BE/server.js" ] || die "'$BE/server.js' nicht gefunden."
[ -f "$BE/package.json" ] || die "'$BE/package.json' nicht gefunden."

# ── Guard 1: Node-Version (mock.timers mit Date braucht >= 20.11) ────
NODE_MAJOR=$(node -p 'process.versions.node.split(".")[0]')
NODE_MINOR=$(node -p 'process.versions.node.split(".")[1]')
if [ "$NODE_MAJOR" -lt 20 ] || { [ "$NODE_MAJOR" -eq 20 ] && [ "$NODE_MINOR" -lt 11 ]; }; then
  die "Node >= 20.11 erforderlich (gefunden: $(node --version)). mock.timers mit Date gibt es erst ab 20.11."
fi
ok "Node $(node --version)"

# ── Guard 2: sauberer Git-Stand ──────────────────────────────────────
if command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
  BRANCH=$(git rev-parse --abbrev-ref HEAD)
  if [ "$BRANCH" = "main" ] || [ "$BRANCH" = "master" ]; then
    die "Du bist auf '$BRANCH'. Bitte zuerst einen Branch anlegen:  git checkout -b batch-b-tests"
  fi
  if [ -n "$(git status --porcelain)" ]; then
    die "Arbeitsverzeichnis ist nicht sauber. Bitte erst committen oder stashen."
  fi
  ok "Branch '$BRANCH', Arbeitsverzeichnis sauber"
else
  say "(kein Git-Repo erkannt — überspringe Branch-Prüfung)"
fi

echo
echo "── B0: server.js aufteilen ─────────────────────────────────────"

# Der Split passiert MECHANISCH: das Skript liest deine echte server.js und
# schneidet sie an einem Anker durch. Es fügt KEINE nachgebaute Version ein.
# Alles vor dem Anker wandert unverändert (inkl. aller Kommentare) nach app.js.
node - "$BE" <<'NODE_SPLIT'
const fs   = require('fs');
const path = require('path');
const BE   = process.argv[2];

const serverPath = path.join(BE, 'server.js');
const appPath    = path.join(BE, 'app.js');
const src        = fs.readFileSync(serverPath, 'utf8');

if (fs.existsSync(appPath) && /require\('\.\/app'\)/.test(src)) {
  console.log('  \x1b[90m·\x1b[0m app.js existiert bereits, server.js ist bereits aufgeteilt — übersprungen');
  process.exit(0);
}
if (fs.existsSync(appPath)) {
  console.error('\n  \x1b[31m✗ app.js existiert bereits, server.js ist aber nicht aufgeteilt. Bitte manuell prüfen.\x1b[0m\n');
  process.exit(1);
}

// Anker suchen: bevorzugt die Kommentarzeile, sonst mongoose.connect(
const lines = src.split('\n');
let cut = lines.findIndex(l => /^\s*\/\/\s*─+\s*DB\s*\+\s*Server\s*Start/i.test(l));
if (cut === -1) cut = lines.findIndex(l => /^\s*mongoose\.connect\(/.test(l));
if (cut === -1) {
  console.error('\n  \x1b[31m✗ Kein Anker in server.js gefunden (weder "── DB + Server Start" noch "mongoose.connect(").');
  console.error('    Es wurde NICHTS geändert. Bitte melde dich mit dem Kopf deiner server.js.\x1b[0m\n');
  process.exit(1);
}

const head = lines.slice(0, cut).join('\n').replace(/\s*$/, '');
const tail = lines.slice(cut).join('\n');

if (!/mongoose\.connect\(/.test(tail)) {
  console.error('\n  \x1b[31m✗ Hinter dem Anker steht kein mongoose.connect(. Abbruch, nichts geändert.\x1b[0m\n');
  process.exit(1);
}
if (/app\.listen\(/.test(head)) {
  console.error('\n  \x1b[31m✗ app.listen( steht vor dem Anker. Abbruch, nichts geändert.\x1b[0m\n');
  process.exit(1);
}

fs.writeFileSync(serverPath + '.bak', src);

fs.writeFileSync(appPath, head + `

// ── Export ───────────────────────────────────────────────────────
// Diese Datei baut die Express-App nur auf. Sie verbindet sich NICHT mit
// der Datenbank, startet KEINEN Listener und plant KEINEN Cron-Job — das
// macht server.js. Dadurch kann die App im Test geladen werden, ohne dass
// dabei ein echter Server auf Port 3000 und der Mitternachts-Cron starten.
//
// Hinweis: 'mongoose' und 'scheduleDailyClose' werden hier eventuell noch
// importiert, aber nicht mehr benutzt. Das ist Absicht — der Kopf der Datei
// bleibt für diesen Schritt unangetastet (kleinstmögliche Änderung).
// Aufräumen erfolgt in Batch C.
module.exports = app;
`);

fs.writeFileSync(serverPath, `require('dotenv').config();
const mongoose = require('mongoose');
const app      = require('./app');
const { scheduleDailyClose } = require('./services/dailyClose');

${tail.replace(/^[\s\S]*?(?=mongoose\.connect\()/, '// ── DB + Server Start ─────────────────────────────────────────────\n')}
`);

console.log('  \x1b[32m✓\x1b[0m app.js erzeugt (' + head.split('\n').length + ' Zeilen, unverändert übernommen)');
console.log('  \x1b[32m✓\x1b[0m server.js auf Verbinden/Starten/Cron reduziert');
console.log('  \x1b[32m✓\x1b[0m Sicherungskopie: server.js.bak');
NODE_SPLIT

echo
echo "── B0: additive Test-Exporte ───────────────────────────────────"

add_test_export() {
  local file="$1" marker="$2" snippet="$3"
  [ -f "$file" ] || die "$file nicht gefunden"
  if grep -q "$marker" "$file"; then
    skip "$(basename "$file") — Export schon vorhanden"
  else
    printf '\n%s\n' "$snippet" >> "$file"
    ok "$(basename "$file") — $marker ergänzt"
  fi
}

add_test_export "$BE/routes/reports.js" "__test__" \
"// Nur für Tests exportiert. Der Router selbst bleibt der Default-Export,
// damit app.js unverändert \`require('./routes/reports')\` benutzen kann.
module.exports.__test__ = { pickDailyRepresentatives };"

add_test_export "$BE/routes/auth.js" "__test__" \
"// Nur für Tests exportiert — siehe routes/reports.js.
module.exports.__test__ = { safeIp };"

if grep -q "escapeMarkdown" "$BE/services/telegram.js" && grep -q "module.exports = { sendTelegram, buildTelegramText, escapeMarkdown }" "$BE/services/telegram.js"; then
  skip "telegram.js — escapeMarkdown schon exportiert"
else
  node - "$BE" <<'NODE_TG'
const fs = require('fs'); const p = process.argv[2] + '/services/telegram.js';
let s = fs.readFileSync(p, 'utf8');
const before = s;
s = s.replace(/module\.exports\s*=\s*\{\s*sendTelegram\s*,\s*buildTelegramText\s*\}\s*;?/,
              'module.exports = { sendTelegram, buildTelegramText, escapeMarkdown };');
if (s === before) { console.error('\n  \x1b[31m✗ module.exports in telegram.js nicht wie erwartet — nichts geändert.\x1b[0m\n'); process.exit(1); }
fs.writeFileSync(p, s);
console.log('  \x1b[32m✓\x1b[0m telegram.js — escapeMarkdown ergänzt');
NODE_TG
fi

echo
echo "── package.json: Test-Skripte ──────────────────────────────────"

node - "$BE" <<'NODE_PKG'
const fs = require('fs'); const p = process.argv[2] + '/package.json';
const pkg = JSON.parse(fs.readFileSync(p, 'utf8'));
// WICHTIG: 'node --test test/' funktioniert ab Node 22 NICHT (das Verzeichnis
// wird als Modul aufgelöst). Quotierte Globs sind die zuverlässige Form.
const want = {
  'test':             'node --test "test/**/*.test.js"',
  'test:unit':        'node --test "test/unit/**/*.test.js"',
  'test:integration': 'node --test "test/integration/**/*.test.js"',
  'test:watch':       'node --test --watch "test/**/*.test.js"',
  'test:coverage':    'node --test --experimental-test-coverage "test/**/*.test.js"'
};
pkg.scripts = pkg.scripts || {};
let added = 0;
for (const [k, v] of Object.entries(want)) if (pkg.scripts[k] !== v) { pkg.scripts[k] = v; added++; }
fs.writeFileSync(p, JSON.stringify(pkg, null, 2) + '\n');
console.log(added ? `  \x1b[32m✓\x1b[0m ${added} Test-Skript(e) eingetragen` : '  \x1b[90m·\x1b[0m Test-Skripte schon aktuell');
NODE_PKG

echo
echo "── Test-Gerüst ─────────────────────────────────────────────────"

mkdir -p "$BE/test/helpers" "$BE/test/unit" "$BE/test/integration" ".github/workflows"

cat > "$BE/test/helpers/env.js" <<'EOF'
'use strict';
// Muss VOR dem ersten require('../../app') laufen.
// dotenv überschreibt bereits gesetzte Variablen nicht — deshalb gewinnt das hier.
process.env.NODE_ENV           = 'test';
process.env.JWT_SECRET         = process.env.JWT_SECRET || 'test-only-secret-0123456789-nicht-in-produktion-verwenden';
process.env.JWT_EXPIRES_IN     = process.env.JWT_EXPIRES_IN || '1h';
process.env.TRUST_PROXY        = 'false';
// Leer lassen: sendTelegram() wirft dann sofort "Telegram nicht konfiguriert",
// ohne echten Netzwerkaufruf. Tests dürfen niemals in einen echten Kanal posten.
process.env.TELEGRAM_BOT_TOKEN = '';
process.env.TELEGRAM_CHAT_ID   = '';
EOF

cat > "$BE/test/helpers/db.js" <<'EOF'
'use strict';
require('./env');
const mongoose = require('mongoose');

const URI = process.env.MONGODB_TEST_URI || 'mongodb://127.0.0.1:27017/edeka_lager_test';

// ── Sicherung: niemals gegen eine echte Datenbank testen ────────────
// Die Tests leeren nach jedem Fall ALLE Collections. Deshalb läuft hier ein
// harter Guard, bevor überhaupt verbunden wird.
const dbName = URI.split('/').pop().split('?')[0];
if (!/_test$/.test(dbName)) {
  throw new Error(
    `Testdatenbank muss auf "_test" enden (gefunden: "${dbName}").\n` +
    `Setze MONGODB_TEST_URI, z. B. mongodb://127.0.0.1:27017/edeka_lager_test`
  );
}
if (process.env.NODE_ENV === 'production') {
  throw new Error('Tests dürfen nicht mit NODE_ENV=production laufen.');
}

async function connect() {
  if (mongoose.connection.readyState === 1) return;
  try {
    await mongoose.connect(URI, { serverSelectionTimeoutMS: 5000 });
  } catch (err) {
    throw new Error(
      `Keine Verbindung zur Testdatenbank (${URI}).\n` +
      `Läuft MongoDB lokal? Starte sie, oder setze MONGODB_TEST_URI.\n` +
      `Ursprünglicher Fehler: ${err.message}`
    );
  }
}

async function wipe() {
  const cols = mongoose.connection.collections;
  await Promise.all(Object.values(cols).map(c => c.deleteMany({})));
}

async function disconnect() {
  await mongoose.disconnect();
}

module.exports = { connect, wipe, disconnect, URI, dbName };
EOF

cat > "$BE/test/helpers/http.js" <<'EOF'
'use strict';
require('./env');
const { once } = require('node:events');
const app = require('../../app');

let server = null;
let base   = '';

async function start() {
  if (server) return base;
  server = app.listen(0, '127.0.0.1');
  await once(server, 'listening');
  base = `http://127.0.0.1:${server.address().port}`;
  return base;
}

async function stop() {
  if (!server) return;
  await new Promise(res => server.close(res));
  server = null;
  base   = '';
}

/**
 * Minimaler HTTP-Client auf Basis des eingebauten fetch — bewusst ohne
 * zusätzliche Abhängigkeit (kein supertest).
 * Gibt { status, body, text, headers } zurück; body ist null, wenn die
 * Antwort kein JSON ist (z. B. bei Excel/PDF-Downloads).
 */
async function req(path, { method = 'GET', token, body, raw = false } = {}) {
  const headers = {};
  if (token) headers.Authorization = `Bearer ${token}`;
  if (body !== undefined) headers['Content-Type'] = 'application/json';

  const res = await fetch(base + path, {
    method,
    headers,
    body: body !== undefined ? JSON.stringify(body) : undefined,
    redirect: 'manual'
  });

  if (raw) return { status: res.status, headers: res.headers, res };

  const text = await res.text();
  let parsed = null;
  try { parsed = JSON.parse(text); } catch { /* kein JSON — ok */ }
  return { status: res.status, body: parsed, text, headers: res.headers };
}

module.exports = { start, stop, req };
EOF

cat > "$BE/test/helpers/factories.js" <<'EOF'
'use strict';
require('./env');
const bcrypt  = require('bcryptjs');
const User    = require('../../models/User');
const Product = require('../../models/Product');
const { req } = require('./http');

const DEFAULT_PASSWORD = 'TestPasswort123';

async function makeUser({
  username,
  password = DEFAULT_PASSWORD,
  name     = 'Test Benutzer',
  role     = 'lagerist',
  isActive = true
} = {}) {
  // Kostenfaktor 4 statt 12: identische Semantik, aber ~250x schneller.
  // Tests sollen die Route prüfen, nicht bcrypt.
  const hashed = await bcrypt.hash(password, 4);
  return User.create({ username, password: hashed, name, role, isActive, telegramChatId: null });
}

async function login(username, password = DEFAULT_PASSWORD) {
  const r = await req('/api/auth/login', { method: 'POST', body: { username, password } });
  return { token: r.body && r.body.token, status: r.status, body: r.body };
}

async function makeAdminToken(username = 'admin_test') {
  await makeUser({ username, role: 'admin', name: 'Admin Test' });
  const { token } = await login(username);
  return token;
}

async function makeLageristToken(username = 'lager_test') {
  await makeUser({ username, role: 'lagerist', name: 'Lagerist Test' });
  const { token } = await login(username);
  return token;
}

async function makeProduct(over = {}) {
  return Product.create({
    name: 'Apfel', category: 'Obst', unit: 'Kiste', emoji: '🍎',
    isBio: false, currentStock: 10, yesterdayStock: 12, isActive: true, ...over
  });
}

module.exports = { makeUser, login, makeAdminToken, makeLageristToken, makeProduct, DEFAULT_PASSWORD };
EOF

ok "test/helpers/ (env, db, http, factories)"

# ── B1: Unit-Tests ───────────────────────────────────────────────────

cat > "$BE/test/unit/date-berlin.test.js" <<'EOF'
'use strict';
const test   = require('node:test');
const assert = require('node:assert/strict');
const { berlinDateString, yesterdayInBerlin } = require('../../services/dailyClose');

test('berlinDateString: gewöhnlicher Wintertag', () => {
  assert.equal(berlinDateString(new Date('2026-02-10T12:00:00Z')), '2026-02-10');
});

test('berlinDateString: später UTC-Zeitpunkt liegt in Berlin schon am Folgetag', () => {
  // 22:30 UTC im Sommer = 00:30 CEST am nächsten Tag
  assert.equal(berlinDateString(new Date('2026-07-15T22:30:00Z')), '2026-07-16');
});

test('berlinDateString: Sommerzeitumstellung (Umstellung 29.03.2026)', () => {
  assert.equal(berlinDateString(new Date('2026-03-29T00:30:00Z')), '2026-03-29'); // noch CET
  assert.equal(berlinDateString(new Date('2026-03-29T22:30:00Z')), '2026-03-30'); // schon CEST
});

test('berlinDateString: Winterzeitumstellung (Umstellung 25.10.2026)', () => {
  assert.equal(berlinDateString(new Date('2026-10-24T22:30:00Z')), '2026-10-25');
  assert.equal(berlinDateString(new Date('2026-10-25T00:30:00Z')), '2026-10-25');
});

test('yesterdayInBerlin: gewöhnlicher Tag', (t) => {
  t.mock.timers.enable({ apis: ['Date'], now: Date.parse('2026-05-12T09:00:00Z') });
  assert.equal(yesterdayInBerlin(), '2026-05-11');
});

test('yesterdayInBerlin: Jahreswechsel', (t) => {
  t.mock.timers.enable({ apis: ['Date'], now: Date.parse('2026-01-01T00:30:00Z') });
  assert.equal(yesterdayInBerlin(), '2025-12-31');
});

test('yesterdayInBerlin: Monatswechsel (1. März -> 28. Februar)', (t) => {
  t.mock.timers.enable({ apis: ['Date'], now: Date.parse('2026-03-01T10:00:00Z') });
  assert.equal(yesterdayInBerlin(), '2026-02-28');
});

test('yesterdayInBerlin: Nacht der Sommerzeitumstellung', (t) => {
  // 22:30 UTC am 29.03. = 00:30 CEST am 30.03. -> der zu schließende Tag ist der 29.
  t.mock.timers.enable({ apis: ['Date'], now: Date.parse('2026-03-29T22:30:00Z') });
  assert.equal(yesterdayInBerlin(), '2026-03-29');
});

test('yesterdayInBerlin: Nacht der Winterzeitumstellung', (t) => {
  t.mock.timers.enable({ apis: ['Date'], now: Date.parse('2026-10-24T23:30:00Z') });
  assert.equal(yesterdayInBerlin(), '2026-10-24');
});
EOF

cat > "$BE/test/unit/report-select.test.js" <<'EOF'
'use strict';
const test   = require('node:test');
const assert = require('node:assert/strict');
const { pickDailyRepresentatives } = require('../../routes/reports').__test__;

const log = (date, type, iso) => ({ date, type, sentAt: new Date(iso) });

test('leere Eingabe ergibt leere Liste', () => {
  assert.deepEqual(pickDailyRepresentatives([]), []);
});

test('auto-midnight schlägt manual — unabhängig von der Reihenfolge', () => {
  const m = log('2026-05-01', 'manual',        '2026-05-01T08:00:00Z');
  const a = log('2026-05-01', 'auto-midnight', '2026-05-01T22:00:00Z');
  assert.equal(pickDailyRepresentatives([m, a])[0].type, 'auto-midnight');
  assert.equal(pickDailyRepresentatives([a, m])[0].type, 'auto-midnight');
});

test('ohne auto-midnight gewinnt der späteste manuelle Bericht', () => {
  const early = log('2026-05-02', 'manual', '2026-05-02T09:00:00Z');
  const late  = log('2026-05-02', 'manual', '2026-05-02T17:00:00Z');
  const [rep] = pickDailyRepresentatives([early, late]);
  assert.equal(rep.sentAt.toISOString(), '2026-05-02T17:00:00.000Z');
});

test('genau ein Eintrag pro Datum', () => {
  const logs = [
    log('2026-05-01', 'manual',        '2026-05-01T08:00:00Z'),
    log('2026-05-01', 'manual',        '2026-05-01T12:00:00Z'),
    log('2026-05-01', 'auto-midnight', '2026-05-01T22:00:00Z'),
    log('2026-05-02', 'manual',        '2026-05-02T09:00:00Z')
  ];
  const reps = pickDailyRepresentatives(logs);
  assert.equal(reps.length, 2);
  assert.equal(new Set(reps.map(r => r.date)).size, 2);
});

test('Ergebnis ist absteigend nach Datum sortiert', () => {
  const logs = [
    log('2026-04-30', 'manual', '2026-04-30T10:00:00Z'),
    log('2026-05-02', 'manual', '2026-05-02T10:00:00Z'),
    log('2026-05-01', 'manual', '2026-05-01T10:00:00Z')
  ];
  assert.deepEqual(pickDailyRepresentatives(logs).map(r => r.date),
                   ['2026-05-02', '2026-05-01', '2026-04-30']);
});

test('Verbrauch wird niemals doppelt gezählt (Kernregel)', () => {
  // Drei Berichte an einem Tag, jeder zeigt den KUMULATIVEN Verbrauch seit
  // Mitternacht. Summiert man sie, kommt 24 statt 14 heraus.
  const logs = [
    { date: '2026-05-01', type: 'manual', sentAt: new Date('2026-05-01T08:00:00Z'), snapshot: [{ consumed: 3 }] },
    { date: '2026-05-01', type: 'manual', sentAt: new Date('2026-05-01T13:00:00Z'), snapshot: [{ consumed: 7 }] },
    { date: '2026-05-01', type: 'manual', sentAt: new Date('2026-05-01T19:00:00Z'), snapshot: [{ consumed: 14 }] }
  ];
  const reps = pickDailyRepresentatives(logs);
  const total = reps.reduce((s, l) => s + l.snapshot.reduce((x, p) => x + p.consumed, 0), 0);
  assert.equal(total, 14);
});
EOF

cat > "$BE/test/unit/safe-ip.test.js" <<'EOF'
'use strict';
const test   = require('node:test');
const assert = require('node:assert/strict');
const { safeIp } = require('../../routes/auth').__test__;

test('gültige IPv4 wird übernommen', () => {
  assert.equal(safeIp('192.168.1.10'), '192.168.1.10');
});

test('Oktett über 255 wird verworfen', () => {
  assert.equal(safeIp('999.1.1.1'), '');
});

test('gültige IPv6 wird übernommen', () => {
  assert.equal(safeIp('2001:db8::1'), '2001:db8::1');
});

test('gefälschter/unsinniger Wert wird verworfen', () => {
  assert.equal(safeIp('<script>alert(1)</script>'), '');
  assert.equal(safeIp('not-an-ip'), '');
});

test('leere Eingaben ergeben einen leeren String', () => {
  assert.equal(safeIp(undefined), '');
  assert.equal(safeIp(null), '');
  assert.equal(safeIp(''), '');
});

test('überlange Eingabe wird verworfen', () => {
  assert.equal(safeIp('a:'.repeat(40)), '');
});

// ── ROT: Fehler, der in Batch A behoben wird ─────────────────────────
// Node liefert IPv4-Clients auf einem Dual-Stack-Socket als "::ffff:1.2.3.4".
// safeIp() verwirft diese Form, weil sie Punkte enthält und damit an der
// IPv6-Prüfung (/^[0-9a-fA-F:]+$/) scheitert. Ergebnis: Der Login-Verlauf
// speichert für die meisten echten Logins eine leere IP.
test('IPv4-mapped IPv6 wird akzeptiert (Node liefert diese Form)', () => {
  assert.equal(safeIp('::ffff:127.0.0.1'), '::ffff:127.0.0.1');
});
EOF

cat > "$BE/test/unit/telegram-format.test.js" <<'EOF'
'use strict';
const test   = require('node:test');
const assert = require('node:assert/strict');
const { escapeMarkdown, buildTelegramText } = require('../../services/telegram');

test('Markdown-Sonderzeichen werden maskiert', () => {
  assert.equal(escapeMarkdown('Bio_Apfel'),  'Bio\\_Apfel');
  assert.equal(escapeMarkdown('*Extra*'),    '\\*Extra\\*');
  assert.equal(escapeMarkdown('A[B]C'),      'A\\[B]C');
  assert.equal(escapeMarkdown('`code`'),     '\\`code\\`');
});

test('null/undefined ergeben einen leeren String, keinen Absturz', () => {
  assert.equal(escapeMarkdown(null), '');
  assert.equal(escapeMarkdown(undefined), '');
});

const product = (over = {}) => ({
  name: 'Apfel', unit: 'kg', category: 'Obst', emoji: '🍎',
  isBio: false, currentStock: 3, yesterdayStock: 5, ...over
});

test('Produktname mit Sonderzeichen wird maskiert', () => {
  const txt = buildTelegramText([product({ name: 'Apfel_Bio' })]);
  assert.match(txt, /Apfel\\_Bio/);
});

test('Verbrauch wird angezeigt, Auffüllen ergibt keine negative Zahl', () => {
  assert.match(buildTelegramText([product({ currentStock: 3, yesterdayStock: 5 })]), /\(−2\)/);
  const refill = buildTelegramText([product({ currentStock: 9, yesterdayStock: 5 })]);
  assert.doesNotMatch(refill, /−/);
});

// ── ROT: Fehler, der in Batch A behoben wird ─────────────────────────
// Jedes Feld im Telegram-Text läuft durch escapeMarkdown() — außer `emoji`.
// Ein einzelnes "*" dort erzeugt eine ungerade Zahl an Sternchen, woraufhin
// Telegram die GESAMTE Nachricht mit einem Parse-Fehler ablehnt, nicht nur
// diese eine Zeile.
test('Emoji-Feld wird ebenfalls maskiert', () => {
  const txt = buildTelegramText([product({ emoji: '*' })]);
  const stars = (txt.match(/(?<!\\)\*/g) || []).length;
  assert.equal(stars % 2, 0, `ungerade Anzahl unmaskierter "*" (${stars}) — Telegram lehnt die Nachricht ab`);
});
EOF

cat > "$BE/test/unit/export-normalize.test.js" <<'EOF'
'use strict';
const test   = require('node:test');
const assert = require('node:assert/strict');
const { normalizeFromLiveProducts, normalizeFromSnapshot } = require('../../services/exportBuilder');

// Beide Funktionen speisen dieselben Excel-/PDF-Bauer. Weichen ihre
// Zeilenformen voneinander ab, sieht ein Live-Export anders aus als der
// Export desselben Bestands aus der Historie.
test('beide Quellen erzeugen dieselben Felder', () => {
  const live = normalizeFromLiveProducts([
    { name: 'Apfel', emoji: '🍎', category: 'Obst', unit: 'kg', isBio: true, currentStock: 4, yesterdayStock: 9 }
  ]);
  const snap = normalizeFromSnapshot([
    { productName: 'Apfel', emoji: '🍎', category: 'Obst', unit: 'kg', isBio: true, closingStock: 4, consumed: 5 }
  ]);
  assert.deepEqual(Object.keys(live[0]).sort(), Object.keys(snap[0]).sort());
  assert.deepEqual(live[0], snap[0]);
});

test('fehlende Werte bekommen Standardwerte statt undefined', () => {
  const [row] = normalizeFromLiveProducts([{ name: 'X' }]);
  assert.equal(row.emoji, '📦');
  assert.equal(row.category, 'Sonstige');
  assert.equal(row.unit, 'Kiste');
  assert.equal(row.stock, 0);
  assert.equal(row.consumed, 0);
});

test('Auffüllen ergibt Verbrauch 0, nicht negativ', () => {
  const [row] = normalizeFromLiveProducts([{ name: 'X', currentStock: 20, yesterdayStock: 5 }]);
  assert.equal(row.consumed, 0);
});
EOF

ok "test/unit/ (5 Dateien)"

# ── B2: Integrationstests ────────────────────────────────────────────

cat > "$BE/test/integration/auth.test.js" <<'EOF'
'use strict';
const test   = require('node:test');
const assert = require('node:assert/strict');
const db     = require('../helpers/db');
const { start, stop, req } = require('../helpers/http');
const { makeUser, login } = require('../helpers/factories');

test.before(async () => { await db.connect(); await start(); });
test.after (async () => { await stop(); await db.disconnect(); });
test.beforeEach(async () => { await db.wipe(); });

test('gültige Zugangsdaten liefern ein Token', async () => {
  await makeUser({ username: 'anna' });
  const r = await login('anna');
  assert.equal(r.status, 200);
  assert.ok(r.token, 'kein Token in der Antwort');
  assert.equal(r.body.user.username, 'anna');
  assert.equal(r.body.user.password, undefined, 'Passwort darf nie zurückkommen');
});

test('falsches Passwort ergibt 401', async () => {
  await makeUser({ username: 'anna' });
  const r = await login('anna', 'falsch');
  assert.equal(r.status, 401);
  assert.equal(r.body.token, undefined);
});

test('deaktivierter Benutzer kann sich nicht anmelden', async () => {
  await makeUser({ username: 'gesperrt', isActive: false });
  assert.equal((await login('gesperrt')).status, 401);
});

test('Fehlermeldung verrät nicht, ob der Benutzer existiert', async () => {
  await makeUser({ username: 'anna' });
  const a = await login('anna', 'falsch');
  const b = await login('gibtesnicht', 'falsch');
  assert.equal(a.body.message, b.body.message);
});

test('Anfrage ohne Token ergibt 401', async () => {
  assert.equal((await req('/api/products')).status, 401);
});

test('manipuliertes Token ergibt 401', async () => {
  const r = await req('/api/products', { token: 'eyJhbGciOiJIUzI1NiJ9.gefaelscht.xxx' });
  assert.equal(r.status, 401);
});

test('Token eines nachträglich deaktivierten Benutzers wird abgewiesen', async () => {
  const user = await makeUser({ username: 'anna' });
  const { token } = await login('anna');
  assert.equal((await req('/api/products', { token })).status, 200);
  user.isActive = false;
  await user.save();
  const after = await req('/api/products', { token });
  assert.equal(after.status, 403, 'Deaktivierung muss sofort wirken');
});

// ── ROT: NoSQL-Operator im Login-Feld (Batch A) ──────────────────────
test('Operator-Objekt als Benutzername ergibt 401, nicht den ersten Treffer', async () => {
  await makeUser({ username: 'anna' });
  const r = await req('/api/auth/login', {
    method: 'POST',
    body: { username: { $ne: null }, password: 'egal' }
  });
  assert.equal(r.status, 401);
  assert.equal(r.body && r.body.token, undefined);
});
EOF

cat > "$BE/test/integration/rate-limit.test.js" <<'EOF'
'use strict';
// Eigene Datei: der Limiter hat einen prozessweiten Zustand. Der node-Test-
// Runner startet pro Datei einen eigenen Prozess, dadurch beeinflusst dieser
// Test die übrigen Login-Tests nicht.
const test   = require('node:test');
const assert = require('node:assert/strict');
const db     = require('../helpers/db');
const { start, stop, req } = require('../helpers/http');
const { makeUser } = require('../helpers/factories');

test.before(async () => { await db.connect(); await db.wipe(); await start(); });
test.after (async () => { await stop(); await db.disconnect(); });

test('der 11. Fehlversuch wird mit 429 abgewiesen', async () => {
  await makeUser({ username: 'anna' });
  const codes = [];
  for (let i = 0; i < 12; i++) {
    const r = await req('/api/auth/login', { method: 'POST', body: { username: 'anna', password: 'falsch' } });
    codes.push(r.status);
  }
  assert.ok(codes.includes(429), `kein 429 in ${JSON.stringify(codes)} — greift der Limiter wirklich?`);
  assert.equal(codes.slice(0, 10).every(c => c === 401), true, 'die ersten 10 Versuche sollen 401 sein');
});
EOF

cat > "$BE/test/integration/injection.test.js" <<'EOF'
'use strict';
const test   = require('node:test');
const assert = require('node:assert/strict');
const db     = require('../helpers/db');
const DailyLog = require('../../models/DailyLog');
const { start, stop, req } = require('../helpers/http');
const { makeAdminToken } = require('../helpers/factories');

test.before(async () => { await db.connect(); await start(); });
test.after (async () => { await stop(); await db.disconnect(); });
test.beforeEach(async () => { await db.wipe(); });

async function seedLogs() {
  await DailyLog.create([
    { date: '2026-05-01', sentAt: new Date('2026-05-01T22:00:00Z'), type: 'auto-midnight', snapshot: [] },
    { date: '2026-05-02', sentAt: new Date('2026-05-02T22:00:00Z'), type: 'auto-midnight', snapshot: [] },
    { date: '2026-05-03', sentAt: new Date('2026-05-03T22:00:00Z'), type: 'auto-midnight', snapshot: [] }
  ]);
}

test('Referenz: scope=daily mit gültigem Datum löscht genau einen Tag', async () => {
  const token = await makeAdminToken();
  await seedLogs();
  const r = await req('/api/reports/reset-logs', {
    method: 'POST', token, body: { scope: 'daily', date: '2026-05-02' }
  });
  assert.equal(r.status, 200);
  assert.equal(await DailyLog.countDocuments({}), 2);
});

// ── ROT: der Kern des Befunds (Batch A) ──────────────────────────────
// { "scope": "daily", "date": { "$ne": null } } wird ungeprüft zu einem
// Mongo-Operator. Aus "lösche heute" wird "lösche alles" — und die Antwort
// meldet weiterhin scope: "daily".
test('Operator-Objekt als Datum löscht NICHT die gesamte Historie', async () => {
  const token = await makeAdminToken();
  await seedLogs();
  await req('/api/reports/reset-logs', {
    method: 'POST', token, body: { scope: 'daily', date: { $ne: null } }
  });
  const rest = await DailyLog.countDocuments({});
  assert.equal(rest, 3, `${3 - rest} Log(s) wurden durch einen manipulierten "date"-Wert gelöscht`);
});

test('ungültiges Datumsformat wird mit 400 abgewiesen', async () => {
  const token = await makeAdminToken();
  await seedLogs();
  const r = await req('/api/reports/reset-logs', {
    method: 'POST', token, body: { scope: 'daily', date: 'nicht-ein-datum' }
  });
  assert.equal(r.status, 400);
  assert.equal(await DailyLog.countDocuments({}), 3);
});

test('Operator im Query-String von /export wird mit 400 abgewiesen', async () => {
  const token = await makeAdminToken();
  await seedLogs();
  const r = await req('/api/reports/export?type=excel&date[$ne]=x', { token });
  assert.equal(r.status, 400, 'Operator-Objekte dürfen nicht in die Mongo-Abfrage gelangen');
});

test('reset-logs ist ohne Token nicht erreichbar', async () => {
  await seedLogs();
  const r = await req('/api/reports/reset-logs', { method: 'POST', body: { scope: 'all' } });
  assert.equal(r.status, 401);
  assert.equal(await DailyLog.countDocuments({}), 3);
});
EOF

cat > "$BE/test/integration/authz.test.js" <<'EOF'
'use strict';
const test   = require('node:test');
const assert = require('node:assert/strict');
const db     = require('../helpers/db');
const Category = require('../../models/Category');
const { start, stop, req } = require('../helpers/http');
const { makeAdminToken, makeLageristToken } = require('../helpers/factories');

test.before(async () => { await db.connect(); await start(); });
test.after (async () => { await stop(); await db.disconnect(); });
test.beforeEach(async () => { await db.wipe(); });

// Diese Datei hält den BEABSICHTIGTEN Rechte-Zuschnitt fest, damit ihn
// niemand später versehentlich "härtet". Lageristen dürfen Kategorien und
// Einheiten anlegen; nur Admins dürfen sie ändern oder löschen.

test('Lagerist DARF eine Kategorie anlegen (so gewollt)', async () => {
  const token = await makeLageristToken();
  const r = await req('/api/categories', { method: 'POST', token, body: { name: 'Nüsse' } });
  assert.equal(r.status, 201);
});

test('Lagerist DARF eine Einheit anlegen (so gewollt)', async () => {
  const token = await makeLageristToken();
  const r = await req('/api/units', { method: 'POST', token, body: { name: 'Palette' } });
  assert.equal(r.status, 201);
});

test('Lagerist darf eine Kategorie NICHT ändern', async () => {
  const token = await makeLageristToken();
  const cat = await Category.create({ name: 'Obst', emoji: '🍎' });
  const r = await req(`/api/categories/${cat._id}`, { method: 'PUT', token, body: { name: 'Neu' } });
  assert.equal(r.status, 403);
});

test('Lagerist darf eine Kategorie NICHT löschen', async () => {
  const token = await makeLageristToken();
  const cat = await Category.create({ name: 'Obst', emoji: '🍎' });
  const r = await req(`/api/categories/${cat._id}`, { method: 'DELETE', token });
  assert.equal(r.status, 403);
});

test('Lagerist erreicht die Benutzerverwaltung nicht', async () => {
  const token = await makeLageristToken();
  assert.equal((await req('/api/users', { token })).status, 403);
});

test('Admin erreicht die Benutzerverwaltung', async () => {
  const token = await makeAdminToken();
  assert.equal((await req('/api/users', { token })).status, 200);
});

test('Lagerist darf Bestände nicht zurücksetzen', async () => {
  const token = await makeLageristToken();
  const r = await req('/api/reports/reset-stock', { method: 'POST', token, body: {} });
  assert.equal(r.status, 403);
});
EOF

cat > "$BE/test/integration/products-validation.test.js" <<'EOF'
'use strict';
const test   = require('node:test');
const assert = require('node:assert/strict');
const db     = require('../helpers/db');
const Category = require('../../models/Category');
const Unit     = require('../../models/Unit');
const { start, stop, req } = require('../helpers/http');
const { makeLageristToken, makeProduct } = require('../helpers/factories');

test.before(async () => { await db.connect(); await start(); });
test.after (async () => { await stop(); await db.disconnect(); });
test.beforeEach(async () => {
  await db.wipe();
  await Category.create({ name: 'Obst', emoji: '🍎' });
  await Unit.create({ name: 'Kiste' });
});

const base = { name: 'Apfel', category: 'Obst', unit: 'Kiste', emoji: '🍎' };

test('PATCH /stock weist nicht-numerische Werte ab', async () => {
  const token = await makeLageristToken();
  const p = await makeProduct();
  for (const bad of ['abc', null, {}, [], 'NaN']) {
    const r = await req(`/api/products/${p._id}/stock`, { method: 'PATCH', token, body: { currentStock: bad } });
    assert.equal(r.status, 400, `Wert ${JSON.stringify(bad)} hätte abgelehnt werden müssen`);
  }
});

test('PATCH /stock weist negative Werte ab', async () => {
  const token = await makeLageristToken();
  const p = await makeProduct();
  const r = await req(`/api/products/${p._id}/stock`, { method: 'PATCH', token, body: { currentStock: -5 } });
  assert.equal(r.status, 400);
});

test('unbekannte Kategorie wird abgewiesen', async () => {
  const token = await makeLageristToken();
  const r = await req('/api/products', { method: 'POST', token, body: { ...base, category: 'Gibtesnicht' } });
  assert.equal(r.status, 400);
});

test('dieselbe Variante zweimal anzulegen schlägt fehl', async () => {
  const token = await makeLageristToken();
  assert.equal((await req('/api/products', { method: 'POST', token, body: base })).status, 201);
  assert.equal((await req('/api/products', { method: 'POST', token, body: base })).status, 400);
});

// ── ROT: uneinheitliche Validierung (Batch A) ────────────────────────
// PATCH /stock prüft sauber auf eine endliche, nicht-negative Zahl.
// POST /products macht dagegen `Number(currentStock) || 0` — "abc" wird
// stillschweigend zu 0. Zwei Endpunkte, dasselbe Feld, zwei Regeln.
test('POST /products weist ungültigen Anfangsbestand ab statt ihn zu 0 zu machen', async () => {
  const token = await makeLageristToken();
  const r = await req('/api/products', { method: 'POST', token, body: { ...base, currentStock: 'abc' } });
  assert.equal(r.status, 400, `stattdessen ${r.status} — der Wert wurde still zu ${r.body && r.body.currentStock}`);
});

test('POST /products weist negativen Anfangsbestand ab', async () => {
  const token = await makeLageristToken();
  const r = await req('/api/products', { method: 'POST', token, body: { ...base, currentStock: -3 } });
  assert.equal(r.status, 400);
});
EOF

ok "test/integration/ (5 Dateien)"

# ── Doku + CI ────────────────────────────────────────────────────────

cat > "$BE/.env.test.example" <<'EOF'
# Kopie nach .env.test ist NICHT nötig — die Tests setzen ihre Variablen selbst
# (siehe test/helpers/env.js). Nur die Datenbank-Adresse ist überschreibbar.
#
# Der Datenbankname MUSS auf _test enden, sonst brechen die Tests ab.
MONGODB_TEST_URI=mongodb://127.0.0.1:27017/edeka_lager_test
EOF

cat > "$BE/test/README.md" <<'EOF'
# Tests

## Ausführen

```bash
cd Edeka.lager/backend

npm run test:unit          # schnell, keine Datenbank nötig
npm run test:integration   # braucht eine laufende MongoDB
npm test                   # alles
npm run test:coverage      # mit Abdeckungsbericht
```

## Datenbank für die Integrationstests

Standard ist `mongodb://127.0.0.1:27017/edeka_lager_test`. Abweichend:

```bash
MONGODB_TEST_URI=mongodb://127.0.0.1:27017/mein_test npm run test:integration
```

Der Name **muss auf `_test` enden** — sonst bricht `test/helpers/db.js` ab,
bevor überhaupt verbunden wird. Die Tests leeren nach jedem Fall alle
Collections; dieser Guard verhindert, dass das je die echte Datenbank trifft.

Telegram wird in Tests nie kontaktiert: `TELEGRAM_BOT_TOKEN` ist leer gesetzt,
wodurch `sendTelegram()` sofort ohne Netzwerkaufruf abbricht.

## Warum manche Tests rot sind

Sechs Tests schlagen absichtlich fehl. Sie beschreiben Fehler, die in
**Batch A** behoben werden — sie sind der Beweis, dass die Fehler existieren,
und werden nach den Korrekturen grün. Jeder davon ist im Quelltext mit
`── ROT:` markiert.

Ein Test, der nach einer Korrektur grün wird, ist der Nachweis. Ein Test, der
von Anfang an grün ist, beweist nichts über die Korrektur.
EOF

cat > ".github/workflows/ci.yml" <<'EOF'
name: CI

on:
  push:
    branches: ['**']
  pull_request:

jobs:
  test:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: Edeka.lager/backend

    services:
      mongo:
        image: mongo:7
        ports: ['27017:27017']
        options: >-
          --health-cmd "mongosh --quiet --eval 'db.runCommand({ping:1})'"
          --health-interval 10s --health-timeout 5s --health-retries 10

    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: '22'
          cache: npm
          cache-dependency-path: Edeka.lager/backend/package-lock.json

      - run: npm ci

      - name: Unit-Tests
        run: npm run test:unit

      - name: Integrationstests
        run: npm run test:integration
        env:
          MONGODB_TEST_URI: mongodb://127.0.0.1:27017/edeka_lager_test
EOF

ok ".env.test.example, test/README.md, .github/workflows/ci.yml"

echo
echo "── Selbstprüfung ───────────────────────────────────────────────"

FAILED=0
for f in "$BE/app.js" "$BE/server.js" "$BE"/test/helpers/*.js "$BE"/test/unit/*.js "$BE"/test/integration/*.js; do
  if node --check "$f" 2>/dev/null; then :; else say "Syntaxfehler in $f"; FAILED=1; fi
done
[ "$FAILED" -eq 0 ] && ok "alle erzeugten Dateien sind syntaktisch gültig" || die "Syntaxprüfung fehlgeschlagen"

node -e "
  const app = require('./$BE/app.js');
  if (typeof app !== 'function') { console.error('app.js exportiert keine Express-App'); process.exit(1); }
" 2>/dev/null && ok "app.js lädt und exportiert die Express-App" \
              || say "app.js konnte nicht geladen werden — vermutlich fehlt 'npm install' im backend-Ordner"

echo
echo "── Fertig ──────────────────────────────────────────────────────"
echo
echo "  Nächste Schritte:"
echo
echo "    cd $BE"
echo "    npm install"
echo "    npm run test:unit          # sollte laufen, 1 Test rot (safeIp)"
echo "    npm run test:integration   # braucht MongoDB"
echo
echo "  Erwartet: 6 rote Tests. Das ist der Sollzustand — sie sind der"
echo "  Nachweis für die Fehler, die Batch A behebt."
echo
echo "  Rückgängig machen:  git checkout . && git clean -fd"
echo "  (die Sicherungskopie der alten server.js liegt unter $BE/server.js.bak)"
echo
