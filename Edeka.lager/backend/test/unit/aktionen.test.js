'use strict';
//
// Der Aktionsverteiler in shared.js ersetzt onclick="…" im Markup.
//
// Ein Element trägt data-action="name"; EIN Listener am Dokument ruft
// aktionAusfuehren, und die sucht die registrierte Funktion. Geprüft wird
// hier die Verteilung selbst — ohne Browser, im vm-Harness.
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const { ladeShared } = require('../helpers/browser');

function element(action, daten = {}) {
  const el = { dataset: Object.assign({ action }, daten) };
  el.closest = (sel) => (sel === '[data-action]' ? el : null);
  return el;
}
const kindVon    = (eltern) => ({ closest: (sel) => eltern.closest(sel) });
const ohneAktion = () => ({ closest: () => null });

function aufbau() {
  const { sandbox } = ladeShared({ token: 'test-token' });
  assert.equal(typeof sandbox.registriereAktionen, 'function', 'registriereAktionen fehlt in shared.js');
  assert.equal(typeof sandbox.aktionAusfuehren,    'function', 'aktionAusfuehren fehlt in shared.js');
  return sandbox;
}

function mitKonsole(art, fn) {
  const zeilen = [];
  const alt = console[art];
  console[art] = (...a) => zeilen.push(a.map(String).join(' '));
  try { fn(); } finally { console[art] = alt; }
  return zeilen;
}

test('ein Klick auf ein Element mit data-action ruft die registrierte Funktion', () => {
  const s = aufbau();
  const aufrufe = [];
  s.registriereAktionen({ probe: (el) => aufrufe.push(el.dataset.id) });
  assert.equal(s.aktionAusfuehren({ target: element('probe', { id: 'p1' }) }), true);
  assert.deepEqual(aufrufe, ['p1']);
});

test('ein Klick auf ein Kind-Element im Knopf kommt ebenfalls an', () => {
  // Etwa das SVG im Abmelde-Knopf: das Ziel ist das Icon, nicht der Knopf.
  const s = aufbau();
  const aufrufe = [];
  s.registriereAktionen({ probe: () => aufrufe.push(1) });
  s.aktionAusfuehren({ target: kindVon(element('probe')) });
  assert.equal(aufrufe.length, 1);
});

test('ein Klick ohne data-action tut nichts', () => {
  const s = aufbau();
  assert.equal(s.aktionAusfuehren({ target: ohneAktion() }), false);
});

test('eine unbekannte Aktion wird gemeldet statt still zu scheitern', () => {
  const s = aufbau();
  let ergebnis;
  const warnungen = mitKonsole('warn', () => {
    ergebnis = s.aktionAusfuehren({ target: element('gibtEsNicht') });
  });
  assert.equal(ergebnis, false);
  assert.ok(warnungen.some(w => w.includes('gibtEsNicht')),
    'ein Tippfehler in data-action verschwände sonst spurlos');
});

test('eine abgelehnte async-Aktion wird abgefangen, nicht "Uncaught (in promise)"', async () => {
  const s = aufbau();
  let unbehandelt = null;
  const wache = (e) => { unbehandelt = e; };
  process.on('unhandledRejection', wache);
  const fehler = [];
  const alt = console.error;
  console.error = (...a) => fehler.push(a.map(String).join(' '));
  try {
    s.registriereAktionen({ kaputt: async () => { throw new Error('absichtlich'); } });
    s.aktionAusfuehren({ target: element('kaputt') });
    await new Promise(r => { setTimeout(r, 30); });
  } finally {
    console.error = alt;
    process.off('unhandledRejection', wache);
  }
  assert.equal(unbehandelt, null, 'die Ablehnung blieb unbehandelt');
  assert.ok(fehler.some(f => f.includes('absichtlich')), 'der Fehler wurde nicht protokolliert');
});

test('dieselbe Funktion zweimal registrieren ist still, eine andere unter gleichem Namen nicht', () => {
  const s = aufbau();
  const eins = () => {};
  const warnungen = mitKonsole('warn', () => {
    s.registriereAktionen({ doppelt: eins });
    s.registriereAktionen({ doppelt: eins });
    s.registriereAktionen({ doppelt: () => {} });
  });
  assert.equal(warnungen.length, 1, `erwartet eine Warnung, bekam ${warnungen.length}`);
});

test('die Seitenleiste bringt ihre Aktionen selbst mit', () => {
  // Sie werden auf JEDER Seite gebraucht, deshalb registriert shared.js sie.
  const s = aufbau();
  assert.equal(typeof s.aktionIstRegistriert, 'function');
  for (const name of ['berichtSenden', 'abmelden', 'themaWechseln', 'seitenleisteUmschalten']) {
    assert.ok(s.aktionIstRegistriert(name), `${name} fehlt`);
  }
});
