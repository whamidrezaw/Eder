#!/usr/bin/env bash
#
# apply-c2-fixes.sh — Batch C2, Schritt 2: die Korrekturen
#
#   C2.1  Auswahlfenster nach DATUM statt nach Protokollanzahl
#         (neue Hilfsfunktion repraesentantenIds, ohne Momentaufnahmen)
#   C2.2  /analytics rechnet in der Datenbank ($project, $unwind, $group)
#         statt alle Momentaufnahmen nach Node zu laden
#   C2.3  Gruppierung nach productId statt nach Produktnamen
#   C2.4  days wird geprüft — negative Werte ergeben 400, kein leeres Diagramm
#   C2.5  /history benutzt dasselbe Datumsfenster
#   +     Unit-Tests für den neuen Bereichsprüfer
#
# Ausführen im Wurzelverzeichnis des Repos:
#     bash apply-c2-fixes.sh
#
# Erst PLANEN, dann SCHREIBEN. Fehlt ein Anker, bricht das Skript ab und
# ändert NICHTS. Mehrere Vorgänge auf derselben Datei werden verkettet —
# routes/reports.js bekommt drei.
#
set -euo pipefail

BE="Edeka.lager/backend"
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
skip() { printf '  \033[90m·\033[0m %s\n' "$1"; }
die()  { printf '\n  \033[31m✗ %s\033[0m\n\n' "$1" >&2; exit 1; }

echo
echo "── Batch C2, Schritt 2: Korrekturen ────────────────────────────"
echo

[ -f "$BE/routes/reports.js" ] || die "'$BE/routes/reports.js' nicht gefunden."
[ -f "$BE/lib/validate.js" ]   || die "'$BE/lib/validate.js' fehlt. Bitte zuerst Batch A anwenden."
[ -f "$BE/test/integration/analytics.test.js" ] || die "C2-Tests fehlen. Bitte zuerst apply-c2-tests.sh ausführen."

if command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
  [ -z "$(git status --porcelain)" ] || die "Arbeitsverzeichnis nicht sauber. Bitte erst committen."
  ok "Arbeitsverzeichnis sauber"
fi

echo
echo "── Planen und anwenden (alles oder nichts) ─────────────────────"

node - "$BE" <<'NODE_C2'
const fs   = require('fs');
const path = require('path');
const BE   = process.argv[2];
const P    = (...p) => path.join(BE, ...p);
const lies = f => fs.readFileSync(f, 'utf8');

const plan    = [];
const fehler  = [];
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

function umgebung(text, muster, zeilen = 8) {
  const lines = text.split('\n');
  const idx = lines.findIndex(l => muster.test(l));
  if (idx === -1) return '      (keine ähnliche Zeile gefunden)';
  return lines.slice(Math.max(0, idx - 2), idx + zeilen)
              .map((l, i) => `      ${idx - 1 + i}| ${l}`).join('\n');
}

function patch({ name, datei, schonDa, suche, ersetze, hinweis, naehe }) {
  const e = hole(datei);
  if (!e) { fehler.push({ name, datei, hinweis: 'Datei nicht gefunden', ausschnitt: '' }); return; }
  if (schonDa && schonDa.test(e.aktuell)) { plan.push({ datei, name, geaendert: false }); return; }
  const neu = e.aktuell.replace(suche, ersetze);
  if (neu === e.aktuell) {
    fehler.push({ name, datei, hinweis, ausschnitt: naehe ? umgebung(e.aktuell, naehe) : '' });
    return;
  }
  e.aktuell = neu;
  plan.push({ datei, name, geaendert: true });
}

// ── C2.4a  Bereichsprüfer in lib/validate.js ──────────────────────
patch({
  name: 'C2.4  lib/validate.js: parseRangeInt',
  datei: 'lib/validate.js',
  schonDa: /parseRangeInt/,
  suche: /module\.exports = \{ parseIsoDate, parseStock, normalizeIp, checkJwtSecret \};/,
  ersetze: [
    '/**',
    ' * Ganzzahliger Bereichsparameter aus einer Query (days, limit).',
    ' *',
    ' * Gibt die Zahl zurück, den Standard bei fehlendem Wert, und null bei',
    ' * allem, was nicht hineinpasst. Vorher stand dort',
    ' * Math.min(parseInt(days) || 14, 90): das ließ negative Werte durch, und',
    ' * daraus wurden limit(-40) und slice(0, -5) — beides verkürzte still,',
    ' * bis das Diagramm leer war, ohne dass jemand einen Fehler sah.',
    ' */',
    'function parseRangeInt(value, { min, max, standard }) {',
    "  if (value === undefined || value === null || value === '') return standard;",
    "  if (typeof value === 'boolean' || typeof value === 'object') return null;",
    '  const n = Number(value);',
    '  if (!Number.isInteger(n) || n < min || n > max) return null;',
    '  return n;',
    '}',
    '',
    'module.exports = { parseIsoDate, parseStock, parseRangeInt, normalizeIp, checkJwtSecret };'
  ].join('\n'),
  hinweis: 'Die module.exports-Zeile in lib/validate.js sieht anders aus als erwartet.',
  naehe: /module\.exports/
});

// ── C2.1  Hilfsfunktion repraesentantenIds ────────────────────────
patch({
  name: 'C2.1  repraesentantenIds (Fenster nach Datum)',
  datei: 'routes/reports.js',
  schonDa: /repraesentantenIds/,
  suche: /(  return Object\.values\(byDate\)\.sort\(\(a, b\) => b\.date\.localeCompare\(a\.date\)\);\n\})/,
  ersetze: (treffer) => treffer + [
    '',
    '',
    '/**',
    ' * Bestimmt für die letzten `anzahl` Tage je Tag das maßgebliche Protokoll',
    ' * und gibt nur deren IDs zurück.',
    ' *',
    ' * Vorher wurde das Fenster mit limit(anzahl * 8) begrenzt — also nach der',
    ' * ANZAHL der Protokolle statt nach dem Datum. Die Annahme "höchstens acht',
    ' * Berichte pro Tag" ist nirgends zugesichert: bei zwanzig Berichten am Tag',
    ' * deckten 112 geladene Protokolle nur sechs von vierzehn Tagen ab, und die',
    ' * älteren Tage verschwanden ohne jeden Hinweis aus dem Diagramm.',
    ' *',
    ' * Die Auswahlregel bleibt dieselbe wie in pickDailyRepresentatives:',
    ' * auto-midnight schlägt manual, sonst gewinnt der späteste Bericht des',
    ' * Tages. Die Momentaufnahmen werden hier bewusst NICHT geladen, damit die',
    ' * Auswahl unabhängig von der Datenmenge bleibt.',
    ' */',
    'async function repraesentantenIds(anzahl) {',
    '  const zeilen = await DailyLog.aggregate([',
    '    { $project: { date: 1, type: 1, sentAt: 1 } },',
    "    { $addFields: { istAuto: { $eq: ['$type', 'auto-midnight'] } } },",
    '    { $sort: { date: -1, istAuto: -1, sentAt: -1 } },',
    "    { $group: { _id: '$date', logId: { $first: '$_id' } } },",
    '    { $sort: { _id: -1 } },',
    '    { $limit: anzahl }',
    '  ]);',
    '  return zeilen.map(z => z.logId);',
    '}'
  ].join('\n'),
  hinweis: 'Das Ende von pickDailyRepresentatives wurde nicht gefunden.',
  naehe: /pickDailyRepresentatives/
});

// ── C2.2 + C2.3 + C2.4b  /analytics neu ───────────────────────────
(() => {
  const name = 'C2.2/C2.3  /analytics: Aggregation in der Datenbank, Gruppierung nach productId';
  const e = hole('routes/reports.js');
  if (!e) { fehler.push({ name, datei: 'routes/reports.js', hinweis: 'Datei nicht gefunden', ausschnitt: '' }); return; }
  if (/repraesentantenIds\(days\)/.test(e.aktuell)) { plan.push({ datei: 'routes/reports.js', name, geaendert: false }); return; }

  const lines = e.aktuell.split('\n');
  const start = lines.findIndex(l => /^router\.get\('\/analytics'/.test(l));
  if (start === -1) {
    fehler.push({ name, datei: 'routes/reports.js',
                  hinweis: "router.get('/analytics' nicht am Zeilenanfang gefunden",
                  ausschnitt: umgebung(e.aktuell, /analytics/, 6) });
    return;
  }
  const ende = lines.findIndex((l, i) => i > start && l === '});');
  if (ende === -1) {
    fehler.push({ name, datei: 'routes/reports.js',
                  hinweis: 'Ende des analytics-Handlers nicht erkennbar',
                  ausschnitt: umgebung(e.aktuell, /^router\.get\('\/analytics'/, 20) });
    return;
  }

  const neu = [
    "router.get('/analytics', auth, async (req, res) => {",
    "  const days = require('../lib/validate')",
    "    .parseRangeInt(req.query.days, { min: 1, max: 90, standard: 14 });",
    '  if (days === null) {',
    '    return res.status(400).json({',
    "      message: 'Ungültiger Wert für days. Erwartet wird eine ganze Zahl von 1 bis 90.'",
    '    });',
    '  }',
    '',
    '  const logIds = await repraesentantenIds(days);',
    '  if (logIds.length === 0) {',
    '    return res.json({ trend: [], topProducts: [], allProducts: [], summary: {} });',
    '  }',
    '',
    '  // Trend: je Tag eine Zeile. Die Summen entstehen in der Datenbank.',
    '  // Vorher wurden dafür alle Momentaufnahmen nach Node geladen und dort',
    '  // aufaddiert — bei 20 Tagen mit je 100 Produkten über 2000 Positionen,',
    '  // um am Ende höchstens 100 Ergebniszeilen zu berechnen.',
    '  const trend = await DailyLog.aggregate([',
    '    { $match: { _id: { $in: logIds } } },',
    '    { $project: {',
    '        _id:           0,',
    '        date:          1,',
    "        totalStock:    { $sum: '$snapshot.closingStock' },",
    "        totalConsumed: { $sum: '$snapshot.consumed' },",
    "        productCount:  { $size: { $ifNull: ['$snapshot', []] } }",
    '    } },',
    '    { $sort: { date: 1 } }',
    '  ]);',
    '',
    '  // Produkte: gruppiert nach productId, nicht nach Namen.',
    '  //',
    '  // Momentaufnahmen halten den Namen des jeweiligen Tages fest — das ist',
    '  // richtig und soll so bleiben. Falsch war, daraus den Gruppierungs-',
    '  // schlüssel zu bilden: eine Umbenennung zerlegte die Historie in zwei',
    '  // Zeitreihen, und zwei verschiedene Produkte mit gleichem Namen wurden',
    '  // zusammengeworfen. Die productId steht in jeder Momentaufnahme.',
    '  //',
    '  // Für alte Einträge ohne productId bleibt der Name als Notschlüssel.',
    '  // $last liefert wegen der Sortierung nach Datum den jüngsten Namen.',
    '  const gruppen = await DailyLog.aggregate([',
    '    { $match: { _id: { $in: logIds } } },',
    '    { $sort: { date: 1 } },',
    "    { $unwind: '$snapshot' },",
    '    { $addFields: {',
    '        gruppe: { $ifNull: [',
    "          '$snapshot.productId',",
    '          { $concat: [',
    "            { $ifNull: ['$snapshot.productName', '?'] }, '__',",
    "            { $toString: { $ifNull: ['$snapshot.isBio', false] } }, '__',",
    "            { $ifNull: ['$snapshot.unit', '?'] }",
    '          ] }',
    '        ] }',
    '    } },',
    '    { $group: {',
    "        _id:           '$gruppe',",
    "        productId:     { $first: '$snapshot.productId' },",
    "        name:          { $last: '$snapshot.productName' },",
    "        emoji:         { $last: '$snapshot.emoji' },",
    "        category:      { $last: '$snapshot.category' },",
    "        unit:          { $last: '$snapshot.unit' },",
    "        isBio:         { $last: '$snapshot.isBio' },",
    "        totalConsumed: { $sum: { $ifNull: ['$snapshot.consumed', 0] } },",
    '        days:          { $sum: 1 }',
    '    } }',
    '  ]);',
    '',
    '  const allProducts = gruppen.map(g => ({',
    '    productId:     g.productId ?? null,',
    '    name:          g.name,',
    "    emoji:         g.emoji || '📦',",
    "    category:      g.category || 'Sonstige',",
    "    unit:          g.unit || 'Kiste',",
    '    isBio:         !!g.isBio,',
    '    totalConsumed: g.totalConsumed,',
    '    days:          g.days,',
    '    avgConsumed:   parseFloat((g.totalConsumed / g.days).toFixed(1))',
    '  }));',
    '',
    '  const topProducts = [...allProducts]',
    '    .sort((a, b) => b.totalConsumed - a.totalConsumed)',
    '    .slice(0, 10);',
    '',
    '  const categoryBreakdown = {};',
    '  allProducts.forEach(p => {',
    '    categoryBreakdown[p.category] = (categoryBreakdown[p.category] || 0) + p.totalConsumed;',
    '  });',
    '',
    '  const gesamtVerbrauch = trend.reduce((s, d) => s + d.totalConsumed, 0);',
    '',
    '  res.json({',
    '    trend,',
    '    topProducts,',
    '    allProducts,',
    '    summary: {',
    '      totalDays:        trend.length,',
    '      totalConsumed:    gesamtVerbrauch,',
    '      avgDailyConsumed: trend.length',
    '        ? parseFloat((gesamtVerbrauch / trend.length).toFixed(1))',
    '        : 0,',
    '      categoryBreakdown',
    '    }',
    '  });',
    '});'
  ];

  e.aktuell = [...lines.slice(0, start), ...neu, ...lines.slice(ende + 1)].join('\n');
  plan.push({ datei: 'routes/reports.js', name, geaendert: true });
})();

// ── C2.5  /history: dasselbe Datumsfenster ────────────────────────
patch({
  name: 'C2.5  /history benutzt das Datumsfenster',
  datei: 'routes/reports.js',
  // Achtung: nicht auf den Funktionsnamen prüfen — die Definition aus C2.1
  // steht dann schon in der Datei und ergäbe einen falschen Treffer.
  schonDa: /Fenster nach Datum, nicht nach Protokollanzahl/,
  suche: /const rawLogs = await DailyLog\.find\(\)\.sort\(\{\s*date:\s*-1,\s*sentAt:\s*-1\s*\}\)\.limit\((\w+) \* 8\);\r?\n(\s*)const repLogs = pickDailyRepresentatives\(rawLogs\)\.slice\(0, \1\);/,
  ersetze: (_t, variable, einzug) => [
    '// Fenster nach Datum, nicht nach Protokollanzahl — siehe',
    einzug + '// repraesentantenIds(). Vorher fielen bei vielen Berichten pro Tag',
    einzug + '// die älteren Tage still aus der Liste.',
    einzug + 'const repIds  = await repraesentantenIds(' + variable + ');',
    einzug + 'const repLogs = await DailyLog.find({ _id: { $in: repIds } }).sort({ date: -1 });'
  ].join('\n'),
  hinweis: 'Die Protokollauswahl in /history sieht anders aus als erwartet.',
  naehe: /history/
});

// ── Abschlussprüfung, noch in der Planphase ───────────────────────
// Erst nach allen Vorgängen prüfen — und zwar bevor etwas geschrieben wird,
// sonst bleibt bei einem Fund ein halb angewendeter Stand zurück.
{
  const rj = dateien.get('routes/reports.js');
  if (rj && /\.limit\((?:days|limit|anzahl) \* 8\)/.test(rj.aktuell)) {
    fehler.push({
      name: 'Abschlussprüfung',
      datei: 'routes/reports.js',
      hinweis: "Nach allen Vorgängen ist noch ein '* 8'-Fenster übrig — ein Vorgang hat nicht gegriffen",
      ausschnitt: umgebung(rj.aktuell, /\* 8/)
    });
  }
}

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

for (const [datei, e] of dateien) {
  if (e.aktuell === e.original) continue;
  const f = P(...datei.split('/'));
  if (!fs.existsSync(f + '.c2.bak')) fs.writeFileSync(f + '.c2.bak', e.original);
  fs.writeFileSync(f, e.aktuell);
  console.log(`  \x1b[90m→\x1b[0m geschrieben: ${datei}`);
}
NODE_C2

echo
echo "── Unit-Tests für parseRangeInt ────────────────────────────────"

UT="$BE/test/unit/validate.test.js"
if grep -q 'parseRangeInt' "$UT"; then
  skip "schon vorhanden"
else
  cat >> "$UT" <<'EOF'

// ── Neu in C2: Bereichsprüfer für days und limit ──────────────────
const { parseRangeInt } = require('../../lib/validate');
const BEREICH = { min: 1, max: 90, standard: 14 };

test('parseRangeInt nimmt Werte im Bereich an', () => {
  assert.equal(parseRangeInt('7', BEREICH), 7);
  assert.equal(parseRangeInt(30, BEREICH), 30);
  assert.equal(parseRangeInt('90', BEREICH), 90);
  assert.equal(parseRangeInt('1', BEREICH), 1);
});

test('parseRangeInt gibt bei fehlendem Wert den Standard zurück', () => {
  assert.equal(parseRangeInt(undefined, BEREICH), 14);
  assert.equal(parseRangeInt(null, BEREICH), 14);
  assert.equal(parseRangeInt('', BEREICH), 14);
});

test('parseRangeInt lehnt ab, was nicht in den Bereich passt', () => {
  assert.equal(parseRangeInt('-5', BEREICH),  null, 'negative Werte führten zu einem leeren Diagramm');
  assert.equal(parseRangeInt('0', BEREICH),   null);
  assert.equal(parseRangeInt('91', BEREICH),  null);
  assert.equal(parseRangeInt('7.5', BEREICH), null);
  assert.equal(parseRangeInt('abc', BEREICH), null);
  assert.equal(parseRangeInt(['7'], BEREICH), null);
  assert.equal(parseRangeInt({}, BEREICH),    null);
  assert.equal(parseRangeInt(true, BEREICH),  null);
  assert.equal(parseRangeInt(Infinity, BEREICH), null);
});
EOF
  ok "3 Tests für parseRangeInt ergänzt"
fi

echo
echo "── Selbstprüfung ───────────────────────────────────────────────"
for f in "$BE/routes/reports.js" "$BE/lib/validate.js" "$UT"; do
  node --check "$f" >/dev/null 2>&1 || die "Syntaxfehler in $f — rückgängig mit: git checkout ."
done
ok "alle geänderten Dateien sind syntaktisch gültig"

grep -q "parseRangeInt" "$BE/lib/validate.js" || die "parseRangeInt fehlt in lib/validate.js"
grep -q "module.exports = { parseIsoDate, parseStock, parseRangeInt," "$BE/lib/validate.js" \
  || die "parseRangeInt wird nicht exportiert — git checkout ."
ok "lib/validate.js exportiert parseRangeInt"

grep -q "repraesentantenIds" "$BE/routes/reports.js" || die "repraesentantenIds fehlt"
if grep -qE '\.limit\((days|limit|anzahl) \* 8\)' "$BE/routes/reports.js"; then
  die "es gibt noch ein '* 8'-Fenster in routes/reports.js — git checkout ."
fi
ok "kein '* 8'-Fenster mehr in routes/reports.js"

echo
echo "── Tests ───────────────────────────────────────────────────────"
echo
( cd "$BE" && npm run test:unit ) || true
echo
( cd "$BE" && npm run test:integration ) || true

echo
echo "── Danach ──────────────────────────────────────────────────────"
echo
echo "  Erwartet: 51/51 Unit und 50/50 Integration grün."
echo
echo "  Zwei Punkte für später, bewusst NICHT in diesem Schritt:"
echo "   · /history lädt weiterhin vollständige Momentaufnahmen. Die"
echo "     Datenmenge ist jetzt auf 'limit' Protokolle begrenzt statt auf"
echo "     'limit * 8' — also besser als vorher, aber noch nicht in der"
echo "     Datenbank gerechnet. Dafür brauche ich den Rumpf des Handlers."
echo "   · /history prüft seinen limit-Parameter noch nicht mit"
echo "     parseRangeInt. Gleicher Grund."
echo
echo "  Rückgängig:  git checkout . && git clean -fd"
echo
