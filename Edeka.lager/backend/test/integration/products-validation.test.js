'use strict';
const test   = require('node:test');
const assert = require('node:assert/strict');
const db     = require('../helpers/db');
const Category = require('../../models/Category');
const Unit     = require('../../models/Unit');
const { start, stop, req } = require('../helpers/http');
const { makeLageristToken, makeProduct } = require('../helpers/factories');

test.before(async () => { await db.connect(); await start(); });
test.after (async () => { await stop(); await db.disconnect(); });
test.beforeEach(async () => {
  await db.wipe();
  await Category.create({ name: 'Obst', emoji: '🍎' });
  await Unit.create({ name: 'Kiste' });
});

const base = { name: 'Apfel', category: 'Obst', unit: 'Kiste', emoji: '🍎' };

test('PATCH /stock weist nicht-numerische Werte ab', async () => {
  const token = await makeLageristToken();
  const p = await makeProduct();
  for (const bad of ['abc', null, {}, [], 'NaN']) {
    const r = await req(`/api/products/${p._id}/stock`, { method: 'PATCH', token, body: { currentStock: bad } });
    assert.equal(r.status, 400, `Wert ${JSON.stringify(bad)} hätte abgelehnt werden müssen`);
  }
});

test('PATCH /stock weist negative Werte ab', async () => {
  const token = await makeLageristToken();
  const p = await makeProduct();
  const r = await req(`/api/products/${p._id}/stock`, { method: 'PATCH', token, body: { currentStock: -5 } });
  assert.equal(r.status, 400);
});

test('unbekannte Kategorie wird abgewiesen', async () => {
  const token = await makeLageristToken();
  const r = await req('/api/products', { method: 'POST', token, body: { ...base, category: 'Gibtesnicht' } });
  assert.equal(r.status, 400);
});

test('dieselbe Variante zweimal anzulegen schlägt fehl', async () => {
  const token = await makeLageristToken();
  assert.equal((await req('/api/products', { method: 'POST', token, body: base })).status, 201);
  assert.equal((await req('/api/products', { method: 'POST', token, body: base })).status, 400);
});

// ── ROT: uneinheitliche Validierung (Batch A) ────────────────────────
// PATCH /stock prüft sauber auf eine endliche, nicht-negative Zahl.
// POST /products macht dagegen `Number(currentStock) || 0` — "abc" wird
// stillschweigend zu 0. Zwei Endpunkte, dasselbe Feld, zwei Regeln.
test('POST /products weist ungültigen Anfangsbestand ab statt ihn zu 0 zu machen', async () => {
  const token = await makeLageristToken();
  const r = await req('/api/products', { method: 'POST', token, body: { ...base, currentStock: 'abc' } });
  assert.equal(r.status, 400, `stattdessen ${r.status} — der Wert wurde still zu ${r.body && r.body.currentStock}`);
});

test('POST /products weist negativen Anfangsbestand ab', async () => {
  const token = await makeLageristToken();
  const r = await req('/api/products', { method: 'POST', token, body: { ...base, currentStock: -3 } });
  assert.equal(r.status, 400);
});
