'use strict';
//
// Die Isolation der Testdatenbanken hängt an diesen beiden Funktionen.
// Ohne Tests wäre sie nur eine Behauptung.
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const { datenbankName, mitDatenbank } = require('../helpers/db-name');

test('jede Testdatei bekommt einen eigenen Namen', () => {
  assert.equal(datenbankName('/x/test/integration/auth.test.js'), 'edeka_auth_test');
  assert.equal(datenbankName('/x/test/integration/daily-close.test.js'), 'edeka_daily_close_test');
  assert.equal(datenbankName('/x/test/integration/products-validation.test.js'),
               'edeka_products_validation_test');
});

test('die Namen aller Integrationsdateien sind verschieden', () => {
  const dateien = ['auth', 'authz', 'analytics', 'injection', 'rate-limit',
                   'daily-close', 'change-password', 'products-validation'];
  const namen = dateien.map(d => datenbankName(`/x/test/integration/${d}.test.js`));
  assert.equal(new Set(namen).size, dateien.length,
    `nicht eindeutig: ${namen.join(', ')}`);
});

test('jeder abgeleitete Name endet auf _test — sonst greift der Guard nicht', () => {
  // Das ist die Eigenschaft, auf der die Sicherung in db.js beruht: egal
  // wie der Dateiname aussieht, der abgeleitete Name muss den Guard
  // passieren. '/x/.js' ist hier bewusst dabei — path.basename entfernt
  // die Endung nicht, wenn danach nichts übrig bliebe.
  for (const pfad of ['/x/auth.test.js', '/x/a-b-c.test.js', '/x/X.Y.test.js',
                      '/x/123.test.js', '/x/Ünïcode.test.js', '/x/.js']) {
    const n = datenbankName(pfad);
    assert.match(n, /_test$/, `"${pfad}" ergab "${n}"`);
  }
});

test('ohne jeden Dateinamen bleibt es beim Standard', () => {
  assert.equal(datenbankName(''), 'edeka_lager_test');
  assert.equal(datenbankName(undefined), 'edeka_lager_test');
  assert.equal(datenbankName(null), 'edeka_lager_test');
});

test('mitDatenbank tauscht den Namen in der URI aus', () => {
  assert.equal(
    mitDatenbank('mongodb://127.0.0.1:27017/edeka_lager_test', 'edeka_auth_test'),
    'mongodb://127.0.0.1:27017/edeka_auth_test');
});

test('mitDatenbank hängt einen Namen an, wenn die URI keinen hat', () => {
  assert.equal(mitDatenbank('mongodb://127.0.0.1:27017', 'edeka_auth_test'),
               'mongodb://127.0.0.1:27017/edeka_auth_test');
  assert.equal(mitDatenbank('mongodb://127.0.0.1:27017/', 'edeka_auth_test'),
               'mongodb://127.0.0.1:27017/edeka_auth_test');
});

test('mitDatenbank lässt Optionen hinter ? unangetastet', () => {
  assert.equal(
    mitDatenbank('mongodb://127.0.0.1:27017/alt?retryWrites=true&w=majority', 'edeka_auth_test'),
    'mongodb://127.0.0.1:27017/edeka_auth_test?retryWrites=true&w=majority');
});

test('mitDatenbank kommt mit mongodb+srv zurecht', () => {
  assert.equal(
    mitDatenbank('mongodb+srv://u:p@cluster.mongodb.net/alt_test?tls=true', 'edeka_auth_test'),
    'mongodb+srv://u:p@cluster.mongodb.net/edeka_auth_test?tls=true');
});
