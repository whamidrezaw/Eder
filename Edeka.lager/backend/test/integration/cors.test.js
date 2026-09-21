'use strict';
//
// E3 — CORS.
//
// CORS entscheidet, welche ANDEREN Websites aus dem Browser heraus mit dieser
// API sprechen dürfen. Heute: alle. Das Frontend wird von derselben Adresse
// ausgeliefert und braucht diese Erlaubnis gar nicht.
//
// Ehrlich eingeordnet: das Risiko ist hier gering. Angemeldet wird über
// einen Bearer-Header, nicht über ein Cookie, und sessionStorage ist an die
// eigene Origin gebunden — eine fremde Seite kommt an das Token nicht heran.
// Das Schließen ist Verteidigung in der Tiefe, keine Behebung eines offenen
// Lecks.
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const { start, stop, req } = require('../helpers/http');

test.before(async () => { await start(); });
test.after (async () => { await stop(); });

const FREMD = 'https://evil.example';

// Leitplanke: das eigene Frontend darf nicht leiden.
test('Anfragen von der eigenen Adresse funktionieren unverändert', async () => {
  const r = await req('/api/health');
  assert.equal(r.status, 200, r.text);
});

// ── ROT ──
test('eine fremde Website bekommt keine Freigabe', async () => {
  const r = await req('/api/health', { headers: { Origin: FREMD } });
  const freigabe = r.headers.get('access-control-allow-origin');
  assert.notEqual(freigabe, FREMD, 'die fremde Origin wird heute einfach zurückgespiegelt');
  assert.notEqual(freigabe, '*', 'Freigabe für alle');
});

// ── ROT ──
test('auch die Vorabanfrage einer fremden Website wird nicht freigegeben', async () => {
  // Bevor ein Browser eine PATCH-Anfrage mit Authorization-Header von einer
  // fremden Seite schickt, fragt er per OPTIONS um Erlaubnis.
  const r = await req('/api/products', {
    method: 'OPTIONS',
    headers: {
      Origin: FREMD,
      'Access-Control-Request-Method': 'PATCH',
      'Access-Control-Request-Headers': 'authorization,content-type'
    }
  });
  assert.notEqual(r.headers.get('access-control-allow-origin'), FREMD,
    'die Vorabanfrage einer fremden Seite wird heute bewilligt');
});
