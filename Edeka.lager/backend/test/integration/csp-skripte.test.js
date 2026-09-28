'use strict';
//
// script-src und Markup passen zusammen — das Gegenstück zu csp-markup.test.js.
//
// 'unsafe-inline' in script-src erlaubt zweierlei, das eingeschleustes HTML
// ausnutzen könnte: <script>-Blöcke im Markup und javascript:-Adressen. Seit
// Phase F braucht die App beides nicht. Solange das so bleibt, darf die CSP
// es nicht erlauben. Kommt je wieder ein Inline-Skript dazu, wird dieser Test
// rot — und man entscheidet bewusst, statt die Tür still offen zu lassen.
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const fs     = require('node:fs');
const path   = require('node:path');
const { start, stop, req } = require('../helpers/http');

const FE = path.join(__dirname, '../../../frontend');
const KOMMENTAR = /^\s*(\/\/|\/\*|\*|<!--)/;

function dateien(dir) {
  const out = [];
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) out.push(...dateien(p));
    else if (/\.(html|js)$/.test(e.name) && e.name !== 'chart.umd.min.js') out.push(p);
  }
  return out;
}

function inlineSkripte() {
  const funde = [];
  for (const p of dateien(FE)) {
    const rel = path.relative(FE, p);
    const text = fs.readFileSync(p, 'utf8');
    if (p.endsWith('.html')) {
      for (const m of text.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)) {
        if (!/\bsrc\s*=/i.test(m[1]) && m[2].trim()) funde.push(`${rel}: <script> ohne src`);
      }
    }
    text.split('\n').forEach((zeile, i) => {
      if (!KOMMENTAR.test(zeile) && /javascript:/i.test(zeile)) funde.push(`${rel}:${i + 1}: javascript:-Adresse`);
    });
  }
  return funde;
}

test.before(async () => { await start(); });
test.after (async () => { await stop(); });

test('script-src erlaubt Inline-Skripte genau dann, wenn die App welche hat', async () => {
  const funde = inlineSkripte();
  const r = await req('/index.html');
  const csp = r.headers.get('content-security-policy') || '';
  // "script-src " mit Leerzeichen: script-src-attr ist eine andere Direktive.
  const scriptSrc = csp.split(';').map(s => s.trim()).find(s => s.startsWith('script-src ')) || '';
  const erlaubt = /'unsafe-inline'/.test(scriptSrc);
  if (funde.length) {
    assert.ok(erlaubt, `Inline-Skripte vorhanden, aber die CSP verbietet sie:\n    ${funde.join('\n    ')}`);
  } else {
    assert.equal(erlaubt, false,
      `Die App hat keine Inline-Skripte — script-src darf 'unsafe-inline' nicht mehr erlauben: "${scriptSrc}"`);
  }
});
