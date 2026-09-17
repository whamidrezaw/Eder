'use strict';
const test   = require('node:test');
const assert = require('node:assert/strict');
const db     = require('../helpers/db');
const Category = require('../../models/Category');
const { start, stop, req } = require('../helpers/http');
const { makeAdminToken, makeLageristToken } = require('../helpers/factories');

test.before(async () => { await db.connect(); await start(); });
test.after (async () => { await stop(); await db.disconnect(); });
test.beforeEach(async () => { await db.wipe(); });

// Diese Datei hält den BEABSICHTIGTEN Rechte-Zuschnitt fest, damit ihn
// niemand später versehentlich "härtet". Lageristen dürfen Kategorien und
// Einheiten anlegen; nur Admins dürfen sie ändern oder löschen.

test('Lagerist DARF eine Kategorie anlegen (so gewollt)', async () => {
  const token = await makeLageristToken();
  const r = await req('/api/categories', { method: 'POST', token, body: { name: 'Nüsse' } });
  assert.equal(r.status, 201);
});

test('Lagerist DARF eine Einheit anlegen (so gewollt)', async () => {
  const token = await makeLageristToken();
  const r = await req('/api/units', { method: 'POST', token, body: { name: 'Palette' } });
  assert.equal(r.status, 201);
});

test('Lagerist darf eine Kategorie NICHT ändern', async () => {
  const token = await makeLageristToken();
  const cat = await Category.create({ name: 'Obst', emoji: '🍎' });
  const r = await req(`/api/categories/${cat._id}`, { method: 'PUT', token, body: { name: 'Neu' } });
  assert.equal(r.status, 403);
});

test('Lagerist darf eine Kategorie NICHT löschen', async () => {
  const token = await makeLageristToken();
  const cat = await Category.create({ name: 'Obst', emoji: '🍎' });
  const r = await req(`/api/categories/${cat._id}`, { method: 'DELETE', token });
  assert.equal(r.status, 403);
});

test('Lagerist erreicht die Benutzerverwaltung nicht', async () => {
  const token = await makeLageristToken();
  assert.equal((await req('/api/users', { token })).status, 403);
});

test('Admin erreicht die Benutzerverwaltung', async () => {
  const token = await makeAdminToken();
  assert.equal((await req('/api/users', { token })).status, 200);
});

test('Lagerist darf Bestände nicht zurücksetzen', async () => {
  const token = await makeLageristToken();
  const r = await req('/api/reports/reset-stock', { method: 'POST', token, body: {} });
  assert.equal(r.status, 403);
});
