'use strict';
//
// Die Kurzanleitung nennt nur, was es in der Oberfläche wirklich gibt.
//
// Jede Beschriftung, die sie in „…“ zitiert, muss wörtlich in den Seiten oder
// Skripten des Frontends stehen — als ganzes Wort („Admin“ zählt nicht, nur
// weil es „🔑 Admins“ gibt) und nicht bloß in einem Kommentar. HTML-Entitäten
// werden aufgelöst; „…“ mitten in einem Zitat steht für einen Platzhalter, etwa
// eine Zahl. Benennt jemand einen Knopf um, wird dieser Test rot, bis die
// Anleitung nachzieht.
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const fs     = require('node:fs');
const path   = require('node:path');

const WURZEL   = path.join(__dirname, '../../../..');
const FRONTEND = path.join(WURZEL, 'Edeka.lager', 'frontend');
const ANLEITUNG = path.join(WURZEL, 'Edeka.lager', 'KURZANLEITUNG.md');

const entitaeten = (s) => s.replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"');
function oberflaeche() {
  const teile = [];
  (function lauf(dir) {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, e.name);
      if (e.isDirectory()) lauf(p);
      else if (/\.(html|js)$/.test(e.name) && !e.name.includes('.min.')) {
        // Kommentarzeilen sind keine Oberfläche.
        const ohneKommentare = fs.readFileSync(p, 'utf8').split('\n')
          .filter(z => !/^\s*(\/\/|\/\*|\*)/.test(z)).join('\n');
        teile.push(entitaeten(ohneKommentare.replace(/<!--[\s\S]*?-->/g, '')));
      }
    }
  })(FRONTEND);
  return teile.join('\n');
}

test('jede zitierte Beschriftung gibt es in der Oberfläche', () => {
  const text = fs.readFileSync(ANLEITUNG, 'utf8');
  const zitate = [...text.replace(/\n/g, ' ').matchAll(/„([^“]+)“/g)].map(m => m[1]);
  assert.ok(zitate.length > 30, `nur ${zitate.length} Zitate gefunden — Einlesen fehlgeschlagen?`);
  const ui = oberflaeche();
  const maskiert = (t) => t.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const alsWort = (teil) => new RegExp(`(?<![\\p{L}\\p{N}])${maskiert(teil)}(?![\\p{L}\\p{N}])`, 'u').test(ui);
  const fehlt = zitate.filter(z => !z.split('…').map(s => s.trim()).filter(Boolean).every(alsWort));
  assert.deepEqual([...new Set(fehlt)], [], 'in der Anleitung zitiert, in der Oberfläche nicht vorhanden');
});

test('die Anleitung verrät keine Adresse — sie wird von Hand eingetragen', () => {
  const text = fs.readFileSync(ANLEITUNG, 'utf8');
  assert.match(text, /\*\*Adresse der App:\*\* _{20,}/);
  assert.doesNotMatch(text, /https?:\/\//);
});
