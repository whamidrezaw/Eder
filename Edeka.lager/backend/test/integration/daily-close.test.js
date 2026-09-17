'use strict';
//
// Batch C1 — Tagesabschluss.
//
// Diese Datei beschreibt vier Regeln, die der Abschluss einhalten muss.
// Mehrere Tests sind absichtlich ROT: sie sind der Nachweis, dass die
// Regeln heute verletzt werden. Jeder rote Test ist mit "── ROT:" markiert.
//
const test     = require('node:test');
const assert   = require('node:assert/strict');
const db       = require('../helpers/db');
const Product  = require('../../models/Product');
const DailyLog = require('../../models/DailyLog');
const dailyClose = require('../../services/dailyClose');
const { closeDay, yesterdayInBerlin } = dailyClose;

test.before(async () => { await db.connect(); });
test.after (async () => { await db.disconnect(); });
test.beforeEach(async () => { await db.wipe(); });

async function seedProducts(anzahl = 3, bestand = 10) {
  const docs = [];
  for (let i = 0; i < anzahl; i++) {
    docs.push({
      name: `Produkt ${i}`, category: 'Obst', unit: 'Kiste', emoji: '🍎',
      isBio: false, currentStock: bestand, yesterdayStock: bestand, isActive: true
    });
  }
  return Product.create(docs);
}

// Ersetzt eine Model-Methode und stellt die Vererbung danach wieder her.
// (Model-Methoden liegen auf dem Prototyp — ein delete reicht zum Aufräumen.)
function ersetze(model, methode, fabrik) {
  const original = model[methode].bind(model);
  model[methode] = fabrik(original);
  return () => { delete model[methode]; };
}

// ── Kontrolle: läuft der Abschluss überhaupt? ─────────────────────
// Dieser Test muss GRÜN sein. Ist er rot, stimmt eine meiner Annahmen
// über closeDay() nicht — dann bitte seine Ausgabe schicken.

test('Kontrolle: closeDay() schreibt genau ein Protokoll für gestern', async () => {
  await seedProducts(3, 10);
  await closeDay();

  const alle = await DailyLog.find({}).lean();
  assert.equal(alle.length, 1,
    `erwartet 1 Protokoll, gefunden: ${JSON.stringify(alle.map(l => [l.date, l.type]))}`);
  assert.equal(alle[0].type, 'auto-midnight',
    `Typ ist "${alle[0].type}" — meine Annahme "auto-midnight" stimmt dann nicht`);
  assert.equal(alle[0].date, yesterdayInBerlin());
});

test('Kontrolle: nach dem Abschluss ist der Verbrauch für den neuen Tag 0', async () => {
  await seedProducts(3, 10);
  await closeDay();

  for (const p of await Product.find({}).lean()) {
    assert.equal(Math.max(0, p.yesterdayStock - p.currentStock), 0,
      `${p.name}: sofort nach dem Abschluss wird Verbrauch angezeigt`);
  }
});

// ── Regel 2: genau ein auto-midnight je Tag ───────────────────────

// ── ROT ──
test('zweiter Abschluss am selben Tag legt kein zweites Protokoll an', async () => {
  await seedProducts(2, 10);
  await closeDay();
  await closeDay();

  const n = await DailyLog.countDocuments({ date: yesterdayInBerlin(), type: 'auto-midnight' });
  assert.equal(n, 1,
    `${n} auto-midnight-Protokolle für denselben Tag — der Abschluss ist nicht idempotent. ` +
    `Ein Neustart um 00:00 oder ein zweites Server-Exemplar erzeugt Dubletten.`);
});

// ── ROT ──
test('die Datenbank selbst verhindert doppelte auto-midnight-Protokolle', async () => {
  await DailyLog.syncIndexes();
  const datum = '2026-05-02';
  await DailyLog.create({ date: datum, sentAt: new Date(), type: 'auto-midnight', snapshot: [] });

  await assert.rejects(
    () => DailyLog.create({ date: datum, sentAt: new Date(), type: 'auto-midnight', snapshot: [] }),
    /E11000|duplicate key/,
    'Es fehlt ein eindeutiger Index auf { date, type } für auto-midnight. ' +
    'Ohne ihn hilft eine Prüfung im Code nicht gegen zwei parallele Prozesse.'
  );
});

// Leitplanke: Der Index darf NICHT zu streng werden. An einem Tag dürfen
// beliebig viele manuelle Berichte entstehen — das ist der Normalfall.
test('mehrere manuelle Berichte am selben Tag bleiben erlaubt', async () => {
  await DailyLog.syncIndexes();
  const datum = '2026-05-02';
  await DailyLog.create({ date: datum, sentAt: new Date('2026-05-02T08:00:00Z'), type: 'manual', snapshot: [] });
  await DailyLog.create({ date: datum, sentAt: new Date('2026-05-02T13:00:00Z'), type: 'manual', snapshot: [] });
  await DailyLog.create({ date: datum, sentAt: new Date('2026-05-02T19:00:00Z'), type: 'manual', snapshot: [] });

  assert.equal(await DailyLog.countDocuments({ date: datum, type: 'manual' }), 3);
});

// ── Regel 3: ein erneuter Abschluss löscht den Tagesverbrauch nicht ──

// ── ROT ──
test('zweiter Abschluss löscht den Verbrauch des laufenden Tages nicht', async () => {
  const [p] = await seedProducts(1, 10);
  await closeDay();                                                // Basislinie: 10

  await Product.updateOne({ _id: p._id }, { currentStock: 4 });     // Verkauf über den Tag
  await closeDay();                                                // z. B. Klick auf "Tag abschließen"

  const nachher = await Product.findById(p._id).lean();
  assert.equal(nachher.yesterdayStock, 10,
    `Basislinie wurde auf ${nachher.yesterdayStock} überschrieben — ` +
    `der bis dahin gemessene Verbrauch von 6 verschwindet aus der Anzeige.`);
});

// ── Regel 1: Momentaufnahme und Basislinie gehören zusammen ───────

// ── ROT ──
test('gleichzeitige Bestandsänderung während des Abschlusses erzeugt keinen Phantomverbrauch', async () => {
  const [p] = await seedProducts(1, 10);

  // Zwischen dem Lesen der Produkte und dem Schreiben von yesterdayStock
  // liegt eine Lücke. Hier wird genau dort eine Änderung eingeschoben —
  // so, wie sie in einer Nacht mit spätem Wareneingang passieren kann.
  let hookLief = false;
  const aufraeumen = ersetze(DailyLog, 'create', (original) => async (...args) => {
    const ergebnis = await original(...args);
    hookLief = true;
    await Product.updateOne({ _id: p._id }, { currentStock: 3 });
    return ergebnis;
  });

  try { await closeDay(); } finally { aufraeumen(); }

  assert.ok(hookLief,
    'closeDay() benutzt DailyLog.create nicht — dieser Test greift nicht. Bitte Ausgabe schicken.');

  const nachher = await Product.findById(p._id).lean();
  assert.equal(nachher.yesterdayStock, nachher.currentStock,
    `yesterdayStock=${nachher.yesterdayStock}, currentStock=${nachher.currentStock} — ` +
    `direkt nach dem Abschluss zeigt die Übersicht einen Verbrauch, den es nie gab.`);
});

// ── Schreibaufwand ────────────────────────────────────────────────

// ── ROT ──
test('closeDay() schreibt die Basislinie gesammelt, nicht einmal pro Produkt', async () => {
  await seedProducts(40, 10);

  let einzelschreibungen = 0;
  const zaehlen = (original) => (...args) => { einzelschreibungen++; return original(...args); };
  const auf1 = ersetze(Product, 'findByIdAndUpdate', zaehlen);
  const auf2 = ersetze(Product, 'findOneAndUpdate', zaehlen);
  const auf3 = ersetze(Product, 'updateOne',        zaehlen);

  try { await closeDay(); } finally { auf1(); auf2(); auf3(); }

  assert.ok(einzelschreibungen <= 2,
    `${einzelschreibungen} Einzelschreibvorgänge bei 40 Produkten. ` +
    `Eine Sammeloperation genügt — und nur sie liest und schreibt je Dokument atomar.`);
});

// ── Regel 4: verpasster Abschluss wird nachgeholt ─────────────────

// ── ROT ──
test('ein verpasster Tagesabschluss wird beim Start nachgeholt', async () => {
  assert.equal(typeof dailyClose.catchUpIfNeeded, 'function',
    'catchUpIfNeeded() gibt es noch nicht. War der Server um Mitternacht aus, ' +
    'bleibt der Tag für immer offen und die Verbrauchsanzeige den ganzen Folgetag falsch.');

  await seedProducts(2, 10);
  assert.equal(await DailyLog.countDocuments({}), 0);

  await dailyClose.catchUpIfNeeded();

  assert.equal(await DailyLog.countDocuments({ date: yesterdayInBerlin(), type: 'auto-midnight' }), 1,
    'der fehlende Abschluss wurde nicht nachgeholt');
});

// ── ROT ──
test('ein bereits erledigter Abschluss wird beim Start nicht wiederholt', async () => {
  assert.equal(typeof dailyClose.catchUpIfNeeded, 'function', 'catchUpIfNeeded() fehlt noch');

  const [p] = await seedProducts(1, 10);
  await closeDay();
  await Product.updateOne({ _id: p._id }, { currentStock: 4 });

  await dailyClose.catchUpIfNeeded();   // Neustart mitten am Tag

  const nachher = await Product.findById(p._id).lean();
  assert.equal(nachher.yesterdayStock, 10,
    'ein Neustart am Vormittag hat die Basislinie überschrieben');
  assert.equal(await DailyLog.countDocuments({ type: 'auto-midnight' }), 1);
});
