'use strict';
const test   = require('node:test');
const assert = require('node:assert/strict');
const { start, stop, req } = require('../helpers/http');

test.before(async () => { await start(); });
test.after (async () => { await stop(); });

test('health antwortet — ohne Angaben zur Umgebung des Servers', async () => {
  const r = await req('/api/health');
  assert.equal(r.status, 200);
  assert.equal(r.body.status, 'ok');
  assert.equal(typeof r.body.uptime, 'number');
  assert.ok(!('env' in r.body), `verrät NODE_ENV: ${JSON.stringify(r.body)}`);
});
