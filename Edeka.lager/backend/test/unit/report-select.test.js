'use strict';
const test   = require('node:test');
const assert = require('node:assert/strict');
const { pickDailyRepresentatives } = require('../../routes/reports').__test__;

const log = (date, type, iso) => ({ date, type, sentAt: new Date(iso) });

test('leere Eingabe ergibt leere Liste', () => {
  assert.deepEqual(pickDailyRepresentatives([]), []);
});

test('auto-midnight schlägt manual — unabhängig von der Reihenfolge', () => {
  const m = log('2026-05-01', 'manual',        '2026-05-01T08:00:00Z');
  const a = log('2026-05-01', 'auto-midnight', '2026-05-01T22:00:00Z');
  assert.equal(pickDailyRepresentatives([m, a])[0].type, 'auto-midnight');
  assert.equal(pickDailyRepresentatives([a, m])[0].type, 'auto-midnight');
});

test('ohne auto-midnight gewinnt der späteste manuelle Bericht', () => {
  const early = log('2026-05-02', 'manual', '2026-05-02T09:00:00Z');
  const late  = log('2026-05-02', 'manual', '2026-05-02T17:00:00Z');
  const [rep] = pickDailyRepresentatives([early, late]);
  assert.equal(rep.sentAt.toISOString(), '2026-05-02T17:00:00.000Z');
});

test('genau ein Eintrag pro Datum', () => {
  const logs = [
    log('2026-05-01', 'manual',        '2026-05-01T08:00:00Z'),
    log('2026-05-01', 'manual',        '2026-05-01T12:00:00Z'),
    log('2026-05-01', 'auto-midnight', '2026-05-01T22:00:00Z'),
    log('2026-05-02', 'manual',        '2026-05-02T09:00:00Z')
  ];
  const reps = pickDailyRepresentatives(logs);
  assert.equal(reps.length, 2);
  assert.equal(new Set(reps.map(r => r.date)).size, 2);
});

test('Ergebnis ist absteigend nach Datum sortiert', () => {
  const logs = [
    log('2026-04-30', 'manual', '2026-04-30T10:00:00Z'),
    log('2026-05-02', 'manual', '2026-05-02T10:00:00Z'),
    log('2026-05-01', 'manual', '2026-05-01T10:00:00Z')
  ];
  assert.deepEqual(pickDailyRepresentatives(logs).map(r => r.date),
                   ['2026-05-02', '2026-05-01', '2026-04-30']);
});

test('Verbrauch wird niemals doppelt gezählt (Kernregel)', () => {
  // Drei Berichte an einem Tag, jeder zeigt den KUMULATIVEN Verbrauch seit
  // Mitternacht. Summiert man sie, kommt 24 statt 14 heraus.
  const logs = [
    { date: '2026-05-01', type: 'manual', sentAt: new Date('2026-05-01T08:00:00Z'), snapshot: [{ consumed: 3 }] },
    { date: '2026-05-01', type: 'manual', sentAt: new Date('2026-05-01T13:00:00Z'), snapshot: [{ consumed: 7 }] },
    { date: '2026-05-01', type: 'manual', sentAt: new Date('2026-05-01T19:00:00Z'), snapshot: [{ consumed: 14 }] }
  ];
  const reps = pickDailyRepresentatives(logs);
  const total = reps.reduce((s, l) => s + l.snapshot.reduce((x, p) => x + p.consumed, 0), 0);
  assert.equal(total, 14);
});
