'use strict';
//
// server.js als echter Prozess: Auf welcher Adresse lauscht er, was tut er
// bei belegtem Port, und verweigert er eine unsichere Proxy-Einstellung?
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const net    = require('node:net');
const path   = require('node:path');
const { spawn } = require('node:child_process');

const BACKEND = path.join(__dirname, '../..');
const GEHEIM  = 'test-only-secret-0123456789-nicht-in-produktion-verwenden';

function freierPort() {
  return new Promise((resolve) => {
    const s = net.createServer();
    s.listen(0, '127.0.0.1', () => { const p = s.address().port; s.close(() => resolve(p)); });
  });
}

// Alle Werte, die zählen, ausdrücklich gesetzt: dotenv überschreibt sie
// nicht. Sonst zöge der Test auf dem Server Werte aus der echten .env.
function starte(env, { bisZeile = null, zeitlimit = 6000 } = {}) {
  return new Promise((resolve) => {
    const kind = spawn(process.execPath, ['-r', './test/helpers/ohne-db.js', 'server.js'], {
      cwd: BACKEND,
      env: {
        PATH: process.env.PATH, NODE_ENV: 'test', JWT_SECRET: GEHEIM,
        MONGODB_URI: 'mongodb://127.0.0.1:1/unbenutzt', TRUST_PROXY: 'false', HOST: '',
        TELEGRAM_BOT_TOKEN: '', TELEGRAM_CHAT_ID: '', ...env
      }
    });
    let aus = '', err = '';
    const uhr = setTimeout(() => kind.kill(), zeitlimit);
    kind.stdout.on('data', (d) => { aus += d; if (bisZeile && bisZeile.test(aus)) kind.kill(); });
    kind.stderr.on('data', (d) => { err += d; });
    kind.on('exit', (code) => { clearTimeout(uhr); resolve({ code, aus, err }); });
  });
}

test('ohne HOST lauscht der Server nur auf 127.0.0.1', async () => {
  const port = await freierPort();
  const r = await starte({ PORT: String(port) }, { bisZeile: /Server läuft/ });
  assert.match(r.aus, new RegExp(`Server läuft auf 127\\.0\\.0\\.1:${port}`), r.aus + r.err);
});

test('bei belegtem Port meldet er das und endet — statt Erfolg vorzutäuschen', async () => {
  const belegt = net.createServer();
  await new Promise((r) => { belegt.listen(0, '127.0.0.1', r); });
  const port = belegt.address().port;
  try {
    const r = await starte({ PORT: String(port) });
    assert.doesNotMatch(r.aus, /Server läuft/, 'meldete Erfolg, obwohl er nicht lauschen konnte');
    assert.equal(r.code, 1, 'der Prozess lief weiter, ohne etwas auszuliefern');
    assert.match(r.err, /Kann nicht auf 127\.0\.0\.1:\d+ lauschen: EADDRINUSE/);
  } finally {
    await new Promise((r) => { belegt.close(r); });
  }
});

test('TRUST_PROXY=true bei einer App im Netz: Start verweigert', async () => {
  const r = await starte({ TRUST_PROXY: 'true', HOST: '0.0.0.0', PORT: String(await freierPort()) });
  assert.doesNotMatch(r.aus, /Server läuft/);
  assert.equal(r.code, 1);
  assert.match(r.err, /X-Forwarded-For/);
});

test('TRUST_PROXY=true hinter dem lokalen Tunnel: startet normal', async () => {
  const port = await freierPort();
  const r = await starte({ TRUST_PROXY: 'true', PORT: String(port) }, { bisZeile: /Server läuft/ });
  assert.match(r.aus, /Server läuft auf 127\.0\.0\.1/, r.aus + r.err);
});
