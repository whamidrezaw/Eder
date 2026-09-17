'use strict';
const test   = require('node:test');
const assert = require('node:assert/strict');
const db     = require('../helpers/db');
const DailyLog = require('../../models/DailyLog');
const { start, stop, req } = require('../helpers/http');
const { makeAdminToken } = require('../helpers/factories');

test.before(async () => { await db.connect(); await start(); });
test.after (async () => { await stop(); await db.disconnect(); });
test.beforeEach(async () => { await db.wipe(); });

async function seedLogs() {
  await DailyLog.create([
    { date: '2026-05-01', sentAt: new Date('2026-05-01T22:00:00Z'), type: 'auto-midnight', snapshot: [] },
    { date: '2026-05-02', sentAt: new Date('2026-05-02T22:00:00Z'), type: 'auto-midnight', snapshot: [] },
    { date: '2026-05-03', sentAt: new Date('2026-05-03T22:00:00Z'), type: 'auto-midnight', snapshot: [] }
  ]);
}

test('Referenz: scope=daily mit gültigem Datum löscht genau einen Tag', async () => {
  const token = await makeAdminToken();
  await seedLogs();
  const r = await req('/api/reports/reset-logs', {
    method: 'POST', token, body: { scope: 'daily', date: '2026-05-02' }
  });
  assert.equal(r.status, 200);
  assert.equal(await DailyLog.countDocuments({}), 2);
});

// ── ROT: der Kern des Befunds (Batch A) ──────────────────────────────
// { "scope": "daily", "date": { "$ne": null } } wird ungeprüft zu einem
// Mongo-Operator. Aus "lösche heute" wird "lösche alles" — und die Antwort
// meldet weiterhin scope: "daily".
test('Operator-Objekt als Datum löscht NICHT die gesamte Historie', async () => {
  const token = await makeAdminToken();
  await seedLogs();
  await req('/api/reports/reset-logs', {
    method: 'POST', token, body: { scope: 'daily', date: { $ne: null } }
  });
  const rest = await DailyLog.countDocuments({});
  assert.equal(rest, 3, `${3 - rest} Log(s) wurden durch einen manipulierten "date"-Wert gelöscht`);
});

test('ungültiges Datumsformat wird mit 400 abgewiesen', async () => {
  const token = await makeAdminToken();
  await seedLogs();
  const r = await req('/api/reports/reset-logs', {
    method: 'POST', token, body: { scope: 'daily', date: 'nicht-ein-datum' }
  });
  assert.equal(r.status, 400);
  assert.equal(await DailyLog.countDocuments({}), 3);
});

test('Operator im Query-String von /export wird mit 400 abgewiesen', async () => {
  const token = await makeAdminToken();
  await seedLogs();
  const r = await req('/api/reports/export?type=excel&date[$ne]=x', { token });
  assert.equal(r.status, 400, 'Operator-Objekte dürfen nicht in die Mongo-Abfrage gelangen');
});

test('reset-logs ist ohne Token nicht erreichbar', async () => {
  await seedLogs();
  const r = await req('/api/reports/reset-logs', { method: 'POST', body: { scope: 'all' } });
  assert.equal(r.status, 401);
  assert.equal(await DailyLog.countDocuments({}), 3);
});
