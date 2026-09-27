#!/usr/bin/env bash
#
# apply-d1-betrieb.sh — Phase D, Schritt 1: Betriebssicherheit im Code
#
# Fünf Befunde, alle am echten Quelltext geprüft:
#
#   1. server.js lauscht auf ALLEN Netzwerkadressen. Der Tunnel läuft auf
#      derselben Maschine; niemand soll an ihm vorbei direkt auf Port 3000.
#      → Standard jetzt 127.0.0.1, über HOST änderbar.
#
#   2. TRUST_PROXY=true bei einer App, die im Netz lauscht, heißt: jeder
#      Client darf X-Forwarded-For fälschen — IP-Grenze beim Login umgangen,
#      falsche Adressen im Log. → Diese Kombination verweigert den Start,
#      wie schon ein unsicherer JWT_SECRET.
#
#   3. Express 5 übergibt einen Fehler beim Lauschen (Port belegt) an den
#      Callback von app.listen. server.js ignorierte ihn und meldete trotzdem
#      "✅ Server läuft" — ein Prozess, der Erfolg meldet und nichts ausliefert.
#      Unter systemd wird genau das wichtig. → Fehler melden, Exit 1.
#
#   4. Der Fehler-Handler protokollierte NUR außerhalb von production. In
#      production — also im Laden — hinterließ ein 500er keine Spur.
#      → 5xx immer ins Server-Log; nach außen weiter nur die allgemeine
#      Meldung. Der Handler zieht nach lib/fehlerbehandlung.js um, damit er
#      endlich Tests bekommt; bisher prüfte keiner seine Antworten.
#
#   5. /api/health verriet NODE_ENV. → Feld entfernt.
#
# Legt den Branch phase-d an, falls du auf main bist.
#
# Ausführen im Wurzelverzeichnis des Repos:
#     bash apply-d1-betrieb.sh
#
set -euo pipefail

BE="Edeka.lager/backend"
SELBST="$(basename "$0")"
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
die()  { printf '\n  \033[31m✗ %s\033[0m\n\n' "$1" >&2; exit 1; }

echo
echo "── Phase D, Schritt 1: Betriebssicherheit im Code ──────────────"
echo

for f in server.js app.js lib/validate.js test/helpers/http.js; do
  [ -f "$BE/$f" ] || die "'$BE/$f' nicht gefunden."
done
[ -f "$BE/../../.env.example" ] || [ -f "$BE/.env.example" ] || die ".env.example nicht gefunden."
ENVBSP="$BE/.env.example"

if command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
  SCHMUTZ=$(git status --porcelain | grep -v -- "$SELBST" || true)
  [ -z "$SCHMUTZ" ] || { printf '%s\n' "$SCHMUTZ" | sed 's/^/     /'; die "Arbeitsverzeichnis nicht sauber (siehe oben)."; }
  BRANCH=$(git rev-parse --abbrev-ref HEAD)
  if [ "$BRANCH" = "main" ]; then
    if git show-ref --verify --quiet refs/heads/phase-d; then
      git checkout -q phase-d
    else
      git checkout -q -b phase-d
    fi
    BRANCH=phase-d
  fi
  ok "Branch '$BRANCH', Arbeitsverzeichnis sauber (ohne $SELBST)"
fi

# ── 1  Tests, mit Aufräumen bei Abbruch ──────────────────────────────
NEU=( "$BE/test/unit/netzwerk.test.js"
      "$BE/test/unit/fehlerbehandlung.test.js"
      "$BE/test/integration/health.test.js"
      "$BE/test/integration/server-start.test.js"
      "$BE/test/helpers/ohne-db.js" )
DA=()
for f in "${NEU[@]}"; do [ -f "$f" ] && DA+=(1) || DA+=(0); done
FERTIG=0
aufraeumen() {
  [ "$FERTIG" = "1" ] && return
  for i in "${!NEU[@]}"; do [ "${DA[$i]}" = "0" ] && rm -f "${NEU[$i]}"; done
  printf '  \033[90m·\033[0m Abbruch: angelegte Testdateien wieder entfernt\n' >&2
}
trap aufraeumen EXIT

echo
echo "── Tests schreiben ─────────────────────────────────────────────"
mkdir -p "$BE/test/unit" "$BE/test/integration" "$BE/test/helpers"

cat > "$BE/test/unit/netzwerk.test.js" <<'EOF'
'use strict';
//
// Auf welcher Adresse lauscht der Server, und wann ist TRUST_PROXY sicher?
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const { listenHost, checkProxyConfig } = require('../../lib/validate');

test('listenHost: ohne HOST nur die eigene Maschine', () => {
  assert.equal(listenHost({}), '127.0.0.1');
  assert.equal(listenHost({ HOST: '' }), '127.0.0.1');
  assert.equal(listenHost({ HOST: '   ' }), '127.0.0.1');
});

test('listenHost: ein bewusst gesetzter HOST gilt', () => {
  assert.equal(listenHost({ HOST: '0.0.0.0' }), '0.0.0.0');
  assert.equal(listenHost({ HOST: ' ::1 ' }), '::1');
});

test('checkProxyConfig: ohne TRUST_PROXY nie ein Problem', () => {
  assert.equal(checkProxyConfig({}), null);
  assert.equal(checkProxyConfig({ HOST: '0.0.0.0' }), null);
  assert.equal(checkProxyConfig({ TRUST_PROXY: 'false', HOST: '0.0.0.0' }), null);
});

test('checkProxyConfig: TRUST_PROXY hinter einem lokalen Tunnel ist in Ordnung', () => {
  assert.equal(checkProxyConfig({ TRUST_PROXY: 'true' }), null);
  assert.equal(checkProxyConfig({ TRUST_PROXY: 'TRUE', HOST: '::1' }), null);
  assert.equal(checkProxyConfig({ TRUST_PROXY: 'true', HOST: 'localhost' }), null);
});

test('checkProxyConfig: TRUST_PROXY bei einer App im Netz verweigert den Start', () => {
  for (const host of ['0.0.0.0', '::', '10.0.0.151']) {
    const problem = checkProxyConfig({ TRUST_PROXY: 'true', HOST: host });
    assert.ok(problem, `${host} wurde durchgelassen`);
    assert.match(problem, /X-Forwarded-For/);
  }
});

test('checkProxyConfig liest TRUST_PROXY genau wie app.js — kein Fehlalarm', () => {
  // app.js vergleicht ohne trim: " true" schaltet dort NICHTS ein. Meldete
  // die Prüfung hier trotzdem ein Problem, verweigerte der Server grundlos
  // den Start.
  assert.equal(checkProxyConfig({ TRUST_PROXY: ' true', HOST: '0.0.0.0' }), null);
});
EOF

cat > "$BE/test/unit/fehlerbehandlung.test.js" <<'EOF'
'use strict';
//
// Der globale Fehler-Handler — bisher inline in app.js und ohne einen
// einzigen Test, obwohl jeder 500er durch ihn läuft.
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const fehlerbehandlung = require('../../lib/fehlerbehandlung');

const REQ = { method: 'POST', path: '/api/products/66f0c0ffee' };

function antwort() {
  const r = { code: null, body: null };
  r.status = (c) => { r.code = c; return r; };
  r.json   = (b) => { r.body = b; return r; };
  return r;
}

function lauf(umgebung, fehler) {
  const altEnv = process.env.NODE_ENV;
  const altLog = console.error;
  const log = [];
  process.env.NODE_ENV = umgebung;
  console.error = (...a) => log.push(a.map(String).join(' '));
  const res = antwort();
  try { fehlerbehandlung(fehler, REQ, res, () => {}); }
  finally { process.env.NODE_ENV = altEnv; console.error = altLog; }
  return { res, log };
}

test('Express erkennt ihn als Fehler-Handler: genau vier Parameter', () => {
  // Mit drei Parametern wäre er eine gewöhnliche Middleware, und Fehler
  // liefen stumm an ihm vorbei.
  assert.equal(fehlerbehandlung.length, 4);
});

test('production, unerwarteter Fehler: im Server-Log, nach außen nur allgemein', () => {
  const { res, log } = lauf('production', new Error('Verbindung zu mongodb://intern:27017 verloren'));
  assert.equal(res.code, 500);
  assert.deepEqual(res.body, { message: 'Interner Serverfehler' }, 'Einzelheiten gingen an den Browser');
  assert.equal(log.length, 1, 'ein 500er im Laden hinterließe keine Spur');
  assert.match(log[0], /POST \/api\/products\/66f0c0ffee/);
  assert.match(log[0], /mongodb:\/\/intern/);
});

test('production, ungültige ID: 400 und kein Log-Rauschen', () => {
  const { res, log } = lauf('production', Object.assign(new Error('Cast to ObjectId failed'), { name: 'CastError' }));
  assert.equal(res.code, 400);
  assert.equal(res.body.message, 'Ungültige ID');
  assert.equal(log.length, 0);
});

test('doppelter Eintrag: 409', () => {
  const { res } = lauf('production', Object.assign(new Error('E11000'), { code: 11000 }));
  assert.equal(res.code, 409);
  assert.equal(res.body.message, 'Dieser Eintrag existiert bereits');
});

test('ValidationError: 400 mit den einzelnen Meldungen', () => {
  const err = Object.assign(new Error('x'), {
    name: 'ValidationError',
    errors: { name: { message: 'Name fehlt' }, unit: { message: 'Einheit unbekannt' } }
  });
  const { res } = lauf('production', err);
  assert.equal(res.code, 400);
  assert.equal(res.body.message, 'Name fehlt, Einheit unbekannt');
});

test('ein Fehler mit eigenem Status behält ihn und seine Meldung', () => {
  const { res, log } = lauf('production', Object.assign(new Error('Keine Berechtigung'), { status: 403 }));
  assert.equal(res.code, 403);
  assert.equal(res.body.message, 'Keine Berechtigung');
  assert.equal(log.length, 0);
});

test('außerhalb von production wird wie bisher jeder Fehler protokolliert', () => {
  const { log } = lauf('development', Object.assign(new Error('Cast'), { name: 'CastError' }));
  assert.equal(log.length, 1);
});
EOF

cat > "$BE/test/integration/health.test.js" <<'EOF'
'use strict';
const test   = require('node:test');
const assert = require('node:assert/strict');
const { start, stop, req } = require('../helpers/http');

test.before(async () => { await start(); });
test.after (async () => { await stop(); });

test('health antwortet — ohne Angaben zur Umgebung des Servers', async () => {
  const r = await req('/api/health');
  assert.equal(r.status, 200);
  assert.equal(r.body.status, 'ok');
  assert.equal(typeof r.body.uptime, 'number');
  assert.ok(!('env' in r.body), `verrät NODE_ENV: ${JSON.stringify(r.body)}`);
});
EOF

cat > "$BE/test/helpers/ohne-db.js" <<'EOF'
'use strict';
//
// Nur für test/integration/server-start.test.js: server.js starten, ohne
// eine Datenbank zu brauchen — geprüft wird dort das Lauschen (Adresse,
// belegter Port, Startabbruch), nicht die Datenbank.
//
// mongoose.connect meldet sofort Erfolg. Abfragen, die beim Start trotzdem
// losgehen (Nachholen des Tagesabschlusses), warten nur auf eine Verbindung,
// die nie kommt — der Test beendet den Prozess lange vorher.
//
const mongoose = require('mongoose');
mongoose.connect = async () => mongoose;
EOF

cat > "$BE/test/integration/server-start.test.js" <<'EOF'
'use strict';
//
// server.js als echter Prozess: Auf welcher Adresse lauscht er, was tut er
// bei belegtem Port, und verweigert er eine unsichere Proxy-Einstellung?
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const net    = require('node:net');
const path   = require('node:path');
const { spawn } = require('node:child_process');

const BACKEND = path.join(__dirname, '../..');
const GEHEIM  = 'test-only-secret-0123456789-nicht-in-produktion-verwenden';

function freierPort() {
  return new Promise((resolve) => {
    const s = net.createServer();
    s.listen(0, '127.0.0.1', () => { const p = s.address().port; s.close(() => resolve(p)); });
  });
}

// Alle Werte, die zählen, ausdrücklich gesetzt: dotenv überschreibt sie
// nicht. Sonst zöge der Test auf dem Server Werte aus der echten .env.
function starte(env, { bisZeile = null, zeitlimit = 6000 } = {}) {
  return new Promise((resolve) => {
    const kind = spawn(process.execPath, ['-r', './test/helpers/ohne-db.js', 'server.js'], {
      cwd: BACKEND,
      env: {
        PATH: process.env.PATH, NODE_ENV: 'test', JWT_SECRET: GEHEIM,
        MONGODB_URI: 'mongodb://127.0.0.1:1/unbenutzt', TRUST_PROXY: 'false', HOST: '',
        TELEGRAM_BOT_TOKEN: '', TELEGRAM_CHAT_ID: '', ...env
      }
    });
    let aus = '', err = '';
    const uhr = setTimeout(() => kind.kill(), zeitlimit);
    kind.stdout.on('data', (d) => { aus += d; if (bisZeile && bisZeile.test(aus)) kind.kill(); });
    kind.stderr.on('data', (d) => { err += d; });
    kind.on('exit', (code) => { clearTimeout(uhr); resolve({ code, aus, err }); });
  });
}

test('ohne HOST lauscht der Server nur auf 127.0.0.1', async () => {
  const port = await freierPort();
  const r = await starte({ PORT: String(port) }, { bisZeile: /Server läuft/ });
  assert.match(r.aus, new RegExp(`Server läuft auf 127\\.0\\.0\\.1:${port}`), r.aus + r.err);
});

test('bei belegtem Port meldet er das und endet — statt Erfolg vorzutäuschen', async () => {
  const belegt = net.createServer();
  await new Promise((r) => { belegt.listen(0, '127.0.0.1', r); });
  const port = belegt.address().port;
  try {
    const r = await starte({ PORT: String(port) });
    assert.doesNotMatch(r.aus, /Server läuft/, 'meldete Erfolg, obwohl er nicht lauschen konnte');
    assert.equal(r.code, 1, 'der Prozess lief weiter, ohne etwas auszuliefern');
    assert.match(r.err, /Kann nicht auf 127\.0\.0\.1:\d+ lauschen: EADDRINUSE/);
  } finally {
    await new Promise((r) => { belegt.close(r); });
  }
});

test('TRUST_PROXY=true bei einer App im Netz: Start verweigert', async () => {
  const r = await starte({ TRUST_PROXY: 'true', HOST: '0.0.0.0', PORT: String(await freierPort()) });
  assert.doesNotMatch(r.aus, /Server läuft/);
  assert.equal(r.code, 1);
  assert.match(r.err, /X-Forwarded-For/);
});

test('TRUST_PROXY=true hinter dem lokalen Tunnel: startet normal', async () => {
  const port = await freierPort();
  const r = await starte({ TRUST_PROXY: 'true', PORT: String(port) }, { bisZeile: /Server läuft/ });
  assert.match(r.aus, /Server läuft auf 127\.0\.0\.1/, r.aus + r.err);
});
EOF
for f in "${NEU[@]}"; do node --check "$f" >/dev/null 2>&1 || die "Syntaxfehler in $f"; done
ok "4 Testdateien und ein Test-Helfer (18 Tests)"

echo
echo "── Vorher: ROT erwartet (dauert ~15 s: alte Fassung hängt bis zur Zeitgrenze) ──"
echo
( cd "$BE" && node --test --test-reporter=spec \
    test/unit/netzwerk.test.js test/unit/fehlerbehandlung.test.js \
    test/integration/health.test.js test/integration/server-start.test.js ) 2>&1 \
  | grep -E "^(✔|✖) " | awk '!seen[$0]++' | head -20 || true

# ── 2  Umbau (alles oder nichts) ─────────────────────────────────────
echo
echo "── Umbau (alles oder nichts) ───────────────────────────────────"
node - "$BE" "$ENVBSP" <<'NODE_D1'
const fs = require('fs'), path = require('path');
const BE = process.argv[2], ENVBSP = process.argv[3];
const P = {
  validate: path.join(BE, 'lib', 'validate.js'),
  server:   path.join(BE, 'server.js'),
  app:      path.join(BE, 'app.js'),
  fehler:   path.join(BE, 'lib', 'fehlerbehandlung.js'),
  envbsp:   ENVBSP
};
const alt = {}, neu = {};
for (const [k, f] of Object.entries(P)) { alt[k] = fs.existsSync(f) ? fs.readFileSync(f, 'utf8') : null; neu[k] = alt[k]; }
const fehler = [], meldungen = [];

function ersetze(k, suche, durch) {
  const n = neu[k].split(suche).length - 1;
  if (n !== 1) { fehler.push(`${path.basename(P[k])}: Anker ${n}× statt 1×: ${suche.split('\n')[0].slice(0, 70)}`); return; }
  neu[k] = neu[k].replace(suche, () => durch);
}

// ── lib/validate.js ───────────────────────────────────────────────
if (/function listenHost/.test(neu.validate)) {
  meldungen.push('\x1b[90m·\x1b[0m validate.js: schon erweitert');
} else {
  const exp = 'module.exports = { parseIsoDate, parseStock, parseRangeInt, normalizeIp, checkJwtSecret };';
  ersetze('validate', exp, [
    '// ── Netzwerk ──────────────────────────────────────────────────────',
    '// Adresse, auf der der Server lauscht. Standard: nur die eigene Maschine.',
    '// Davor sitzt ein Tunnel auf demselben Rechner; niemand soll an ihm',
    '// vorbei direkt auf den Port der App.',
    'function listenHost(env) {',
    '  const h = env && typeof env.HOST === \'string\' ? env.HOST.trim() : \'\';',
    '  return h || \'127.0.0.1\';',
    '}',
    '',
    'const LOOPBACK = new Set([\'127.0.0.1\', \'::1\', \'localhost\']);',
    '',
    '// TRUST_PROXY=true heißt: dem Header X-Forwarded-For glauben. Sicher nur,',
    '// wenn ausschließlich der Proxy die App erreicht. Lauscht sie im Netz, kann',
    '// jeder Client den Header selbst setzen — die IP-Grenze beim Login wäre',
    '// umgangen, im Log stünden erfundene Adressen.',
    '// TRUST_PROXY wird GENAU wie in app.js gelesen (ohne trim): sonst meldete',
    '// diese Prüfung ein Problem, wo app.js gar nichts einschaltet.',
    'function checkProxyConfig(env) {',
    '  const vertrauen = String((env && env.TRUST_PROXY) || \'\').toLowerCase() === \'true\';',
    '  if (!vertrauen) return null;',
    '  const host = listenHost(env);',
    '  if (LOOPBACK.has(host)) return null;',
    '  return \'TRUST_PROXY=true, aber HOST=\' + host + \': Die App wäre direkt erreichbar, \' +',
    '    \'und jeder Client könnte X-Forwarded-For fälschen. \' +',
    '    \'HOST weglassen (Standard 127.0.0.1) oder TRUST_PROXY=false.\';',
    '}',
    '',
    'module.exports = { parseIsoDate, parseStock, parseRangeInt, normalizeIp, checkJwtSecret, listenHost, checkProxyConfig };'
  ].join('\n'));
  meldungen.push('\x1b[32m✓\x1b[0m validate.js: listenHost, checkProxyConfig');
}

// ── server.js ─────────────────────────────────────────────────────
if (/listenHost/.test(neu.server)) {
  meldungen.push('\x1b[90m·\x1b[0m server.js: schon umgestellt');
} else {
  ersetze('server', "const { checkJwtSecret } = require('./lib/validate');",
                    "const { checkJwtSecret, listenHost, checkProxyConfig } = require('./lib/validate');");
  ersetze('server', '}\n\n// ── DB + Server Start', [
    '}',
    '',
    '// ── Fail-fast: TRUST_PROXY nur hinter einem Tunnel auf DIESER Maschine ─',
    'const proxyProblem = checkProxyConfig(process.env);',
    'if (proxyProblem) {',
    '  console.error(\'❌ Start abgebrochen: \' + proxyProblem);',
    '  process.exit(1);',
    '}',
    '',
    '// ── DB + Server Start'
  ].join('\n'));
  ersetze('server', [
    '    const PORT = parseInt(process.env.PORT) || 3000;',
    '    app.listen(PORT, () => {',
    '      console.log(`✅ Server läuft auf Port ${PORT} [${process.env.NODE_ENV || \'development\'}]`);',
    '    });'
  ].join('\n'), [
    '    const PORT = parseInt(process.env.PORT) || 3000;',
    '    const HOST = listenHost(process.env);',
    '    // Express 5 übergibt einen Fehler beim Lauschen (etwa: Port belegt) an',
    '    // diesen Callback. Früher wurde er übergangen und trotzdem "läuft"',
    '    // gemeldet — ein Prozess, der Erfolg vortäuscht und nichts ausliefert.',
    '    app.listen(PORT, HOST, (err) => {',
    '      if (err) {',
    '        console.error(`❌ Kann nicht auf ${HOST}:${PORT} lauschen: ${err.code || err.message}`);',
    '        process.exit(1);',
    '      }',
    '      console.log(`✅ Server läuft auf ${HOST}:${PORT} [${process.env.NODE_ENV || \'development\'}]`);',
    '    });'
  ].join('\n'));
  meldungen.push('\x1b[32m✓\x1b[0m server.js: 127.0.0.1, Proxy-Prüfung, Fehler beim Lauschen');
}

// ── Fehler-Handler: aus app.js nach lib/fehlerbehandlung.js ───────
if (neu.fehler !== null) {
  meldungen.push('\x1b[90m·\x1b[0m lib/fehlerbehandlung.js: existiert schon');
} else {
  const a = neu.app;
  const start = a.indexOf('// ── Global Error Handler');
  const kopf  = start === -1 ? -1 : a.indexOf('app.use((err, req, res, next) => {', start);
  const ende  = kopf  === -1 ? -1 : a.indexOf('\n});\n', kopf);
  if (start === -1 || kopf === -1 || ende === -1) {
    fehler.push('app.js: Fehler-Handler nicht in der erwarteten Form gefunden');
  } else {
    const kommentar = a.slice(a.indexOf('\n', start) + 1, kopf).replace(/\s+$/, '');
    let rumpf = a.slice(kopf + 'app.use((err, req, res, next) => {'.length, ende);
    const logAlt = [
      "  if (process.env.NODE_ENV !== 'production') {",
      '    console.error(`[ERROR] ${req.method} ${req.path}:`, err.stack || err.message);',
      '  }'
    ].join('\n');
    if (rumpf.split(logAlt).length - 1 !== 1) {
      fehler.push('app.js: die Log-Bedingung im Fehler-Handler sieht anders aus');
    } else {
      rumpf = rumpf.replace(logAlt, () => [
        '  // Serverfehler IMMER protokollieren, auch in production — bisher nur',
        '  // außerhalb davon, ein 500er im Laden hinterließ also keine Spur.',
        '  // Unter systemd landet das im Journal (journalctl -u edeka-lager).',
        '  // 4xx sind Fehler des Clients und bleiben in production still.',
        "  if (status >= 500 || process.env.NODE_ENV !== 'production') {",
        '    console.error(`[ERROR] ${req.method} ${req.path}:`, err.stack || err.message);',
        '  }'
      ].join('\n'));
      neu.fehler = [
        "'use strict';",
        '//',
        '// Globaler Fehler-Handler der App — vorher inline in app.js. Eigene Datei,',
        '// damit er ohne Server und ohne Datenbank testbar ist',
        '// (test/unit/fehlerbehandlung.test.js).',
        '//',
        kommentar,
        'function fehlerbehandlung(err, req, res, next) {' + rumpf,
        '}',
        '',
        'module.exports = fehlerbehandlung;',
        ''
      ].join('\n');
      neu.app = a.slice(0, start) + [
        '// ── Global Error Handler ──────────────────────────────────────────',
        '// Steht in lib/fehlerbehandlung.js, damit er Tests hat. Muss die letzte',
        '// Middleware bleiben: nur so erreichen ihn die Fehler aller Routen.',
        "app.use(require('./lib/fehlerbehandlung'));"
      ].join('\n') + a.slice(ende + '\n});'.length);
      meldungen.push('\x1b[32m✓\x1b[0m lib/fehlerbehandlung.js: Handler umgezogen, 5xx immer im Log');
    }
  }
}

// ── /api/health ohne NODE_ENV ─────────────────────────────────────
if (!/env:\s*process\.env\.NODE_ENV \|\| 'development'/.test(neu.app)) {
  meldungen.push('\x1b[90m·\x1b[0m app.js: health schon ohne env');
} else {
  const h = /(\n[ \t]*timestamp: new Date\(\)\.toISOString\(\)),\n[ \t]*env:[ \t]*process\.env\.NODE_ENV \|\| 'development'\n/;
  if (!h.test(neu.app)) fehler.push('app.js: health-Antwort sieht anders aus');
  else { neu.app = neu.app.replace(h, (_m, ts) => ts + '\n'); meldungen.push('\x1b[32m✓\x1b[0m app.js: /api/health verrät NODE_ENV nicht mehr'); }
}

// ── .env.example ──────────────────────────────────────────────────
if (/^#?\s*HOST=/m.test(neu.envbsp)) {
  meldungen.push('\x1b[90m·\x1b[0m .env.example: HOST schon dokumentiert');
} else {
  ersetze('envbsp', 'PORT=3000\n', [
    'PORT=3000',
    '# Adresse, auf der der Server lauscht. Standard 127.0.0.1: nur diese',
    '# Maschine — der Tunnel läuft auf demselben Rechner. 0.0.0.0 nur, wenn die',
    '# App bewusst direkt im Netz erreichbar sein soll, und dann NICHT zusammen',
    '# mit TRUST_PROXY=true: diese Kombination verweigert den Start.',
    '# HOST=127.0.0.1',
    ''
  ].join('\n'));
  ersetze('envbsp', '\nTRUST_PROXY=false', [
    '',
    '# Nur zusammen mit HOST=127.0.0.1 (Standard) — sonst startet der Server nicht.',
    'TRUST_PROXY=false'
  ].join('\n'));
  meldungen.push('\x1b[32m✓\x1b[0m .env.example: HOST dokumentiert');
}

// ── Prüfung vor dem Schreiben ─────────────────────────────────────
for (const k of ['validate', 'server', 'app', 'fehler']) {
  if (neu[k] === null || neu[k] === alt[k]) continue;
  try { new Function('require', 'module', 'exports', '__dirname', 'process', neu[k]); }
  catch (e) { fehler.push(`${path.basename(P[k])} wäre ungültig: ${e.message}`); }
}
if (fehler.length) {
  console.log('\n  \x1b[31mEs wurde NICHTS geändert:\x1b[0m');
  fehler.forEach(x => console.log('  \x1b[31m✗\x1b[0m ' + x));
  console.log('');
  process.exit(1);
}
for (const [k, f] of Object.entries(P)) {
  if (neu[k] === null || neu[k] === alt[k]) continue;
  if (alt[k] !== null && !fs.existsSync(f + '.d1.bak')) fs.writeFileSync(f + '.d1.bak', alt[k]);
  fs.writeFileSync(f, neu[k]);
}
meldungen.forEach(m => console.log('  ' + m));
NODE_D1

FERTIG=1

for f in server.js app.js lib/validate.js lib/fehlerbehandlung.js; do
  node --check "$BE/$f" >/dev/null 2>&1 || die "Syntaxfehler in $BE/$f — rückgängig: git checkout . && git clean -fd"
done
ok "syntaktisch gültig"

lauf() {
  local aus
  aus=$( cd "$BE" && npm run "$1" 2>&1 || true )
  printf '%s\n' "$aus" | grep -E "^(ℹ|#) (tests|pass|fail) " | sed "s/^/    [$1] /" >&2 || true
  printf '%s\n' "$aus" | grep -E "^(ℹ|#) fail " | awk '{print $3}' | tail -1 || true
}

echo
echo "── Nachher: GRÜN erwartet ──────────────────────────────────────"
echo
( cd "$BE" && node --test --test-reporter=spec \
    test/unit/netzwerk.test.js test/unit/fehlerbehandlung.test.js \
    test/integration/health.test.js test/integration/server-start.test.js ) 2>&1 \
  | grep -E "^(✔|✖) " || true
echo
U=$(lauf test:unit); I=$(lauf test:integration)
echo "  Unit: fail=${U:-?}   Integration: fail=${I:-?}"
[ "${U:-1}" = "0" ] && [ "${I:-1}" = "0" ] || die "Tests nicht grün — rückgängig: git checkout . && git clean -fd"
ok "alle Tests grün"

set +e
LINT_AUS=$( cd "$BE" && npm run lint 2>&1 ); LINT=$?
set -e
[ "$LINT" -eq 0 ] && ok "Lint sauber" || { printf '%s\n' "$LINT_AUS" | grep -vE "^>|^$"; die "Lint meldet etwas — rückgängig: git checkout . && git clean -fd"; }

echo
echo "── Danach ──────────────────────────────────────────────────────"
echo
echo "  Erwartet: 94 Unit- und 90 Integrationstests grün."
echo
echo "    mkdir -p tools && mv $SELBST tools/"
echo "    git add -A && git commit -m 'Phase D Schritt 1: Betriebssicherheit im Code'"
echo "    git push -u origin phase-d"
echo
echo "  Dann den laufenden Server neu starten (Fenster 1: Strg+C, dann"
echo "  NODE_ENV=production npm start). Die Startzeile lautet jetzt:"
echo "    ✅ Server läuft auf 127.0.0.1:3000 [production]"
echo
echo "  Rückgängig:  git checkout . && git clean -fd"
echo
