'use strict';
// Eigene Datei: der Limiter hat einen prozessweiten Zustand. Der node-Test-
// Runner startet pro Datei einen eigenen Prozess, dadurch beeinflusst dieser
// Test die übrigen Login-Tests nicht.
const test   = require('node:test');
const assert = require('node:assert/strict');
const db     = require('../helpers/db');
const { start, stop, req } = require('../helpers/http');
const { makeUser } = require('../helpers/factories');

test.before(async () => { await db.connect(); await db.wipe(); await start(); });
test.after (async () => { await stop(); await db.disconnect(); });

test('der 11. Fehlversuch wird mit 429 abgewiesen', async () => {
  await makeUser({ username: 'anna' });
  const codes = [];
  for (let i = 0; i < 12; i++) {
    const r = await req('/api/auth/login', { method: 'POST', body: { username: 'anna', password: 'falsch' } });
    codes.push(r.status);
  }
  assert.ok(codes.includes(429), `kein 429 in ${JSON.stringify(codes)} — greift der Limiter wirklich?`);
  assert.equal(codes.slice(0, 10).every(c => c === 401), true, 'die ersten 10 Versuche sollen 401 sein');
});
