'use strict';
//
// Vertrag des Bestandsschreibers.
//
// Diese Tests sind rot, weil createBestandsschreiber noch nicht existiert —
// sie beweisen den Befund nicht, sie beschreiben die Lösung. Der Beweis
// liegt schon vor: drei 409 hintereinander in der Browserkonsole, bei einem
// einzigen Benutzer und einem einzigen Produkt.
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const { ladeShared } = require('../helpers/browser');

const warte = (ms) => new Promise(r => { setTimeout(r, ms); });

function fehler409(stand, version) {
  const e = new Error('Konflikt');
  e.status = 409;
  e.data = { code: 'STOCK_CONFLICT', currentStock: stand, updatedAt: version };
  return e;
}

// Baut einen Schreiber mit Attrappen und gibt alles zurück, was ein Test
// beobachten will. antwortGeber bestimmt, wie der Server reagiert.
function aufbau(antwortGeber) {
  const { sandbox } = ladeShared({ token: 'test-token' });
  const bauen = sandbox.createBestandsschreiber;
  assert.equal(typeof bauen, 'function',
    'createBestandsschreiber fehlt in shared.js');

  const produkt  = { _id: 'p1', name: 'Äpfel', currentStock: 10, updatedAt: 'v1' };
  const anfragen = [];
  const meldungen = [];
  const fragen   = [];
  let jaSagen    = true;

  const schreiber = bauen({
    holeProdukt: () => produkt,
    zeichne:     () => {},
    melde:       (t) => meldungen.push(t),
    frage:       (t) => { fragen.push(t); return jaSagen; },
    schreibe: (id, wert, version) => {
      const a = { id, wert, version };
      anfragen.push(a);
      return antwortGeber
        ? antwortGeber(a)
        : Promise.resolve({ currentStock: wert, updatedAt: 'v' + (anfragen.length + 1) });
    },
    verzoegerung: 5
  });

  return {
    schreiber, produkt, anfragen, meldungen, fragen,
    nein: () => { jaSagen = false; }
  };
}

// ── Der Befund ────────────────────────────────────────────────────

test('drei schnelle Klicks ergeben EINE Anfrage mit dem Endwert', async () => {
  const t = aufbau();

  t.schreiber.aendern('p1', 1);
  t.schreiber.aendern('p1', 1);
  t.schreiber.aendern('p1', 1);

  // Die Anzeige springt sofort mit — der Nutzer wartet auf nichts.
  assert.equal(t.produkt.currentStock, 13, 'die Anzeige folgt dem Klick nicht sofort');

  await warte(40);
  assert.equal(t.anfragen.length, 1, `${t.anfragen.length} Anfragen statt einer`);
  assert.equal(t.anfragen[0].wert, 13);
  assert.equal(t.fragen.length, 0, 'es wurde ein Konflikt erfunden, den es nicht gab');
});

test('ein Klick während einer laufenden Anfrage benutzt danach die frische Version', async () => {
  let ersteAufloesen;
  const t = aufbau((a) => a.wert === 11
    ? new Promise(r => { ersteAufloesen = () => r({ currentStock: 11, updatedAt: 'v2' }); })
    : Promise.resolve({ currentStock: a.wert, updatedAt: 'v3' }));

  t.schreiber.aendern('p1', 1);          // 11
  await warte(20);
  assert.equal(t.anfragen.length, 1, 'die erste Anfrage läuft nicht');

  t.schreiber.aendern('p1', 1);          // 12, während die erste noch läuft
  await warte(20);
  assert.equal(t.anfragen.length, 1, 'zwei Anfragen gleichzeitig für dasselbe Produkt');

  ersteAufloesen();
  await warte(30);

  assert.equal(t.anfragen.length, 2);
  assert.equal(t.anfragen[1].wert, 12);
  assert.equal(t.anfragen[1].version, 'v2',
    'die zweite Anfrage schickt noch die alte Version — genau der Fehler von vorher');
  assert.equal(t.fragen.length, 0);
});

// ── Echte Konflikte müssen erhalten bleiben ───────────────────────

test('ein echter Konflikt fragt nach und schreibt dann mit der frischen Version', async () => {
  const t = aufbau((a) => a.version === 'v1'
    ? Promise.reject(fehler409(8, 'v9'))
    : Promise.resolve({ currentStock: a.wert, updatedAt: 'v10' }));

  t.schreiber.setzen('p1', 4);
  await warte(30);

  assert.equal(t.fragen.length, 1, 'es wurde nicht nachgefragt');
  assert.match(t.fragen[0], /8/, 'die Rückfrage nennt den aktuellen Stand nicht');

  await warte(30);
  assert.equal(t.anfragen.length, 2, 'nach dem Ja wurde nicht erneut geschrieben');
  assert.equal(t.anfragen[1].version, 'v9', 'der zweite Versuch benutzt nicht die frische Version');
  assert.equal(t.anfragen[1].wert, 4);
});

test('wer den Konflikt abbricht, überschreibt nichts', async () => {
  const t = aufbau((a) => a.version === 'v1'
    ? Promise.reject(fehler409(8, 'v9'))
    : Promise.resolve({ currentStock: a.wert, updatedAt: 'v10' }));
  t.nein();

  t.schreiber.setzen('p1', 4);
  await warte(40);

  assert.equal(t.anfragen.length, 1, 'trotz Abbruch wurde geschrieben');
  assert.equal(t.produkt.currentStock, 8, 'die Anzeige zeigt nicht den echten Stand');
});

// ── Andere Fehler ─────────────────────────────────────────────────

test('ein anderer Fehler meldet sich und nimmt die Anzeige zurück', async () => {
  const t = aufbau(() => {
    const e = new Error('Server kaputt');
    e.status = 500;
    return Promise.reject(e);
  });

  t.schreiber.aendern('p1', 5);          // Anzeige zeigt sofort 15
  await warte(40);

  assert.equal(t.meldungen.length, 1, 'der Fehler wurde nicht gemeldet');
  assert.match(t.meldungen[0], /Server kaputt/);
  assert.equal(t.produkt.currentStock, 10,
    'die Anzeige bleibt auf einem Wert stehen, den der Server nie bekommen hat');
});

test('ein Wert, der dem bestätigten Stand entspricht, erzeugt keine Anfrage', async () => {
  const t = aufbau();
  t.schreiber.aendern('p1', 1);
  t.schreiber.aendern('p1', -1);         // wieder 10
  await warte(40);
  assert.equal(t.anfragen.length, 0, 'es wurde ohne Änderung geschrieben');
});
