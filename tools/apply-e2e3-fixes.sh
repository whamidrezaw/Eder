#!/usr/bin/env bash
#
# apply-e2e3-fixes.sh — Phase E2 + E3, Schritt 2: die Korrekturen
#
#   E2.1  lib/limits.js       alle Mengenbegrenzungen an einer Stelle
#   E2.2  routes/auth.js      Login: erst je Benutzername, dann Decke je IP
#   E2.3  routes/reports.js   send-now und export je Benutzer, 10/Minute
#   E3.1  app.js              CORS nur für ausdrücklich eingetragene Origins
#   E3.2  .env.example        CORS-Kommentar war nach E3 falsch; neue Variablen
#   +     ein neuer Test für die REIHENFOLGE der beiden Login-Stufen
#
# Ausführen im Wurzelverzeichnis des Repos:
#     bash apply-e2e3-fixes.sh
#
set -euo pipefail

BE="Edeka.lager/backend"
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
skip() { printf '  \033[90m·\033[0m %s\n' "$1"; }
die()  { printf '\n  \033[31m✗ %s\033[0m\n\n' "$1" >&2; exit 1; }

echo
echo "── Phase E2 + E3, Schritt 2: Korrekturen ───────────────────────"
echo

[ -f "$BE/routes/auth.js" ]    || die "'$BE/routes/auth.js' nicht gefunden."
[ -f "$BE/routes/reports.js" ] || die "'$BE/routes/reports.js' nicht gefunden."
[ -f "$BE/app.js" ]            || die "'$BE/app.js' nicht gefunden."
[ -f "$BE/test/integration/rate-limit-reports.test.js" ] \
  || die "E2/E3-Tests fehlen. Bitte zuerst apply-e2e3-tests.sh ausführen."

if command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
  BRANCH=$(git rev-parse --abbrev-ref HEAD)
  [ "$BRANCH" != "main" ] || die "Du bist auf main. Bitte auf phase-e wechseln."
  [ -z "$(git status --porcelain)" ] || die "Arbeitsverzeichnis nicht sauber. Bitte erst committen."
  ok "Branch '$BRANCH', Arbeitsverzeichnis sauber"
fi

# ── E2.1  lib/limits.js ──────────────────────────────────────────────
echo
echo "── Neues Modul ─────────────────────────────────────────────────"
if [ -f "$BE/lib/limits.js" ] && grep -q 'loginJeName' "$BE/lib/limits.js"; then
  skip "lib/limits.js schon vorhanden"
else
cat > "$BE/lib/limits.js" <<'EOF'
'use strict';
//
// Alle Mengenbegrenzungen an einer Stelle.
//
// Die Begrenzer werden EINMAL beim Laden erzeugt und gelten dann für alle
// Anfragen — ihr Zählerstand lebt im Prozess. Deshalb dürfen sie nie
// innerhalb eines Handlers neu angelegt werden.
//
const { rateLimit } = require('express-rate-limit');

const MINUTE        = 60 * 1000;
const VIERTELSTUNDE = 15 * MINUTE;

function zahlAusUmgebung(name, standard) {
  const n = Number(process.env[name]);
  return Number.isInteger(n) && n > 0 ? n : standard;
}

// Unverändert übernommen: index.html wartet auf genau diesen 429 und zeigt
// dazu eine eigene Meldung an.
const LOGIN_NACHRICHT = {
  message: 'Zu viele Login-Versuche. Bitte versuchen Sie es in einigen Minuten erneut.'
};

// ── Login, Stufe 1: je Benutzername ─────────────────────────────────
// Schützt das einzelne Konto gegen Durchprobieren. Der Name wird wie im
// User-Schema kleingeschrieben und getrimmt — sonst bekäme "ANNA" einen
// frischen Topf mit zehn neuen Versuchen für dasselbe Konto.
const loginJeName = rateLimit({
  windowMs: VIERTELSTUNDE,
  limit: 10,
  standardHeaders: true,
  legacyHeaders: false,
  message: LOGIN_NACHRICHT,
  keyGenerator: (req) => 'login-name:' + String(req.body?.username ?? '').toLowerCase().trim()
});

// ── Login, Stufe 2: Decke je IP ─────────────────────────────────────
// Bremst das Streuen über viele Konten von einer Adresse aus. Hoch genug,
// dass eine Filiale hinter einer gemeinsamen Adresse sie im Alltag nie
// erreicht. Standard 100; im Test über LOGIN_IP_LIMIT niedriger gestellt.
// Die Standard-Schlüsselbildung nutzt req.ip und beachtet damit
// TRUST_PROXY aus app.js.
const loginJeIp = rateLimit({
  windowMs: VIERTELSTUNDE,
  limit: zahlAusUmgebung('LOGIN_IP_LIMIT', 100),
  standardHeaders: true,
  legacyHeaders: false,
  message: LOGIN_NACHRICHT
});

// ── Aufwendige Aktionen: je Benutzer ────────────────────────────────
// Diese Begrenzer stehen HINTER auth — erst dort gibt es req.user.
function jeBenutzer(bereich, limit, text) {
  return rateLimit({
    windowMs: MINUTE,
    limit,
    standardHeaders: true,
    legacyHeaders: false,
    message: { message: text },
    keyGenerator: (req) => bereich + ':' + String(req.user?._id ?? 'ohne-anmeldung')
  });
}

// send-now schreibt jedes Mal eine vollständige Momentaufnahme und ruft
// Telegram; export baut eine komplette Excel- oder PDF-Datei.
const sendNowJeBenutzer = jeBenutzer('send-now', 10,
  'Zu viele Berichte in kurzer Zeit. Bitte eine Minute warten.');
const exportJeBenutzer  = jeBenutzer('export', 10,
  'Zu viele Exporte in kurzer Zeit. Bitte eine Minute warten.');

module.exports = { loginJeName, loginJeIp, sendNowJeBenutzer, exportJeBenutzer };
EOF
  ok "lib/limits.js"
fi

echo
echo "── Quelltext (alles oder nichts) ───────────────────────────────"

node - "$BE" <<'NODE_E23'
const fs = require('fs'), path = require('path');
const BE = process.argv[2];
const P  = (...p) => path.join(BE, ...p);
const plan = [], fehler = [], dateien = new Map();

function hole(d) {
  if (!dateien.has(d)) {
    const f = P(...d.split('/'));
    if (!fs.existsSync(f)) return null;
    const t = fs.readFileSync(f, 'utf8');
    dateien.set(d, { original: t, aktuell: t });
  }
  return dateien.get(d);
}
function umgebung(text, muster, zeilen = 10) {
  const L = text.split('\n'), i = L.findIndex(l => muster.test(l));
  if (i === -1) return '      (keine ähnliche Zeile gefunden)';
  return L.slice(Math.max(0, i - 2), i + zeilen).map((l, k) => `      ${i - 1 + k}| ${l}`).join('\n');
}
function patch({ name, datei, schonDa, suche, ersetze, hinweis, naehe }) {
  const e = hole(datei);
  if (!e) { fehler.push({ name, datei, hinweis: 'Datei nicht gefunden', ausschnitt: '' }); return; }
  if (schonDa && schonDa.test(e.aktuell)) { plan.push({ datei, name, geaendert: false }); return; }
  const neu = e.aktuell.replace(suche, ersetze);
  if (neu === e.aktuell) {
    fehler.push({ name, datei, hinweis, ausschnitt: naehe ? umgebung(e.aktuell, naehe) : '' });
    return;
  }
  e.aktuell = neu;
  plan.push({ datei, name, geaendert: true });
}

// ── E2.2  Login ───────────────────────────────────────────────────
// Der alte Kommentar erklärte, warum je IP und nicht je Name: so sollten
// zugleich Durchprobieren eines Kontos und Streuen über viele Konten
// gebremst werden. Beide Ziele bleiben erhalten — nur auf zwei Stufen
// verteilt. Das Wissen aus dem alten Kommentar wandert in den neuen.
patch({
  name: 'E2.2  Login: zwei Stufen statt eines Limiters je IP',
  datei: 'routes/auth.js',
  schonDa: /loginJeName/,
  suche: /\/\/ ── Rate Limiting[^\n]*\n(?:\/\/[^\n]*\n)*const loginLimiter = rateLimit\(\{[\s\S]*?\n\}\);/,
  ersetze: () => [
    '// ── Mengenbegrenzung für den Login ──────────────────────────────',
    '// Vorher: EIN Limiter je IP. Die Begründung war richtig gedacht — er',
    '// sollte zugleich das Durchprobieren eines Kontos und das Streuen über',
    '// viele Konten von einer Adresse bremsen. Nicht bedacht war, dass in',
    '// einer Filiale alle Geräte hinter EINER öffentlichen Adresse sitzen:',
    '// zehn Tippfehler eines Kollegen sperrten die ganze Filiale aus.',
    '//',
    '// Jetzt zwei Stufen (lib/limits.js), die beide Ziele von damals halten:',
    '//   loginJeName   10 Fehlversuche je Benutzername  — schützt das Konto',
    '//   loginJeIp     hohe Decke je IP, Standard 100   — bremst das Streuen',
    '//',
    '// Die Reihenfolge ist wesentlich: je Name ZUERST. Andersherum zählt',
    '// jeder bereits abgewiesene Versuch weiter auf die IP-Decke, und einer,',
    '// der dreißigmal klickt, sperrt wieder die ganze Filiale aus. Das ist',
    '// geprüft: test/integration/login-limit-order.test.js.',
    '//',
    '// index.html wartet weiterhin auf 429 mit derselben Meldung.',
    "const { loginJeName, loginJeIp } = require('../lib/limits');"
  ].join('\n'),
  hinweis: 'Der alte loginLimiter samt Kommentar wurde nicht gefunden.',
  naehe: /loginLimiter/
});

patch({
  name: 'E2.2  Login-Route: Reihenfolge je Name, dann je IP',
  datei: 'routes/auth.js',
  schonDa: /router\.post\('\/login', loginJeName, loginJeIp,/,
  suche: /router\.post\('\/login', loginLimiter, async \(req, res\) => \{/,
  ersetze: "router.post('/login', loginJeName, loginJeIp, async (req, res) => {",
  hinweis: "Die Zeile router.post('/login', loginLimiter, ...) wurde nicht gefunden.",
  naehe: /\/login'/
});

// rateLimit wird in auth.js danach nicht mehr gebraucht — und der Lint würde
// es als ungenutzt melden. Genau dafür haben wir ihn.
patch({
  name: 'E2.2  auth.js: ungenutztes require von express-rate-limit entfernt',
  datei: 'routes/auth.js',
  schonDa: /^(?![\s\S]*require\('express-rate-limit'\))/,
  suche: /^const rateLimit\s*=\s*require\('express-rate-limit'\);\r?\n/m,
  ersetze: '',
  hinweis: 'Die require-Zeile für express-rate-limit wurde nicht gefunden.',
  naehe: /express-rate-limit/
});

// ── E2.3  send-now und export ─────────────────────────────────────
// Der Begrenzer steht HINTER auth: erst dort gibt es req.user. Davor würde
// jeder Aufruf unter "ohne-anmeldung" im selben Topf landen.
patch({
  name: 'E2.3  send-now: 10 je Benutzer und Minute',
  datei: 'routes/reports.js',
  schonDa: /sendNowJeBenutzer/,
  suche: /router\.post\('\/send-now', auth, async \(req, res\) => \{/,
  ersetze: "router.post('/send-now', auth, require('../lib/limits').sendNowJeBenutzer, async (req, res) => {",
  hinweis: "Die Zeile router.post('/send-now', auth, ...) wurde nicht gefunden.",
  naehe: /send-now/
});

patch({
  name: 'E2.3  export: 10 je Benutzer und Minute',
  datei: 'routes/reports.js',
  schonDa: /exportJeBenutzer/,
  suche: /router\.get\('\/export', auth, async \(req, res\) => \{/,
  ersetze: "router.get('/export', auth, require('../lib/limits').exportJeBenutzer, async (req, res) => {",
  hinweis: "Die Zeile router.get('/export', auth, ...) wurde nicht gefunden.",
  naehe: /'\/export'/
});

// ── E3.1  CORS ────────────────────────────────────────────────────
patch({
  name: 'E3.1  CORS nur für eingetragene Origins',
  datei: 'app.js',
  schonDa: /erlaubteOrigins/,
  suche: /\/\/ ── CORS ─+[^\n]*\n(?:\/\/[^\n]*\n)*app\.use\(cors\(\{\s*\n\s*origin: \(origin, callback\) => callback\(null, true\)\s*\n\}\)\);/,
  ersetze: () => [
    '// ── CORS ─────────────────────────────────────────────────────────',
    '// CORS entscheidet, welche ANDEREN Websites aus dem Browser heraus die',
    '// Antworten dieser API lesen dürfen. Es schützt NICHT den Server: eine',
    '// Anfrage aus einem Skript oder mit curl kümmert sich nicht darum.',
    '//',
    '// Die frühere Begründung für "alle Origins" bleibt richtig: angemeldet',
    '// wird über einen Authorization-Header, nicht über ein Cookie, und das',
    '// Token in sessionStorage ist für fremde Seiten unerreichbar. Das',
    '// Schließen hier ist Verteidigung in der Tiefe, kein offenes Leck.',
    '//',
    '// Das eigene Frontend kommt von derselben Adresse und braucht gar keine',
    '// Freigabe — der Browser prüft CORS nur zwischen VERSCHIEDENEN Origins.',
    '// Es läuft also über IP, Domain und jeden Port weiter, ohne dass etwas',
    '// in .env stehen muss. Das war das Ziel der alten Regel; es bleibt.',
    '//',
    '// Wer doch eine fremde Origin braucht, etwa einen eigenen Entwicklungs-',
    '// server, trägt sie kommagetrennt in CORS_ORIGINS ein.',
    '//',
    '// credentials:true bleibt bewusst weg: es gibt keine Cookies, und die',
    '// Option würde nur ein künftiges Risiko öffnen.',
    "const erlaubteOrigins = String(process.env.CORS_ORIGINS || '')",
    "  .split(',')",
    '  .map(s => s.trim())',
    '  .filter(Boolean);',
    '',
    'app.use(cors({',
    '  // Ohne Origin-Header (gleiche Adresse, curl, Server-zu-Server) gibt es',
    '  // nichts zu entscheiden. Ist eine gesetzt, zählt allein die Liste.',
    '  origin: (origin, callback) => callback(null, !origin || erlaubteOrigins.includes(origin))',
    '}));'
  ].join('\n'),
  hinweis: 'Der CORS-Block in app.js sieht anders aus als erwartet.',
  naehe: /cors\(/
});

// ── E3.2  .env.example ────────────────────────────────────────────
// Der alte Kommentar sagte "jede Origin wird akzeptiert" — nach E3 falsch.
// Ein falscher Kommentar ist schlimmer als keiner.
patch({
  name: 'E3.2  .env.example: CORS-Kommentar berichtigt, CORS_ORIGINS ergänzt',
  datei: '.env.example',
  schonDa: /CORS_ORIGINS=/,
  suche: /# DOMAIN [^\n]*\n#[^\n]*\nDOMAIN=[^\n]*\n/,
  ersetze: () => [
    '# Für CORS nicht nötig — nur als Notiz für eine spätere Einrichtung',
    '# (HTTPS, Reverse Proxy).',
    'DOMAIN=https://deine-domain.de',
    '',
    '# Fremde Origins, die die API aus dem Browser heraus lesen dürfen,',
    '# kommagetrennt. LEER LASSEN, solange kein fremdes Frontend existiert:',
    '# das eigene kommt von derselben Adresse und braucht keine Freigabe.',
    '# Beispiel: CORS_ORIGINS=http://localhost:5500,https://test.example',
    'CORS_ORIGINS=',
    ''
  ].join('\n'),
  hinweis: 'Der DOMAIN-Block in .env.example sieht anders aus als erwartet.',
  naehe: /DOMAIN=/
});

patch({
  name: 'E3.2  .env.example: LOGIN_IP_LIMIT dokumentiert',
  datei: '.env.example',
  schonDa: /LOGIN_IP_LIMIT/,
  suche: /(TRUST_PROXY=false\r?\n)/,
  ersetze: (_m, zeile) => zeile + [
    '',
    '# Decke für Login-Versuche je IP in 15 Minuten (Standard 100). Muss so',
    '# hoch sein, dass eine ganze Filiale hinter einer gemeinsamen Adresse sie',
    '# im Alltag nie erreicht. Die Grenze je Benutzername (10) gilt getrennt.',
    '# LOGIN_IP_LIMIT=100',
    ''
  ].join('\n'),
  hinweis: 'Die Zeile TRUST_PROXY=false wurde nicht gefunden.',
  naehe: /TRUST_PROXY/
});

if (fehler.length) {
  console.log('\n  \x1b[31mEs wurde NICHTS geändert:\x1b[0m\n');
  for (const f of fehler) {
    console.log(`  \x1b[31m✗\x1b[0m ${f.name}  (${f.datei})`);
    console.log(`     ${f.hinweis}`);
    if (f.ausschnitt) console.log('     Umgebung in deiner Datei:\n' + f.ausschnitt);
    console.log('');
  }
  console.log('  Schick mir die obigen Ausschnitte.\n');
  process.exit(1);
}
for (const p of plan) {
  console.log(p.geaendert ? `  \x1b[32m✓\x1b[0m ${p.name}`
                          : `  \x1b[90m·\x1b[0m ${p.name} — schon angewendet`);
}
for (const [d, e] of dateien) {
  if (e.aktuell === e.original) continue;
  const f = P(...d.split('/'));
  if (!fs.existsSync(f + '.e23.bak')) fs.writeFileSync(f + '.e23.bak', e.original);
  fs.writeFileSync(f, e.aktuell);
  console.log(`  \x1b[90m→\x1b[0m geschrieben: ${d}`);
}
NODE_E23

# ── Neuer Test: die Reihenfolge ──────────────────────────────────────
echo
echo "── Neuer Test ──────────────────────────────────────────────────"
ZIEL="$BE/test/integration/login-limit-order.test.js"
if [ -f "$ZIEL" ]; then
  skip "login-limit-order.test.js schon vorhanden"
else
cat > "$ZIEL" <<'EOF'
'use strict';
//
// E2 — die REIHENFOLGE der beiden Login-Stufen.
//
// Beim Entwurf fiel auf: login-limit-user.test.js würde eine vertauschte
// Reihenfolge NICHT bemerken. Dort versucht es anna zehnmal, die IP-Decke
// liegt bei 100 — die wird nie erreicht, egal in welcher Reihenfolge.
//
// Steht die IP-Decke vorn, zählt jeder schon abgewiesene Versuch weiter auf
// sie. Dann genügt EIN Kollege, der dreißigmal klickt, und die ganze Filiale
// ist wieder ausgesperrt — der Fehler, den E2 beheben soll, käme durch die
// Hintertür zurück. Mit Decke 15 macht dieser Test genau das sichtbar.
//
process.env.LOGIN_IP_LIMIT = '15';

const test   = require('node:test');
const assert = require('node:assert/strict');
const db     = require('../helpers/db');
const { start, stop } = require('../helpers/http');
const { makeUser, login } = require('../helpers/factories');

test.before(async () => { await db.connect(); await db.wipe(); await start(); });
test.after (async () => { await stop(); await db.disconnect(); });

test('wer dreißigmal klickt, sperrt die anderen nicht über die IP-Decke aus', async () => {
  await makeUser({ username: 'anna' });
  await makeUser({ username: 'bernd' });

  for (let i = 0; i < 30; i++) await login('anna', 'vertippt');

  const b = await login('bernd');
  assert.equal(b.status, 200,
    `bernd bekam ${b.status}. annas abgewiesene Versuche zählen auf die IP-Decke — ` +
    `die Stufe je Benutzername muss VOR der Decke je IP stehen.`);
});
EOF
  ok "test/integration/login-limit-order.test.js (1 Test)"
fi

# ── Selbstprüfung ────────────────────────────────────────────────────
echo
echo "── Selbstprüfung ───────────────────────────────────────────────"
for f in "$BE/lib/limits.js" "$BE/routes/auth.js" "$BE/routes/reports.js" "$BE/app.js" "$ZIEL"; do
  node --check "$f" >/dev/null 2>&1 || die "Syntaxfehler in $f — rückgängig mit: git checkout ."
done
ok "syntaktisch gültig"

grep -q "router.post('/login', loginJeName, loginJeIp," "$BE/routes/auth.js" \
  || die "die Login-Route hat nicht die Reihenfolge je Name, dann je IP"
ok "Reihenfolge: je Name, dann je IP"

( cd "$BE" && npm run lint ) >/dev/null 2>&1 && ok "Lint sauber" \
  || { ( cd "$BE" && npm run lint ) 2>&1 | grep -v '^>' ; die "Lint meldet etwas — siehe oben"; }

echo
echo "── Tests ───────────────────────────────────────────────────────"
echo
( cd "$BE" && npm run test:unit ) 2>&1 | grep -E "^ℹ (tests|pass|fail)" || true
echo
# Diesmal UNGEFILTERT für die neuen Dateien — im letzten Lauf hat ein grep
# genau die Meldungen verschluckt, die gezeigt hätten, aus welchem Grund ein
# Test rot war.
( cd "$BE" && node --test \
    test/integration/rate-limit-reports.test.js \
    test/integration/login-limit-user.test.js \
    test/integration/login-limit-ip.test.js \
    test/integration/login-limit-order.test.js \
    test/integration/cors.test.js \
    test/integration/cors-allowlist.test.js ) 2>&1 | grep -vE "^\s*(at |node:internal)" || true
echo
echo "  Gesamtlauf Integration:"
( cd "$BE" && npm run test:integration ) 2>&1 | grep -E "^ℹ (tests|pass|fail)" || true

echo
echo "── Danach ──────────────────────────────────────────────────────"
echo
echo "  Erwartet: 65 Unit- und 78 Integrationstests grün."
echo
echo "  Dass die send-now- und export-Tests jetzt grün sind, belegt auch"
echo "  nachträglich, dass sie vorher aus dem RICHTIGEN Grund rot waren:"
echo "  ein grüner Test hat alle Zusicherungen erfüllt, auch die Kontrolle"
echo "  'funktioniert im Test überhaupt'."
echo
echo "  Von Hand im Browser: anmelden, einen Bericht senden, einen Export"
echo "  laden — alles wie bisher. Dann elfmal hintereinander exportieren:"
echo "  der elfte zeigt 'Zu viele Exporte in kurzer Zeit'."
echo
echo "  Danach:"
echo "    git mv apply-e2e3-tests.sh apply-e2e3-fixes.sh tools/"
echo "    git add -A && git commit -m 'E2/E3: Mengenbegrenzung je Benutzer, CORS nur auf Liste'"
echo "    git push"
echo
echo "  Rückgängig:  git checkout . && git clean -fd"
echo
