'use strict';
//
// E2 — die REIHENFOLGE der beiden Login-Stufen.
//
// Beim Entwurf fiel auf: login-limit-user.test.js würde eine vertauschte
// Reihenfolge NICHT bemerken. Dort versucht es anna zehnmal, die IP-Decke
// liegt bei 100 — die wird nie erreicht, egal in welcher Reihenfolge.
//
// Steht die IP-Decke vorn, zählt jeder schon abgewiesene Versuch weiter auf
// sie. Dann genügt EIN Kollege, der dreißigmal klickt, und die ganze Filiale
// ist wieder ausgesperrt — der Fehler, den E2 beheben soll, käme durch die
// Hintertür zurück. Mit Decke 15 macht dieser Test genau das sichtbar.
//
process.env.LOGIN_IP_LIMIT = '15';

const test   = require('node:test');
const assert = require('node:assert/strict');
const db     = require('../helpers/db');
const { start, stop } = require('../helpers/http');
const { makeUser, login } = require('../helpers/factories');

test.before(async () => { await db.connect(); await db.wipe(); await start(); });
test.after (async () => { await stop(); await db.disconnect(); });

test('wer dreißigmal klickt, sperrt die anderen nicht über die IP-Decke aus', async () => {
  await makeUser({ username: 'anna' });
  await makeUser({ username: 'bernd' });

  for (let i = 0; i < 30; i++) await login('anna', 'vertippt');

  const b = await login('bernd');
  assert.equal(b.status, 200,
    `bernd bekam ${b.status}. annas abgewiesene Versuche zählen auf die IP-Decke — ` +
    `die Stufe je Benutzername muss VOR der Decke je IP stehen.`);
});
