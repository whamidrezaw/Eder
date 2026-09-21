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
