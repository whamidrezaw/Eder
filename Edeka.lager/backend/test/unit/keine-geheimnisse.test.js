'use strict';
//
// Keine Archive und keine echten .env-Dateien im Repository.
//
// Am 06.07.2026 kam ein ZIP ins öffentliche Repo, darin eine .env mit dem
// echten JWT_SECRET. Die Suche im Text fand es nicht — ein ZIP ist binär.
// Deshalb die einfachere, sichere Regel: solche Dateien werden gar nicht
// erst versioniert. .env.example bleibt erlaubt.
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const path   = require('node:path');
const { spawnSync } = require('node:child_process');

const WURZEL   = path.join(__dirname, '../../../..');
const ARCHIV   = /\.(zip|tar|tgz|gz|bz2|xz|7z|rar)$/i;
// .env, .env.local, .env.production … — aber keine Vorlagen: .env.example,
// .env.test.example und alles andere, was auf .example endet.
const UMGEBUNG = /(^|\/)\.env(\.[^/]*)?$/;
const VORLAGE  = /\.example$/;

test('keine Archive und keine .env-Dateien im Repository', (t) => {
  const r = spawnSync('git', ['ls-files'], { cwd: WURZEL, encoding: 'utf8' });
  if (r.status !== 0) { t.skip('kein Git-Repository'); return; }
  const funde = r.stdout.split('\n').filter(f => f && (ARCHIV.test(f) || (UMGEBUNG.test(f) && !VORLAGE.test(f))));
  assert.deepEqual(funde, [], 'versioniert, aber verboten:\n    ' + funde.join('\n    '));
});
