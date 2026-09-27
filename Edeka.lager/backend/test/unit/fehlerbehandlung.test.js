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
