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

// ── ROT: Fehler, der in Batch A behoben wird ─────────────────────────
// Node liefert IPv4-Clients auf einem Dual-Stack-Socket als "::ffff:1.2.3.4".
// safeIp() verwirft diese Form, weil sie Punkte enthält und damit an der
// IPv6-Prüfung (/^[0-9a-fA-F:]+$/) scheitert. Ergebnis: Der Login-Verlauf
// speichert für die meisten echten Logins eine leere IP.
test('IPv4-mapped IPv6 wird akzeptiert (Node liefert diese Form)', () => {
  assert.equal(safeIp('::ffff:127.0.0.1'), '::ffff:127.0.0.1');
});
