#!/usr/bin/env bash
#
# apply-test-isolation.sh — eine eigene Datenbank je Testdatei
#
# Befund: node --test startet jede Testdatei in einem eigenen Prozess und
# führt mehrere davon parallel aus (Voreinstellung: Kerne minus eins). Alle
# Integrationsdateien teilten sich EINE Datenbank und leerten sie in
# beforeEach. Auf dem Einkern-VPS lief das zufällig sequenziell und fiel nie
# auf; auf dem CI-Runner mit vier Kernen löschte jede Datei die Daten der
# anderen mitten im Lauf:
#
#   E11000 duplicate key: { username: "lager_test" }
#   401 !== 400   (der Benutzer war weggewischt, das Token damit ungültig)
#
# Korrektur: Der Datenbankname wird aus dem Dateinamen abgeleitet. Damit ist
# die Testsuite richtig, unabhängig davon, wie sie gestartet wird — statt
# richtig zu sein, solange niemand parallel startet.
#
# Ausführen im Wurzelverzeichnis des Repos:
#     bash apply-test-isolation.sh
#
set -euo pipefail

BE="Edeka.lager/backend"
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
skip() { printf '  \033[90m·\033[0m %s\n' "$1"; }
die()  { printf '\n  \033[31m✗ %s\033[0m\n\n' "$1" >&2; exit 1; }

echo
echo "── Testisolation: eine Datenbank je Datei ──────────────────────"
echo

[ -f "$BE/test/helpers/db.js" ] || die "'$BE/test/helpers/db.js' nicht gefunden."

if command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
  [ -z "$(git status --porcelain)" ] || die "Arbeitsverzeichnis nicht sauber. Bitte erst committen."
  ok "Arbeitsverzeichnis sauber"
fi

# ── 1  Reines Namensmodul ────────────────────────────────────────────
cat > "$BE/test/helpers/db-name.js" <<'EOF'
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
EOF
ok "test/helpers/db-name.js"

# ── 2  db.js neu ─────────────────────────────────────────────────────
cp "$BE/test/helpers/db.js" "$BE/test/helpers/db.js.iso.bak"
cat > "$BE/test/helpers/db.js" <<'EOF'
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
EOF
ok "test/helpers/db.js neu geschrieben (Sicherungskopie: db.js.iso.bak)"

# ── 3  Unit-Tests für das Namensmodul ────────────────────────────────
cat > "$BE/test/unit/db-name.test.js" <<'EOF'
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
EOF
ok "test/unit/db-name.test.js (8 Tests)"

# ── 4  Dokumentation nachziehen ──────────────────────────────────────
cat > "$BE/test/README.md" <<'EOF'
# Tests

## Ausführen

```bash
cd Edeka.lager/backend

npm run test:unit          # schnell, keine Datenbank nötig
npm run test:integration   # braucht eine laufende MongoDB
npm test                   # alles
npm run test:coverage      # mit Abdeckungsbericht
```

## Datenbanken für die Integrationstests

`MONGODB_TEST_URI` ist eine **Vorlage**, keine feste Datenbank. Standard ist
`mongodb://127.0.0.1:27017/edeka_lager_test`. Jede Testdatei bekommt daraus
ihre eigene Datenbank, abgeleitet aus dem Dateinamen:

| Datei                                     | Datenbank                        |
| ----------------------------------------- | -------------------------------- |
| `test/integration/auth.test.js`           | `edeka_auth_test`                |
| `test/integration/daily-close.test.js`    | `edeka_daily_close_test`         |
| `test/integration/analytics.test.js`      | `edeka_analytics_test`           |

Der Grund: `node --test` startet jede Datei in einem eigenen Prozess und
führt mehrere davon gleichzeitig aus. Mit einer gemeinsamen Datenbank löschte
jede Datei in `beforeEach` die Daten der anderen. Auf einer Maschine mit
einem Kern fiel das nie auf, auf einem Runner mit vier Kernen sofort.

Jede Datenbank wird am Ende ihres Laufs verworfen. Zum Nachsehen nach einem
Fehlschlag:

```bash
KEEP_TEST_DB=1 npm run test:integration
```

Der abgeleitete Name endet immer auf `_test`; andernfalls bricht
`test/helpers/db.js` ab, bevor überhaupt verbunden wird. Die Ableitung selbst
ist in `test/unit/db-name.test.js` abgesichert.

Telegram wird in Tests nie kontaktiert: `TELEGRAM_BOT_TOKEN` ist leer gesetzt,
wodurch `sendTelegram()` sofort ohne Netzwerkaufruf abbricht.
EOF
ok "test/README.md aktualisiert"

# ── Selbstprüfung ────────────────────────────────────────────────────
echo
echo "── Selbstprüfung ───────────────────────────────────────────────"
for f in "$BE/test/helpers/db-name.js" "$BE/test/helpers/db.js" "$BE/test/unit/db-name.test.js"; do
  node --check "$f" >/dev/null 2>&1 || die "Syntaxfehler in $f — rückgängig mit: git checkout ."
done
ok "syntaktisch gültig"

echo
echo "  Abgeleitete Datenbanken:"
( cd "$BE" && for f in test/integration/*.test.js; do
    node -e "
      const { datenbankName } = require('./test/helpers/db-name');
      console.log('    ' + '$f'.padEnd(46) + ' -> ' + datenbankName('$f'));
    "
  done )

echo
echo "── Tests ───────────────────────────────────────────────────────"
echo
( cd "$BE" && npm run test:unit ) || true

echo
echo "── Beweis: derselbe Lauf, der eben zerbrochen ist ──────────────"
echo "   node --test --test-concurrency=4 — vier Dateien gleichzeitig"
echo
( cd "$BE" && node --test --test-concurrency=4 "test/integration/**/*.test.js" 2>&1 | tail -12 ) || true

echo
echo "── Danach ──────────────────────────────────────────────────────"
echo
echo "  Erwartet: 65 Unit-Tests grün, und der parallele Lauf oben"
echo "  ebenfalls 57/57 — genau der Lauf, der eben an"
echo "  'E11000 duplicate key: lager_test' gescheitert ist."
echo
echo "  Am CI-Workflow ist nichts zu ändern: MONGODB_TEST_URI dient dort"
echo "  jetzt als Vorlage. Der Runner hat vier Kerne, führt also von sich"
echo "  aus parallel aus — und beweist die Isolation bei jedem Lauf."
echo
echo "    git add -A && git commit -m 'Testisolation: eine Datenbank je Datei'"
echo "    git push"
echo
echo "  Rückgängig:  git checkout . && git clean -fd"
echo
