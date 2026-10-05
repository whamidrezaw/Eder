'use strict';
//
// tools/alarm.sh — Lebenszeichen und Fehlermeldungen an Healthchecks.io.
//
// Geprüft gegen einen nachgebauten Healthchecks.io-Server, eine nachgebaute
// App und echte HTTPS-Server mit selbst ausgestellten Zertifikaten:
// jede Meldung geht per POST an die richtige Prüfung; ein Fehler geht an
// …/fail; vom Protokoll der App verlässt nichts den Server; die geheimen
// Ping-Adressen erscheinen in keiner Ausgabe.
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const fs     = require('node:fs');
const os     = require('node:os');
const path   = require('node:path');
const http   = require('node:http');
const https  = require('node:https');
const { spawn, spawnSync } = require('node:child_process');

const SKRIPT = path.join(__dirname, '../../../../tools/alarm.sh');
const vorhanden = (cmd) => spawnSync('sh', ['-c', `command -v ${cmd}`]).status === 0;
const OHNE = ['bash', 'curl', 'openssl'].every(vorhanden) ? false : 'curl oder openssl fehlt';

function lauschen(server) {
  return new Promise((ok) => { server.listen(0, '127.0.0.1', () => ok(server.address().port)); });
}

// Ein nachgebautes Healthchecks.io: merkt sich jede Anfrage.
async function hcNachbau(t) {
  const anfragen = [];
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', (c) => { body += c; });
    req.on('end', () => { anfragen.push({ method: req.method, pfad: req.url, body }); res.end('OK'); });
  });
  const port = await lauschen(server);
  t.after(() => server.close());
  const basis = `http://127.0.0.1:${port}/ping`;
  return {
    anfragen,
    env: {
      HC_SICHERUNG: `${basis}/aaaa-sicherung`, HC_EXTERN: `${basis}/bbbb-extern`,
      HC_APP: `${basis}/cccc-app`, HC_ZERTIFIKAT: `${basis}/dddd-zertifikat`
    }
  };
}

function lauf(env, ...args) {
  return new Promise((ok) => {
    const kind = spawn('bash', [SKRIPT, ...args], {
      env: { PATH: env.PATH || process.env.PATH, HOME: os.tmpdir(), ALARM_KONF: '/nicht/vorhanden', ...env }
    });
    let stdout = '', stderr = '';
    kind.stdout.on('data', (c) => { stdout += c; });
    kind.stderr.on('data', (c) => { stderr += c; });
    kind.on('close', (status) => ok({ status, stdout, stderr }));
  });
}

// Keine geheime Ping-Adresse in irgendeiner Ausgabe.
function ohneGeheimnis(r, hc) {
  for (const url of Object.values(hc.env)) {
    const geheim = url.split('/').pop();
    assert.ok(!r.stdout.includes(geheim) && !r.stderr.includes(geheim), `Ausgabe enthält ${geheim}`);
  }
}

test('ok: Lebenszeichen per POST an die richtige Prüfung', { skip: OHNE }, async (t) => {
  const hc = await hcNachbau(t);
  for (const [pruefung, pfad] of [['sicherung', '/ping/aaaa-sicherung'], ['extern', '/ping/bbbb-extern']]) {
    const r = await lauf(hc.env, 'ok', pruefung);
    assert.equal(r.status, 0, r.stderr);
    const a = hc.anfragen.at(-1);
    assert.deepEqual([a.method, a.pfad], ['POST', pfad]);
    ohneGeheimnis(r, hc);
  }
});

test('unbekannte Prüfung, unbekannte Einheit, fehlende Adresse: Abbruch ohne Meldung', { skip: OHNE }, async (t) => {
  const hc = await hcNachbau(t);
  const ohneSicherung = { ...hc.env, HC_SICHERUNG: '' };
  for (const [env, args] of [[hc.env, ['ok', 'gibt-es-nicht']],
                             [hc.env, ['fehlgeschlagen', 'fremd.service']],
                             [ohneSicherung, ['ok', 'sicherung']],
                             [hc.env, ['quatsch']]]) {
    const r = await lauf(env, ...args);
    assert.notEqual(r.status, 0, `angenommen: ${args.join(' ')}`);
    ohneGeheimnis(r, hc);
  }
  assert.equal(hc.anfragen.length, 0);
});

function mitJournal(t, zeilen) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'journal-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  fs.writeFileSync(path.join(dir, 'journalctl'), `#!/bin/sh\nprintf '%s\\n' ${zeilen.map((z) => `'${z}'`).join(' ')}\n`, { mode: 0o755 });
  return `${dir}:${process.env.PATH}`;
}

test('fehlgeschlagen: Sicherungsdienste melden ihre letzten Protokollzeilen an …/fail', { skip: OHNE }, async (t) => {
  const hc = await hcNachbau(t);
  const PATH = mitJournal(t, ['mongodump für edeka_lager fehlgeschlagen.']);
  for (const [einheit, pfad] of [['edeka-sicherung.service', '/ping/aaaa-sicherung/fail'],
                                 ['edeka-extern.service', '/ping/bbbb-extern/fail']]) {
    const r = await lauf({ ...hc.env, PATH }, 'fehlgeschlagen', einheit);
    assert.equal(r.status, 0, r.stderr);
    const a = hc.anfragen.at(-1);
    assert.deepEqual([a.method, a.pfad], ['POST', pfad]);
    assert.match(a.body, new RegExp(einheit.replace('.', '\\.')));
    assert.match(a.body, /mongodump für edeka_lager fehlgeschlagen/);
  }
});

test('fehlgeschlagen: vom Protokoll der App verlässt NICHTS den Server', { skip: OHNE }, async (t) => {
  const hc = await hcNachbau(t);
  const PATH = mitJournal(t, ['Anmeldung fehlgeschlagen für benutzer anna.schmidt']);
  const r = await lauf({ ...hc.env, PATH }, 'fehlgeschlagen', 'edeka-lager.service');
  assert.equal(r.status, 0, r.stderr);
  const a = hc.anfragen.at(-1);
  assert.deepEqual([a.method, a.pfad], ['POST', '/ping/cccc-app/fail']);
  assert.match(a.body, /edeka-lager\.service/);
  assert.match(a.body, /journalctl -u edeka-lager/);
  assert.doesNotMatch(a.body, /anna/);
});

test('herzschlag: gesund → Lebenszeichen, krank oder weg → …/fail mit Grund', { skip: OHNE }, async (t) => {
  const hc = await hcNachbau(t);
  let antwort = { code: 200, body: '{"status":"ok"}' };
  const app = http.createServer((req, res) => { res.statusCode = antwort.code; res.end(antwort.body); });
  const port = await lauschen(app);
  t.after(() => app.close());
  const env = { ...hc.env, APP_URL: `http://127.0.0.1:${port}` };

  let r = await lauf(env, 'herzschlag');
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual([hc.anfragen.at(-1).method, hc.anfragen.at(-1).pfad], ['POST', '/ping/cccc-app']);

  antwort = { code: 503, body: 'Bad Gateway' };
  r = await lauf(env, 'herzschlag');
  assert.equal(r.status, 0, r.stderr);
  assert.equal(hc.anfragen.at(-1).pfad, '/ping/cccc-app/fail');
  assert.match(hc.anfragen.at(-1).body, /HTTP 503/);

  antwort = { code: 200, body: '{"status":"kaputt"}' };
  r = await lauf(env, 'herzschlag');
  assert.equal(hc.anfragen.at(-1).pfad, '/ping/cccc-app/fail');

  r = await lauf({ ...hc.env, APP_URL: 'http://127.0.0.1:9' }, 'herzschlag');
  assert.equal(r.status, 0, r.stderr);
  assert.equal(hc.anfragen.at(-1).pfad, '/ping/cccc-app/fail');
  assert.match(hc.anfragen.at(-1).body, /nicht erreichbar/);
  ohneGeheimnis(r, hc);
});

async function httpsMitZertifikat(t, tage) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zert-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const r = spawnSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', String(tage),
    '-subj', '/CN=localhost', '-keyout', path.join(dir, 'key.pem'), '-out', path.join(dir, 'cert.pem')], { stdio: 'ignore' });
  assert.equal(r.status, 0, 'openssl req');
  const server = https.createServer({ key: fs.readFileSync(path.join(dir, 'key.pem')),
                                      cert: fs.readFileSync(path.join(dir, 'cert.pem')) }, (req, res) => res.end('ok'));
  const port = await lauschen(server);
  t.after(() => server.close());
  return `https://127.0.0.1:${port}`;
}

test('zertifikat: lange gültig → Lebenszeichen, bald abgelaufen → …/fail mit Resttagen', { skip: OHNE }, async (t) => {
  const hc = await hcNachbau(t);
  let r = await lauf({ ...hc.env, APP_URL: await httpsMitZertifikat(t, 60) }, 'zertifikat');
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual([hc.anfragen.at(-1).method, hc.anfragen.at(-1).pfad], ['POST', '/ping/dddd-zertifikat']);
  assert.match(hc.anfragen.at(-1).body, /noch (59|60) Tage/);

  r = await lauf({ ...hc.env, APP_URL: await httpsMitZertifikat(t, 5) }, 'zertifikat');
  assert.equal(r.status, 0, r.stderr);
  assert.equal(hc.anfragen.at(-1).pfad, '/ping/dddd-zertifikat/fail');
  assert.match(hc.anfragen.at(-1).body, /läuft in [45] Tagen ab/);
});

test('probe: ein Probealarm, als solcher erkennbar', { skip: OHNE }, async (t) => {
  const hc = await hcNachbau(t);
  const r = await lauf(hc.env, 'probe');
  assert.equal(r.status, 0, r.stderr);
  assert.equal(hc.anfragen.at(-1).pfad, '/ping/cccc-app/fail');
  assert.match(hc.anfragen.at(-1).body, /PROBEALARM/);
});

test('Healthchecks.io nicht erreichbar: Fehler — ohne die geheime Adresse zu zeigen', { skip: OHNE }, async () => {
  const env = { HC_SICHERUNG: 'http://127.0.0.1:9/ping/eeee-geheim' };
  const r = await lauf(env, 'ok', 'sicherung');
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, /nicht erreicht/);
  assert.ok(!r.stderr.includes('eeee-geheim') && !r.stdout.includes('eeee-geheim'));
});
