'use strict';
//
// Die Schließen-Knöpfe der Dialoge sind echte Knöpfe.
//
// Ein <div> ist mit der Tastatur nicht erreichbar — kein Tab, kein Enter. Wer
// ohne Maus arbeitet, kam aus dem Dialog nicht heraus. "✕" allein liest ein
// Bildschirmleser als "Multiplikationszeichen"; aria-label gibt ihm den
// Namen. type="button", weil ein Knopf in einem <form> das Formular sonst
// abschickt und die Seite neu lädt.
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const fs     = require('node:fs');
const path   = require('node:path');

const FE = path.join(__dirname, '../../../frontend');

test('Schließen-Knöpfe sind <button type="button"> mit aria-label', () => {
  const funde = [];
  let anzahl = 0;
  for (const f of fs.readdirSync(FE).filter(x => x.endsWith('.html'))) {
    const text = fs.readFileSync(path.join(FE, f), 'utf8');
    for (const m of text.matchAll(/<([a-z]+)\b([^>]*\bclass="[^"]*\bmodal-close\b[^"]*"[^>]*)>/gi)) {
      anzahl++;
      const [, tag, attr] = m;
      const wo = `${f}: <${tag}${attr.slice(0, 50)}…>`;
      if (tag.toLowerCase() !== 'button') { funde.push(`${wo} ist kein <button>`); continue; }
      if (!/\btype="button"/.test(attr))      funde.push(`${wo} ohne type="button"`);
      if (!/\baria-label="[^"]+"/.test(attr)) funde.push(`${wo} ohne aria-label`);
    }
  }
  assert.ok(anzahl > 0, 'keinen einzigen Schließen-Knopf gefunden — Klassenname geändert?');
  assert.deepEqual(funde, [], `${funde.length} Befund(e):\n    ` + funde.join('\n    '));
});
