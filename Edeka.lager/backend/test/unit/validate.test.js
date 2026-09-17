'use strict';
const test   = require('node:test');
const assert = require('node:assert/strict');
const { parseIsoDate, parseStock, normalizeIp, checkJwtSecret } = require('../../lib/validate');

test('parseIsoDate nimmt gültige Datumsangaben an', () => {
  assert.equal(parseIsoDate('2026-05-02'), '2026-05-02');
  assert.equal(parseIsoDate('  2026-12-31  '), '2026-12-31');
});

test('parseIsoDate lehnt Mongo-Operatoren ab', () => {
  assert.equal(parseIsoDate({ $ne: null }), null);
  assert.equal(parseIsoDate({ $gt: '' }),   null);
  assert.equal(parseIsoDate(['2026-05-02']), null);
});

test('parseIsoDate lehnt falsche Formate und unmögliche Tage ab', () => {
  assert.equal(parseIsoDate('02.05.2026'), null);
  assert.equal(parseIsoDate('2026-5-2'),   null);
  assert.equal(parseIsoDate('2026-02-30'), null);
  assert.equal(parseIsoDate('2026-13-01'), null);
  assert.equal(parseIsoDate(''),   null);
  assert.equal(parseIsoDate(null), null);
});

test('parseStock nimmt Zahlen und numerische Strings an', () => {
  assert.equal(parseStock(0),     0);
  assert.equal(parseStock(12),    12);
  assert.equal(parseStock('7'),   7);
  assert.equal(parseStock('2.5'), 2.5);
  assert.equal(parseStock('2,5'), 2.5);
});

test('parseStock lehnt genau die Werte ab, die vorher durchgerutscht sind', () => {
  assert.equal(parseStock([]),      null, 'Number([]) ist 0 — das war die Lücke');
  assert.equal(parseStock(['5']),   null, 'Number(["5"]) ist 5');
  assert.equal(parseStock({}),      null);
  assert.equal(parseStock(null),    null);
  assert.equal(parseStock(true),    null);
  assert.equal(parseStock('abc'),   null);
  assert.equal(parseStock(''),      null);
  assert.equal(parseStock(-1),      null);
  assert.equal(parseStock(Infinity),null);
  assert.equal(parseStock(NaN),     null);
});

test('normalizeIp führt IPv4-mapped auf reine IPv4 zurück', () => {
  assert.equal(normalizeIp('::ffff:127.0.0.1'),    '127.0.0.1');
  assert.equal(normalizeIp('::FFFF:192.168.1.10'), '192.168.1.10');
});

test('normalizeIp lässt gültige Adressen unverändert', () => {
  assert.equal(normalizeIp('192.168.1.10'), '192.168.1.10');
  assert.equal(normalizeIp('2001:db8::1'),  '2001:db8::1');
});

test('normalizeIp verwirft Unbrauchbares', () => {
  assert.equal(normalizeIp('999.1.1.1'),       '');
  assert.equal(normalizeIp('::ffff:999.1.1.1'),'');
  assert.equal(normalizeIp('<script>'),        '');
  assert.equal(normalizeIp(undefined),         '');
  assert.equal(normalizeIp('a:'.repeat(40)),   '');
});

test('checkJwtSecret bemängelt fehlende, kurze und Beispiel-Schlüssel', () => {
  assert.ok(checkJwtSecret(undefined));
  assert.ok(checkJwtSecret(''));
  assert.ok(checkJwtSecret('kurz'));
  assert.ok(checkJwtSecret('ein-sehr-langer-zufaelliger-string-hier-einfuegen'));
});

test('checkJwtSecret akzeptiert einen echten Schlüssel', () => {
  const echt = require('crypto').randomBytes(48).toString('base64url');
  assert.equal(checkJwtSecret(echt), null);
});
