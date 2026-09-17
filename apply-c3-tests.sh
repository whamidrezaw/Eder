#!/usr/bin/env bash
#
# apply-c3-tests.sh — Batch C3, Schritt 1: nur Tests, keine Korrekturen
#
# Beweist die beiden Frontend-Befunde, bevor etwas geändert wird:
#   · ein 401 wegen falschen aktuellen Passworts meldet den Benutzer ab
#   · logout() löscht mit localStorage.clear() auch das Farbschema
#
# Dazu ein Klärungstest im Backend: sind die beiden 401-Antworten
# überhaupt voneinander unterscheidbar? Die Antwort entscheidet, ob die
# Korrektur nur im Browser stattfindet oder auch auf dem Server.
#
# Frontend-Tests laufen über node:vm mit einer selbstgebauten
# Browser-Umgebung — keine neue Abhängigkeit.
#
# Ausführen im Wurzelverzeichnis des Repos:
#     bash apply-c3-tests.sh
#
# Idempotent. Rührt keine Anwendungslogik an.
#
set -euo pipefail

BE="Edeka.lager/backend"
FE="Edeka.lager/frontend"
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; }
die() { printf '\n  \033[31m✗ %s\033[0m\n\n' "$1" >&2; exit 1; }

echo
echo "── Batch C3, Schritt 1: Beweise ────────────────────────────────"
echo

[ -d "$BE/test/unit" ]              || die "'$BE/test' fehlt. Bitte zuerst Batch B anwenden."
[ -f "$FE/assets/shared.js" ]       || die "'$FE/assets/shared.js' nicht gefunden."

if command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
  [ -z "$(git status --porcelain)" ] || die "Arbeitsverzeichnis nicht sauber. Bitte erst committen."
  ok "Arbeitsverzeichnis sauber"
fi

mkdir -p "$BE/test/helpers"

# ── Browser-Attrappe ─────────────────────────────────────────────────
cat > "$BE/test/helpers/browser.js" <<'EOF'
'use strict';
//
// Lädt frontend/assets/shared.js in eine nachgebaute Browser-Umgebung.
//
// Bewusst mit node:vm statt jsdom: keine zusätzliche Abhängigkeit, und in
// einem eigenen vm-Context landen Funktionsdeklarationen der obersten Ebene
// ohnehin auf dem globalen Objekt. Ob shared.js sie zusätzlich auf window
// legt, ist damit egal.
//
const vm   = require('node:vm');
const fs   = require('node:fs');
const path = require('node:path');

const SHARED = path.join(__dirname, '../../../frontend/assets/shared.js');

/** Ein Response-ähnliches Objekt für die fetch-Attrappe. */
function antwort(status, koerper) {
  const text = typeof koerper === 'string' ? koerper : JSON.stringify(koerper);
  return {
    ok:         status >= 200 && status < 300,
    status,
    statusText: String(status),
    headers:    { get: () => 'application/json' },
    json:       async () => (typeof koerper === 'string' ? JSON.parse(koerper) : koerper),
    text:       async () => text,
    blob:       async () => ({ size: text.length, type: 'application/json' }),
    clone()     { return antwort(status, koerper); }
  };
}

function speicher(anfang = {}) {
  const daten = new Map(Object.entries(anfang).map(([k, v]) => [k, String(v)]));
  return {
    getItem:    k => (daten.has(k) ? daten.get(k) : null),
    setItem:    (k, v) => { daten.set(k, String(v)); },
    removeItem: k => { daten.delete(k); },
    clear:      () => { daten.clear(); },
    key:        i => [...daten.keys()][i] ?? null,
    get length() { return daten.size; },
    _daten:     daten
  };
}

function element() {
  const attrs = new Map();
  const el = {
    setAttribute:       (k, v) => attrs.set(k, String(v)),
    getAttribute:       k => (attrs.has(k) ? attrs.get(k) : null),
    removeAttribute:    k => attrs.delete(k),
    appendChild:        () => {},
    removeChild:        () => {},
    remove:             () => {},
    addEventListener:   () => {},
    removeEventListener:() => {},
    querySelector:      () => null,
    querySelectorAll:   () => [],
    focus:              () => {},
    click:              () => {},
    classList: { add() {}, remove() {}, toggle() {}, contains: () => false },
    style:   {},
    dataset: {},
    attributes: attrs,
    children: [],
    value:    '',
    checked:  false,
    textContent: '',
    innerHTML:   '',
    innerText:   ''
  };
  return el;
}

/**
 * @param {object} o
 * @param {string|null} o.token      Inhalt von sessionStorage.token
 * @param {string}      o.pathname   window.location.pathname
 * @param {object}      o.lokal      Startinhalt von localStorage
 * @param {function}    o.fetchStub  Attrappe für fetch
 */
function ladeShared({ token = null, pathname = '/dashboard.html', lokal = {}, fetchStub } = {}) {
  if (!fs.existsSync(SHARED)) {
    throw new Error(`shared.js nicht gefunden: ${SHARED}`);
  }

  const sessionStorage = speicher(token ? { token } : {});
  const localStorage   = speicher(lokal);
  const navigationen   = [];
  const fetchAufrufe   = [];

  const location = {
    pathname,
    search:   '',
    hash:     '',
    host:     'localhost:3000',
    origin:   'http://localhost:3000',
    protocol: 'http:',
    _href:    'http://localhost:3000' + pathname,
    get href() { return this._href; },
    set href(v) { navigationen.push(v); this._href = String(v); },
    assign(v)   { navigationen.push(v); this._href = String(v); },
    replace(v)  { navigationen.push(v); this._href = String(v); },
    reload()    { navigationen.push('[reload]'); }
  };

  const documentElement = element();
  const dokument = {
    documentElement,
    body:             element(),
    head:             element(),
    readyState:       'complete',
    getElementById:   () => null,
    querySelector:    () => null,
    querySelectorAll: () => [],
    createElement:    () => element(),
    addEventListener: () => {},
    cookie:           ''
  };

  const standardFetch = async (url, opts) => {
    fetchAufrufe.push({ url, opts });
    return antwort(200, {});
  };

  const sandbox = {
    console,
    document: dokument,
    sessionStorage,
    localStorage,
    location,
    navigator: { userAgent: 'node-test', language: 'de-DE' },
    fetch: fetchStub
      ? (async (url, opts) => { fetchAufrufe.push({ url, opts }); return fetchStub(url, opts); })
      : standardFetch,
    setTimeout, clearTimeout, setInterval, clearInterval,
    URL, URLSearchParams, Intl, Date, Math, JSON,
    Blob:     class Blob { constructor(t) { this.parts = t; } },
    FormData: class FormData {},
    alert:   () => {},
    confirm: () => true,
    prompt:  () => null,
    requestAnimationFrame: (fn) => setTimeout(fn, 0),
    Chart:   class Chart { constructor() {} destroy() {} update() {} }
  };
  sandbox.window     = sandbox;    // window.x und x sind dasselbe
  sandbox.globalThis = sandbox;
  sandbox.self       = sandbox;

  vm.createContext(sandbox);

  const quelle = fs.readFileSync(SHARED, 'utf8');
  try {
    vm.runInContext(quelle, sandbox, { filename: 'shared.js' });
  } catch (err) {
    throw new Error(
      `shared.js konnte in der Attrappe nicht geladen werden: ${err.message}\n` +
      `Wahrscheinlich fehlt in test/helpers/browser.js eine Nachbildung. ` +
      `Bitte diese Meldung schicken.`
    );
  }

  // Nachlauf: mit const/let deklarierte Funktionen landen nicht auf dem
  // globalen Objekt. Ein zweites Skript im selben Context sieht sie aber
  // und kann sie herüberlegen.
  const gesucht = [
    'api', 'logout', 'escapeHtml', 'toggleTheme', 'showToast',
    'fmtDate', 'fmtTime', 'fmtRelative', 'animVal', 'sendReportNow', 'downloadCSV'
  ];
  vm.runInContext(
    gesucht.map(n => `try { if (typeof ${n} === 'function') window.${n} = ${n}; } catch (e) {}`).join('\n'),
    sandbox
  );

  const gefunden = gesucht.filter(n => typeof sandbox[n] === 'function');

  return { sandbox, sessionStorage, localStorage, location, navigationen, fetchAufrufe, gefunden };
}

module.exports = { ladeShared, antwort, SHARED };
EOF
ok "test/helpers/browser.js"

# ── Frontend-Tests ───────────────────────────────────────────────────
ZIEL_FE="$BE/test/unit/shared-js.test.js"
[ -f "$ZIEL_FE" ] && cp "$ZIEL_FE" "$ZIEL_FE.bak"

cat > "$ZIEL_FE" <<'EOF'
'use strict';
//
// Batch C3 — frontend/assets/shared.js
//
// Zwei Tests sind absichtlich ROT und mit "── ROT ──" markiert.
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const { ladeShared, antwort } = require('../helpers/browser');

// ── Kontrollen: müssen GRÜN sein ──────────────────────────────────
// Sind diese rot, stimmt etwas an der Browser-Attrappe nicht — dann bitte
// die Meldung schicken, bevor irgendetwas am Frontend geändert wird.

test('Kontrolle: shared.js lädt und stellt api() und logout() bereit', () => {
  const { gefunden, sandbox } = ladeShared({ token: 'T' });
  console.log('   gefundene Funktionen:', gefunden.join(', ') || '(keine)');

  assert.equal(typeof sandbox.api, 'function',
    `api() nicht gefunden. Vorhanden: ${gefunden.join(', ') || 'nichts'}`);
  assert.equal(typeof sandbox.logout, 'function',
    `logout() nicht gefunden. Vorhanden: ${gefunden.join(', ') || 'nichts'}`);
});

test('Kontrolle: ohne Token leitet shared.js zur Anmeldeseite', () => {
  const ohne = ladeShared({ token: null, pathname: '/dashboard.html' });
  assert.ok(ohne.navigationen.length > 0,
    'ohne Token müsste zur Anmeldeseite weitergeleitet werden');
  assert.match(ohne.navigationen[0], /index\.html/);

  const mit = ladeShared({ token: 'T', pathname: '/dashboard.html' });
  assert.deepEqual(mit.navigationen, [],
    'mit Token darf nicht weitergeleitet werden');
});

// ── Leitplanke: ein echter Sitzungsabbruch MUSS abmelden ──────────
// Dieser Test ist heute grün und muss nach der Korrektur grün bleiben.
// Er verhindert, dass wir die Abmeldung beim Reparieren ganz abschalten.

test('ein 401 auf einer normalen Route beendet die Sitzung', async () => {
  const u = ladeShared({
    token: 'T',
    lokal: { theme: 'dark' },
    fetchStub: async () => antwort(401, { message: 'Ungültiger Token' })
  });

  await assert.rejects(() => u.sandbox.api('/api/products'));

  assert.equal(u.sessionStorage.getItem('token'), null,
    'bei ungültigem Token muss die Sitzung beendet werden');
  assert.ok(u.navigationen.some(n => /index\.html/.test(n)),
    'bei ungültigem Token muss zur Anmeldeseite geleitet werden');
});

// ── Befund 1: Tippfehler beim Passwort wirft aus der Sitzung ──────

// ── ROT ──
test('ein falsches aktuelles Passwort beendet die Sitzung nicht', async () => {
  const u = ladeShared({
    token: 'T',
    lokal: { theme: 'dark' },
    fetchStub: async () => antwort(401, { message: 'Aktuelles Passwort falsch' })
  });

  await assert.rejects(() => u.sandbox.api(
    '/api/auth/change-password', 'PUT',
    { currentPassword: 'vertippt', newPassword: 'NeuesPasswort123' }
  ));

  assert.equal(u.fetchAufrufe.length, 1,
    'api() hat kein fetch ausgelöst — der Test greift nicht. Bitte Ausgabe schicken.');

  assert.equal(u.sessionStorage.getItem('token'), 'T',
    'Die Sitzung wurde beendet, obwohl nur das aktuelle Passwort falsch war. ' +
    'api() behandelt jeden 401 als abgelaufene Sitzung — ein Tippfehler im ' +
    'Passwortfeld wirft den Benutzer damit aus dem System.');
  assert.deepEqual(u.navigationen, [],
    'es wurde zur Anmeldeseite weitergeleitet');
});

// ── Befund 2: logout() räumt zu viel auf ──────────────────────────

// ── ROT ──
test('logout beendet die Sitzung, behält aber die Anzeige-Einstellungen', () => {
  const u = ladeShared({ token: 'T', lokal: { theme: 'dark' } });

  u.sandbox.logout();

  assert.equal(u.sessionStorage.getItem('token'), null,
    'die Sitzung muss beendet werden');
  assert.ok(u.navigationen.some(n => /index\.html/.test(n)),
    'nach dem Abmelden muss die Anmeldeseite folgen');

  assert.equal(u.localStorage.getItem('theme'), 'dark',
    'localStorage.clear() löscht auch das gespeicherte Farbschema — nach jedem ' +
    'Abmelden steht das Thema wieder auf dem Standard, obwohl es nichts mit ' +
    'der Sitzung zu tun hat.');
});

// ── Offene Frage: verschluckt escapeHtml die Null? ────────────────
// escapeHtml(0) gibt bei einer Prüfung auf Falsy-Werte '' zurück statt '0'.
// Ob das hier zutrifft, entscheidet der Test.

test('escapeHtml verschluckt die Null nicht', (t) => {
  const { sandbox } = ladeShared({ token: 'T' });
  if (typeof sandbox.escapeHtml !== 'function') {
    t.skip('escapeHtml ist nicht in shared.js definiert');
    return;
  }
  assert.equal(sandbox.escapeHtml(0), '0', 'die Zahl 0 wird zu einem leeren String');
  assert.equal(sandbox.escapeHtml(false), 'false');
  assert.equal(sandbox.escapeHtml(''), '');
  assert.equal(sandbox.escapeHtml(null), '');
  assert.equal(sandbox.escapeHtml('<b>x</b>'), '&lt;b&gt;x&lt;/b&gt;');
});
EOF
ok "test/unit/shared-js.test.js (6 Tests)"

# ── Klärungstest im Backend ──────────────────────────────────────────
ZIEL_BE="$BE/test/integration/change-password.test.js"
[ -f "$ZIEL_BE" ] && cp "$ZIEL_BE" "$ZIEL_BE.bak"

cat > "$ZIEL_BE" <<'EOF'
'use strict';
//
// Batch C3 — kann der Browser die beiden 401-Fälle auseinanderhalten?
//
// Der Frontend-Fehler ist, dass api() jeden 401 als abgelaufene Sitzung
// behandelt. Die Frage davor ist: könnte er es überhaupt besser wissen?
// Falls beide Antworten gleich aussehen, braucht die Korrektur auch eine
// Server-Seite (ein maschinenlesbares code-Feld).
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const db     = require('../helpers/db');
const { start, stop, req } = require('../helpers/http');
const { makeUser, login, DEFAULT_PASSWORD } = require('../helpers/factories');

test.before(async () => { await db.connect(); await start(); });
test.after (async () => { await stop(); await db.disconnect(); });
test.beforeEach(async () => { await db.wipe(); });

const NEU = 'EinNeuesPasswort123';

test('Kontrolle: mit richtigem aktuellen Passwort geht die Änderung durch', async () => {
  await makeUser({ username: 'anna' });
  const { token } = await login('anna');

  const r = await req('/api/auth/change-password', {
    method: 'PUT', token,
    body: { currentPassword: DEFAULT_PASSWORD, newPassword: NEU }
  });
  assert.notEqual(r.status, 404,
    `Route oder Methode stimmt nicht: ${r.status} ${r.text}`);
  assert.equal(r.status, 200, `erwartet 200, bekommen ${r.status}: ${r.text}`);

  assert.equal((await login('anna', NEU)).status, 200, 'das neue Passwort gilt nicht');
  assert.equal((await login('anna', DEFAULT_PASSWORD)).status, 401, 'das alte Passwort gilt noch');
});

test('Kontrolle: ein falsches aktuelles Passwort ergibt 401', async () => {
  await makeUser({ username: 'anna' });
  const { token } = await login('anna');

  const r = await req('/api/auth/change-password', {
    method: 'PUT', token,
    body: { currentPassword: 'vertippt', newPassword: NEU }
  });
  assert.equal(r.status, 401, `erwartet 401, bekommen ${r.status}: ${r.text}`);
});

test('die beiden 401-Antworten sind voneinander unterscheidbar', async () => {
  await makeUser({ username: 'anna' });
  const { token } = await login('anna');

  const tokenFehler = await req('/api/products', { token: 'voelligKaputt' });
  const passwortFehler = await req('/api/auth/change-password', {
    method: 'PUT', token,
    body: { currentPassword: 'vertippt', newPassword: NEU }
  });

  assert.equal(tokenFehler.status, 401);
  assert.equal(passwortFehler.status, 401);

  console.log('   401 wegen Token   :', JSON.stringify(tokenFehler.body));
  console.log('   401 wegen Passwort:', JSON.stringify(passwortFehler.body));

  assert.notDeepEqual(tokenFehler.body, passwortFehler.body,
    'Beide 401-Antworten sind identisch. Der Browser kann dann unmöglich ' +
    'erkennen, ob die Sitzung abgelaufen ist oder nur das Passwort falsch ' +
    'war — die Korrektur braucht dann auch eine Server-Seite.');
});
EOF
ok "test/integration/change-password.test.js (3 Tests)"

echo
echo "── Selbstprüfung ───────────────────────────────────────────────"
for f in "$BE/test/helpers/browser.js" "$ZIEL_FE" "$ZIEL_BE"; do
  node --check "$f" >/dev/null 2>&1 || die "Syntaxfehler in $f"
done
ok "syntaktisch gültig"
node --check "$FE/assets/shared.js" >/dev/null 2>&1 \
  && ok "frontend/assets/shared.js ist syntaktisch gültig" \
  || die "frontend/assets/shared.js hat einen Syntaxfehler"

echo
echo "── Tests ───────────────────────────────────────────────────────"
echo
( cd "$BE" && npm run test:unit ) || true
echo
( cd "$BE" && npm run test:integration ) || true

echo
echo "── Erwartung ───────────────────────────────────────────────────"
echo
echo "  2 ROT    die beiden Frontend-Befunde"
echo "  3 GRÜN   Kontrollen im Frontend (Laden, Weiterleitung, Leitplanke)"
echo "  1 OFFEN  escapeHtml(0)"
echo "  3 OFFEN  die drei Backend-Klärungstests"
echo "  103 GRÜN alles aus Batch A, B, C1 und C2"
echo
echo "  Wichtig: Sind die beiden KONTROLLEN im Frontend rot, liegt es an"
echo "  meiner Browser-Attrappe und nicht an deinem Code. Dann bitte nur"
echo "  die Ausgabe schicken — insbesondere die Liste der gefundenen"
echo "  Funktionen und die Zeile 'shared.js konnte ... nicht geladen werden'."
echo
echo "  Für die Korrektur brauche ich anschließend zwei Dinge:"
echo "    sed -n '/async function api/,/^}/p'  $FE/assets/shared.js"
echo "    sed -n '/function escapeHtml/,/^}/p' $FE/assets/shared.js"
echo
echo "  Rückgängig:  git checkout . && git clean -fd"
echo
