'use strict';
//
// Die HTML-Seiten enthalten keinen ausführbaren Code mehr.
//
// Solange Logik in einem Inline-<script> steckt, sieht sie weder ESLint
// noch der vm-Harness: mehrere tausend Zeilen ohne jede Prüfung. Genau
// dort lag "rawLogs is not defined", das erst im Betrieb als 500 auffiel.
//
// Dieser Test hält den Zustand fest, sobald er erreicht ist — er verhindert
// den Rückfall, nicht mehr und nicht weniger.
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const fs     = require('node:fs');
const path   = require('node:path');

const FE = path.join(__dirname, '../../../frontend');

function htmlDateien(dir) {
  const out = [];
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) out.push(...htmlDateien(p));
    else if (e.name.endsWith('.html')) out.push(p);
  }
  return out;
}

test('keine HTML-Seite enthält noch einen Inline-Skriptblock', () => {
  const offen = [];
  for (const datei of htmlDateien(FE)) {
    const text = fs.readFileSync(datei, 'utf8');
    let anzahl = 0;
    for (const m of text.matchAll(/<script(\s[^>]*)?>([\s\S]*?)<\/script>/gi)) {
      if (/\bsrc\s*=/.test(m[1] || '')) continue;   // lädt eine Datei — in Ordnung
      if (m[2].trim() === '') continue;             // leerer Block
      anzahl++;
    }
    if (anzahl > 0) offen.push(`${path.basename(datei)}: ${anzahl}`);
  }
  assert.deepEqual(offen, [],
    'Seiten mit Inline-Skript (Datei: Anzahl):\n    ' + offen.join('\n    '));
});
