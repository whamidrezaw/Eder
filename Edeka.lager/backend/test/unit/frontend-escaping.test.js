'use strict';
//
// Jede Einfügung eines emoji-Werts in HTML muss durch escapeHtml laufen.
//
// emoji war das einzige vom Benutzer gesetzte Feld, das im Frontend
// ungeschützt ins HTML ging — Name und Einheit direkt daneben wurden
// maskiert. In Batch A wurde nur die Telegram-Hälfte geschlossen.
//
// Das ist eine Prüfung am Quelltext, kein Verhaltenstest: die Inline-
// Skripte in den HTML-Dateien lassen sich im Harness noch nicht laden.
// Das ändert sich mit Phase F.
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const fs     = require('node:fs');
const path   = require('node:path');

const FE = path.join(__dirname, '../../../frontend');

function dateien(dir) {
  const out = [];
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) out.push(...dateien(p));
    else if (/\.(html|js)$/.test(e.name) && e.name !== 'chart.umd.min.js') out.push(p);
  }
  return out;
}

test('jede emoji-Einfügung in HTML läuft durch escapeHtml', () => {
  const offen = [];
  for (const f of dateien(FE)) {
    fs.readFileSync(f, 'utf8').split('\n').forEach((zeile, i) => {
      for (const m of zeile.matchAll(/\$\{([^{}]*emoji[^{}]*)\}/gi)) {
        if (!m[1].trim().startsWith('escapeHtml(')) {
          offen.push(`${path.relative(FE, f)}:${i + 1}  \${${m[1].trim()}}`);
        }
      }
    });
  }
  assert.deepEqual(offen, [],
    `${offen.length} emoji-Einfügung(en) ohne escapeHtml:\n    ` + offen.join('\n    '));
});
