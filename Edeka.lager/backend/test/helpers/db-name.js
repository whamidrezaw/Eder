'use strict';
//
// Reine Funktionen ohne Seiteneffekte — bewusst getrennt von db.js, damit
// sie ohne Mongoose und ohne Datenbank unit-getestet werden können.
//
const path = require('node:path');

/**
 * Leitet aus dem Pfad einer Testdatei einen eigenen Datenbanknamen ab.
 *
 *   test/integration/auth.test.js  ->  edeka_auth_test
 *
 * Der Name endet immer auf _test, damit die Sicherung in db.js unverändert
 * greift. Ohne erkennbaren Dateinamen bleibt es beim gemeinsamen Standard.
 */
function datenbankName(dateipfad) {
  const stamm = path.basename(String(dateipfad || ''), '.js')
    .replace(/\.test$/, '')
    .replace(/[^a-zA-Z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '')
    .toLowerCase();
  return stamm ? `edeka_${stamm}_test` : 'edeka_lager_test';
}

/**
 * Ersetzt den Datenbanknamen in einer Mongo-URI. Optionen hinter ? bleiben
 * erhalten; fehlt in der URI ein Name, wird einer angehängt.
 */
function mitDatenbank(uri, name) {
  const [ohneOptionen, optionen] = String(uri).split('?');
  const teile = ohneOptionen.replace(/\/+$/, '').split('/');
  // mongodb://host:port        -> drei Teile, es gibt noch keinen Namen
  // mongodb://host:port/dbname -> vier Teile
  if (teile.length <= 3) teile.push(name);
  else teile[teile.length - 1] = name;
  return teile.join('/') + (optionen ? '?' + optionen : '');
}

module.exports = { datenbankName, mitDatenbank };
