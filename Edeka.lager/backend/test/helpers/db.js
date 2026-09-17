'use strict';
require('./env');
const mongoose = require('mongoose');

const URI = process.env.MONGODB_TEST_URI || 'mongodb://127.0.0.1:27017/edeka_lager_test';

// ── Sicherung: niemals gegen eine echte Datenbank testen ────────────
// Die Tests leeren nach jedem Fall ALLE Collections. Deshalb läuft hier ein
// harter Guard, bevor überhaupt verbunden wird.
const dbName = URI.split('/').pop().split('?')[0];
if (!/_test$/.test(dbName)) {
  throw new Error(
    `Testdatenbank muss auf "_test" enden (gefunden: "${dbName}").\n` +
    `Setze MONGODB_TEST_URI, z. B. mongodb://127.0.0.1:27017/edeka_lager_test`
  );
}
if (process.env.NODE_ENV === 'production') {
  throw new Error('Tests dürfen nicht mit NODE_ENV=production laufen.');
}

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
  await mongoose.disconnect();
}

module.exports = { connect, wipe, disconnect, URI, dbName };
