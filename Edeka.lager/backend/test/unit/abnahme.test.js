'use strict';
//
// tools/abnahme.sh — die Prüfung über den ganzen Betrieb.
//
// Eine Abnahme, die sich nicht irren kann, ist wertlos. Geprüft gegen einen
// nachgebauten Server (systemctl, docker, curl, openssl, ss, iptables,
// journalctl als Attrappen, git echt): erst alles grün, dann je ein Defekt —
// und jeder Defekt muss genau seine eigene Zeile rot machen.
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const fs     = require('node:fs');
const os     = require('node:os');
const path   = require('node:path');
const { spawnSync } = require('node:child_process');

const SKRIPT = path.join(__dirname, '../../../../tools/abnahme.sh');
const OHNE = spawnSync('sh', ['-c', 'command -v bash && command -v git']).status === 0 ? false : 'bash oder git fehlt';

// Attrappen: kleine Node-Skripte, gesteuert über Umgebungsvariablen.
const ATTRAPPEN = {
  sudo: `#!/bin/sh\nexec "$@"\n`,
  systemctl: `#!/usr/bin/env node
const a = process.argv.slice(2);
if (a[0] === 'is-active') process.exit((process.env.STUB_INAKTIV || '').split(',').includes(a[2]) ? 3 : 0);
if (a[0] === 'show') { console.log('edeka-hc-fehler@edeka-lager.service.service'); process.exit(0); }
process.exit(1);`,
  curl: `#!/usr/bin/env node
const a = process.argv.slice(2), url = a.filter(x => /^https?:/.test(x)).pop() || '';
const oeffentlich = url.startsWith('https://');
if (oeffentlich && process.env.STUB_OEFFENTLICH_AUS) { process.stderr.write('curl: (28) timeout'); process.exit(28); }
if (a.includes('-w')) { process.stdout.write('301 https://test.duckdns.org/'); process.exit(0); }
if (a.some(x => /^-[a-zA-Z]*I/.test(x))) {
  const skript = process.env.STUB_SKRIPT_SRC || "'self'";
  process.stdout.write('HTTP/2 200\\r\\ncontent-security-policy: default-src \\'self\\';script-src ' + skript +
    ";script-src-attr 'none';style-src 'self' 'unsafe-inline'\\r\\n\\r\\n");
  process.exit(0);
}
process.stdout.write('{"status":"ok","uptime":1}');`,
  openssl: `#!/usr/bin/env node
const a = process.argv.slice(2);
if (a[0] === 's_client') { console.log('-----BEGIN CERTIFICATE-----'); process.exit(0); }
const ende = new Date(Date.now() + Number(process.env.STUB_ZERT_TAGE || 60) * 86400e3 + 3600e3);
console.log('notAfter=' + ende.toUTCString());`,
  docker: `#!/usr/bin/env node
const f = process.argv.slice(2).join(' ');
console.log(f.includes('State.Running') ? 'true' : 'edeka-mongo-daten edeka-mongo-config');`,
  ss: `#!/usr/bin/env node
const app = process.env.STUB_APP_OFFEN ? '0.0.0.0:3000' : '127.0.0.1:3000';
for (const l of ['0.0.0.0:22', '0.0.0.0:80', '[::]:443', app, '127.0.0.1:27017'])
  console.log('LISTEN 0 511 ' + l + ' 0.0.0.0:*');`,
  journalctl: `#!/usr/bin/env node
if (!process.env.STUB_KEIN_HERZ) console.log('Finished edeka-herzschlag.service - Herzschlag.');`,
  iptables: `#!/usr/bin/env node
for (const p of [22, 80, 443]) console.log('-A INPUT -p tcp -m tcp --dport ' + p + ' -j ACCEPT');
console.log('-A INPUT -j REJECT --reject-with icmp-host-prohibited');`,
  df: `#!/bin/sh\nprintf 'Use%%\\n 30%%\\n'\n`,
  'apt-get': `#!/bin/sh\nexit 0\n`
};

const git = (cwd, ...args) => {
  const r = spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@t', ...args], { cwd, encoding: 'utf8' });
  assert.equal(r.status, 0, `git ${args.join(' ')}: ${r.stderr}`);
  return r.stdout.trim();
};

function server(t) {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), 'abnahme-'));
  t.after(() => fs.rmSync(d, { recursive: true, force: true }));
  const bin = path.join(d, 'bin'); fs.mkdirSync(bin);
  for (const [name, inhalt] of Object.entries(ATTRAPPEN)) fs.writeFileSync(path.join(bin, name), inhalt, { mode: 0o755 });

  const konf = (name, text) => { const p = path.join(d, name); fs.writeFileSync(p, text); return p; };
  // Code-Repository: main, sauber, gleich mit origin
  const repo = path.join(d, 'repo'), repoOrigin = path.join(d, 'repo.git');
  git(d, 'init', '-q', '--bare', '-b', 'main', repoOrigin);
  git(d, 'init', '-q', '-b', 'main', repo);
  fs.writeFileSync(path.join(repo, 'datei'), 'x');
  git(repo, 'add', '.'); git(repo, 'commit', '-qm', 'eins');
  git(repo, 'remote', 'add', 'origin', repoOrigin); git(repo, 'push', '-q', 'origin', 'main');
  // Sicherungen und ihre Kopie außer Haus
  const ziel = path.join(d, 'sicherungen'); fs.mkdirSync(path.join(ziel, '2026-10-05_023001'), { recursive: true });
  const extern = path.join(d, 'extern'), externOrigin = path.join(d, 'extern.git');
  git(d, 'init', '-q', '--bare', '-b', 'main', externOrigin);
  git(d, 'init', '-q', '-b', 'main', extern);
  fs.mkdirSync(path.join(extern, '2026-10-05_023001'));
  fs.writeFileSync(path.join(extern, '2026-10-05_023001', 'edeka_lager.archive.gz.age'), 'chiffre');
  git(extern, 'add', '.'); git(extern, 'commit', '-qm', 'Sicherung');
  git(extern, 'remote', 'add', 'origin', externOrigin); git(extern, 'push', '-q', 'origin', 'main');

  return {
    ziel,
    env: {
      PATH: `${bin}:${process.env.PATH}`, HOME: d,
      ABNAHME_REPO: repo, SICHERUNG_ZIEL: ziel, EXTERN_ARBEIT: extern,
      DUCKDNS_KONF: konf('duckdns.env', 'DUCKDNS_DOMAIN=test\nDUCKDNS_TOKEN=geheim\n'),
      EXTERN_KONF: konf('extern.env', 'EXTERN_SSH_KEY=/dev/null\n'),
      ALARM_KONF: konf('alarm.env', ['SICHERUNG', 'EXTERN', 'APP', 'ZERTIFIKAT'].map(n => `HC_${n}=https://hc-ping.com/${n}`).join('\n') + '\n'),
      RULES_V4: konf('rules.v4', '-A INPUT -p tcp -m tcp --dport 443 -j ACCEPT\n')
    }
  };
}

function abnahme(s, extra = {}) {
  const r = spawnSync('bash', [SKRIPT], { encoding: 'utf8', env: { ...s.env, ...extra } });
  const rein = r.stdout.replace(/\x1b\[[0-9;]*m/g, '');
  return { status: r.status, aus: rein, rot: rein.split('\n').filter(z => /^\s*✗ /.test(z)).map(z => z.replace(/^\s*✗\s*/, '')) };
}

test('alles in Ordnung: kein ✗, Rückgabe 0 — auch mit unsafe-inline nur bei den Stilen', { skip: OHNE }, (t) => {
  const r = abnahme(server(t));
  assert.deepEqual(r.rot, [], r.aus);
  assert.equal(r.status, 0);
  assert.match(r.aus, /Alles in Ordnung: (\d+) von \1 Prüfungen/);
  assert.match(r.aus, /Zertifikat: noch 60 Tage/);
});

const DEFEKTE = [
  // Ist HTTPS von außen nicht erreichbar, lässt sich auch die CSP nicht lesen: zwei Zeilen.
  ['öffentliche Adresse unerreichbar (z. B. Security List zu)', { STUB_OEFFENTLICH_AUS: '1' }, [/^öffentlich: /, /^CSP: /]],
  ['Inline-Skripte wieder erlaubt', { STUB_SKRIPT_SRC: "'self' 'unsafe-inline'" }, [/^CSP: /]],
  ['App lauscht auf allen Adressen', { STUB_APP_OFFEN: '1' }, [/^App \(3000\) und MongoDB/]],
  ['Zertifikat läuft in 5 Tagen ab', { STUB_ZERT_TAGE: '5' }, [/^Zertifikat: 5 Tage/]],
  ['Herzschlag-Timer gestoppt', { STUB_INAKTIV: 'edeka-herzschlag.timer' }, [/^edeka-herzschlag\.timer aktiv/]],
  ['kein Herzschlag in den letzten 10 Minuten', { STUB_KEIN_HERZ: '1' }, [/^Herzschlag in den letzten/]]
];
for (const [name, env, zeilen] of DEFEKTE) {
  test(`Defekt: ${name} — genau diese Zeilen rot`, { skip: OHNE }, (t) => {
    const r = abnahme(server(t), env);
    assert.equal(r.status, 1, r.aus);
    assert.equal(r.rot.length, zeilen.length, `erwartet ${zeilen.length} ✗, bekommen:\n${r.rot.join('\n')}`);
    zeilen.forEach((z, i) => assert.match(r.rot[i], z));
  });
}

test('Defekt: Sicherung älter als 26 Stunden — genau diese Zeile rot', { skip: OHNE }, (t) => {
  const s = server(t);
  const alt = (Date.now() - 30 * 3600e3) / 1000;
  fs.utimesSync(path.join(s.ziel, '2026-10-05_023001'), alt, alt);
  const r = abnahme(s);
  assert.equal(r.status, 1);
  assert.deepEqual(r.rot.map(z => z.split(' (')[0]), ['keine geprüfte Sicherung der letzten 26 Stunden']);
});

test('Defekt: die jüngste Sicherung fehlt in der Kopie außer Haus — genau diese Zeile rot', { skip: OHNE }, (t) => {
  const s = server(t);
  fs.mkdirSync(path.join(s.ziel, '2026-10-06_023001'));
  const r = abnahme(s);
  assert.equal(r.status, 1);
  assert.equal(r.rot.length, 1, r.rot.join('\n'));
  assert.match(r.rot[0], /^Kopie außer Haus enthält 2026-10-06_023001/);
});
