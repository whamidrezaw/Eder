'use strict';
//
// E2 — send-now und export werden je BENUTZER begrenzt: 10 je Minute.
//
// send-now löst jedes Mal einen Telegram-Aufruf und das Schreiben einer
// vollständigen Momentaufnahme aus; export baut eine komplette Excel-Datei.
// Beides ist heute unbegrenzt. Die Begrenzung gilt je Benutzer — alle
// Tests hier kommen von 127.0.0.1, eine Begrenzung je IP würde bernd also
// durch annas Aufrufe mitsperren. Genau das prüft jeweils der Schluss.
//
// Beide Tests sind ROT.
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const jwt    = require('jsonwebtoken');
const db     = require('../helpers/db');
const { start, stop, req } = require('../helpers/http');
const { makeUser, makeProduct } = require('../helpers/factories');

test.before(async () => { await db.connect(); await start(); });
test.after (async () => { await stop(); await db.disconnect(); });
test.beforeEach(async () => { await db.wipe(); });

// Direkt signiert statt über /login — der Login-Limiter soll hier nicht
// mitspielen. Dass dieser Weg trägt, hat E1 bereits belegt.
const tokenFuer = (u) => jwt.sign({ id: u._id.toString() }, process.env.JWT_SECRET, { expiresIn: '1h' });

async function zweiBenutzer() {
  const anna  = await makeUser({ username: 'anna_rl',  name: 'Anna'  });
  const bernd = await makeUser({ username: 'bernd_rl', name: 'Bernd' });
  return { anna: tokenFuer(anna), bernd: tokenFuer(bernd) };
}

// ── ROT ──
test('send-now: nach 10 Aufrufen in einer Minute ist Schluss — nur für diesen Benutzer', async () => {
  const { anna, bernd } = await zweiBenutzer();
  await makeProduct({ currentStock: 5 });

  const codes = [];
  for (let i = 0; i < 11; i++) {
    const r = await req('/api/reports/send-now', { method: 'POST', token: anna });
    codes.push(r.status);
  }
  assert.ok(codes[0] < 500, `send-now funktioniert im Test gar nicht (${codes[0]}) — bitte melden`);
  assert.ok(codes.slice(0, 10).every(c => c !== 429), `schon vor dem 11. Aufruf gesperrt: ${codes}`);
  assert.equal(codes[10], 429,
    `der 11. Aufruf ging durch (${codes}). Jeder Aufruf schreibt eine vollständige ` +
    `Momentaufnahme und ruft Telegram — heute beliebig oft hintereinander.`);

  const b = await req('/api/reports/send-now', { method: 'POST', token: bernd });
  assert.notEqual(b.status, 429, 'bernd wurde durch annas Aufrufe mitgesperrt — Begrenzung je IP statt je Benutzer');
});

// ── ROT ──
test('export: nach 10 Aufrufen in einer Minute ist Schluss — nur für diesen Benutzer', async () => {
  const { anna, bernd } = await zweiBenutzer();
  await makeProduct({ currentStock: 5 });

  const hole = async (token) => {
    const r = await req('/api/reports/export?type=excel', { token, raw: true });
    await r.res.arrayBuffer().catch(() => {});   // Antwort verbrauchen, Verbindung freigeben
    return r.status;
  };

  const codes = [];
  for (let i = 0; i < 11; i++) codes.push(await hole(anna));

  assert.ok(codes[0] < 500, `export funktioniert im Test gar nicht (${codes[0]}) — bitte melden`);
  assert.ok(codes.slice(0, 10).every(c => c !== 429), `schon vor dem 11. Aufruf gesperrt: ${codes}`);
  assert.equal(codes[10], 429,
    `der 11. Aufruf ging durch (${codes}). Jeder baut eine vollständige Excel-Datei.`);

  assert.notEqual(await hole(bernd), 429, 'bernd wurde durch annas Aufrufe mitgesperrt');
});
