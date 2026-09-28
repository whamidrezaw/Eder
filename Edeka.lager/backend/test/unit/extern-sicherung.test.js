'use strict';
//
// tools/extern-sicherung.sh — die Kopie außerhalb des Servers.
//
// Geprüft mit echtem age und einem echten, nackten Git-Repository als
// Gegenstelle (so wie GitHub): nur fertige, geprüfte Sicherungen gehen raus,
// nie ein Archiv im Klartext; Entschlüsseln mit dem privaten Schlüssel ergibt
// Byte für Byte das Original; ein zweiter Lauf ändert nichts; ohne gültigen
// Schlüssel erreicht nichts das Repository.
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const fs     = require('node:fs');
const os     = require('node:os');
const path   = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');

const SKRIPT = path.join(__dirname, '../../../../tools/extern-sicherung.sh');
const vorhanden = (cmd) => spawnSync('sh', ['-c', `command -v ${cmd}`]).status === 0;
const BEREIT = ['age', 'age-keygen', 'git', 'bash'].every(vorhanden);
const OHNE = BEREIT ? false : 'age fehlt — sudo apt install age';

const sha = (buf) => crypto.createHash('sha256').update(buf).digest('hex');

function umgebung(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'extern-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const ziel = path.join(dir, 'sicherungen');
  fs.mkdirSync(ziel);
  const remote = path.join(dir, 'gegenstelle.git');
  spawnSync('git', ['init', '-q', '--bare', '-b', 'main', remote]);
  const schluessel = path.join(dir, 'schluessel.txt');
  spawnSync('age-keygen', ['-o', schluessel], { stdio: 'ignore' });
  const empfaenger = spawnSync('age-keygen', ['-y', schluessel], { encoding: 'utf8' }).stdout.trim();
  return { dir, ziel, remote, schluessel, empfaenger, arbeit: path.join(dir, 'arbeit') };
}

// Eine Sicherung so, wie tools/sicherung.sh sie hinterlässt.
function sicherung(u, stempel, dbs = ['edeka_lager']) {
  const ordner = path.join(u.ziel, stempel);
  fs.mkdirSync(ordner);
  const summen = {};
  for (const db of dbs) {
    const archiv = crypto.randomBytes(2048);
    fs.writeFileSync(path.join(ordner, `${db}.archive.gz`), archiv);
    fs.writeFileSync(path.join(ordner, `${db}.inhalt`), 'products 3\nusers 2\n');
    fs.writeFileSync(path.join(ordner, `${db}.dump.log`), 'done dumping\n');
    summen[db] = sha(archiv);
  }
  return summen;
}

function lauf(u, extra = {}) {
  return spawnSync('bash', [SKRIPT], {
    encoding: 'utf8',
    env: {
      PATH: process.env.PATH, HOME: u.dir, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_NOSYSTEM: '1',
      EXTERN_REPO: u.remote, EXTERN_EMPFAENGER: u.empfaenger,
      EXTERN_ARBEIT: u.arbeit, SICHERUNG_ZIEL: u.ziel, ...extra
    }
  });
}

const git = (u, ...args) => spawnSync('git', ['--git-dir', u.remote, ...args], { encoding: 'utf8' });
const baum = (u) => git(u, 'ls-tree', '-r', '--name-only', 'main').stdout.split('\n').filter(Boolean).sort();
const stand = (u) => git(u, 'rev-parse', '-q', '--verify', 'refs/heads/main').stdout.trim();

function entschluesselt(u, pfad) {
  const blob = spawnSync('git', ['--git-dir', u.remote, 'show', `main:${pfad}`]).stdout;
  const r = spawnSync('age', ['-d', '-i', u.schluessel], { input: blob });
  assert.equal(r.status, 0, `age -d ${pfad}: ${r.stderr}`);
  return r.stdout;
}

test('geprüfte Sicherungen gehen verschlüsselt raus — unfertige nie, Klartext nie', { skip: OHNE }, (t) => {
  const u = umgebung(t);
  const a = sicherung(u, '2026-09-27_023001');
  const b = sicherung(u, '2026-09-28_023002', ['edeka_lager', 'zweite_db']);
  fs.mkdirSync(path.join(u.ziel, '2026-09-29_023003.unfertig'));
  fs.writeFileSync(path.join(u.ziel, '2026-09-29_023003.unfertig', 'edeka_lager.archive.gz'), 'halb');

  const r = lauf(u);
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual(baum(u), [
    '2026-09-27_023001/edeka_lager.archive.gz.age', '2026-09-27_023001/edeka_lager.inhalt', '2026-09-27_023001/edeka_lager.sha256',
    '2026-09-28_023002/edeka_lager.archive.gz.age', '2026-09-28_023002/edeka_lager.inhalt', '2026-09-28_023002/edeka_lager.sha256',
    '2026-09-28_023002/zweite_db.archive.gz.age', '2026-09-28_023002/zweite_db.inhalt', '2026-09-28_023002/zweite_db.sha256'
  ]);
  // Byte für Byte das Original — und die mitgelieferte Prüfsumme stimmt
  assert.equal(sha(entschluesselt(u, '2026-09-27_023001/edeka_lager.archive.gz.age')), a.edeka_lager);
  assert.equal(sha(entschluesselt(u, '2026-09-28_023002/zweite_db.archive.gz.age')), b.zweite_db);
  const summe = git(u, 'show', 'main:2026-09-28_023002/edeka_lager.sha256').stdout;
  assert.match(summe, new RegExp(`^${b.edeka_lager}\\s+\\*?edeka_lager\\.archive\\.gz`));
  // Protokolle der Probe bleiben auf dem Server
  assert.ok(!baum(u).some(f => f.endsWith('.log')));
});

test('ein zweiter Lauf ändert nichts', { skip: OHNE }, (t) => {
  const u = umgebung(t);
  sicherung(u, '2026-09-28_023002');
  assert.equal(lauf(u).status, 0);
  const vorher = stand(u);
  const r = lauf(u);
  assert.equal(r.status, 0, r.stderr);
  assert.equal(stand(u), vorher);
  assert.match(r.stdout, /nichts Neues/);
});

test('eine verpasste Nacht wird nachgeholt', { skip: OHNE }, (t) => {
  const u = umgebung(t);
  sicherung(u, '2026-09-26_023001');
  assert.equal(lauf(u).status, 0);
  sicherung(u, '2026-09-27_023001');
  sicherung(u, '2026-09-28_023001');
  const r = lauf(u);
  assert.equal(r.status, 0, r.stderr);
  const ordner = [...new Set(baum(u).map(f => f.split('/')[0]))];
  assert.deepEqual(ordner, ['2026-09-26_023001', '2026-09-27_023001', '2026-09-28_023001']);
});

test('im Stand bleiben EXTERN_BEHALTEN Sicherungen, ältere nur noch in der Geschichte', { skip: OHNE }, (t) => {
  const u = umgebung(t);
  for (const s of ['2026-09-25_023001', '2026-09-26_023001', '2026-09-27_023001']) sicherung(u, s);
  assert.equal(lauf(u, { EXTERN_BEHALTEN: '2' }).status, 0);
  const ordner = [...new Set(baum(u).map(f => f.split('/')[0]))];
  assert.deepEqual(ordner, ['2026-09-26_023001', '2026-09-27_023001']);
  const geschichte = git(u, 'log', '--format=%h', 'main', '--', '2026-09-25_023001').stdout.trim();
  assert.notEqual(geschichte, '', 'die älteste muss in der Geschichte stehen');
  // und sie wird beim nächsten Lauf nicht wieder hineingeschoben
  const vorher = stand(u);
  assert.equal(lauf(u, { EXTERN_BEHALTEN: '2' }).status, 0);
  assert.equal(stand(u), vorher);
});

test('ohne gültigen öffentlichen Schlüssel erreicht nichts das Repository', { skip: OHNE }, (t) => {
  const u = umgebung(t);
  sicherung(u, '2026-09-28_023002');
  for (const falsch of ['', 'kein-schluessel', 'AGE-SECRET-KEY-1QQQ']) {
    const r = lauf(u, { EXTERN_EMPFAENGER: falsch });
    assert.notEqual(r.status, 0, `angenommen: '${falsch}'`);
    assert.match(r.stderr, /EXTERN_EMPFAENGER/);
  }
  assert.equal(stand(u), '', 'nichts darf das Repository erreicht haben');
});

test('nie mit Gewalt ins Sicherungs-Repository', () => {
  const text = fs.readFileSync(SKRIPT, 'utf8');
  assert.doesNotMatch(text, /push[^\n]*(--force|\s-f\b|\+HEAD|\+main)/);
});
