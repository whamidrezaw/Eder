'use strict';
//
// E2 — zusätzlich eine hohe Decke je IP.
//
// Ohne sie könnte jemand von einer Adresse aus viele verschiedene
// Benutzernamen durchprobieren, jeden zehnmal. Die Decke liegt im Betrieb
// hoch genug, dass eine Filiale sie nie erreicht; hier wird sie über
// LOGIN_IP_LIMIT niedrig gestellt, damit der Test in Sekunden läuft.
//
// Die Variable MUSS vor dem ersten require der App gesetzt sein.
process.env.LOGIN_IP_LIMIT = '15';

const test   = require('node:test');
const assert = require('node:assert/strict');
const db     = require('../helpers/db');
const { start, stop } = require('../helpers/http');
const { login } = require('../helpers/factories');

test.before(async () => { await db.connect(); await db.wipe(); await start(); });
test.after (async () => { await stop(); await db.disconnect(); });

// ── ROT ──
test('viele verschiedene Benutzernamen von einer Adresse stoßen an die Decke', async () => {
  const codes = [];
  for (let i = 1; i <= 16; i++) {
    // Jeder Name nur einmal — die Begrenzung je Name greift also nie.
    codes.push((await login(`niemand_${i}`, 'egal')).status);
  }

  assert.ok(codes.slice(0, 15).every(c => c !== 429),
    `vor Erreichen der Decke gesperrt: ${codes}. Heute zählt der Limiter ` +
    `je IP mit Grenze 10 — verschiedene Benutzer blockieren sich gegenseitig.`);
  assert.equal(codes[15], 429, `die Decke greift nicht: ${codes}`);
});
