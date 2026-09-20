#!/usr/bin/env bash
#
# apply-c2-history.sh — C2, Nachtrag für /history
#
# Der vorige Schritt hat in /history die Auswahl ersetzt und dabei rawLogs
# entfernt — ohne zu prüfen, ob rawLogs weiter unten noch benutzt wird. Es
# wurde benutzt:
#
#   reportsToday: rawLogs.filter(l => l.date === log.date && l.type === 'manual').length
#
# Daher der 500er. Dieses Skript stellt reportsToday wieder her, und zwar
# richtig: gezählt wird in der Datenbank statt in einem abgeschnittenen
# Fenster. Vorher bekamen Tage außerhalb des Fensters eine 0, obwohl es an
# ihnen Berichte gab — dasselbe "* 8" hat also an zwei Stellen geschadet.
#
# Zusätzlich:
#   · limit wird mit parseRangeInt geprüft (wie days in /analytics)
#   · eine Abschlussprüfung stellt sicher, dass kein rawLogs mehr übrig ist
#   · zwei neue Tests
#
# Ausführen im Wurzelverzeichnis des Repos:
#     bash apply-c2-history.sh
#
set -euo pipefail

BE="Edeka.lager/backend"
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
skip() { printf '  \033[90m·\033[0m %s\n' "$1"; }
die()  { printf '\n  \033[31m✗ %s\033[0m\n\n' "$1" >&2; exit 1; }

echo
echo "── C2, Nachtrag: /history ──────────────────────────────────────"
echo

[ -f "$BE/routes/reports.js" ] || die "'$BE/routes/reports.js' nicht gefunden."
grep -q "parseRangeInt" "$BE/lib/validate.js" || die "parseRangeInt fehlt. Bitte zuerst apply-c2-fixes.sh ausführen."

if command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
  [ -z "$(git status --porcelain)" ] || die "Arbeitsverzeichnis nicht sauber. Bitte erst committen."
  ok "Arbeitsverzeichnis sauber"
fi

echo
echo "── Planen und anwenden (alles oder nichts) ─────────────────────"

node - "$BE" <<'NODE_HIST'
const fs   = require('fs');
const path = require('path');
const BE   = process.argv[2];
const P    = (...p) => path.join(BE, ...p);

const plan    = [];
const fehler  = [];
const dateien = new Map();

function hole(datei) {
  if (!dateien.has(datei)) {
    const f = P(...datei.split('/'));
    if (!fs.existsSync(f)) return null;
    const t = fs.readFileSync(f, 'utf8');
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

// ── 1  limit prüfen wie days in /analytics ────────────────────────
patch({
  name: 'H1  /history prüft limit mit parseRangeInt',
  datei: 'routes/reports.js',
  schonDa: /parseRangeInt\(req\.query\.limit/,
  suche: /const limit = Math\.min\(parseInt\(req\.query\.limit\) \|\| 30, 365\);/,
  ersetze: [
    "const limit = require('../lib/validate')",
    "    .parseRangeInt(req.query.limit, { min: 1, max: 365, standard: 30 });",
    '  if (limit === null) {',
    '    return res.status(400).json({',
    "      message: 'Ungültiger Wert für limit. Erwartet wird eine ganze Zahl von 1 bis 365.'",
    '    });',
    '  }'
  ].join('\n'),
  hinweis: 'Die limit-Zeile in /history sieht anders aus als erwartet.',
  naehe: /req\.query\.limit/
});

// ── 2  Manuelle Berichte je Tag in der Datenbank zählen ───────────
patch({
  name: 'H2  manuelle Berichte je Tag werden in der Datenbank gezählt',
  datei: 'routes/reports.js',
  schonDa: /manuelleProTag/,
  suche: /(  const repLogs = await DailyLog\.find\(\{ _id: \{ \$in: repIds \} \}\)\.sort\(\{ date: -1 \}\);\n)/,
  ersetze: (treffer) => treffer + [
    '',
    '  // Anzahl der manuellen Berichte je Tag.',
    '  //',
    '  // Vorher wurde dafür das vorab geladene Fenster gefiltert — also genau',
    '  // die Liste, die durch limit * 8 abgeschnitten war. Tage außerhalb des',
    '  // Fensters bekamen eine 0, obwohl an ihnen berichtet wurde. Gezählt',
    '  // wird jetzt direkt in der Datenbank, für genau die angezeigten Tage.',
    '  const datumsListe = repLogs.map(l => l.date);',
    '  const zaehlung = await DailyLog.aggregate([',
    "    { $match: { date: { $in: datumsListe }, type: 'manual' } },",
    '    { $project: { date: 1 } },',
    "    { $group: { _id: '$date', anzahl: { $sum: 1 } } }",
    '  ]);',
    '  const manuelleProTag = new Map(zaehlung.map(z => [z._id, z.anzahl]));'
  ].join('\n'),
  hinweis: 'Die von apply-c2-fixes.sh eingefügte repLogs-Zeile wurde nicht gefunden.',
  naehe: /repIds/
});

// ── 3  reportsToday auf die Zählung umstellen ─────────────────────
patch({
  name: 'H3  reportsToday benutzt die Zählung statt rawLogs',
  datei: 'routes/reports.js',
  schonDa: /reportsToday:\s*manuelleProTag/,
  suche: /reportsToday:(\s*)rawLogs\.filter\([^)]*\)\.length,/,
  ersetze: (_t, abstand) => `reportsToday:${abstand}manuelleProTag.get(log.date) || 0,`,
  hinweis: 'Die reportsToday-Zeile sieht anders aus als erwartet.',
  naehe: /reportsToday/
});

// ── Abschlussprüfung, noch in der Planphase ───────────────────────
// Die Lehre aus dem 500er: ein gültiger Anker sagt nichts darüber, ob der
// entfernte Code weiter unten noch gebraucht wird. Also ausdrücklich prüfen,
// dass kein rawLogs mehr übrig ist — und zwar bevor etwas geschrieben wird.
{
  const e = dateien.get('routes/reports.js');
  // Nur echten Code prüfen: ein Kommentar, der das alte Bezeichner-Wort
  // erwähnt, ist kein Fehler — genau daran ist dieser Wächter erst
  // fälschlich angeschlagen.
  const nurCode = e ? e.aktuell.split('\n').filter(l => !/^\s*\/\//.test(l)).join('\n') : '';
  if (e && /\brawLogs\b/.test(nurCode)) {
    fehler.push({
      name: 'Abschlussprüfung',
      datei: 'routes/reports.js',
      hinweis: 'rawLogs kommt noch vor, ist aber nirgends mehr definiert',
      ausschnitt: umgebung(e.aktuell, /\brawLogs\b/)
    });
  }
}

if (fehler.length) {
  console.log('\n  \x1b[31mEs wurde NICHTS geändert:\x1b[0m\n');
  for (const f of fehler) {
    console.log(`  \x1b[31m✗\x1b[0m ${f.name}  (${f.datei})`);
    console.log(`     ${f.hinweis}`);
    if (f.ausschnitt) console.log('     Umgebung in deiner Datei:\n' + f.ausschnitt);
    console.log('');
  }
  console.log('  Schick mir die obigen Ausschnitte.\n');
  process.exit(1);
}

for (const p of plan) {
  if (!p.geaendert) { console.log(`  \x1b[90m·\x1b[0m ${p.name} — schon angewendet`); continue; }
  console.log(`  \x1b[32m✓\x1b[0m ${p.name}`);
}

for (const [datei, e] of dateien) {
  if (e.aktuell === e.original) continue;
  const f = P(...datei.split('/'));
  if (!fs.existsSync(f + '.hist.bak')) fs.writeFileSync(f + '.hist.bak', e.original);
  fs.writeFileSync(f, e.aktuell);
  console.log(`  \x1b[90m→\x1b[0m geschrieben: ${datei}`);
}
NODE_HIST

echo
echo "── Neue Tests ──────────────────────────────────────────────────"

ZIEL="$BE/test/integration/analytics.test.js"
if grep -q 'zählt die manuellen Berichte' "$ZIEL"; then
  skip "schon vorhanden"
else
  cat >> "$ZIEL" <<'EOF'

// ── Nachtrag C2: /history ─────────────────────────────────────────

test('/history zählt die manuellen Berichte je Tag vollständig', async () => {
  // 20 Tage mit je 20 Protokollen: eines auto-midnight, 19 manuell.
  // Vorher wurde diese Zahl aus dem abgeschnittenen rawLogs-Fenster
  // gefiltert — Tage außerhalb des Fensters bekamen eine 0.
  await seedLogs({ tage: 20, proTag: 20, produkte: 1 });

  const r = await req('/api/reports/history?limit=20', { token });
  assert.equal(r.status, 200, r.text);

  const liste = Array.isArray(r.body)
    ? r.body
    : (r.body.history || r.body.rows || r.body.days || r.body.entries);
  assert.ok(Array.isArray(liste), `unerwartete Antwortform: ${JSON.stringify(r.body).slice(0, 200)}`);
  assert.equal(liste.length, 20);

  for (const zeile of liste) {
    assert.equal(zeile.reportsToday, 19,
      `${zeile.date}: reportsToday ist ${zeile.reportsToday}, erwartet 19`);
  }
});

test('/history weist einen unsinnigen limit-Wert mit 400 ab', async () => {
  await seedLogs({ tage: 3, proTag: 1, produkte: 1 });

  for (const schlecht of ['-5', '0', '366', 'abc']) {
    const r = await req(`/api/reports/history?limit=${schlecht}`, { token });
    assert.equal(r.status, 400, `limit=${schlecht} ergab ${r.status}: ${r.text}`);
  }

  const gut = await req('/api/reports/history?limit=3', { token });
  assert.equal(gut.status, 200, gut.text);
});
EOF
  ok "2 Tests ergänzt"
fi

echo
echo "── Selbstprüfung ───────────────────────────────────────────────"
node --check "$BE/routes/reports.js" >/dev/null 2>&1 \
  || die "Syntaxfehler in routes/reports.js — rückgängig mit: git checkout ."
node --check "$ZIEL" >/dev/null 2>&1 || die "Syntaxfehler in $ZIEL"
ok "syntaktisch gültig"

if grep -v '^[[:space:]]*//' "$BE/routes/reports.js" | grep -q "rawLogs"; then
  die "rawLogs kommt noch im Code vor — git checkout ."
else
  ok "kein rawLogs mehr im Code von routes/reports.js"
fi

echo
echo "  Alle Bezeichner, die von den C2-Patches eingeführt wurden:"
for name in repraesentantenIds repIds manuelleProTag datumsListe; do
  n=$(grep -c "\b$name\b" "$BE/routes/reports.js" || true)
  printf '    %-22s %s Vorkommen\n' "$name" "$n"
done

echo
echo "── Tests ───────────────────────────────────────────────────────"
echo
( cd "$BE" && npm run test:integration ) || true

echo
echo "  Erwartet: 52 / 52 grün."
echo "  Rückgängig:  git checkout . && git clean -fd"
echo
