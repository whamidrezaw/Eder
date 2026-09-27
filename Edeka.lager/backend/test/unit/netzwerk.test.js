'use strict';
//
// Auf welcher Adresse lauscht der Server, und wann ist TRUST_PROXY sicher?
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const { listenHost, checkProxyConfig } = require('../../lib/validate');

test('listenHost: ohne HOST nur die eigene Maschine', () => {
  assert.equal(listenHost({}), '127.0.0.1');
  assert.equal(listenHost({ HOST: '' }), '127.0.0.1');
  assert.equal(listenHost({ HOST: '   ' }), '127.0.0.1');
});

test('listenHost: ein bewusst gesetzter HOST gilt', () => {
  assert.equal(listenHost({ HOST: '0.0.0.0' }), '0.0.0.0');
  assert.equal(listenHost({ HOST: ' ::1 ' }), '::1');
});

test('checkProxyConfig: ohne TRUST_PROXY nie ein Problem', () => {
  assert.equal(checkProxyConfig({}), null);
  assert.equal(checkProxyConfig({ HOST: '0.0.0.0' }), null);
  assert.equal(checkProxyConfig({ TRUST_PROXY: 'false', HOST: '0.0.0.0' }), null);
});

test('checkProxyConfig: TRUST_PROXY hinter einem lokalen Tunnel ist in Ordnung', () => {
  assert.equal(checkProxyConfig({ TRUST_PROXY: 'true' }), null);
  assert.equal(checkProxyConfig({ TRUST_PROXY: 'TRUE', HOST: '::1' }), null);
  assert.equal(checkProxyConfig({ TRUST_PROXY: 'true', HOST: 'localhost' }), null);
});

test('checkProxyConfig: TRUST_PROXY bei einer App im Netz verweigert den Start', () => {
  for (const host of ['0.0.0.0', '::', '10.0.0.151']) {
    const problem = checkProxyConfig({ TRUST_PROXY: 'true', HOST: host });
    assert.ok(problem, `${host} wurde durchgelassen`);
    assert.match(problem, /X-Forwarded-For/);
  }
});

test('checkProxyConfig liest TRUST_PROXY genau wie app.js — kein Fehlalarm', () => {
  // app.js vergleicht ohne trim: " true" schaltet dort NICHTS ein. Meldete
  // die Prüfung hier trotzdem ein Problem, verweigerte der Server grundlos
  // den Start.
  assert.equal(checkProxyConfig({ TRUST_PROXY: ' true', HOST: '0.0.0.0' }), null);
});
