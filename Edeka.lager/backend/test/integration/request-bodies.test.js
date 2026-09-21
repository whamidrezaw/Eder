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
