'use strict';
const test   = require('node:test');
const assert = require('node:assert/strict');
const { findeOperatorSchluessel } = require('../../lib/sanitize');

test('harmlose Daten werden durchgelassen', () => {
  assert.equal(findeOperatorSchluessel({ name: 'Apfel', stock: 3 }), null);
  assert.equal(findeOperatorSchluessel({ liste: [{ a: 1 }, { b: 2 }] }), null);
  assert.equal(findeOperatorSchluessel({}), null);
  assert.equal(findeOperatorSchluessel({ datum: new Date() }), null);
});

test('Preise und Namen mit Punkt im WERT bleiben erlaubt', () => {
  assert.equal(findeOperatorSchluessel({ name: 'H.-Milch 3.5%' }), null);
});

test('Operator auf oberster Ebene wird gefunden', () => {
  assert.equal(findeOperatorSchluessel({ date: { $ne: null } }), '$ne');
});

test('Operator tief im Objekt wird gefunden', () => {
  assert.equal(findeOperatorSchluessel({ a: { b: { c: { $gt: '' } } } }), '$gt');
});

test('Operator in einem Array wird gefunden', () => {
  assert.equal(findeOperatorSchluessel({ liste: [{ ok: 1 }, { $where: 'x' }] }), '$where');
});

test('Punkt im SCHLÜSSEL wird abgewiesen', () => {
  assert.equal(findeOperatorSchluessel({ 'user.role': 'admin' }), 'user.role');
});
