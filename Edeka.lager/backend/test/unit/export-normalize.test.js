'use strict';
const test   = require('node:test');
const assert = require('node:assert/strict');
const { normalizeFromLiveProducts, normalizeFromSnapshot } = require('../../services/exportBuilder');

// Beide Funktionen speisen dieselben Excel-/PDF-Bauer. Weichen ihre
// Zeilenformen voneinander ab, sieht ein Live-Export anders aus als der
// Export desselben Bestands aus der Historie.
test('beide Quellen erzeugen dieselben Felder', () => {
  const live = normalizeFromLiveProducts([
    { name: 'Apfel', emoji: '🍎', category: 'Obst', unit: 'kg', isBio: true, currentStock: 4, yesterdayStock: 9 }
  ]);
  const snap = normalizeFromSnapshot([
    { productName: 'Apfel', emoji: '🍎', category: 'Obst', unit: 'kg', isBio: true, closingStock: 4, consumed: 5 }
  ]);
  assert.deepEqual(Object.keys(live[0]).sort(), Object.keys(snap[0]).sort());
  assert.deepEqual(live[0], snap[0]);
});

test('fehlende Werte bekommen Standardwerte statt undefined', () => {
  const [row] = normalizeFromLiveProducts([{ name: 'X' }]);
  assert.equal(row.emoji, '📦');
  assert.equal(row.category, 'Sonstige');
  assert.equal(row.unit, 'Kiste');
  assert.equal(row.stock, 0);
  assert.equal(row.consumed, 0);
});

test('Auffüllen ergibt Verbrauch 0, nicht negativ', () => {
  const [row] = normalizeFromLiveProducts([{ name: 'X', currentStock: 20, yesterdayStock: 5 }]);
  assert.equal(row.consumed, 0);
});
