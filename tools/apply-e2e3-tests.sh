#!/usr/bin/env bash
#
# apply-e2e3-tests.sh — Phase E2 + E3, Schritt 1: nur Tests
#
#   E2  Mengenbegrenzung
#       · send-now und export: 10 Aufrufe je BENUTZER und Minute
#       · Login: 10 Fehlversuche je BENUTZERNAME, dazu eine hohe Decke je IP
#   E3  CORS: nur ausdrücklich erlaubte fremde Origins, Standard: keine
#
# Warum "je Benutzer" und nicht "je IP": In einer Filiale sitzen alle Geräte
# hinter EINER öffentlichen Adresse. Eine Begrenzung je IP hieße: vertippt
# sich einer zehnmal, kommt die ganze Filiale eine Viertelstunde nicht rein.
#
# Ausführen im Wurzelverzeichnis des Repos:
#     bash apply-e2e3-tests.sh
#
set -euo pipefail

BE="Edeka.lager/backend"
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
skip() { printf '  \033[90m·\033[0m %s\n' "$1"; }
die()  { printf '\n  \033[31m✗ %s\033[0m\n\n' "$1" >&2; exit 1; }

echo
echo "── Phase E2 + E3, Schritt 1: Beweise ───────────────────────────"
echo

[ -f "$BE/test/helpers/http.js" ] || die "'$BE/test/helpers/http.js' nicht gefunden."

if command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
  BRANCH=$(git rev-parse --abbrev-ref HEAD)
  [ "$BRANCH" != "main" ] || die "Du bist auf main. Bitte auf phase-e wechseln."
  [ -z "$(git status --porcelain)" ] || die "Arbeitsverzeichnis nicht sauber. Bitte erst committen."
  ok "Branch '$BRANCH', Arbeitsverzeichnis sauber"
fi

# ── Harness: eigene Header erlauben ──────────────────────────────────
# Für CORS muss der Test einen fremden Origin-Header setzen können.
# Node's fetch überträgt ihn tatsächlich (im Browser wäre er gesperrt) —
# das ist vorab geprüft, sonst wären die CORS-Tests wertlos.
echo
echo "── Harness ─────────────────────────────────────────────────────"
node - "$BE" <<'NODE_HTTP'
const fs = require('fs');
const p = process.argv[2] + '/test/helpers/http.js';
const t = fs.readFileSync(p, 'utf8');
if (/headers: zusatz/.test(t)) {
  console.log('  \x1b[90m·\x1b[0m req() kann schon eigene Header setzen');
  process.exit(0);
}
const alt = "async function req(path, { method = 'GET', token, body, raw = false } = {}) {\n  const headers = {};";
if (!t.includes(alt)) {
  console.error('\n  \x1b[31m✗ Kopf von req() sieht anders aus als erwartet — nichts geändert.\x1b[0m\n');
  process.exit(1);
}
const neu = "async function req(path, { method = 'GET', token, body, raw = false, headers: zusatz = {} } = {}) {\n" +
            "  // zusatz: eigene Header, z. B. Origin für die CORS-Tests.\n" +
            "  const headers = { ...zusatz };";
fs.writeFileSync(p + '.e2.bak', t);
fs.writeFileSync(p, t.replace(alt, neu));
console.log('  \x1b[32m✓\x1b[0m req() nimmt eigene Header entgegen');
NODE_HTTP

mkdir -p "$BE/test/integration"
TI="$BE/test/integration"

# ── E2a  send-now und export je Benutzer ─────────────────────────────
cat > "$TI/rate-limit-reports.test.js" <<'EOF'
'use strict';
//
// E2 — send-now und export werden je BENUTZER begrenzt: 10 je Minute.
//
// send-now löst jedes Mal einen Telegram-Aufruf und das Schreiben einer
// vollständigen Momentaufnahme aus; export baut eine komplette Excel-Datei.
// Beides ist heute unbegrenzt. Die Begrenzung gilt je Benutzer — alle
// Tests hier kommen von 127.0.0.1, eine Begrenzung je IP würde bernd also
// durch annas Aufrufe mitsperren. Genau das prüft jeweils der Schluss.
//
// Beide Tests sind ROT.
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const jwt    = require('jsonwebtoken');
const db     = require('../helpers/db');
const { start, stop, req } = require('../helpers/http');
const { makeUser, makeProduct } = require('../helpers/factories');

test.before(async () => { await db.connect(); await start(); });
test.after (async () => { await stop(); await db.disconnect(); });
test.beforeEach(async () => { await db.wipe(); });

// Direkt signiert statt über /login — der Login-Limiter soll hier nicht
// mitspielen. Dass dieser Weg trägt, hat E1 bereits belegt.
const tokenFuer = (u) => jwt.sign({ id: u._id.toString() }, process.env.JWT_SECRET, { expiresIn: '1h' });

async function zweiBenutzer() {
  const anna  = await makeUser({ username: 'anna_rl',  name: 'Anna'  });
  const bernd = await makeUser({ username: 'bernd_rl', name: 'Bernd' });
  return { anna: tokenFuer(anna), bernd: tokenFuer(bernd) };
}

// ── ROT ──
test('send-now: nach 10 Aufrufen in einer Minute ist Schluss — nur für diesen Benutzer', async () => {
  const { anna, bernd } = await zweiBenutzer();
  await makeProduct({ currentStock: 5 });

  const codes = [];
  for (let i = 0; i < 11; i++) {
    const r = await req('/api/reports/send-now', { method: 'POST', token: anna });
    codes.push(r.status);
  }
  assert.ok(codes[0] < 500, `send-now funktioniert im Test gar nicht (${codes[0]}) — bitte melden`);
  assert.ok(codes.slice(0, 10).every(c => c !== 429), `schon vor dem 11. Aufruf gesperrt: ${codes}`);
  assert.equal(codes[10], 429,
    `der 11. Aufruf ging durch (${codes}). Jeder Aufruf schreibt eine vollständige ` +
    `Momentaufnahme und ruft Telegram — heute beliebig oft hintereinander.`);

  const b = await req('/api/reports/send-now', { method: 'POST', token: bernd });
  assert.notEqual(b.status, 429, 'bernd wurde durch annas Aufrufe mitgesperrt — Begrenzung je IP statt je Benutzer');
});

// ── ROT ──
test('export: nach 10 Aufrufen in einer Minute ist Schluss — nur für diesen Benutzer', async () => {
  const { anna, bernd } = await zweiBenutzer();
  await makeProduct({ currentStock: 5 });

  const hole = async (token) => {
    const r = await req('/api/reports/export?type=excel', { token, raw: true });
    await r.res.arrayBuffer().catch(() => {});   // Antwort verbrauchen, Verbindung freigeben
    return r.status;
  };

  const codes = [];
  for (let i = 0; i < 11; i++) codes.push(await hole(anna));

  assert.ok(codes[0] < 500, `export funktioniert im Test gar nicht (${codes[0]}) — bitte melden`);
  assert.ok(codes.slice(0, 10).every(c => c !== 429), `schon vor dem 11. Aufruf gesperrt: ${codes}`);
  assert.equal(codes[10], 429,
    `der 11. Aufruf ging durch (${codes}). Jeder baut eine vollständige Excel-Datei.`);

  assert.notEqual(await hole(bernd), 429, 'bernd wurde durch annas Aufrufe mitgesperrt');
});
EOF
ok "test/integration/rate-limit-reports.test.js (2 Tests)"

# ── E2b  Login je Benutzername ───────────────────────────────────────
cat > "$TI/login-limit-user.test.js" <<'EOF'
'use strict';
//
// E2 — der Login wird je BENUTZERNAME begrenzt, nicht je IP.
//
// Eigene Datei: der Limiter hält seinen Zustand im Prozess. Der Testrunner
// startet je Datei einen eigenen Prozess, fremde Tests zählen hier also
// nicht mit.
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const db     = require('../helpers/db');
const { start, stop } = require('../helpers/http');
const { makeUser, login } = require('../helpers/factories');

test.before(async () => { await db.connect(); await db.wipe(); await start(); });
test.after (async () => { await stop(); await db.disconnect(); });

// ── ROT ──
test('zehn Fehlversuche für anna sperren bernd nicht aus', async () => {
  await makeUser({ username: 'anna' });
  await makeUser({ username: 'bernd' });

  for (let i = 1; i <= 10; i++) {
    const r = await login('anna', 'vertippt');
    assert.equal(r.status, 401, `Versuch ${i} ergab ${r.status}`);
  }

  // Alle Geräte einer Filiale teilen sich eine öffentliche Adresse. Heute
  // zählt der Limiter je IP — annas Tippfehler sperren damit die ganze
  // Filiale für eine Viertelstunde aus.
  const b = await login('bernd');
  assert.equal(b.status, 200,
    `bernd bekam ${b.status}. Zehn Fehlversuche EINES Kollegen sperren alle ` +
    `aus, die über dieselbe Adresse kommen.`);

  // Leitplanke: der Schutz des einzelnen Kontos bleibt bestehen.
  const elfter = await login('anna', 'vertippt');
  assert.equal(elfter.status, 429, 'annas Konto ist nach zehn Fehlversuchen nicht mehr geschützt');
});
EOF
ok "test/integration/login-limit-user.test.js (1 Test)"

# ── E2c  Login: Decke je IP ──────────────────────────────────────────
cat > "$TI/login-limit-ip.test.js" <<'EOF'
'use strict';
//
// E2 — zusätzlich eine hohe Decke je IP.
//
// Ohne sie könnte jemand von einer Adresse aus viele verschiedene
// Benutzernamen durchprobieren, jeden zehnmal. Die Decke liegt im Betrieb
// hoch genug, dass eine Filiale sie nie erreicht; hier wird sie über
// LOGIN_IP_LIMIT niedrig gestellt, damit der Test in Sekunden läuft.
//
// Die Variable MUSS vor dem ersten require der App gesetzt sein.
process.env.LOGIN_IP_LIMIT = '15';

const test   = require('node:test');
const assert = require('node:assert/strict');
const db     = require('../helpers/db');
const { start, stop } = require('../helpers/http');
const { login } = require('../helpers/factories');

test.before(async () => { await db.connect(); await db.wipe(); await start(); });
test.after (async () => { await stop(); await db.disconnect(); });

// ── ROT ──
test('viele verschiedene Benutzernamen von einer Adresse stoßen an die Decke', async () => {
  const codes = [];
  for (let i = 1; i <= 16; i++) {
    // Jeder Name nur einmal — die Begrenzung je Name greift also nie.
    codes.push((await login(`niemand_${i}`, 'egal')).status);
  }

  assert.ok(codes.slice(0, 15).every(c => c !== 429),
    `vor Erreichen der Decke gesperrt: ${codes}. Heute zählt der Limiter ` +
    `je IP mit Grenze 10 — verschiedene Benutzer blockieren sich gegenseitig.`);
  assert.equal(codes[15], 429, `die Decke greift nicht: ${codes}`);
});
EOF
ok "test/integration/login-limit-ip.test.js (1 Test)"

# ── E3a  CORS ────────────────────────────────────────────────────────
cat > "$TI/cors.test.js" <<'EOF'
'use strict';
//
// E3 — CORS.
//
// CORS entscheidet, welche ANDEREN Websites aus dem Browser heraus mit dieser
// API sprechen dürfen. Heute: alle. Das Frontend wird von derselben Adresse
// ausgeliefert und braucht diese Erlaubnis gar nicht.
//
// Ehrlich eingeordnet: das Risiko ist hier gering. Angemeldet wird über
// einen Bearer-Header, nicht über ein Cookie, und sessionStorage ist an die
// eigene Origin gebunden — eine fremde Seite kommt an das Token nicht heran.
// Das Schließen ist Verteidigung in der Tiefe, keine Behebung eines offenen
// Lecks.
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const { start, stop, req } = require('../helpers/http');

test.before(async () => { await start(); });
test.after (async () => { await stop(); });

const FREMD = 'https://evil.example';

// Leitplanke: das eigene Frontend darf nicht leiden.
test('Anfragen von der eigenen Adresse funktionieren unverändert', async () => {
  const r = await req('/api/health');
  assert.equal(r.status, 200, r.text);
});

// ── ROT ──
test('eine fremde Website bekommt keine Freigabe', async () => {
  const r = await req('/api/health', { headers: { Origin: FREMD } });
  const freigabe = r.headers.get('access-control-allow-origin');
  assert.notEqual(freigabe, FREMD, 'die fremde Origin wird heute einfach zurückgespiegelt');
  assert.notEqual(freigabe, '*', 'Freigabe für alle');
});

// ── ROT ──
test('auch die Vorabanfrage einer fremden Website wird nicht freigegeben', async () => {
  // Bevor ein Browser eine PATCH-Anfrage mit Authorization-Header von einer
  // fremden Seite schickt, fragt er per OPTIONS um Erlaubnis.
  const r = await req('/api/products', {
    method: 'OPTIONS',
    headers: {
      Origin: FREMD,
      'Access-Control-Request-Method': 'PATCH',
      'Access-Control-Request-Headers': 'authorization,content-type'
    }
  });
  assert.notEqual(r.headers.get('access-control-allow-origin'), FREMD,
    'die Vorabanfrage einer fremden Seite wird heute bewilligt');
});
EOF
ok "test/integration/cors.test.js (3 Tests)"

# ── E3b  CORS mit ausdrücklicher Erlaubnis ───────────────────────────
cat > "$TI/cors-allowlist.test.js" <<'EOF'
'use strict';
//
// E3 — wer eine fremde Origin braucht (etwa einen eigenen
// Entwicklungsserver), trägt sie in CORS_ORIGINS ein. Ohne Codeänderung.
//
// Die Variable MUSS vor dem ersten require der App gesetzt sein.
process.env.CORS_ORIGINS = 'https://erlaubt.example, https://auch-erlaubt.example';

const test   = require('node:test');
const assert = require('node:assert/strict');
const { start, stop, req } = require('../helpers/http');

test.before(async () => { await start(); });
test.after (async () => { await stop(); });

// Leitplanken: heute grün (alles ist erlaubt), und müssen es bleiben.
test('eine eingetragene Origin bekommt ihre Freigabe', async () => {
  const r = await req('/api/health', { headers: { Origin: 'https://erlaubt.example' } });
  assert.equal(r.headers.get('access-control-allow-origin'), 'https://erlaubt.example');
});

test('mehrere Einträge, durch Komma getrennt, funktionieren alle', async () => {
  const r = await req('/api/health', { headers: { Origin: 'https://auch-erlaubt.example' } });
  assert.equal(r.headers.get('access-control-allow-origin'), 'https://auch-erlaubt.example');
});

// ── ROT ──
test('eine nicht eingetragene Origin bleibt trotzdem draußen', async () => {
  const r = await req('/api/health', { headers: { Origin: 'https://evil.example' } });
  assert.notEqual(r.headers.get('access-control-allow-origin'), 'https://evil.example');
});
EOF
ok "test/integration/cors-allowlist.test.js (3 Tests)"

# ── tools/README.md nachziehen ───────────────────────────────────────
if [ -f tools/README.md ] && ! grep -q 'apply-e1-fixes.sh' tools/README.md; then
  ZEILEN=""
  [ -f tools/apply-e4.sh ] && ZEILEN="${ZEILEN}| \`apply-e4.sh\` | Aufräumen, Lint in der CI |\n"
  ZEILEN="${ZEILEN}| \`apply-e1-tests.sh\`, \`apply-e1-fixes.sh\` | Optimistische Sperre für Bestandsänderungen |"
  node -e "
    const fs = require('fs'); const p = 'tools/README.md';
    const t = fs.readFileSync(p, 'utf8');
    const anker = '| \`apply-eslint.sh\` | Statische Prüfung |';
    if (!t.includes(anker)) { console.log('  \x1b[90m·\x1b[0m tools/README.md: Anker fehlt, übersprungen'); process.exit(0); }
    fs.writeFileSync(p, t.replace(anker, anker + '\n' + process.argv[1].replace(/\\\\n/g, '\n')));
    console.log('  \x1b[32m✓\x1b[0m tools/README.md um E4 und E1 ergänzt');
  " "$(printf "$ZEILEN")"
else
  skip "tools/README.md schon aktuell"
fi

# ── Selbstprüfung ────────────────────────────────────────────────────
echo
echo "── Selbstprüfung ───────────────────────────────────────────────"
for f in "$BE/test/helpers/http.js" "$TI/rate-limit-reports.test.js" "$TI/login-limit-user.test.js" \
         "$TI/login-limit-ip.test.js" "$TI/cors.test.js" "$TI/cors-allowlist.test.js"; do
  node --check "$f" >/dev/null 2>&1 || die "Syntaxfehler in $f"
done
ok "syntaktisch gültig"

( cd "$BE" && npm run lint ) >/dev/null 2>&1 && ok "Lint sauber" \
  || die "Lint meldet etwas — bitte 'npm run lint' im backend ansehen"

echo
echo "── Tests ───────────────────────────────────────────────────────"
echo
( cd "$BE" && npm run test:integration ) 2>&1 | grep -E "^(✖|ℹ)" || true

echo
echo "── Erwartung ───────────────────────────────────────────────────"
echo
echo "  10 neue Tests:  7 ROT, 3 GRÜN (Leitplanken)"
echo "    rate-limit-reports   2 ROT"
echo "    login-limit-user     1 ROT"
echo "    login-limit-ip       1 ROT"
echo "    cors                 2 ROT, 1 GRÜN"
echo "    cors-allowlist       1 ROT, 2 GRÜN"
echo "  Integration insgesamt 77, davon 7 rot. Die bisherigen 67 bleiben grün."
echo
echo "  Zwei Kontrollen stecken in den send-now- und export-Tests: meldet"
echo "  einer '… funktioniert im Test gar nicht', liegt es am Aufbau und"
echo "  nicht am Befund — dann bitte die Ausgabe schicken."
echo
echo "  Bitte NICHT pushen, solange Tests rot sind — die CI würde rot."
echo
echo "  Rückgängig:  git checkout . && git clean -fd"
echo
