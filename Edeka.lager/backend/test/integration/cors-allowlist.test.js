'use strict';
//
// E3 — wer eine fremde Origin braucht (etwa einen eigenen
// Entwicklungsserver), trägt sie in CORS_ORIGINS ein. Ohne Codeänderung.
//
// Die Variable MUSS vor dem ersten require der App gesetzt sein.
process.env.CORS_ORIGINS = 'https://erlaubt.example, https://auch-erlaubt.example';

const test   = require('node:test');
const assert = require('node:assert/strict');
const { start, stop, req } = require('../helpers/http');

test.before(async () => { await start(); });
test.after (async () => { await stop(); });

// Leitplanken: heute grün (alles ist erlaubt), und müssen es bleiben.
test('eine eingetragene Origin bekommt ihre Freigabe', async () => {
  const r = await req('/api/health', { headers: { Origin: 'https://erlaubt.example' } });
  assert.equal(r.headers.get('access-control-allow-origin'), 'https://erlaubt.example');
});

test('mehrere Einträge, durch Komma getrennt, funktionieren alle', async () => {
  const r = await req('/api/health', { headers: { Origin: 'https://auch-erlaubt.example' } });
  assert.equal(r.headers.get('access-control-allow-origin'), 'https://auch-erlaubt.example');
});

// ── ROT ──
test('eine nicht eingetragene Origin bleibt trotzdem draußen', async () => {
  const r = await req('/api/health', { headers: { Origin: 'https://evil.example' } });
  assert.notEqual(r.headers.get('access-control-allow-origin'), 'https://evil.example');
});
