'use strict';
//
// „Bericht senden“, wenn Telegram nicht eingerichtet ist.
//
// Auf dem Server ist Telegram absichtlich nicht eingerichtet. Bis Phase I
// bekam trotzdem jeder, der „Bericht senden“ drückte, eine rote Meldung:
// „Telegram-Versand fehlgeschlagen: Telegram nicht konfiguriert (.env fehlt …)“
// — jedes Mal. Nicht eingerichtet ist kein Fehler: der Bericht wird
// gespeichert, ohne Warnung und ohne Versuch, Telegram zu erreichen. Ein
// gescheiterter Versand bei eingerichtetem Telegram bleibt eine Warnung (207).
//
// Telegram wird nie wirklich erreicht: eine Attrappe fängt nur Aufrufe an
// api.telegram.org ab — alle anderen (auch die dieses Tests an die App)
// gehen unverändert durch.
//
const test     = require('node:test');
const assert   = require('node:assert/strict');
const jwt      = require('jsonwebtoken');
const db       = require('../helpers/db');
const { start, stop, req } = require('../helpers/http');
const { makeUser, makeProduct } = require('../helpers/factories');
const DailyLog = require('../../models/DailyLog');

test.before(async () => { await db.connect(); await start(); });
test.after (async () => { await stop(); await db.disconnect(); });
test.beforeEach(async () => { await db.wipe(); });

const tokenFuer = (u) => jwt.sign({ id: u._id.toString() }, process.env.JWT_SECRET, { expiresIn: '1h' });
const echtesFetch = global.fetch;
const ENV = { token: process.env.TELEGRAM_BOT_TOKEN, chat: process.env.TELEGRAM_CHAT_ID };

function telegram(t, { token = '', chat = '', antwort }) {
  const aufrufe = [];
  process.env.TELEGRAM_BOT_TOKEN = token;
  process.env.TELEGRAM_CHAT_ID = chat;
  global.fetch = async (url, opts) => {
    if (!String(url).startsWith('https://api.telegram.org/')) return echtesFetch(url, opts);
    aufrufe.push({ url: String(url), body: JSON.parse(opts.body) });
    return antwort();
  };
  t.after(() => { global.fetch = echtesFetch; process.env.TELEGRAM_BOT_TOKEN = ENV.token; process.env.TELEGRAM_CHAT_ID = ENV.chat; });
  return aufrufe;
}

async function senden(name) {
  const u = await makeUser({ username: `${name}_tg`, name });
  await makeProduct({});
  const r = await req('/api/reports/send-now', { method: 'POST', token: tokenFuer(u) });
  return { r, logs: await DailyLog.find({}).lean() };
}

test('ohne Telegram: gespeichert, keine Warnung, kein Versuch', async (t) => {
  const aufrufe = telegram(t, { antwort: () => { throw new Error('darf nie aufgerufen werden'); } });
  const { r, logs } = await senden('kim');
  assert.equal(r.status, 201, JSON.stringify(r.body));
  assert.equal(r.body.telegram, 'aus');
  assert.equal(r.body.telegramError, undefined);
  assert.match(r.body.message, /gespeichert/);
  assert.doesNotMatch(r.body.message, /gesendet|fehlgeschlagen/);
  assert.equal(aufrufe.length, 0, 'ohne Einrichtung kein einziger Versuch, Telegram zu erreichen');
  assert.equal(logs.length, 1);
  assert.equal(logs[0].reportSent, false);
});

test('Telegram eingerichtet, Versand scheitert: gespeichert, aber eine Warnung (207)', async (t) => {
  const aufrufe = telegram(t, { token: 'test-token', chat: '42', antwort: () => { throw new Error('Netz weg'); } });
  const { r, logs } = await senden('lea');
  assert.equal(r.status, 207, JSON.stringify(r.body));
  assert.equal(r.body.telegram, 'fehler');
  assert.match(r.body.telegramError, /Netz weg/);
  assert.equal(aufrufe.length, 1);
  assert.equal(logs.length, 1);
  assert.equal(logs[0].reportSent, false);
});

test('Telegram eingerichtet, Versand klappt: gesendet und gespeichert', async (t) => {
  const aufrufe = telegram(t, { token: 'test-token', chat: '42',
    antwort: () => ({ ok: true, status: 200, json: async () => ({ ok: true, result: {} }) }) });
  const { r, logs } = await senden('max');
  assert.equal(r.status, 201, JSON.stringify(r.body));
  assert.equal(r.body.telegram, 'gesendet');
  assert.match(r.body.message, /gesendet und gespeichert/);
  assert.equal(aufrufe.length, 1);
  assert.equal(aufrufe[0].body.chat_id, '42');
  assert.equal(logs[0].reportSent, true);
});
