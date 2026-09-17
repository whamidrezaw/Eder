#!/usr/bin/env bash
#
# apply-c1-fixes.sh — Batch C1, Schritt 2: die Korrekturen
#
#   C1.1  models/DailyLog.js   partieller eindeutiger Index auf { date, type }
#                              nur für auto-midnight — manuelle Berichte
#                              bleiben unbegrenzt erlaubt
#   C1.2  services/dailyClose  closeDay ist idempotent (mit force-Option),
#                              Basislinie über eine atomare Pipeline statt
#                              N Einzelschreibungen, neu: catchUpIfNeeded()
#   C1.3  routes/reports.js    close-day gibt force weiter und prüft das Datum
#   C1.4  server.js            holt einen verpassten Abschluss beim Start nach
#   +     drei neue Tests für die neue force-Option und die Datumsprüfung
#
# Ausführen im Wurzelverzeichnis des Repos:
#     bash apply-c1-fixes.sh
#
# Erst PLANEN, dann SCHREIBEN. Fehlt ein Anker, bricht das Skript ab und
# ändert NICHTS — und druckt die betroffene Stelle zum Weiterschicken.
#
set -euo pipefail

BE="Edeka.lager/backend"
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
skip() { printf '  \033[90m·\033[0m %s\n' "$1"; }
die()  { printf '\n  \033[31m✗ %s\033[0m\n\n' "$1" >&2; exit 1; }

echo
echo "── Batch C1, Schritt 2: Korrekturen ────────────────────────────"
echo

[ -f "$BE/services/dailyClose.js" ] || die "'$BE/services/dailyClose.js' nicht gefunden."
[ -f "$BE/lib/validate.js" ]        || die "'$BE/lib/validate.js' fehlt. Bitte zuerst Batch A anwenden."
[ -f "$BE/test/integration/daily-close.test.js" ] || die "C1-Tests fehlen. Bitte zuerst apply-c1-tests-fix.sh ausführen."

if command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
  [ -z "$(git status --porcelain)" ] || die "Arbeitsverzeichnis nicht sauber. Bitte erst committen."
  ok "Arbeitsverzeichnis sauber"
fi

echo
echo "── Planen und anwenden (alles oder nichts) ─────────────────────"

node - "$BE" <<'NODE_C1'
const fs   = require('fs');
const path = require('path');
const BE   = process.argv[2];
const P    = (...p) => path.join(BE, ...p);
const lies = f => fs.readFileSync(f, 'utf8');

const plan   = [];
const fehler = [];

// Mehrere Vorgänge können dieselbe Datei betreffen (server.js bekommt zwei).
// Deshalb wird pro Datei EIN Textstand geführt: jeder Vorgang arbeitet auf
// dem Ergebnis des vorherigen, und geschrieben wird erst am Ende — einmal.
// Ohne das überschreibt der zweite Vorgang den ersten, und zwar lautlos.
const dateien = new Map();   // datei -> { original, aktuell }

function hole(datei) {
  if (!dateien.has(datei)) {
    const f = P(...datei.split('/'));
    if (!fs.existsSync(f)) return null;
    const t = lies(f);
    dateien.set(datei, { original: t, aktuell: t });
  }
  return dateien.get(datei);
}

function umgebung(text, muster, zeilen = 6) {
  const lines = text.split('\n');
  const idx = lines.findIndex(l => muster.test(l));
  if (idx === -1) return '      (keine ähnliche Zeile gefunden)';
  return lines.slice(Math.max(0, idx - 2), idx + zeilen)
              .map((l, i) => `      ${idx - 1 + i}| ${l}`).join('\n');
}

function patch({ name, datei, schonDa, suche, ersetze, hinweis, naehe }) {
  const eintrag = hole(datei);
  if (!eintrag) { fehler.push({ name, datei, hinweis: 'Datei nicht gefunden', ausschnitt: '' }); return; }
  if (schonDa && schonDa.test(eintrag.aktuell)) { plan.push({ datei, name, geaendert: false }); return; }
  const neu = eintrag.aktuell.replace(suche, ersetze);
  if (neu === eintrag.aktuell) {
    fehler.push({ name, datei, hinweis, ausschnitt: naehe ? umgebung(eintrag.aktuell, naehe) : '' });
    return;
  }
  eintrag.aktuell = neu;
  plan.push({ datei, name, geaendert: true });
}

// ── C1.1  Partieller eindeutiger Index ────────────────────────────
patch({
  name: 'C1.1  partieller eindeutiger Index auf { date, type }',
  datei: 'models/DailyLog.js',
  schonDa: /partialFilterExpression/,
  suche: /(dailyLogSchema\.index\(\{\s*date:\s*-1,\s*sentAt:\s*-1\s*\}\);)/,
  ersetze: `$1

// Genau EIN automatischer Tagesabschluss je Datum — auf Datenbankebene,
// nicht nur im Code. Eine Prüfung in JavaScript schützt nicht gegen zwei
// Prozesse, die gleichzeitig um 00:00 schreiben.
//
// Der Index ist absichtlich PARTIELL: er greift nur für auto-midnight.
// Manuelle Berichte dürfen beliebig oft am selben Tag entstehen — das ist
// der Normalfall und darf nicht eingeschränkt werden.
dailyLogSchema.index(
  { date: 1, type: 1 },
  { unique: true, partialFilterExpression: { type: 'auto-midnight' } }
);`,
  hinweis: 'Die bestehende index()-Zeile wurde nicht gefunden.',
  naehe: /\.index\(/
});

// ── C1.2  closeDay ersetzen ───────────────────────────────────────
(() => {
  const name = 'C1.2  closeDay: idempotent + atomare Basislinie';
  const eintrag = hole('services/dailyClose.js');
  if (!eintrag) { fehler.push({ name, datei: 'services/dailyClose.js', hinweis: 'Datei nicht gefunden', ausschnitt: '' }); return; }
  const text = eintrag.aktuell;
  if (/catchUpIfNeeded/.test(text)) { plan.push({ datei: 'services/dailyClose.js', name, geaendert: false }); return; }

  const lines = text.split('\n');
  const start = lines.findIndex(l => /^async function closeDay\s*\(/.test(l));
  if (start === -1) {
    fehler.push({ name, datei: 'services/dailyClose.js',
                  hinweis: 'async function closeDay( nicht am Zeilenanfang gefunden',
                  ausschnitt: umgebung(text, /closeDay/, 10) });
    return;
  }
  const ende = lines.findIndex((l, i) => i > start && l === '}');
  if (ende === -1) {
    fehler.push({ name, datei: 'services/dailyClose.js',
                  hinweis: 'Ende der Funktion closeDay nicht erkennbar',
                  ausschnitt: umgebung(text, /^async function closeDay/, 20) });
    return;
  }

  const neueFunktion = `/**
 * Schließt einen Tag ab: legt die endgültige Momentaufnahme als offizielles
 * Protokoll dieses Tages an und setzt yesterdayStock als Basislinie für den
 * Folgetag. Wird vom Mitternachts-Cron, vom Nachholen beim Start und von der
 * Admin-Route benutzt. Verschickt nichts an Telegram.
 *
 * Idempotent: Ein Tag wird nur einmal geschlossen. Ohne diese Prüfung setzte
 * ein zweiter Aufruf yesterdayStock auf den AKTUELLEN Bestand und löschte
 * damit den bis dahin gemessenen Tagesverbrauch — ein Klick auf
 * "Tag manuell schließen" um 09:00 Uhr kostete den ganzen Vormittag.
 *
 * options.force = true schließt einen bereits geschlossenen Tag erneut.
 * Das ist für echte Korrekturen gedacht: Das bestehende Protokoll wird
 * überschrieben (nicht verdoppelt) und die Basislinie neu gesetzt.
 */
async function closeDay(dateStr, options = {}) {
  const force = options.force === true;

  const vorhanden = await DailyLog
    .findOne({ date: dateStr, type: 'auto-midnight' })
    .select('_id')
    .lean();

  if (vorhanden && !force) {
    return { skipped: true, reason: 'already-closed', logId: vorhanden._id, date: dateStr, count: 0 };
  }

  const products = await Product.find({ isActive: true });

  const snapshot = products.map(p => ({
    productId:    p._id,
    productName:  p.name,
    emoji:        p.emoji,
    category:     p.category,
    unit:         p.unit,
    isBio:        !!p.isBio,
    openingStock: p.yesterdayStock ?? 0,
    closingStock: p.currentStock  ?? 0,
    consumed:     Math.max(0, (p.yesterdayStock ?? 0) - (p.currentStock ?? 0))
  }));

  let logId;
  if (vorhanden) {
    // force-Pfad: bestehendes Protokoll aktualisieren. Ein zweites anzulegen
    // würde am eindeutigen Index scheitern — und wäre auch fachlich falsch.
    await DailyLog.updateOne(
      { _id: vorhanden._id },
      { \$set: { sentAt: new Date(), snapshot, reportSent: false } }
    );
    logId = vorhanden._id;
  } else {
    try {
      const log = await DailyLog.create({
        date:       dateStr,
        sentAt:     new Date(),
        type:       'auto-midnight',
        snapshot,
        createdBy:  null,
        reportSent: false
      });
      logId = log._id;
    } catch (err) {
      // Zwei Prozesse gleichzeitig: der eindeutige Index lässt nur einen
      // durch. Der andere hat nichts zu tun — das ist kein Fehlerfall.
      if (err && err.code === 11000) {
        return { skipped: true, reason: 'race-already-closed', date: dateStr, count: 0 };
      }
      throw err;
    }
  }

  // Basislinie in EINER atomaren Operation. Die Pipeline liest currentStock
  // im Moment des Schreibens — nicht aus den oben gelesenen Dokumenten.
  // Vorher standen hier N einzelne findByIdAndUpdate mit vorab gelesenen
  // Werten: bei 40 Produkten 40 Rundreisen, und eine gleichzeitige
  // Bestandsänderung erzeugte am nächsten Tag einen Verbrauch, den es
  // nie gab.
  const basislinie = await Product.updateMany(
    { isActive: true },
    [{ \$set: { yesterdayStock: '\$currentStock' } }]
  );

  return {
    logId,
    date:            dateStr,
    count:           products.length,
    forced:          force,
    baselineUpdated: basislinie.modifiedCount ?? 0
  };
}

/**
 * Holt einen verpassten Tagesabschluss beim Start nach.
 *
 * War der Server um 00:00 aus, lief der Cron-Job nie. yesterdayStock blieb
 * dann auf dem Wert des Vortags und die Anzeige "Verbrauch seit Mitternacht"
 * war den ganzen folgenden Tag falsch, ohne dass es auffiel.
 *
 * Läuft absichtlich still, wenn es nichts zu tun gibt.
 */
async function catchUpIfNeeded() {
  const dateStr = yesterdayInBerlin();

  const vorhanden = await DailyLog
    .findOne({ date: dateStr, type: 'auto-midnight' })
    .select('_id')
    .lean();
  if (vorhanden) return { skipped: true, reason: 'already-closed', date: dateStr };

  const anzahl = await Product.countDocuments({ isActive: true });
  if (anzahl === 0) return { skipped: true, reason: 'no-products', date: dateStr };

  console.log(\`⏳ Tagesabschluss für \${dateStr} fehlt — wird nachgeholt\`);
  const ergebnis = await closeDay(dateStr);
  console.log(\`✅ Tagesabschluss nachgeholt: \${dateStr} (\${ergebnis.count} Produkte)\`);
  return ergebnis;
}`;

  const ersetzt = [...lines.slice(0, start), neueFunktion, ...lines.slice(ende + 1)].join('\n');

  const mitExport = ersetzt.replace(
    /module\.exports\s*=\s*\{\s*closeDay\s*,\s*scheduleDailyClose\s*,\s*yesterdayInBerlin\s*,\s*berlinDateString\s*\}\s*;?/,
    'module.exports = { closeDay, catchUpIfNeeded, scheduleDailyClose, yesterdayInBerlin, berlinDateString };'
  );
  if (mitExport === ersetzt) {
    fehler.push({ name, datei: 'services/dailyClose.js',
                  hinweis: 'module.exports nicht wie erwartet',
                  ausschnitt: umgebung(text, /module\.exports/, 3) });
    return;
  }

  eintrag.aktuell = mitExport;
  plan.push({ datei: 'services/dailyClose.js', name, geaendert: true });
})();

// ── C1.3  close-day-Route: force + Datumsprüfung ──────────────────
patch({
  name: 'C1.3  close-day gibt force weiter und prüft das Datum',
  datei: 'routes/reports.js',
  schonDa: /options\.force|force:\s*req\.body/,
  suche: /const dateStr = req\.body\?\.date \|\| yesterdayInBerlin\(\);\n(\s*)const result = await closeDay\(dateStr\);\n\s*res\.json\(\{ message: `✅ Tag \$\{dateStr\} manuell geschlossen`, \.\.\.result \}\);/,
  ersetze: `const rohDatum = req.body?.date;
$1if (rohDatum !== undefined && rohDatum !== '' &&
$1    !require('../lib/validate').parseIsoDate(rohDatum)) {
$1  return res.status(400).json({ message: 'Ungültiges Datum. Erwartet wird JJJJ-MM-TT.' });
$1}
$1const dateStr = rohDatum || yesterdayInBerlin();

$1// force muss ausdrücklich gesetzt werden. Ohne die Option ist ein zweiter
$1// Abschluss ein No-op — genau das schützt den Verbrauch des laufenden Tages.
$1const force  = req.body?.force === true;
$1const result = await closeDay(dateStr, { force });

$1const message = result.skipped
$1  ? \`ℹ️ Tag \${dateStr} war bereits geschlossen — nichts geändert. Mit "force": true erneut schließen.\`
$1  : \`✅ Tag \${dateStr} \${force ? 'erneut ' : 'manuell '}geschlossen\`;
$1res.json({ message, ...result });`,
  hinweis: 'Der Rumpf der close-day-Route sieht anders aus als erwartet.',
  naehe: /close-day/
});

// ── C1.4  server.js: Nachholen beim Start ─────────────────────────
patch({
  name: 'C1.4  server.js importiert catchUpIfNeeded',
  datei: 'server.js',
  schonDa: /catchUpIfNeeded/,
  suche: /const \{ scheduleDailyClose \} = require\('\.\/services\/dailyClose'\);/,
  ersetze: "const { scheduleDailyClose, catchUpIfNeeded } = require('./services/dailyClose');",
  hinweis: 'Die require-Zeile für dailyClose wurde nicht gefunden.',
  naehe: /dailyClose/
});

patch({
  name: 'C1.4  server.js holt einen verpassten Abschluss nach',
  datei: 'server.js',
  schonDa: /catchUpIfNeeded\(\)\s*\n?\s*\./,
  suche: /(\n)(\s*)scheduleDailyClose\(\);/,
  ersetze: `$1$2// War der Server um Mitternacht aus, wurde der Tag nie geschlossen.
$2// Das wird hier einmalig nachgeholt — absichtlich ohne await: schlägt es
$2// fehl, soll der Server trotzdem starten.
$2catchUpIfNeeded().catch(err =>
$2  console.error('❌ Nachholen des Tagesabschlusses fehlgeschlagen:', err.message));
$2scheduleDailyClose();`,
  hinweis: 'Der Aufruf scheduleDailyClose(); wurde nicht gefunden.',
  naehe: /scheduleDailyClose/
});

// ── Bericht ───────────────────────────────────────────────────────
if (fehler.length) {
  console.log('\n  \x1b[31mAnker nicht gefunden — es wurde NICHTS geändert:\x1b[0m\n');
  for (const f of fehler) {
    console.log(`  \x1b[31m✗\x1b[0m ${f.name}  (${f.datei})`);
    console.log(`     ${f.hinweis}`);
    if (f.ausschnitt) console.log('     Umgebung in deiner Datei:\n' + f.ausschnitt);
    console.log('');
  }
  console.log('  Schick mir die obigen Ausschnitte, dann passe ich die Anker an.\n');
  process.exit(1);
}

for (const p of plan) {
  if (!p.geaendert) { console.log(`  \x1b[90m·\x1b[0m ${p.name} — schon angewendet`); continue; }
  console.log(`  \x1b[32m✓\x1b[0m ${p.name}`);
}

// Jetzt erst schreiben — genau einmal je Datei, mit allen Vorgängen darin.
for (const [datei, e] of dateien) {
  if (e.aktuell === e.original) continue;
  const f = P(...datei.split('/'));
  if (!fs.existsSync(f + '.bak')) fs.writeFileSync(f + '.bak', e.original);
  fs.writeFileSync(f, e.aktuell);
  console.log(`  \x1b[90m→\x1b[0m geschrieben: ${datei}`);
}
NODE_C1

echo
echo "── Neue Tests für die force-Option ─────────────────────────────"

ZIEL="$BE/test/integration/daily-close.test.js"
if grep -q 'force: true schließt' "$ZIEL"; then
  skip "force-Tests schon vorhanden"
else
  cat >> "$ZIEL" <<'EOF'

// ── Neu in C1: die force-Option ───────────────────────────────────
// Diese Tests prüfen NEUES Verhalten. Die acht roten Tests oben bleiben
// unverändert — sie sind der Nachweis und dürfen nicht angepasst werden.

test('force: true schließt einen bereits geschlossenen Tag erneut', async () => {
  const [p] = await seedProducts(1, 10);
  await closeDay(GESTERN());
  await Product.updateOne({ _id: p._id }, { currentStock: 4 });

  await closeDay(GESTERN(), { force: true });

  const nachher = await Product.findById(p._id).lean();
  assert.equal(nachher.yesterdayStock, 4, 'force hat die Basislinie nicht neu gesetzt');
  assert.equal(await DailyLog.countDocuments({ date: GESTERN(), type: 'auto-midnight' }), 1,
    'force darf das Protokoll überschreiben, aber kein zweites anlegen');
});

test('die Route schließt nur mit ausdrücklichem force erneut', async () => {
  const token = await makeAdminToken();
  const [p] = await seedProducts(1, 10);
  await closeDay(GESTERN());
  await Product.updateOne({ _id: p._id }, { currentStock: 4 });

  const ohne = await req('/api/reports/close-day', { method: 'POST', token, body: {} });
  assert.equal(ohne.status, 200, ohne.text);
  assert.equal(ohne.body.skipped, true, 'ohne force muss die Route melden, dass nichts geändert wurde');
  assert.equal((await Product.findById(p._id).lean()).yesterdayStock, 10);

  const mit = await req('/api/reports/close-day', { method: 'POST', token, body: { force: true } });
  assert.equal(mit.status, 200, mit.text);
  assert.notEqual(mit.body.skipped, true);
  assert.equal((await Product.findById(p._id).lean()).yesterdayStock, 4);
});

test('close-day weist ein unbrauchbares Datum mit 400 ab', async () => {
  const token = await makeAdminToken();
  await seedProducts(1, 10);

  const r = await req('/api/reports/close-day', { method: 'POST', token, body: { date: 'kein-datum' } });
  assert.equal(r.status, 400, `stattdessen ${r.status}: ${r.text}`);
  assert.equal(await DailyLog.countDocuments({}), 0);
});
EOF
  ok "3 Tests für force und Datumsprüfung ergänzt"
fi

echo
echo "── Selbstprüfung ───────────────────────────────────────────────"
for f in "$BE/server.js" "$BE/models/DailyLog.js" "$BE/services/dailyClose.js" "$BE/routes/reports.js" "$ZIEL"; do
  node --check "$f" >/dev/null 2>&1 || die "Syntaxfehler in $f — rückgängig mit: git checkout ."
done
ok "alle geänderten Dateien sind syntaktisch gültig"

# node --check findet nur Syntaxfehler. Ein fehlender Import ist erst zur
# Laufzeit ein Fehler — deshalb hier ausdrücklich geprüft.
grep -q "catchUpIfNeeded } = require('./services/dailyClose')" "$BE/server.js" \
  || die "server.js importiert catchUpIfNeeded nicht — git checkout ."
ok "server.js importiert catchUpIfNeeded"

grep -q "catchUpIfNeeded()" "$BE/server.js" \
  || die "server.js ruft catchUpIfNeeded() nicht auf — git checkout ."
ok "server.js ruft catchUpIfNeeded() beim Start auf"

grep -q "module.exports = { closeDay, catchUpIfNeeded," "$BE/services/dailyClose.js" \
  || die "dailyClose.js exportiert catchUpIfNeeded nicht — git checkout ."
ok "dailyClose.js exportiert catchUpIfNeeded"

# Zusätzlich laden, falls node_modules vorhanden ist. Schlägt das fehl, ist es
# nur ein Hinweis — die Tests unten sind der eigentliche Nachweis.
if node -e "
  const dc = require('./$BE/services/dailyClose.js');
  const fehlt = ['closeDay','catchUpIfNeeded','scheduleDailyClose','yesterdayInBerlin','berlinDateString']
    .filter(n => typeof dc[n] !== 'function');
  if (fehlt.length) { console.error(fehlt.join(', ')); process.exit(1); }
" 2>/dev/null; then
  ok "dailyClose.js lädt und stellt alle Funktionen bereit"
else
  skip "dailyClose.js konnte nicht geladen werden (fehlt npm install?) — die Tests prüfen es"
fi

echo
echo "── Tests ───────────────────────────────────────────────────────"
echo
( cd "$BE" && npm run test:unit ) || true
echo
( cd "$BE" && npm run test:integration ) || true

echo
echo "── Danach ──────────────────────────────────────────────────────"
echo
echo "  Erwartet: 48/48 Unit und 42/42 Integration grün."
echo
echo "  WICHTIG für die Produktivdatenbank: Der neue eindeutige Index wird"
echo "  beim nächsten Start angelegt. Existieren dort bereits zwei"
echo "  auto-midnight-Protokolle für denselben Tag, schlägt das Anlegen"
echo "  still fehl. Vorher prüfen:"
echo
echo "    sudo docker exec -it edeka-mongo mongosh edeka_lager --quiet --eval '"
echo "      db.dailylogs.aggregate([{\$match:{type:\"auto-midnight\"}},"
echo "        {\$group:{_id:\"\$date\",n:{\$sum:1}}},{\$match:{n:{\$gt:1}}}]).toArray()'"
echo
echo "  Leeres Ergebnis = alles in Ordnung. Sonst bitte die Ausgabe schicken."
echo
echo "  Rückgängig:  git checkout . && git clean -fd"
echo
