#!/usr/bin/env bash
#
# apply-batch-a.sh — Batch A ("Safety first") für Eder / Edeka.lager
#
# Behebt die Fehler, die Batch B bewiesen hat:
#   A1  Mongo-Operatoren in Request-Daten werden abgewiesen (reset-logs u. a.)
#   A2  Datumsformat bei reset-logs wird geprüft
#   A3  Bestandswerte: [] und ["5"] werden nicht mehr still zu Zahlen
#   A4  POST /products validiert wie PATCH /stock (eine gemeinsame Regel)
#   A5  safeIp normalisiert ::ffff:1.2.3.4 zu 1.2.3.4
#   A6  emoji läuft durch escapeMarkdown
#   A7  JWT_SECRET-Guard beim Start (fail-fast)
#
# Ausführen im Wurzelverzeichnis des Repos:
#     bash apply-batch-a.sh
#
# Arbeitsweise: erst PLANEN, dann SCHREIBEN. Wird auch nur ein Ankerpunkt in
# deinen Dateien nicht gefunden, bricht das Skript ab und ändert NICHTS —
# und druckt die betroffene Stelle, damit du sie mir schicken kannst.
#
set -euo pipefail

BE="Edeka.lager/backend"
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
skip() { printf '  \033[90m·\033[0m %s\n' "$1"; }
die()  { printf '\n  \033[31m✗ %s\033[0m\n\n' "$1" >&2; exit 1; }

echo
echo "── Batch A: Sicherheits- und Validierungsfixes ─────────────────"
echo

[ -d "$BE" ]            || die "Ordner '$BE' nicht gefunden. Bitte im Wurzelverzeichnis des Repos ausführen."
[ -f "$BE/app.js" ]     || die "'$BE/app.js' fehlt. Bitte zuerst apply-batch-b.sh ausführen."
[ -d "$BE/test/unit" ]  || die "'$BE/test' fehlt. Bitte zuerst apply-batch-b.sh ausführen."

if command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
  BRANCH=$(git rev-parse --abbrev-ref HEAD)
  [ "$BRANCH" != "main" ] && [ "$BRANCH" != "master" ] \
    || die "Du bist auf '$BRANCH'. Bitte:  git checkout -b batch-a-fixes"
  [ -z "$(git status --porcelain)" ] \
    || die "Arbeitsverzeichnis nicht sauber. Bitte erst committen oder stashen."
  ok "Branch '$BRANCH', Arbeitsverzeichnis sauber"
fi

echo
echo "── Neue Module (rein additiv) ──────────────────────────────────"

mkdir -p "$BE/lib"

cat > "$BE/lib/validate.js" <<'EOF'
'use strict';
//
// Reine Prüffunktionen ohne Seiteneffekte. Bewusst frei von Express und
// Mongoose, damit sie ohne Datenbank und ohne Server testbar sind.
//

/**
 * Datum im Format JJJJ-MM-TT. Gibt den geprüften String zurück, sonst null.
 *
 * Lehnt alles ab, was kein echter String ist — insbesondere Objekte wie
 * { $ne: null }. Genau dieser Wert hat in Batch B die gesamte Historie
 * gelöscht, weil er ungeprüft in einen Mongo-Filter gewandert ist.
 */
function parseIsoDate(value) {
  if (typeof value !== 'string') return null;
  const s = value.trim();
  if (!/^\d{4}-\d{2}-\d{2}$/.test(s)) return null;
  const [y, m, d] = s.split('-').map(Number);
  const probe = new Date(Date.UTC(y, m - 1, d));
  if (probe.getUTCFullYear() !== y || probe.getUTCMonth() !== m - 1 || probe.getUTCDate() !== d) {
    return null; // z. B. 2026-02-30
  }
  return s;
}

/**
 * Bestandswert. Gibt die Zahl zurück, sonst null.
 *
 * Wichtig ist die Typprüfung VOR Number(): Number([]) ist 0 und Number(["5"])
 * ist 5. Ohne diese Prüfung setzt ein leeres Array den Bestand still auf 0 —
 * so war es vor Batch A, und genau das hat der Test aufgedeckt.
 */
function parseStock(value) {
  if (typeof value === 'number') {
    return Number.isFinite(value) && value >= 0 ? value : null;
  }
  if (typeof value === 'string') {
    const s = value.trim();
    if (!/^\d+([.,]\d+)?$/.test(s)) return null;
    const n = Number(s.replace(',', '.'));
    return Number.isFinite(n) && n >= 0 ? n : null;
  }
  return null;
}

/**
 * Client-IP normalisieren und prüfen.
 *
 * Node liefert IPv4-Clients auf einem Dual-Stack-Socket als "::ffff:1.2.3.4".
 * Diese Form wird auf die reine IPv4 zurückgeführt, damit der Login-Verlauf
 * einheitlich bleibt und alte wie neue Einträge gleich aussehen.
 */
function normalizeIp(raw) {
  let ip = String(raw ?? '').trim();
  if (ip === '' || ip.length > 45) return '';

  const mapped = ip.match(/^::ffff:((?:\d{1,3}\.){3}\d{1,3})$/i);
  if (mapped) ip = mapped[1];

  if (/^(\d{1,3}\.){3}\d{1,3}$/.test(ip) && ip.split('.').every(o => Number(o) <= 255)) return ip;
  if (/^[0-9a-fA-F:]+$/.test(ip) && ip.includes(':')) return ip;
  return '';
}

// Werte, die als Platzhalter kursieren und niemals ein echter Schlüssel sind.
const BEISPIEL_SCHLUESSEL = [
  'ein-sehr-langer-zufaelliger-string-hier-einfuegen',
  'dein-geheimer-schluessel',
  'your-secret-key',
  'changeme', 'change-me', 'secret', 'geheim', 'test'
];

/**
 * Prüft JWT_SECRET beim Start. Gibt einen Fehlertext zurück oder null.
 * Ohne tragfähigen Schlüssel ist ein Abbruch besser als ein laufender
 * Server, dessen Tokens jeder fälschen kann.
 */
function checkJwtSecret(secret) {
  if (typeof secret !== 'string' || secret.trim() === '') {
    return 'JWT_SECRET ist nicht gesetzt.';
  }
  const s = secret.trim();
  if (BEISPIEL_SCHLUESSEL.includes(s.toLowerCase())) {
    return 'JWT_SECRET ist noch ein Beispielwert.';
  }
  if (s.length < 32) {
    return `JWT_SECRET ist zu kurz (${s.length} Zeichen, mindestens 32).`;
  }
  return null;
}

module.exports = { parseIsoDate, parseStock, normalizeIp, checkJwtSecret };
EOF
ok "lib/validate.js"

cat > "$BE/lib/sanitize.js" <<'EOF'
'use strict';
//
// Weist Request-Daten ab, die Mongo-Operatoren enthalten.
//
// Absichtlich ABWEISEND statt bereinigend: Ein stillschweigend entfernter
// Operator sieht für den Aufrufer aus wie ein Erfolg. Ein 400 ist laut und
// taucht in den Logs auf.
//
// Diese Middleware ersetzt keine Validierung pro Route — sie ist die
// Grundsicherung darunter und gilt auch für Routen, die es noch nicht gibt.

const MAX_TIEFE = 8;

function findeOperatorSchluessel(wert, tiefe = 0) {
  if (tiefe > MAX_TIEFE) return '(zu tief verschachtelt)';

  if (Array.isArray(wert)) {
    for (const eintrag of wert) {
      const treffer = findeOperatorSchluessel(eintrag, tiefe + 1);
      if (treffer) return treffer;
    }
    return null;
  }

  if (wert && typeof wert === 'object' && !(wert instanceof Date)) {
    for (const schluessel of Object.keys(wert)) {
      if (schluessel.startsWith('$') || schluessel.includes('.')) return schluessel;
      const treffer = findeOperatorSchluessel(wert[schluessel], tiefe + 1);
      if (treffer) return treffer;
    }
  }

  return null;
}

function rejectMongoOperators(req, res, next) {
  for (const quelle of [req.body, req.query, req.params]) {
    if (!quelle) continue;
    const treffer = findeOperatorSchluessel(quelle);
    if (treffer) {
      return res.status(400).json({ message: `Ungültiges Feld im Request: "${treffer}"` });
    }
  }
  next();
}

module.exports = { rejectMongoOperators, findeOperatorSchluessel };
EOF
ok "lib/sanitize.js"

echo
echo "── Planen und anwenden (alles oder nichts) ─────────────────────"

node - "$BE" <<'NODE_PATCH'
const fs = require('fs');
const path = require('path');
const BE = process.argv[2];

const P = (...p) => path.join(BE, ...p);
const lies = f => fs.readFileSync(f, 'utf8');

const plan = [];   // { datei, name, neu }
const fehler = []; // { name, datei, hinweis, ausschnitt }

function umgebung(text, muster, zeilen = 6) {
  const lines = text.split('\n');
  const idx = lines.findIndex(l => muster.test(l));
  if (idx === -1) return '(keine ähnliche Zeile gefunden)';
  return lines.slice(Math.max(0, idx - 2), idx + zeilen)
              .map((l, i) => `      ${idx - 1 + i}| ${l}`).join('\n');
}

function patch({ name, datei, schonDa, suche, ersetze, hinweis, naehe }) {
  const f = P(...datei.split('/'));
  if (!fs.existsSync(f)) { fehler.push({ name, datei, hinweis: 'Datei nicht gefunden', ausschnitt: '' }); return; }
  const text = lies(f);
  if (schonDa && schonDa.test(text)) { plan.push({ datei, name, neu: null }); return; }
  const neu = text.replace(suche, ersetze);
  if (neu === text) {
    fehler.push({ name, datei, hinweis, ausschnitt: naehe ? umgebung(text, naehe) : '' });
    return;
  }
  plan.push({ datei, name, neu });
}

// ── A7: JWT_SECRET-Guard in server.js (von Batch B erzeugt, Anker bekannt) ──
patch({
  name: 'A7  JWT_SECRET-Guard beim Start',
  datei: 'server.js',
  schonDa: /checkJwtSecret/,
  suche: /(const \{ scheduleDailyClose \} = require\('\.\/services\/dailyClose'\);\n)/,
  ersetze: `$1
// ── Fail-fast: ohne tragfähigen JWT_SECRET nicht starten ──────────
// Ohne Schlüssel startete der Server bisher normal und brach erst beim
// ersten Login mit einem 500er ab. Mit einem schwachen oder öffentlich
// bekannten Schlüssel liefe er sogar dauerhaft weiter — dann kann jeder
// ein Admin-Token fälschen. Beides ist schlimmer als ein Startabbruch.
const { checkJwtSecret } = require('./lib/validate');
const jwtProblem = checkJwtSecret(process.env.JWT_SECRET);
if (jwtProblem) {
  console.error('❌ Start abgebrochen: ' + jwtProblem);
  console.error('   Neuen Schlüssel erzeugen und in .env eintragen:');
  console.error('   node -e "console.log(\\'JWT_SECRET=\\' + require(\\'crypto\\').randomBytes(48).toString(\\'base64url\\'))" >> .env');
  process.exit(1);
}
`,
  hinweis: 'Der require-Block aus Batch B wurde nicht gefunden.',
  naehe: /scheduleDailyClose/
});

// ── A1: Operator-Sperre in app.js vor den API-Routen ──────────────
patch({
  name: 'A1  Mongo-Operator-Sperre (app.js)',
  datei: 'app.js',
  schonDa: /rejectMongoOperators/,
  suche: /(\n\s*app\.use\('\/api\/)/,
  ersetze: `

// ── Grundsicherung gegen Mongo-Operatoren ─────────────────────────
// Muss nach express.json() und vor den API-Routen stehen.
app.use(require('./lib/sanitize').rejectMongoOperators);
$1`,
  hinweis: "Keine Zeile app.use('/api/...') gefunden.",
  naehe: /app\.use\(/
});

// ── A5: safeIp -> normalizeIp ─────────────────────────────────────
(() => {
  const f = P('routes', 'auth.js');
  const text = lies(f);
  if (/lib\/validate/.test(text)) { plan.push({ datei: 'routes/auth.js', name: 'A5  safeIp normalisiert IPv4-mapped', neu: null }); return; }
  const lines = text.split('\n');
  const start = lines.findIndex(l => /^\s*function\s+safeIp\s*\(/.test(l));
  if (start === -1) {
    fehler.push({ name: 'A5  safeIp normalisiert IPv4-mapped', datei: 'routes/auth.js',
                  hinweis: 'function safeIp( nicht gefunden', ausschnitt: umgebung(text, /safeIp/) });
    return;
  }
  const einzug = (lines[start].match(/^\s*/) || [''])[0];
  const ende = lines.findIndex((l, i) => i > start && l === einzug + '}');
  if (ende === -1) {
    fehler.push({ name: 'A5  safeIp normalisiert IPv4-mapped', datei: 'routes/auth.js',
                  hinweis: 'Ende der Funktion safeIp nicht erkennbar', ausschnitt: umgebung(text, /function\s+safeIp/, 14) });
    return;
  }
  const ersatz = [
    einzug + '// Prüfung und Normalisierung liegen in lib/validate.js und sind dort',
    einzug + '// ohne Server unit-getestet. require() ist gecacht — kein Mehraufwand.',
    einzug + 'function safeIp(raw) {',
    einzug + "  return require('../lib/validate').normalizeIp(raw);",
    einzug + '}'
  ];
  plan.push({ datei: 'routes/auth.js', name: 'A5  safeIp normalisiert IPv4-mapped',
              neu: [...lines.slice(0, start), ...ersatz, ...lines.slice(ende + 1)].join('\n') });
})();

// ── A6: emoji durch escapeMarkdown ────────────────────────────────
patch({
  name: 'A6  emoji wird maskiert (telegram.js)',
  datei: 'services/telegram.js',
  schonDa: /escapeMarkdown\(\s*p\.emoji/,
  suche: /\$\{\s*p\.emoji\s*\|\|\s*(['"])📦\1\s*\}/g,
  ersetze: "${escapeMarkdown(p.emoji || '📦')}",
  hinweis: 'Die Stelle ${p.emoji || \'📦\'} wurde nicht gefunden.',
  naehe: /p\.emoji/
});

// ── A2: Datumsprüfung in reset-logs ───────────────────────────────
patch({
  name: 'A2  Datumsformat bei reset-logs',
  datei: 'routes/reports.js',
  schonDa: /parseIsoDate/,
  suche: /filter\s*=\s*\{\s*date:\s*req\.body\?\.date\s*\|\|\s*req\.query\?\.date\s*\|\|\s*todayStr\s*\}\s*;?/,
  ersetze: `{
      // Ungeprüft wanderte dieser Wert direkt in den Mongo-Filter. Mit
      // { $ne: null } wurde aus "lösche heute" ein "lösche alles" — die
      // Antwort meldete weiterhin scope: "daily".
      const rohDatum = req.body?.date ?? req.query?.date ?? todayStr;
      const gutesDatum = require('../lib/validate').parseIsoDate(rohDatum);
      if (!gutesDatum) {
        return res.status(400).json({ message: 'Ungültiges Datum. Erwartet wird JJJJ-MM-TT.' });
      }
      filter = { date: gutesDatum };
    }`,
  hinweis: 'Die Zeile mit filter = { date: req.body?.date || ... } wurde nicht gefunden.',
  naehe: /filter\s*=/
});

// ── A3/A4: Bestandsprüfung an jeder Stelle, die currentStock aus req.body holt ──
(() => {
  const f = P('routes', 'products.js');
  const text = lies(f);
  if (/parseStock/.test(text)) {
    plan.push({ datei: 'routes/products.js', name: 'A3/A4  Bestandsvalidierung', neu: null });
    return;
  }
  const muster = /const\s*\{[\s\S]{0,300}?currentStock[\s\S]{0,300}?\}\s*=\s*req\.body\s*;/g;
  const treffer = text.match(muster);
  if (!treffer) {
    fehler.push({ name: 'A3/A4  Bestandsvalidierung', datei: 'routes/products.js',
                  hinweis: 'Kein "const { ... currentStock ... } = req.body;" gefunden',
                  ausschnitt: umgebung(text, /currentStock/, 8) });
    return;
  }
  // Reine Einfügung — die bestehende Logik bleibt unverändert und sieht
  // ab jetzt nur noch geprüfte Werte.
  const neu = text.replace(muster, m => m + `
    {
      // Typprüfung VOR Number(): Number([]) ist 0, Number(["5"]) ist 5.
      // Ohne diese Zeile setzt ein leeres Array den Bestand still auf null.
      const geprueft = require('../lib/validate').parseStock(currentStock ?? 0);
      if (geprueft === null) {
        return res.status(400).json({ message: 'Ungültiger Bestandswert. Erwartet wird eine Zahl ab 0.' });
      }
    }`);
  plan.push({ datei: 'routes/products.js', name: `A3/A4  Bestandsvalidierung (${treffer.length} Stelle(n))`, neu });
})();

// ── Tests anpassen (von Batch B erzeugt, Wortlaut bekannt) ────────
patch({
  name: 'Test  safeIp erwartet jetzt Normalisierung',
  datei: 'test/unit/safe-ip.test.js',
  schonDa: /normalisiert/,
  suche: /\/\/ ── ROT[\s\S]*$/,
  ersetze: `// Node liefert IPv4-Clients auf einem Dual-Stack-Socket in dieser Form.
// Bewusste Entscheidung: auf reine IPv4 zurückführen, damit der
// Login-Verlauf einheitlich bleibt.
test('IPv4-mapped IPv6 wird zu reiner IPv4 normalisiert', () => {
  assert.equal(safeIp('::ffff:127.0.0.1'), '127.0.0.1');
  assert.equal(safeIp('::ffff:192.168.1.10'), '192.168.1.10');
});

test('echte IPv6 bleibt unverändert', () => {
  assert.equal(safeIp('2001:db8::1'), '2001:db8::1');
});

test('ungültige IPv4 hinter ::ffff: wird verworfen', () => {
  assert.equal(safeIp('::ffff:999.1.1.1'), '');
});
`,
  hinweis: 'Der ROT-Block in safe-ip.test.js wurde nicht gefunden.',
  naehe: /ROT/
});

patch({
  name: 'Test  /export: erst Kontrolle, dann Format',
  datei: 'test/integration/injection.test.js',
  schonDa: /Kontrolle: \/export/,
  suche: /test\('Operator im Query-String von \/export wird mit 400 abgewiesen'[\s\S]*?\n\}\);\n/,
  ersetze: `test('Kontrolle: /export mit gültigem Datum findet die Route', async () => {
  const token = await makeAdminToken();
  await seedLogs();
  const r = await req('/api/reports/export?type=excel&date=2026-05-02', { token });
  assert.notEqual(r.status, 404, \`Route nicht gefunden — die geprüfte URL stimmt nicht (Status \${r.status})\`);
});

test('unbrauchbares Datum bei /export wird mit 400 abgewiesen', async () => {
  const token = await makeAdminToken();
  await seedLogs();
  const r = await req('/api/reports/export?type=excel&date=kein-datum', { token });
  assert.equal(r.status, 400);
});
`,
  hinweis: 'Der /export-Test aus Batch B wurde nicht gefunden.',
  naehe: /export/
});

patch({
  name: 'Test  Login-Operator: 401 wird zu 400',
  datei: 'test/integration/auth.test.js',
  schonDa: /ohne Token ausgeliefert/,
  suche: /\/\/ ── ROT: NoSQL-Operator[\s\S]*$/,
  ersetze: `// Vorher fing Mongoose den Operator durch seine Typprüfung ab und die
// Route antwortete mit 401. Seit der Operator-Sperre wird die Anfrage
// schon davor mit 400 abgewiesen — in beiden Fällen ohne Token, aber der
// frühere Abbruch ist der ehrlichere.
test('Operator-Objekt als Benutzername wird abgewiesen, ohne Token ausgeliefert', async () => {
  await makeUser({ username: 'anna' });
  const r = await req('/api/auth/login', {
    method: 'POST',
    body: { username: { $ne: null }, password: 'egal' }
  });
  assert.equal(r.status, 400);
  assert.equal(r.body && r.body.token, undefined);
});
`,
  hinweis: 'Der ROT-Block in auth.test.js wurde nicht gefunden.',
  naehe: /ROT/
});

// ── Bericht ───────────────────────────────────────────────────────
if (fehler.length) {
  console.log('\n  \x1b[31mAnker nicht gefunden — es wurde NICHTS geändert:\x1b[0m\n');
  for (const f of fehler) {
    console.log(`  \x1b[31m✗\x1b[0m ${f.name}  (${f.datei})`);
    console.log(`     ${f.hinweis}`);
    if (f.ausschnitt) console.log('     Umgebung in deiner Datei:\n' + f.ausschnitt);
    console.log('');
  }
  console.log('  Schick mir die obigen Ausschnitte, dann passe ich die Anker an.\n');
  process.exit(1);
}

for (const p of plan) {
  if (p.neu === null) { console.log(`  \x1b[90m·\x1b[0m ${p.name} — schon angewendet`); continue; }
  const f = P(...p.datei.split('/'));
  if (!fs.existsSync(f + '.bak')) fs.writeFileSync(f + '.bak', lies(f));
  fs.writeFileSync(f, p.neu);
  console.log(`  \x1b[32m✓\x1b[0m ${p.name}`);
}
NODE_PATCH

echo
echo "── Neue Tests für die neuen Module ─────────────────────────────"

cat > "$BE/test/unit/validate.test.js" <<'EOF'
'use strict';
const test   = require('node:test');
const assert = require('node:assert/strict');
const { parseIsoDate, parseStock, normalizeIp, checkJwtSecret } = require('../../lib/validate');

test('parseIsoDate nimmt gültige Datumsangaben an', () => {
  assert.equal(parseIsoDate('2026-05-02'), '2026-05-02');
  assert.equal(parseIsoDate('  2026-12-31  '), '2026-12-31');
});

test('parseIsoDate lehnt Mongo-Operatoren ab', () => {
  assert.equal(parseIsoDate({ $ne: null }), null);
  assert.equal(parseIsoDate({ $gt: '' }),   null);
  assert.equal(parseIsoDate(['2026-05-02']), null);
});

test('parseIsoDate lehnt falsche Formate und unmögliche Tage ab', () => {
  assert.equal(parseIsoDate('02.05.2026'), null);
  assert.equal(parseIsoDate('2026-5-2'),   null);
  assert.equal(parseIsoDate('2026-02-30'), null);
  assert.equal(parseIsoDate('2026-13-01'), null);
  assert.equal(parseIsoDate(''),   null);
  assert.equal(parseIsoDate(null), null);
});

test('parseStock nimmt Zahlen und numerische Strings an', () => {
  assert.equal(parseStock(0),     0);
  assert.equal(parseStock(12),    12);
  assert.equal(parseStock('7'),   7);
  assert.equal(parseStock('2.5'), 2.5);
  assert.equal(parseStock('2,5'), 2.5);
});

test('parseStock lehnt genau die Werte ab, die vorher durchgerutscht sind', () => {
  assert.equal(parseStock([]),      null, 'Number([]) ist 0 — das war die Lücke');
  assert.equal(parseStock(['5']),   null, 'Number(["5"]) ist 5');
  assert.equal(parseStock({}),      null);
  assert.equal(parseStock(null),    null);
  assert.equal(parseStock(true),    null);
  assert.equal(parseStock('abc'),   null);
  assert.equal(parseStock(''),      null);
  assert.equal(parseStock(-1),      null);
  assert.equal(parseStock(Infinity),null);
  assert.equal(parseStock(NaN),     null);
});

test('normalizeIp führt IPv4-mapped auf reine IPv4 zurück', () => {
  assert.equal(normalizeIp('::ffff:127.0.0.1'),    '127.0.0.1');
  assert.equal(normalizeIp('::FFFF:192.168.1.10'), '192.168.1.10');
});

test('normalizeIp lässt gültige Adressen unverändert', () => {
  assert.equal(normalizeIp('192.168.1.10'), '192.168.1.10');
  assert.equal(normalizeIp('2001:db8::1'),  '2001:db8::1');
});

test('normalizeIp verwirft Unbrauchbares', () => {
  assert.equal(normalizeIp('999.1.1.1'),       '');
  assert.equal(normalizeIp('::ffff:999.1.1.1'),'');
  assert.equal(normalizeIp('<script>'),        '');
  assert.equal(normalizeIp(undefined),         '');
  assert.equal(normalizeIp('a:'.repeat(40)),   '');
});

test('checkJwtSecret bemängelt fehlende, kurze und Beispiel-Schlüssel', () => {
  assert.ok(checkJwtSecret(undefined));
  assert.ok(checkJwtSecret(''));
  assert.ok(checkJwtSecret('kurz'));
  assert.ok(checkJwtSecret('ein-sehr-langer-zufaelliger-string-hier-einfuegen'));
});

test('checkJwtSecret akzeptiert einen echten Schlüssel', () => {
  const echt = require('crypto').randomBytes(48).toString('base64url');
  assert.equal(checkJwtSecret(echt), null);
});
EOF

cat > "$BE/test/unit/sanitize.test.js" <<'EOF'
'use strict';
const test   = require('node:test');
const assert = require('node:assert/strict');
const { findeOperatorSchluessel } = require('../../lib/sanitize');

test('harmlose Daten werden durchgelassen', () => {
  assert.equal(findeOperatorSchluessel({ name: 'Apfel', stock: 3 }), null);
  assert.equal(findeOperatorSchluessel({ liste: [{ a: 1 }, { b: 2 }] }), null);
  assert.equal(findeOperatorSchluessel({}), null);
  assert.equal(findeOperatorSchluessel({ datum: new Date() }), null);
});

test('Preise und Namen mit Punkt im WERT bleiben erlaubt', () => {
  assert.equal(findeOperatorSchluessel({ name: 'H.-Milch 3.5%' }), null);
});

test('Operator auf oberster Ebene wird gefunden', () => {
  assert.equal(findeOperatorSchluessel({ date: { $ne: null } }), '$ne');
});

test('Operator tief im Objekt wird gefunden', () => {
  assert.equal(findeOperatorSchluessel({ a: { b: { c: { $gt: '' } } } }), '$gt');
});

test('Operator in einem Array wird gefunden', () => {
  assert.equal(findeOperatorSchluessel({ liste: [{ ok: 1 }, { $where: 'x' }] }), '$where');
});

test('Punkt im SCHLÜSSEL wird abgewiesen', () => {
  assert.equal(findeOperatorSchluessel({ 'user.role': 'admin' }), 'user.role');
});
EOF
ok "test/unit/validate.test.js, test/unit/sanitize.test.js"

echo
echo "── Selbstprüfung ───────────────────────────────────────────────"

for f in "$BE"/lib/*.js "$BE/app.js" "$BE/server.js" "$BE"/routes/*.js "$BE"/services/*.js "$BE"/test/unit/*.js "$BE"/test/integration/*.js; do
  node --check "$f" >/dev/null 2>&1 || die "Syntaxfehler in $f — rückgängig mit: git checkout ."
done
ok "alle geänderten Dateien sind syntaktisch gültig"

echo
echo "  Registrierte Routen in routes/reports.js (zur Kontrolle der /export-URL):"
grep -nE "router\.(get|post|put|patch|delete)\(" "$BE/routes/reports.js" | sed 's/^/    /' || true

echo
echo "── Unit-Tests ──────────────────────────────────────────────────"
echo
( cd "$BE" && npm run test:unit ) || true

echo
echo "── Weiter ──────────────────────────────────────────────────────"
echo
echo "  \033[33mWICHTIG:\033[0m Dein .env hat keinen JWT_SECRET. Der Server startet"
echo "  ab jetzt absichtlich nicht mehr ohne einen. Erzeugen mit:"
echo
echo "    cd $BE"
echo "    node -e \"console.log('JWT_SECRET=' + require('crypto').randomBytes(48).toString('base64url'))\" >> .env"
echo
echo "  Danach:"
echo "    npm run test:integration"
echo "    npm start"
echo
echo "  Rückgängig:  git checkout . && git clean -fd"
echo
