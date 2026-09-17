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
