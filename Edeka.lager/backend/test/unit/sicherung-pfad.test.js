'use strict';
//
// tools/sicherung.sh löscht alte Sicherungen und abgebrochene Reste mit
// rm -rf. Vorher muss ZIEL ein eigener, echter Ordner sein: Symlinks
// aufgelöst, absolut, mindestens drei Ebenen tief, kein Systemordner.
// (agent-skills, security-and-hardening: "Destructive filesystem operations
// resolve symlinks, then verify allowlisted root, minimum depth, and
// ownership before running.")
//
// Geprüft wird nur der Wächter. Der Container heißt so, dass es ihn nicht
// gibt: ein erlaubter Pfad scheitert danach an "läuft nicht" — ohne dass das
// Skript irgendetwas anlegt oder löscht.
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const fs     = require('node:fs');
const os     = require('node:os');
const path   = require('node:path');
const { spawnSync } = require('node:child_process');

const SKRIPT = path.join(__dirname, '../../../../tools/sicherung.sh');

function lauf(ziel) {
  return spawnSync('bash', [SKRIPT], {
    env: { PATH: process.env.PATH, ZIEL: ziel, CONTAINER: `gibt-es-nicht-${process.pid}`, BESITZER: 'root' },
    encoding: 'utf8', timeout: 20000
  });
}
const abgelehnt = (r) => r.status !== 0 && /ZIEL/.test(r.stderr) && !/läuft nicht/.test(r.stderr);
const tmp = () => fs.mkdtempSync(path.join(os.tmpdir(), 'sicherung-'));

test('Wurzel, Systemordner, relative Pfade und Umwege über .. werden abgelehnt', () => {
  for (const ziel of ['/', '/etc', '/home', '/usr/local/x', 'sicherungen', '/tmp/../etc/cron.d']) {
    const r = lauf(ziel);
    assert.ok(abgelehnt(r), `"${ziel}" wurde nicht abgelehnt: ${(r.stderr || r.stdout).trim()}`);
  }
});

test('ein Symlink wird aufgelöst — zeigt er auf /etc, wird abgelehnt', () => {
  const t = tmp();
  try {
    fs.mkdirSync(path.join(t, 'a'));
    fs.symlinkSync('/etc', path.join(t, 'a', 'b'));
    assert.ok(abgelehnt(lauf(path.join(t, 'a', 'b'))), 'Symlink auf /etc durchgelassen');
  } finally { fs.rmSync(t, { recursive: true, force: true }); }
});

test('eine Datei statt eines Ordners wird abgelehnt', () => {
  const t = tmp();
  try {
    fs.mkdirSync(path.join(t, 'x'));
    fs.writeFileSync(path.join(t, 'x', 'datei'), '');
    assert.ok(abgelehnt(lauf(path.join(t, 'x', 'datei'))), 'Datei als ZIEL durchgelassen');
  } finally { fs.rmSync(t, { recursive: true, force: true }); }
});

test('ein eigener, tief genug liegender Ordner wird durchgelassen — und nichts angelegt', () => {
  const t = tmp();
  const ziel = path.join(t, 'edeka', 'sicherungen');
  try {
    const r = lauf(ziel);
    assert.notEqual(r.status, 0);
    assert.match(r.stderr, /läuft nicht/, `am Wächter gescheitert statt am fehlenden Container: ${r.stderr.trim()}`);
    assert.ok(!fs.existsSync(ziel), 'der Wächter darf nichts anlegen');
  } finally { fs.rmSync(t, { recursive: true, force: true }); }
});
