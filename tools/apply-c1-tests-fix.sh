#!/usr/bin/env bash
#
# apply-c1-tests-fix.sh — Korrektur der C1-Tests
#
# Grund: closeDay() nimmt das Datum als Argument entgegen —
#     async function closeDay(dateStr)
# In der ersten Fassung wurde es ohne Argument aufgerufen, dadurch schlug
# schon die DailyLog-Validierung fehl. Der Fehler lag im Test, nicht im Code.
#
# Diese Fassung ruft closeDay(yesterdayInBerlin()) auf und ergänzt einen
# Test über die echte Route POST /api/reports/close-day — den Weg, den ein
# Admin tatsächlich nimmt.
#
# Ausführen im Wurzelverzeichnis des Repos:
#     bash apply-c1-tests-fix.sh
#
# Ändert weiterhin KEINE Anwendungslogik. Nur die eine Testdatei.
#
set -euo pipefail

BE="Edeka.lager/backend"
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; }
die() { printf '\n  \033[31m✗ %s\033[0m\n\n' "$1" >&2; exit 1; }

echo
echo "── C1-Tests korrigieren ────────────────────────────────────────"
echo

ZIEL="$BE/test/integration/daily-close.test.js"
[ -f "$ZIEL" ] || die "'$ZIEL' nicht gefunden. Bitte zuerst apply-c1-tests.sh ausführen."

if command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
  [ -z "$(git status --porcelain)" ] || die "Arbeitsverzeichnis nicht sauber. Bitte erst committen."
  ok "Arbeitsverzeichnis sauber"
fi

cp "$ZIEL" "$ZIEL.bak"

cat > "$ZIEL" <<'EOF'
'use strict';
//
// Batch C1 — Tagesabschluss.
//
// Vier Regeln, die der Abschluss einhalten muss. Mehrere Tests sind
// absichtlich ROT: sie sind der Nachweis, dass die Regeln heute verletzt
// werden. Jeder rote Test ist mit "── ROT ──" markiert.
//
// Signatur laut services/dailyClose.js:  async function closeDay(dateStr)
// Das Datum wird übergeben, nicht intern ermittelt — scheduleDailyClose()
// reicht yesterdayInBerlin() hinein.
//
const test     = require('node:test');
const assert   = require('node:assert/strict');
const db       = require('../helpers/db');
const Product  = require('../../models/Product');
const DailyLog = require('../../models/DailyLog');
const dailyClose = require('../../services/dailyClose');
const { closeDay, yesterdayInBerlin } = dailyClose;
const { start, stop, req } = require('../helpers/http');
const { makeAdminToken }   = require('../helpers/factories');

test.before(async () => { await db.connect(); await start(); });
test.after (async () => { await stop(); await db.disconnect(); });
test.beforeEach(async () => { await db.wipe(); });

const GESTERN = () => yesterdayInBerlin();

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

// ── Kontrollen: müssen GRÜN sein ──────────────────────────────────

test('Kontrolle: closeDay(datum) schreibt genau ein Protokoll', async () => {
  await seedProducts(3, 10);
  await closeDay(GESTERN());

  const alle = await DailyLog.find({}).lean();
  assert.equal(alle.length, 1,
    `erwartet 1 Protokoll, gefunden: ${JSON.stringify(alle.map(l => [l.date, l.type]))}`);
  assert.equal(alle[0].type, 'auto-midnight');
  assert.equal(alle[0].date, GESTERN());
  assert.equal(alle[0].snapshot.length, 3);
});

test('Kontrolle: nach dem Abschluss ist der Verbrauch für den neuen Tag 0', async () => {
  await seedProducts(3, 10);
  await closeDay(GESTERN());

  for (const p of await Product.find({}).lean()) {
    assert.equal(Math.max(0, p.yesterdayStock - p.currentStock), 0,
      `${p.name}: sofort nach dem Abschluss wird Verbrauch angezeigt`);
  }
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

// ── Regel 2: genau ein auto-midnight je Tag ───────────────────────

// ── ROT ──
test('zweiter Abschluss am selben Tag legt kein zweites Protokoll an', async () => {
  await seedProducts(2, 10);
  await closeDay(GESTERN());
  await closeDay(GESTERN());

  const n = await DailyLog.countDocuments({ date: GESTERN(), type: 'auto-midnight' });
  assert.equal(n, 1,
    `${n} auto-midnight-Protokolle für denselben Tag — der Abschluss ist nicht idempotent. ` +
    `Ein Neustart um 00:00, ein zweites Server-Exemplar oder ein Klick auf ` +
    `"Tag manuell schließen" erzeugt Dubletten.`);
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

// ── Regel 3: ein erneuter Abschluss löscht den Tagesverbrauch nicht ──

// ── ROT ──
test('zweiter Abschluss löscht den Verbrauch des laufenden Tages nicht', async () => {
  const [p] = await seedProducts(1, 10);
  await closeDay(GESTERN());                                     // Basislinie: 10

  await Product.updateOne({ _id: p._id }, { currentStock: 4 });   // Verkauf über den Tag
  await closeDay(GESTERN());                                     // erneuter Abschluss

  const nachher = await Product.findById(p._id).lean();
  assert.equal(nachher.yesterdayStock, 10,
    `Basislinie wurde auf ${nachher.yesterdayStock} überschrieben — ` +
    `der bis dahin gemessene Verbrauch von 6 verschwindet aus der Anzeige.`);
});

// ── ROT ──
// Derselbe Fehler auf dem Weg, den ein Mensch tatsächlich nimmt:
// POST /api/reports/close-day ruft closeDay(yesterdayInBerlin()) auf.
// Ein Klick auf "Tag manuell schließen" um 09:00 Uhr löscht damit den
// Verbrauch des ganzen Vormittags.
test('Klick auf "Tag manuell schließen" löscht den Vormittagsverbrauch nicht', async () => {
  const token = await makeAdminToken();
  const [p] = await seedProducts(1, 10);
  await closeDay(GESTERN());

  await Product.updateOne({ _id: p._id }, { currentStock: 4 });

  const antwort = await req('/api/reports/close-day', { method: 'POST', token, body: {} });
  assert.ok(antwort.status < 500, `Route antwortete mit ${antwort.status}: ${antwort.text}`);

  const nachher = await Product.findById(p._id).lean();
  assert.equal(nachher.yesterdayStock, 10,
    `Basislinie über die Route auf ${nachher.yesterdayStock} überschrieben`);
});

// ── Regel 1: Momentaufnahme und Basislinie gehören zusammen ───────

// ── ROT ──
test('gleichzeitige Bestandsänderung während des Abschlusses erzeugt keinen Phantomverbrauch', async () => {
  const [p] = await seedProducts(1, 10);

  // closeDay liest erst alle Produkte, legt dann das Protokoll an und
  // schreibt erst danach yesterdayStock — mit den ZUERST gelesenen Werten.
  // Hier wird genau in diese Lücke eine Änderung eingeschoben.
  let hookLief = false;
  const aufraeumen = ersetze(DailyLog, 'create', (original) => async (...args) => {
    const ergebnis = await original(...args);
    hookLief = true;
    await Product.updateOne({ _id: p._id }, { currentStock: 3 });
    return ergebnis;
  });

  try { await closeDay(GESTERN()); } finally { aufraeumen(); }

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

  try { await closeDay(GESTERN()); } finally { auf1(); auf2(); auf3(); }

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

  assert.equal(await DailyLog.countDocuments({ date: GESTERN(), type: 'auto-midnight' }), 1,
    'der fehlende Abschluss wurde nicht nachgeholt');
});

// ── ROT ──
test('ein bereits erledigter Abschluss wird beim Start nicht wiederholt', async () => {
  assert.equal(typeof dailyClose.catchUpIfNeeded, 'function', 'catchUpIfNeeded() fehlt noch');

  const [p] = await seedProducts(1, 10);
  await closeDay(GESTERN());
  await Product.updateOne({ _id: p._id }, { currentStock: 4 });

  await dailyClose.catchUpIfNeeded();   // Neustart mitten am Tag

  const nachher = await Product.findById(p._id).lean();
  assert.equal(nachher.yesterdayStock, 10,
    'ein Neustart am Vormittag hat die Basislinie überschrieben');
  assert.equal(await DailyLog.countDocuments({ type: 'auto-midnight' }), 1);
});
EOF

ok "test/integration/daily-close.test.js neu geschrieben (11 Tests)"

echo
echo "── Selbstprüfung ───────────────────────────────────────────────"
node --check "$ZIEL" >/dev/null 2>&1 || die "Syntaxfehler in $ZIEL"
ok "syntaktisch gültig"
if grep -qn 'await closeDay()' "$ZIEL"; then
  die "es gibt noch einen closeDay-Aufruf ohne Argument"
else
  ok "kein closeDay-Aufruf ohne Argument mehr"
fi

echo
echo "── Tests ───────────────────────────────────────────────────────"
echo
( cd "$BE" && npm run test:integration ) || true

echo
echo "── Erwartung ───────────────────────────────────────────────────"
echo
echo "  3 GRÜN   2 Kontrollen + Leitplanke für manuelle Berichte"
echo "  8 ROT    die Befunde, die C1 behebt"
echo "  28 GRÜN  alles aus Batch A und B"
echo
echo "  Sind die beiden Kontrollen jetzt grün, war die Signatur die"
echo "  einzige falsche Annahme und wir können reparieren."
echo
echo "  Rückgängig:  git checkout . && git clean -fd"
echo
