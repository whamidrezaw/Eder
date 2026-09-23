'use strict';
//
// Umgestellte Seiten enthalten keinen Inline-Handler mehr.
//
// Die Liste wächst Seite für Seite. Stehen alle Seiten darin, gibt es
// nirgends mehr einen Inline-Handler — und csp-markup.test.js verlangt dann
// von selbst, dass die CSP wieder schließt.
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const fs     = require('node:fs');
const path   = require('node:path');

const FE = path.join(__dirname, '../../../frontend');

const UMGESTELLT = ['dashboard.html', 'assets/dashboard.js', 'assets/shared.js'];

// Kommentarzeilen sind keine Handler — dashboard.js erklärt in einem
// Kommentar, warum dort KEIN onclick="..." mehr steht.
const KOMMENTAR = /^\s*(\/\/|\/\*|\*|<!--)/;

test('umgestellte Seiten enthalten keinen Inline-Handler mehr', () => {
  const funde = [];
  for (const rel of UMGESTELLT) {
    fs.readFileSync(path.join(FE, rel), 'utf8').split('\n').forEach((zeile, i) => {
      if (KOMMENTAR.test(zeile)) return;
      for (const m of zeile.matchAll(/\s(on[a-z]+)\s*=\s*["']/gi)) funde.push(`${rel}:${i + 1} ${m[1]}`);
    });
  }
  assert.deepEqual(funde, [], `${funde.length} Inline-Handler:\n    ` + funde.join('\n    '));
});
