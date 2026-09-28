'use strict';
//
// Die Dokumentation bleibt wahr.
//
// Bis Phase H beschrieb backend/README.md einen Stand vom Juli: 5 von 13
// Einstellungen, DOMAIN "für CORS" (längst CORS_ORIGINS), eine Liste
// "unveränderter" Dateien, die sich alle geändert hatten. Eine Doku, die nicht
// stimmt, führt mit Überzeugung in die falsche Richtung. Geprüft wird hier
// alles, was sich maschinell prüfen lässt — in beide Richtungen, wo es geht.
//
// Und weil das Repository öffentlich ist: keine Server-Adresse und kein
// DuckDNS-Name in der Doku, nur Platzhalter.
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const fs     = require('node:fs');
const path   = require('node:path');

const WURZEL = path.join(__dirname, '../../../..');
const BE     = path.join(WURZEL, 'Edeka.lager', 'backend');
const lies   = (rel) => fs.readFileSync(path.join(WURZEL, rel), 'utf8');

const DOKS = [
  'Edeka.lager/BETRIEB.md', 'Edeka.lager/ENTSCHEIDUNGEN.md',
  'Edeka.lager/backend/README.md', 'Edeka.lager/frontend/README.md',
  'Edeka.lager/backend/test/README.md', 'tools/README.md'
];
// Kommt mit seinem eigenen Commit; danach existiert es ohnehin.
const AUSSTEHEND = new Set(['apply-h1-doku.sh', 'apply-h3-extern.sh']);

const unterschied = (a, b) => [...a].filter(x => !b.has(x)).sort();

test('jedes "npm run …" in der Doku gibt es wirklich', () => {
  const skripte = new Set(Object.keys(JSON.parse(fs.readFileSync(path.join(BE, 'package.json'), 'utf8')).scripts));
  const fehlt = [];
  for (const d of DOKS) for (const m of lies(d).matchAll(/npm run ([a-z][a-z0-9:-]*)/g)) {
    if (!skripte.has(m[1])) fehlt.push(`${d}: npm run ${m[1]}`);
  }
  assert.deepEqual(fehlt, []);
});

test('jede Einstellung aus .env.example ist beschrieben — und umgekehrt', () => {
  const vorlage = new Set([...lies('Edeka.lager/backend/.env.example').matchAll(/^#?\s*([A-Z][A-Z0-9_]*)=/gm)].map(m => m[1]));
  const readme  = new Set([...lies('Edeka.lager/backend/README.md').matchAll(/^\|\s*`([A-Z][A-Z0-9_]*)`\s*\|/gm)].map(m => m[1]));
  assert.deepEqual(unterschied(vorlage, readme), [], 'in .env.example, aber nicht in der README');
  assert.deepEqual(unterschied(readme, vorlage), [], 'in der README, aber nicht in .env.example');
});

test('jede Route der API ist beschrieben — und umgekehrt', () => {
  const app = fs.readFileSync(path.join(BE, 'app.js'), 'utf8');
  const code = new Set();
  for (const m of app.matchAll(/app\.use\(\s*'(\/api\/[a-z]+)'\s*,\s*require\('\.\/routes\/([a-z]+)'\)/g)) {
    const src = fs.readFileSync(path.join(BE, 'routes', `${m[2]}.js`), 'utf8');
    for (const r of src.matchAll(/router\.(get|post|put|patch|delete)\(\s*'([^']*)'/g)) {
      code.add(`${r[1].toUpperCase()} ${m[1]}${r[2] === '/' ? '' : r[2]}`);
    }
  }
  for (const m of app.matchAll(/app\.(get|post)\(\s*'(\/api\/[^']*)'/g)) code.add(`${m[1].toUpperCase()} ${m[2]}`);
  assert.ok(code.size > 20, `nur ${code.size} Routen gefunden — Einlesen fehlgeschlagen?`);
  const doku = new Set([...lies('Edeka.lager/backend/README.md')
    .matchAll(/^\|\s*(GET|POST|PUT|PATCH|DELETE)\s*\|\s*`([^`]+)`\s*\|/gm)].map(m => `${m[1]} ${m[2]}`));
  assert.deepEqual(unterschied(code, doku), [], 'im Code, aber nicht in der README');
  assert.deepEqual(unterschied(doku, code), [], 'in der README, aber nicht im Code');
});

test('jedes Skript in tools/ ist in tools/README.md beschrieben', () => {
  const readme = lies('tools/README.md');
  const fehlt = fs.readdirSync(path.join(WURZEL, 'tools')).filter(f => f.endsWith('.sh') && !readme.includes(f));
  assert.deepEqual(fehlt, []);
});

test('Pfade unter tools/ in der Doku gibt es — oder sie sind angekündigt', () => {
  const fehlt = [];
  for (const d of DOKS) for (const m of lies(d).matchAll(/\btools\/([a-z0-9.-]+\.sh)\b/g)) {
    if (!fs.existsSync(path.join(WURZEL, 'tools', m[1])) && !AUSSTEHEND.has(m[1])) fehlt.push(`${d}: tools/${m[1]}`);
  }
  assert.deepEqual(fehlt, []);
});

test('keine Server-Adresse und kein DuckDNS-Name in der Doku', () => {
  const funde = [];
  (function lauf(dir) {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      if (['node_modules', '.git'].includes(e.name)) continue;
      const p = path.join(dir, e.name);
      if (e.isDirectory()) { lauf(p); continue; }
      if (!e.name.endsWith('.md')) continue;
      const rel = path.relative(WURZEL, p);
      const text = fs.readFileSync(p, 'utf8');
      for (const m of text.matchAll(/\b(?:\d{1,3}\.){3}\d{1,3}\b/g)) {
        if (!['127.0.0.1', '0.0.0.0'].includes(m[0])) funde.push(`${rel}: Adresse ${m[0]}`);
      }
      for (const m of text.matchAll(/\b([a-z0-9-]+)\.duckdns\.org\b/gi)) {
        if (m[1].toLowerCase() !== 'www') funde.push(`${rel}: DuckDNS-Name ${m[0]}`);
      }
    }
  })(WURZEL);
  assert.deepEqual(funde, [], 'öffentliches Repository — bitte Platzhalter <server> bzw. <name>.duckdns.org benutzen');
});
