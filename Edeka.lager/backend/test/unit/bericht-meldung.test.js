'use strict';
//
// Was der Browser nach „Bericht senden“ zeigt.
//
// Ohne eingerichtetes Telegram meldet der Server telegram: "aus". Dann ist
// die Meldung grün — „Bericht gespeichert“ —, und nirgends steht „gesendet“:
// es wurde ja nichts gesendet. Nur ein echter Fehler beim Versand ist rot.
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const { ladeShared, antwort } = require('../helpers/browser');

async function meldungen(status, koerper) {
  const b = ladeShared({ token: 'x', fetchStub: async () => antwort(status, koerper) });
  const gezeigt = [];
  b.sandbox.showToast = (text, art) => gezeigt.push([art, text]);
  await b.sandbox.sendReportNow();
  return gezeigt;
}

test('ohne Telegram: grün „Bericht gespeichert“ — kein Rot, kein „gesendet“', async () => {
  const m = await meldungen(201, { message: '✅ Bericht gespeichert', telegram: 'aus', log: {} });
  assert.deepEqual(m.at(-1), ['ok', '✅ Bericht gespeichert!']);
  assert.ok(!m.some(([art]) => art === 'err'), JSON.stringify(m));
  assert.ok(!m.some(([, text]) => /gesendet/.test(text)), JSON.stringify(m));
});

test('Versand gescheitert: weiterhin die Warnung', async () => {
  const m = await meldungen(207, { telegram: 'fehler', telegramError: 'Netz weg', log: {} });
  assert.deepEqual(m.at(-1), ['err', '⚠️ Bericht gespeichert, Telegram-Versand fehlgeschlagen: Netz weg']);
});

test('gesendet: grün „gesendet und gespeichert“', async () => {
  const m = await meldungen(201, { telegram: 'gesendet', log: {} });
  assert.deepEqual(m.at(-1), ['ok', '✅ Bericht gesendet und gespeichert!']);
});
