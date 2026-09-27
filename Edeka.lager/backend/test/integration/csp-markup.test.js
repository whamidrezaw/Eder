'use strict';
//
// CSP und Markup müssen zueinander passen.
//
// Dieser Test prüft keinen Zustand, sondern eine GLEICHUNG:
//   Inline-Handler im Frontend vorhanden  <=>  CSP erlaubt sie
//
// Stimmt die linke Seite und die rechte nicht, sind alle Knöpfe tot —
// genau so war es von Anfang an: helmet setzt script-src-attr 'none', das
// Frontend baut seine Knöpfe mit onclick="…". Aufgefallen ist es erst beim
// ersten echten Klick im Browser.
//
// Stimmt die rechte Seite und die linke nicht mehr, ist Phase F fertig
// (alle Handler über addEventListener) — dann erzwingt dieser Test, dass
// die vorübergehende Lockerung wieder zurückgenommen wird.
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const fs     = require('node:fs');
const path   = require('node:path');
const { start, stop, req } = require('../helpers/http');

const FE = path.join(__dirname, '../../../frontend');

test.before(async () => { await start(); });
test.after (async () => { await stop(); });

function inlineHandler(dir = FE) {
  const treffer = [];
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) { treffer.push(...inlineHandler(p)); continue; }
    if (!/\.(html|js)$/.test(e.name) || e.name === 'chart.umd.min.js') continue;
    fs.readFileSync(p, 'utf8').split('\n').forEach((zeile, i) => {
      // Kommentarzeilen sind keine Handler. dashboard.js erklärt in einem
      // Kommentar, warum dort KEIN onclick="..." mehr steht — ohne diese
      // Zeile zählte genau diese Erklärung als Handler und hielte die CSP
      // für immer offen.
      if (/^\s*(\/\/|\/\*|\*|<!--)/.test(zeile)) return;
      // on…=" bzw. on…=' — also Attribute, nicht el.onclick = () => …
      for (const m of zeile.matchAll(/\s(on[a-z]+)\s*=\s*["']/gi)) {
        treffer.push(`${path.relative(FE, p)}:${i + 1} ${m[1]}`);
      }
    });
  }
  return treffer;
}

// Erlaubt die CSP Inline-Handler? Fehlt script-src-attr, gilt script-src,
// danach default-src — genau wie im Browser.
function handlerErlaubt(csp) {
  const d = {};
  for (const teil of csp.split(';').map(s => s.trim()).filter(Boolean)) {
    const [name, ...werte] = teil.split(/\s+/);
    d[name.toLowerCase()] = werte;
  }
  const massgeblich = d['script-src-attr'] || d['script-src'] || d['default-src'] || [];
  return massgeblich.includes("'unsafe-inline'");
}

test('CSP und Markup passen zusammen', async () => {
  const handler = inlineHandler();
  const r = await req('/index.html');
  const csp = r.headers.get('content-security-policy');
  assert.ok(csp, 'kein Content-Security-Policy-Header');

  const erlaubt = handlerErlaubt(csp);

  if (handler.length > 0) {
    assert.ok(erlaubt,
      `${handler.length} Inline-Handler im Frontend (etwa ${handler.slice(0, 3).join(', ')}), ` +
      `aber die CSP verbietet sie — jeder dieser Knöpfe ist tot.`);
  } else {
    assert.ok(!erlaubt,
      "Es gibt keine Inline-Handler mehr — Phase F ist fertig. Dann muss die " +
      "vorübergehende Zeile scriptSrcAttr in app.js wieder raus.");
  }
});
