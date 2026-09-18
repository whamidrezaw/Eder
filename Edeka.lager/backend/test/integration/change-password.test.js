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
