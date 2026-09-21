#!/usr/bin/env bash
#
# apply-e1-fixes.sh — Phase E1, Schritt 2: optimistische Sperre
#
#   E1.1  routes/products.js  PATCH /:id/stock verlangt die Version, auf der
#                             die Eingabe beruht, und antwortet mit 409,
#                             wenn jemand schneller war
#   E1.2  dashboard.html      schickt die Version mit und fragt beim Konflikt
#                             nach, statt die Zählung stumm zu verwerfen
#   E1.3  E1-Tests            eine Vorlage nachziehen, drei Tests ergänzen
#
# Als Version dient updatedAt. Mongoose pflegt es bei jedem Update
# (timestamps: true). __v taugt nicht: findByIdAndUpdate zählt es nicht hoch.
#
# ACHTUNG: Nach diesem Schritt ist die Version PFLICHT. Ein Client, der sie
# nicht mitschickt, bekommt 400 mit code VERSION_REQUIRED — sichtbar, nicht
# stumm. Das Frontend wird hier mitgeändert; andere Aufrufer gibt es nach
# meiner Prüfung nicht, das Skript zählt sie zur Sicherheit nach.
#
# Ausführen im Wurzelverzeichnis des Repos:
#     bash apply-e1-fixes.sh
#
set -euo pipefail

BE="Edeka.lager/backend"
FE="Edeka.lager/frontend"
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
skip() { printf '  \033[90m·\033[0m %s\n' "$1"; }
die()  { printf '\n  \033[31m✗ %s\033[0m\n\n' "$1" >&2; exit 1; }

echo
echo "── Phase E1, Schritt 2: optimistische Sperre ───────────────────"
echo

[ -f "$BE/routes/products.js" ] || die "'$BE/routes/products.js' nicht gefunden."
[ -f "$FE/dashboard.html" ]     || die "'$FE/dashboard.html' nicht gefunden."
[ -f "$BE/test/integration/stock-concurrency.test.js" ] \
  || die "E1-Tests fehlen. Bitte zuerst apply-e1-tests.sh ausführen."

if command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
  BRANCH=$(git rev-parse --abbrev-ref HEAD)
  [ "$BRANCH" != "main" ] || die "Du bist auf main. Bitte auf phase-e wechseln."
  [ -z "$(git status --porcelain)" ] || die "Arbeitsverzeichnis nicht sauber. Bitte erst committen."
  ok "Branch '$BRANCH', Arbeitsverzeichnis sauber"
fi

echo
echo "── Aufrufer der Route zählen ───────────────────────────────────"
TREFFER=$(grep -rn --include='*.html' --include='*.js' -- "/stock\`, 'PATCH'" "$FE" 2>/dev/null || true)
ANZ=$(printf '%s' "$TREFFER" | grep -c . || true)
if [ "$ANZ" -eq 0 ]; then
  die "Keine Aufrufstelle gefunden — der Anker stimmt nicht. Nichts geändert."
fi
printf '%s\n' "$TREFFER" | sed 's/^/    /'
if [ "$ANZ" -gt 1 ]; then
  die "Es gibt $ANZ Aufrufstellen, dieses Skript ändert nur die in dashboard.html.
     Die anderen würden nach der Umstellung 400 bekommen. Bitte die Liste oben schicken."
fi
ok "genau eine Aufrufstelle — sie wird mitgeändert"

echo
echo "── Quelltext (alles oder nichts) ───────────────────────────────"

node - "$BE" "$FE" <<'NODE_E1'
const fs   = require('fs');
const path = require('path');
const BE = process.argv[2], FE = process.argv[3];

const plan = [], fehler = [], dateien = new Map();
const pfad = d => d.startsWith('frontend/')
  ? path.join(FE, ...d.replace(/^frontend\//, '').split('/'))
  : path.join(BE, ...d.split('/'));

function hole(d) {
  if (!dateien.has(d)) {
    const f = pfad(d);
    if (!fs.existsSync(f)) return null;
    const t = fs.readFileSync(f, 'utf8');
    dateien.set(d, { original: t, aktuell: t });
  }
  return dateien.get(d);
}
function umgebung(text, muster, zeilen = 10) {
  const L = text.split('\n');
  const i = L.findIndex(l => muster.test(l));
  if (i === -1) return '      (keine ähnliche Zeile gefunden)';
  return L.slice(Math.max(0, i - 2), i + zeilen).map((l, k) => `      ${i - 1 + k}| ${l}`).join('\n');
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

// ── E1.1  Route neu ───────────────────────────────────────────────
(() => {
  const name = 'E1.1  PATCH /:id/stock mit optimistischer Sperre';
  const e = hole('routes/products.js');
  if (!e) { fehler.push({ name, datei: 'routes/products.js', hinweis: 'Datei nicht gefunden', ausschnitt: '' }); return; }
  if (/STOCK_CONFLICT/.test(e.aktuell)) { plan.push({ datei: 'routes/products.js', name, geaendert: false }); return; }

  const L = e.aktuell.split('\n');
  const start = L.findIndex(l => /^router\.patch\('\/:id\/stock'/.test(l));
  if (start === -1) {
    fehler.push({ name, datei: 'routes/products.js',
                  hinweis: "router.patch('/:id/stock' nicht am Zeilenanfang gefunden",
                  ausschnitt: umgebung(e.aktuell, /\/:id\/stock/) });
    return;
  }
  const ende = L.findIndex((l, i) => i > start && l === '});');
  if (ende === -1) {
    fehler.push({ name, datei: 'routes/products.js',
                  hinweis: 'Ende des Handlers nicht erkennbar',
                  ausschnitt: umgebung(e.aktuell, /^router\.patch\('\/:id\/stock'/, 30) });
    return;
  }

  const neu = [
    "router.patch('/:id/stock', auth, async (req, res) => {",
    '  const { currentStock, updatedAt } = req.body;',
    '',
    '  // Typprüfung VOR Number(): Number([]) ist 0, Number(["5"]) ist 5.',
    '  // Ohne sie setzt ein leeres Array den Bestand still auf null.',
    '  // Die Bestandsprüfung steht bewusst VOR der Versionsprüfung: ein',
    '  // unsinniger Wert ist ein unsinniger Wert, egal welche Version dabei',
    '  // liegt.',
    "  const wert = require('../lib/validate').parseStock(currentStock);",
    '  if (wert === null) {',
    "    return res.status(400).json({ message: 'Ungültiger Bestandswert. Erwartet wird eine Zahl ab 0.' });",
    '  }',
    '',
    '  // ── Optimistische Sperre ──────────────────────────────────────',
    '  // Das Formular nimmt eine ABSOLUTE Zählung entgegen ("ich sehe 4 im',
    '  // Regal"), keine Bewegung. Zählen zwei Lageristen gleichzeitig, darf',
    '  // die ältere Zählung die neuere nicht überschreiben — und schon gar',
    '  // nicht lautlos. Beides zusammenzurechnen wäre falsch: dabei käme ein',
    '  // dritter Wert heraus, den niemand im Regal gesehen hat.',
    '  //',
    '  // Als Version dient updatedAt. Mongoose pflegt es bei jedem Update',
    '  // (timestamps: true). __v taugt nicht: findByIdAndUpdate zählt es',
    '  // nicht hoch, es bliebe also immer gleich.',
    "  if (updatedAt === undefined || updatedAt === null || updatedAt === '') {",
    '    return res.status(400).json({',
    "      message: 'Es fehlt der Stand, auf dem die Eingabe beruht (updatedAt).',",
    "      code: 'VERSION_REQUIRED'",
    '    });',
    '  }',
    '  const erwartet = new Date(updatedAt);',
    '  if (Number.isNaN(erwartet.getTime())) {',
    "    return res.status(400).json({ message: 'Ungültiger Wert für updatedAt.', code: 'VERSION_REQUIRED' });",
    '  }',
    '',
    '  // Prüfen und Schreiben in EINER Operation: zwischen einem getrennten',
    '  // Lesen und Schreiben passte sonst genau der Konflikt, den wir hier',
    '  // verhindern wollen.',
    '  const product = await Product.findOneAndUpdate(',
    '    { _id: req.params.id, updatedAt: erwartet },',
    '    { currentStock: wert, updatedBy: req.user._id },',
    "    { returnDocument: 'after', runValidators: true }",
    '  );',
    '  if (product) return res.json(product);',
    '',
    '  // Kein Treffer heißt zweierlei: das Produkt gibt es nicht, oder',
    '  // jemand war schneller. Die Fälle müssen unterschieden werden.',
    '  const aktuell = await Product.findById(req.params.id).lean();',
    "  if (!aktuell) return res.status(404).json({ message: 'Produkt nicht gefunden' });",
    '',
    '  // Der aktuelle Stand geht mit: ohne ihn kann der Aufrufer nur',
    '  // "Fehler" anzeigen, mit ihm kann er fragen und es erneut versuchen.',
    '  return res.status(409).json({',
    '    message: `Der Bestand wurde inzwischen auf ${aktuell.currentStock} geändert.`,',
    "    code: 'STOCK_CONFLICT',",
    '    currentStock: aktuell.currentStock,',
    '    updatedAt: aktuell.updatedAt',
    '  });',
    '});'
  ];

  e.aktuell = [...L.slice(0, start), ...neu, ...L.slice(ende + 1)].join('\n');
  plan.push({ datei: 'routes/products.js', name, geaendert: true });
})();

// ── E1.2a  dashboard.html: Version mitschicken ────────────────────
patch({
  name: 'E1.2  dashboard.html: Version wird mitgeschickt',
  datei: 'frontend/dashboard.html',
  // Das Muster muss auf das passen, was die Ersetzung TATSÄCHLICH schreibt —
  // hier mit Ausrichtungsleerzeichen. Genau daran ist die Prüfung zuerst
  // gescheitert.
  schonDa: /updatedAt:\s+p\.updatedAt/,
  suche: /    const updated = await api\(`\/api\/products\/\$\{id\}\/stock`, 'PATCH', \{ currentStock: num \}\);/,
  ersetze: () => [
    '    // p.updatedAt ist die Version, die DIESER Nutzer gesehen hat — nicht',
    '    // ein frisch geholter Stand. Genau darauf beruht die Prüfung: hätten',
    '    // wir hier neu geladen, wäre das Fenster für den Konflikt nur ein',
    '    // paar Millisekunden groß und die Sperre wirkungslos.',
    '    const updated = await api(`/api/products/${id}/stock`, \'PATCH\', {',
    '      currentStock: num,',
    '      updatedAt:    p.updatedAt',
    '    });'
  ].join('\n'),
  hinweis: 'Die api()-Zeile in setStock wurde nicht gefunden.',
  naehe: /\/stock`, 'PATCH'/
});

// ── E1.2b  dashboard.html: Konflikt behandeln ─────────────────────
patch({
  name: 'E1.2  dashboard.html: Konflikt wird abgefragt statt verworfen',
  datei: 'frontend/dashboard.html',
  schonDa: /STOCK_CONFLICT/,
  suche: /  \} catch \(e\) \{\r?\n    showToast\('⚠️ ' \+ e\.message, 'err'\);\r?\n    renderTable\(\);\r?\n  \}\r?\n\}\r?\nwindow\.setStock = setStock;/,
  ersetze: () => [
    '  } catch (e) {',
    '    // 409 heißt: jemand anders war schneller. Der lokale Stand ist damit',
    '    // veraltet — erst richtigstellen, dann fragen. Ohne die Rückfrage',
    '    // wäre die eigene Zählung einfach weg, und genau das war der Fehler.',
    "    if (e.status === 409 && e.data && e.data.code === 'STOCK_CONFLICT') {",
    '      p.currentStock = e.data.currentStock;',
    '      p.updatedAt    = e.data.updatedAt;',
    '      renderKpis();',
    '      renderTable();',
    '',
    '      const trotzdem = confirm(',
    "        'Jemand anderes hat den Bestand inzwischen auf ' + e.data.currentStock + ' geändert.' +",
    "        '\\n\\nDeine Zählung war ' + num + '.' +",
    "        '\\n\\nTrotzdem ' + num + ' eintragen?'",
    '      );',
    '      // Der zweite Versuch trägt die frische Version. Stimmt der Wert',
    '      // inzwischen ohnehin überein, bricht setStock von selbst ab.',
    '      if (trotzdem) await setStock(id, num);',
    '      return;',
    '    }',
    "    showToast('⚠️ ' + e.message, 'err');",
    '    renderTable();',
    '  }',
    '}',
    'window.setStock = setStock;'
  ].join('\n'),
  hinweis: 'Der catch-Block von setStock sieht anders aus als erwartet.',
  naehe: /window\.setStock/
});

// ── E1.3  Vorlage im Kontrolltest nachziehen ──────────────────────
// Dieser Test schickte bewusst keine Version, weil es sie noch nicht gab.
// Geändert wird nur die Vorlage, nicht seine Aussage: er prüft weiterhin,
// dass updatedAt sich bei jeder Änderung bewegt. Die beiden ROTEN Tests
// bleiben unangetastet — sie sind der Maßstab.
patch({
  name: 'E1.3  Kontrolltest schickt jetzt ebenfalls die Version',
  datei: 'test/integration/stock-concurrency.test.js',
  // Die Ersetzung verteilt den Aufruf auf zwei Zeilen; ein einzeiliges
  // Muster fand sich danach nicht wieder.
  schonDa: /currentStock: 7, updatedAt/,
  suche: /    method: 'PATCH', token: anna, body: \{ currentStock: 7 \}\r?\n/,
  ersetze: "    method: 'PATCH', token: anna,\n    body: { currentStock: 7, updatedAt: vorher.updatedAt.toISOString() }\n",
  hinweis: 'Die Vorlage im Kontrolltest wurde nicht gefunden.',
  naehe: /currentStock: 7/
});

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
  console.log(p.geaendert ? `  \x1b[32m✓\x1b[0m ${p.name}`
                          : `  \x1b[90m·\x1b[0m ${p.name} — schon angewendet`);
}
for (const [d, e] of dateien) {
  if (e.aktuell === e.original) continue;
  const f = pfad(d);
  if (!fs.existsSync(f + '.e1.bak')) fs.writeFileSync(f + '.e1.bak', e.original);
  fs.writeFileSync(f, e.aktuell);
  console.log(`  \x1b[90m→\x1b[0m geschrieben: ${d}`);
}
NODE_E1

# ── Neue Tests für das neue Verhalten ────────────────────────────────
echo
echo "── Neue Tests ──────────────────────────────────────────────────"
ZIEL="$BE/test/integration/stock-concurrency.test.js"
if grep -q 'VERSION_REQUIRED' "$ZIEL"; then
  skip "schon vorhanden"
else
  cat >> "$ZIEL" <<'EOF'

// ── Neu in E1: die Version ist Pflicht ────────────────────────────

test('ohne Version wird die Änderung sichtbar abgewiesen', async () => {
  const { anna } = await zweiLageristen();
  const p = await makeProduct({ currentStock: 10 });

  const r = await req(`/api/products/${p._id}/stock`, {
    method: 'PATCH', token: anna, body: { currentStock: 4 }
  });

  assert.equal(r.status, 400, r.text);
  assert.equal(r.body.code, 'VERSION_REQUIRED');
  assert.equal((await standVon(p._id)).currentStock, 10, 'trotz 400 wurde geschrieben');
});

test('eine unbrauchbare Version wird abgewiesen', async () => {
  const { anna } = await zweiLageristen();
  const p = await makeProduct({ currentStock: 10 });

  for (const muell of ['gestern', '', 'null', '2026-13-45T99:99:99Z']) {
    const r = await req(`/api/products/${p._id}/stock`, {
      method: 'PATCH', token: anna, body: { currentStock: 4, updatedAt: muell }
    });
    assert.equal(r.status, 400, `updatedAt="${muell}" ergab ${r.status}: ${r.text}`);
  }
  assert.equal((await standVon(p._id)).currentStock, 10);
});

test('ein unbekanntes Produkt ergibt weiterhin 404, nicht 409', async () => {
  // Die neue Route unterscheidet "gibt es nicht" von "jemand war
  // schneller". Ohne diesen Test könnte ein 404 unbemerkt zu einem 409
  // werden — und der Aufrufer würde nach einer Version fragen, die es
  // nie geben wird.
  const { anna } = await zweiLageristen();
  const erfunden = new (require('mongoose').Types.ObjectId)();

  const r = await req(`/api/products/${erfunden}/stock`, {
    method: 'PATCH', token: anna,
    body: { currentStock: 4, updatedAt: new Date().toISOString() }
  });
  assert.equal(r.status, 404, r.text);
});
EOF
  ok "3 Tests ergänzt"
fi

# ── Selbstprüfung ────────────────────────────────────────────────────
echo
echo "── Selbstprüfung ───────────────────────────────────────────────"
for f in "$BE/routes/products.js" "$ZIEL"; do
  node --check "$f" >/dev/null 2>&1 || die "Syntaxfehler in $f — rückgängig mit: git checkout ."
done
ok "Backend syntaktisch gültig"

# dashboard.html ist kein JS-Modul — der veränderte Block wird einzeln geprüft.
node - "$FE" <<'NODE_CHK'
const fs = require('fs');
const t = fs.readFileSync(process.argv[2] + '/dashboard.html', 'utf8');
const L = t.split('\n');
const a = L.findIndex(l => /^async function setStock\(/.test(l));
const b = a === -1 ? -1 : L.findIndex((l, i) => i > a && l === '}');
if (a === -1 || b === -1) { console.error('  setStock nicht abgrenzbar'); process.exit(1); }
const block = L.slice(a, b + 1).join('\n');
try {
  new Function(block + '\n;');
  console.log('  \x1b[32m✓\x1b[0m setStock in dashboard.html ist syntaktisch gültig');
} catch (err) {
  console.error('  Syntaxfehler in setStock: ' + err.message);
  process.exit(1);
}
const noetig = ['STOCK_CONFLICT', 'updatedAt:    p.updatedAt', 'confirm('];
const fehlt = noetig.filter(s => !block.includes(s));
if (fehlt.length) { console.error('  fehlt in setStock: ' + fehlt.join(', ')); process.exit(1); }
console.log('  \x1b[32m✓\x1b[0m setStock schickt die Version und behandelt den Konflikt');
NODE_CHK
[ $? -eq 0 ] || die "dashboard.html — rückgängig mit: git checkout ."

( cd "$BE" && npm run lint ) >/dev/null 2>&1 && ok "Lint sauber" \
  || die "Lint meldet etwas — bitte 'npm run lint' im backend ansehen"

echo
echo "── Tests ───────────────────────────────────────────────────────"
echo
( cd "$BE" && npm run test:unit ) 2>&1 | tail -6 || true
echo
( cd "$BE" && npm run test:integration ) 2>&1 | grep -E "^(✖|ℹ)" || true

echo
echo "── Danach ──────────────────────────────────────────────────────"
echo
echo "  Erwartet: 65 Unit- und 67 Integrationstests grün — die beiden"
echo "  roten aus Schritt 1 sind damit geschlossen."
echo
echo "  Im Browser von Hand nachstellen, denn die Frontend-Änderung hat"
echo "  keinen automatischen Test (Inline-Skripte in HTML werden weder"
echo "  geprüft noch getestet — das bleibt die offene Fläche für Phase F):"
echo
echo "   1. Dashboard in ZWEI Tabs öffnen"
echo "   2. In Tab A den Bestand eines Produkts auf 8 setzen"
echo "   3. In Tab B — ohne neu zu laden — dasselbe Produkt auf 4 setzen"
echo "      -> Rückfrage erscheint und nennt 8"
echo "   4. Abbrechen  -> Tabelle zeigt 8"
echo "   5. Schritt 3 wiederholen, diesmal bestätigen -> 4 wird übernommen"
echo "   6. Normale Änderung in einem einzelnen Tab -> unverändert einfach"
echo "   7. Die ± Knöpfe -> funktionieren wie bisher"
echo
echo "  Rückgängig:  git checkout . && git clean -fd"
echo
