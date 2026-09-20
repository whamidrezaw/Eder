'use strict';
require('./env');
const mongoose = require('mongoose');
const { datenbankName, mitDatenbank } = require('./db-name');

// ── Eine eigene Datenbank je Testdatei ──────────────────────────────
//
// node --test startet jede Testdatei in einem eigenen Prozess und führt
// mehrere davon gleichzeitig aus. Vorher teilten sich alle Dateien EINE
// Datenbank und leerten sie in beforeEach: auf einer Maschine mit einem
// Kern lief das zufällig hintereinander, auf dem CI-Runner mit vier Kernen
// löschte jede Datei die Daten der anderen mitten im Lauf.
//
// MONGODB_TEST_URI ist deshalb nur noch die Vorlage — der Name darin wird
// je Datei ersetzt.
const BASIS = process.env.MONGODB_TEST_URI || 'mongodb://127.0.0.1:27017/edeka_lager_test';
const dbName = datenbankName(process.argv[1]);
const URI    = mitDatenbank(BASIS, dbName);

// ── Sicherung: niemals gegen eine echte Datenbank testen ────────────
// Die Tests leeren nach jedem Fall alle Collections und verwerfen die
// Datenbank am Ende. Deshalb läuft dieser Guard, bevor überhaupt
// verbunden wird.
if (!/_test$/.test(dbName)) {
  throw new Error(`Testdatenbank muss auf "_test" enden (abgeleitet: "${dbName}").`);
}
if (process.env.NODE_ENV === 'production') {
  throw new Error('Tests dürfen nicht mit NODE_ENV=production laufen.');
}

// Zum Nachsehen nach einem fehlgeschlagenen Lauf: KEEP_TEST_DB=1 npm run test:integration
const BEHALTEN = process.env.KEEP_TEST_DB === '1';

async function connect() {
  if (mongoose.connection.readyState === 1) return;
  try {
    await mongoose.connect(URI, { serverSelectionTimeoutMS: 5000 });
  } catch (err) {
    throw new Error(
      `Keine Verbindung zur Testdatenbank (${URI}).\n` +
      `Läuft MongoDB lokal? Starte sie, oder setze MONGODB_TEST_URI.\n` +
      `Ursprünglicher Fehler: ${err.message}`
    );
  }
}

async function wipe() {
  const cols = mongoose.connection.collections;
  await Promise.all(Object.values(cols).map(c => c.deleteMany({})));
}

async function disconnect() {
  if (mongoose.connection.readyState === 1 && !BEHALTEN) {
    // Aufräumen darf niemals einen Testlauf kippen.
    try { await mongoose.connection.dropDatabase(); } catch { /* egal */ }
  }
  await mongoose.disconnect();
}

module.exports = { connect, wipe, disconnect, URI, dbName };
