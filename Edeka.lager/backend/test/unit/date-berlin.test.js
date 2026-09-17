'use strict';
const test   = require('node:test');
const assert = require('node:assert/strict');
const { berlinDateString, yesterdayInBerlin } = require('../../services/dailyClose');

test('berlinDateString: gewöhnlicher Wintertag', () => {
  assert.equal(berlinDateString(new Date('2026-02-10T12:00:00Z')), '2026-02-10');
});

test('berlinDateString: später UTC-Zeitpunkt liegt in Berlin schon am Folgetag', () => {
  // 22:30 UTC im Sommer = 00:30 CEST am nächsten Tag
  assert.equal(berlinDateString(new Date('2026-07-15T22:30:00Z')), '2026-07-16');
});

test('berlinDateString: Sommerzeitumstellung (Umstellung 29.03.2026)', () => {
  assert.equal(berlinDateString(new Date('2026-03-29T00:30:00Z')), '2026-03-29'); // noch CET
  assert.equal(berlinDateString(new Date('2026-03-29T22:30:00Z')), '2026-03-30'); // schon CEST
});

test('berlinDateString: Winterzeitumstellung (Umstellung 25.10.2026)', () => {
  assert.equal(berlinDateString(new Date('2026-10-24T22:30:00Z')), '2026-10-25');
  assert.equal(berlinDateString(new Date('2026-10-25T00:30:00Z')), '2026-10-25');
});

test('yesterdayInBerlin: gewöhnlicher Tag', (t) => {
  t.mock.timers.enable({ apis: ['Date'], now: Date.parse('2026-05-12T09:00:00Z') });
  assert.equal(yesterdayInBerlin(), '2026-05-11');
});

test('yesterdayInBerlin: Jahreswechsel', (t) => {
  t.mock.timers.enable({ apis: ['Date'], now: Date.parse('2026-01-01T00:30:00Z') });
  assert.equal(yesterdayInBerlin(), '2025-12-31');
});

test('yesterdayInBerlin: Monatswechsel (1. März -> 28. Februar)', (t) => {
  t.mock.timers.enable({ apis: ['Date'], now: Date.parse('2026-03-01T10:00:00Z') });
  assert.equal(yesterdayInBerlin(), '2026-02-28');
});

test('yesterdayInBerlin: Nacht der Sommerzeitumstellung', (t) => {
  // 22:30 UTC am 29.03. = 00:30 CEST am 30.03. -> der zu schließende Tag ist der 29.
  t.mock.timers.enable({ apis: ['Date'], now: Date.parse('2026-03-29T22:30:00Z') });
  assert.equal(yesterdayInBerlin(), '2026-03-29');
});

test('yesterdayInBerlin: Nacht der Winterzeitumstellung', (t) => {
  t.mock.timers.enable({ apis: ['Date'], now: Date.parse('2026-10-24T23:30:00Z') });
  assert.equal(yesterdayInBerlin(), '2026-10-24');
});
