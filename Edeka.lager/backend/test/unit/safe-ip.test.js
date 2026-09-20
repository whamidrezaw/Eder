'use strict';
const test   = require('node:test');
const assert = require('node:assert/strict');
const { safeIp } = require('../../routes/auth').__test__;

test('gültige IPv4 wird übernommen', () => {
  assert.equal(safeIp('192.168.1.10'), '192.168.1.10');
});

test('Oktett über 255 wird verworfen', () => {
  assert.equal(safeIp('999.1.1.1'), '');
});

test('gültige IPv6 wird übernommen', () => {
  assert.equal(safeIp('2001:db8::1'), '2001:db8::1');
});

test('gefälschter/unsinniger Wert wird verworfen', () => {
  assert.equal(safeIp('<script>alert(1)</script>'), '');
  assert.equal(safeIp('not-an-ip'), '');
});

test('leere Eingaben ergeben einen leeren String', () => {
  assert.equal(safeIp(undefined), '');
  assert.equal(safeIp(null), '');
  assert.equal(safeIp(''), '');
});

test('überlange Eingabe wird verworfen', () => {
  assert.equal(safeIp('a:'.repeat(40)), '');
});

// Node liefert IPv4-Clients auf einem Dual-Stack-Socket in dieser Form.
// Bewusste Entscheidung: auf reine IPv4 zurückführen, damit der
// Login-Verlauf einheitlich bleibt.
test('IPv4-mapped IPv6 wird zu reiner IPv4 normalisiert', () => {
  assert.equal(safeIp('::ffff:127.0.0.1'), '127.0.0.1');
  assert.equal(safeIp('::ffff:192.168.1.10'), '192.168.1.10');
});

test('echte IPv6 bleibt unverändert', () => {
  assert.equal(safeIp('2001:db8::1'), '2001:db8::1');
});

test('ungültige IPv4 hinter ::ffff: wird verworfen', () => {
  assert.equal(safeIp('::ffff:999.1.1.1'), '');
});
