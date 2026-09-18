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

// ── Neu in C3: die Kennzeichnung ──────────────────────────────────
// Diese beiden Tests halten den Vertrag fest, auf dem api() im Browser
// aufbaut. Ohne sie wäre die Attrappe im Frontend-Test nur eine Behauptung.

test('ein 401 wegen Zugangsdaten ist als solcher gekennzeichnet', async () => {
  await makeUser({ username: 'anna' });
  const { token } = await login('anna');

  const passwortFehler = await req('/api/auth/change-password', {
    method: 'PUT', token,
    body: { currentPassword: 'vertippt', newPassword: NEU }
  });
  assert.equal(passwortFehler.status, 401);
  assert.equal(passwortFehler.body.code, 'BAD_CREDENTIALS',
    'ohne diese Kennzeichnung kann der Browser den Fall nicht von einer ' +
    'abgelaufenen Sitzung unterscheiden');

  const loginFehler = await req('/api/auth/login', {
    method: 'POST', body: { username: 'anna', password: 'falsch' }
  });
  assert.equal(loginFehler.status, 401);
  assert.equal(loginFehler.body.code, 'BAD_CREDENTIALS');
});

test('ein 401 aus der Token-Prüfung trägt diese Kennzeichnung NICHT', async () => {
  const r = await req('/api/products', { token: 'voelligKaputt' });
  assert.equal(r.status, 401);
  assert.notEqual(r.body.code, 'BAD_CREDENTIALS',
    'sonst würde eine abgelaufene Sitzung nicht mehr zum Abmelden führen — ' +
    'genau die Leitplanke, die das verhindern soll');
});
