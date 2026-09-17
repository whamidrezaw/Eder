'use strict';
//
// Batch C2 — Auswertungen (/analytics und /history).
//
// Mehrere Tests sind absichtlich ROT: sie sind der Nachweis, dass die
// Auswertungen heute still Daten verlieren, zu viel in den Arbeitsspeicher
// holen und nach dem Produktnamen statt nach der Produkt-ID gruppieren.
// Jeder rote Test ist mit "── ROT ──" markiert.
//
const test     = require('node:test');
const assert   = require('node:assert/strict');
const mongoose = require('mongoose');
const db       = require('../helpers/db');
const DailyLog = require('../../models/DailyLog');
const { berlinDateString } = require('../../services/dailyClose');
const { start, stop, req }  = require('../helpers/http');
const { makeLageristToken } = require('../helpers/factories');

let token;

test.before(async () => { await db.connect(); await start(); });
test.after (async () => { await stop(); await db.disconnect(); });
test.beforeEach(async () => { await db.wipe(); token = await makeLageristToken(); });

// Feste Basis statt "heute", damit die Tests unabhängig vom Kalender sind.
const BASIS = Date.UTC(2026, 8, 1);            // 2026-09-01
function datumVor(tage) {
  const d = new Date(BASIS);
  d.setUTCDate(d.getUTCDate() - tage);
  return d.toISOString().slice(0, 10);
}

function eintrag(over = {}) {
  return {
    productId:    new mongoose.Types.ObjectId(),
    productName:  'Apfel',
    emoji:        '🍎',
    category:     'Obst',
    unit:         'kg',
    isBio:        false,
    openingStock: 10,
    closingStock: 8,
    consumed:     2,
    ...over
  };
}

/**
 * Legt `tage` Tage mit je `proTag` Protokollen an. Das erste Protokoll je
 * Tag ist auto-midnight (mehr erlaubt der eindeutige Index nicht), der Rest
 * manuell. Jedes Protokoll enthält `produkte` Positionen.
 */
async function seedLogs({ tage, proTag = 1, produkte = 1 }) {
  const docs = [];
  for (let t = 0; t < tage; t++) {
    const datum = datumVor(t);
    for (let i = 0; i < proTag; i++) {
      docs.push({
        date:   datum,
        sentAt: new Date(`${datum}T${String(6 + (i % 16)).padStart(2, '0')}:00:00Z`),
        type:   i === 0 ? 'auto-midnight' : 'manual',
        snapshot: Array.from({ length: produkte }, (_, k) =>
          eintrag({ productName: `Produkt ${k}`, consumed: 2 }))
      });
    }
  }
  await DailyLog.insertMany(docs);
  return docs.length;
}

// Ersetzt eine Model-Methode und stellt die Vererbung danach wieder her.
function ersetze(model, methode, fabrik) {
  const original = model[methode].bind(model);
  model[methode] = fabrik(original);
  return () => { delete model[methode]; };
}

// ── Kontrolle: muss GRÜN sein ─────────────────────────────────────

test('Kontrolle: /analytics liefert für jeden Tag einen Punkt', async () => {
  await seedLogs({ tage: 5, proTag: 1, produkte: 2 });

  const r = await req('/api/reports/analytics?days=14', { token });
  assert.equal(r.status, 200, r.text);
  assert.equal(r.body.trend.length, 5,
    `erwartet 5 Tage, bekommen ${r.body.trend.length}`);
  assert.equal(r.body.trend[0].totalConsumed, 4, 'zwei Produkte à 2 = 4 pro Tag');
  assert.equal(r.body.summary.totalDays, 5);
});

// ── Befund 1: die Annahme "höchstens 8 Berichte pro Tag" ──────────

// ── ROT ──
test('/analytics verliert keine Tage, wenn viel berichtet wurde', async () => {
  // 14 Tage, 20 Berichte je Tag. Das Fenster limit(days * 8) = 112 deckt
  // damit nur die sechs jüngsten Tage ab — acht Tage fallen still heraus.
  await seedLogs({ tage: 14, proTag: 20, produkte: 1 });

  const r = await req('/api/reports/analytics?days=14', { token });
  assert.equal(r.status, 200, r.text);
  assert.equal(r.body.trend.length, 14,
    `nur ${r.body.trend.length} von 14 Tagen im Ergebnis — das Fenster wird ` +
    `nach Anzahl der Protokolle begrenzt, nicht nach Datum. An einem Tag mit ` +
    `vielen Berichten verschwinden ältere Tage ohne Hinweis aus dem Diagramm.`);
});

// ── ROT ──
test('/history verliert keine Tage, wenn viel berichtet wurde', async () => {
  await seedLogs({ tage: 20, proTag: 20, produkte: 1 });

  const r = await req('/api/reports/history?limit=20', { token });
  assert.equal(r.status, 200, r.text);

  // Antwortform ist mir nicht sicher bekannt — hier wird sie ermittelt.
  const liste = Array.isArray(r.body)
    ? r.body
    : (r.body.history || r.body.rows || r.body.days || r.body.entries);
  assert.ok(Array.isArray(liste),
    `unerwartete Antwortform: ${JSON.stringify(r.body).slice(0, 200)}`);

  assert.equal(liste.length, 20,
    `nur ${liste.length} von 20 Tagen — dasselbe limit * 8 wie in /analytics.`);
});

// ── Befund 2: Arbeitsspeicher ─────────────────────────────────────

// ── ROT ──
test('/analytics holt nicht alle Momentaufnahmen in den Arbeitsspeicher', async () => {
  await seedLogs({ tage: 20, proTag: 1, produkte: 100 });

  // Ein Protokoll für den echten heutigen Tag, damit die Zählerprobe unten
  // etwas zu messen hat (/today fragt nach berlinDateString(new Date())).
  await DailyLog.create({
    date:   berlinDateString(new Date()),
    sentAt: new Date(),
    type:   'manual',
    snapshot: Array.from({ length: 5 }, (_, k) => eintrag({ productName: `Heute ${k}` }))
  });

  let positionen = 0;
  const zaehle = (ergebnis) => {
    const liste = Array.isArray(ergebnis) ? ergebnis : (ergebnis ? [ergebnis] : []);
    for (const d of liste) {
      const s = d && (d.snapshot || (d._doc && d._doc.snapshot));
      if (Array.isArray(s)) positionen += s.length;
    }
  };

  // Query-Objekte werden verzögert ausgeführt: gezählt wird in exec(),
  // denn "await query" ruft intern genau das auf.
  const haenge = (original) => (...args) => {
    const q = original(...args);
    const origExec = q.exec.bind(q);
    q.exec = async (...a) => { const r = await origExec(...a); zaehle(r); return r; };
    return q;
  };
  const auf1 = ersetze(DailyLog, 'find', haenge);
  const auf2 = ersetze(DailyLog, 'findOne', haenge);

  try {
    // Probe: greift der Zähler überhaupt? /today lädt bewusst Momentaufnahmen
    // und ist nicht Teil von C2 — dort muss der Zähler anschlagen.
    await req('/api/reports/today', { token });
    assert.ok(positionen > 0,
      'der Zähler greift nicht — die Messung unten wäre wertlos. Bitte Ausgabe schicken.');

    positionen = 0;
    const r = await req('/api/reports/analytics?days=20', { token });
    assert.equal(r.status, 200, r.text);

    assert.ok(positionen <= 200,
      `${positionen} Momentaufnahme-Positionen wurden nach Node geladen, um ` +
      `höchstens 100 Ergebniszeilen zu berechnen. Das Zusammenfassen gehört ` +
      `in die Datenbank ($unwind + $group), nicht in den Arbeitsspeicher.`);
  } finally {
    auf1(); auf2();
  }
});

// ── Befund 3: Gruppierung nach Namen statt nach Produkt-ID ────────

// ── ROT ──
test('ein umbenanntes Produkt bleibt eine Zeitreihe', async () => {
  const pid = new mongoose.Types.ObjectId();

  // Momentaufnahmen halten den Namen des jeweiligen Tages fest — das ist
  // richtig. Falsch ist, daraus den Gruppierungsschlüssel zu bilden.
  await DailyLog.insertMany([
    { date: datumVor(1), sentAt: new Date(`${datumVor(1)}T22:00:00Z`), type: 'auto-midnight',
      snapshot: [eintrag({ productId: pid, productName: 'Apfel', consumed: 3 })] },
    { date: datumVor(0), sentAt: new Date(`${datumVor(0)}T22:00:00Z`), type: 'auto-midnight',
      snapshot: [eintrag({ productId: pid, productName: 'Apfel Braeburn', consumed: 4 })] }
  ]);

  const r = await req('/api/reports/analytics?days=14', { token });
  assert.equal(r.status, 200, r.text);

  assert.equal(r.body.allProducts.length, 1,
    `${r.body.allProducts.length} Einträge für ein einziges Produkt ` +
    `(${r.body.allProducts.map(p => p.name).join(', ')}) — eine Umbenennung ` +
    `spaltet die Historie, obwohl die productId in der Momentaufnahme steht.`);
  assert.equal(r.body.allProducts[0].totalConsumed, 7, 'beide Tage müssen zusammenzählen');
});

// ── ROT ──
test('zwei verschiedene Produkte mit gleichem Namen bleiben getrennt', async () => {
  const datum = datumVor(0);
  await DailyLog.create({
    date: datum, sentAt: new Date(`${datum}T22:00:00Z`), type: 'auto-midnight',
    snapshot: [
      eintrag({ productName: 'Apfel', consumed: 3 }),   // eigene productId
      eintrag({ productName: 'Apfel', consumed: 5 })    // andere productId
    ]
  });

  const r = await req('/api/reports/analytics?days=14', { token });
  assert.equal(r.status, 200, r.text);

  assert.equal(r.body.allProducts.length, 2,
    `${r.body.allProducts.length} statt 2 Einträge — zwei getrennte Produkte ` +
    `wurden allein wegen des gleichen Namens zusammengeworfen.`);
});

// ── Offene Frage: wird isBio richtig gemeldet? ────────────────────
// In meiner Kopie von routes/reports.js liegt genau an dieser Stelle eine
// Bruchkante; ich kann nicht erkennen, ob dort !p.isBio oder !!p.isBio
// steht. Bei !p.isBio wäre die Bio-Kennzeichnung in allen Auswertungen
// verdreht. Dieser Test entscheidet es, statt zu raten.

test('isBio wird in den Auswertungen unverdreht gemeldet', async () => {
  const datum = datumVor(0);
  await DailyLog.create({
    date: datum, sentAt: new Date(`${datum}T22:00:00Z`), type: 'auto-midnight',
    snapshot: [
      eintrag({ productName: 'Bio-Apfel',   isBio: true,  consumed: 1 }),
      eintrag({ productName: 'Normalapfel', isBio: false, consumed: 1 })
    ]
  });

  const r = await req('/api/reports/analytics?days=14', { token });
  assert.equal(r.status, 200, r.text);

  const bio    = r.body.allProducts.find(p => p.name === 'Bio-Apfel');
  const normal = r.body.allProducts.find(p => p.name === 'Normalapfel');
  assert.ok(bio && normal, `Produkte nicht gefunden: ${JSON.stringify(r.body.allProducts)}`);

  assert.equal(bio.isBio,    true,  'Bio-Produkt wird als nicht-Bio gemeldet');
  assert.equal(normal.isBio, false, 'Normalprodukt wird als Bio gemeldet');
});

// ── Randfall: unsinniger days-Parameter ───────────────────────────
// Math.min(parseInt(days) || 14, 90) lässt negative Werte durch. Daraus
// wird limit(-8 * n) und slice(0, -n) — beides still verkürzend.

test('/analytics verhält sich bei negativem days-Wert vernünftig', async () => {
  await seedLogs({ tage: 5, proTag: 1, produkte: 1 });

  const r = await req('/api/reports/analytics?days=-5', { token });
  assert.ok(r.status === 200 || r.status === 400,
    `unerwarteter Status ${r.status}: ${r.text}`);

  if (r.status === 200) {
    assert.ok(Array.isArray(r.body.trend), 'trend muss ein Array sein');
    assert.ok(r.body.trend.length > 0,
      'bei vorhandenen Protokollen darf ein negativer days-Wert nicht zu ' +
      'einem leeren Diagramm führen — entweder 400 oder ein sinnvoller Standard.');
  }
});
