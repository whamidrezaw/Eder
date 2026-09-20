#!/usr/bin/env bash
#
# apply-e1-tests.sh — Phase E1, Schritt 1: nur Tests, keine Korrekturen
#
# Beweist, dass zwei gleichzeitige Bestandsänderungen einander lautlos
# überschreiben. Nach diesem Skript sollen Tests ROT sein.
#
# Ausführen im Wurzelverzeichnis des Repos:
#     bash apply-e1-tests.sh
#
# Idempotent. Rührt keine Anwendungslogik an.
#
set -euo pipefail

BE="Edeka.lager/backend"
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; }
die() { printf '\n  \033[31m✗ %s\033[0m\n\n' "$1" >&2; exit 1; }

echo
echo "── Phase E1, Schritt 1: Beweise ────────────────────────────────"
echo

[ -d "$BE/test/integration" ]  || die "'$BE/test' fehlt."
[ -f "$BE/routes/products.js" ] || die "'$BE/routes/products.js' nicht gefunden."

if command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
  BRANCH=$(git rev-parse --abbrev-ref HEAD)
  [ "$BRANCH" != "main" ] || die "Du bist auf main. Bitte auf phase-e wechseln."
  [ -z "$(git status --porcelain)" ] || die "Arbeitsverzeichnis nicht sauber. Bitte erst committen."
  ok "Branch '$BRANCH', Arbeitsverzeichnis sauber"
fi

ZIEL="$BE/test/integration/stock-concurrency.test.js"
[ -f "$ZIEL" ] && cp "$ZIEL" "$ZIEL.bak"

cat > "$ZIEL" <<'EOF'
'use strict';
//
// Phase E1 — gleichzeitige Bestandsänderungen.
//
// Zwei Lageristen zählen dasselbe Produkt. Heute gewinnt der letzte
// Schreiber, und der andere erfährt nie, dass seine Zählung weg ist.
//
// Die Regel, die hier festgehalten wird: Wer auf einem veralteten Stand
// aufsetzt, bekommt einen 409 mit dem aktuellen Stand — und entscheidet
// selbst. Zusammenrechnen wäre falsch: das Formular nimmt eine absolute
// Zählung entgegen ("ich sehe 4 im Regal"), keine Bewegung. Aus zwei
// Zählungen einen dritten Wert zu errechnen, den niemand gesehen hat,
// wäre schlimmer als der Konflikt.
//
// Rote Tests sind mit "── ROT ──" markiert.
//
const test     = require('node:test');
const assert   = require('node:assert/strict');
const jwt      = require('jsonwebtoken');
const db       = require('../helpers/db');
const Product  = require('../../models/Product');
const { start, stop, req } = require('../helpers/http');
const { makeUser, makeProduct } = require('../helpers/factories');

test.before(async () => { await db.connect(); await start(); });
test.after (async () => { await stop(); await db.disconnect(); });
test.beforeEach(async () => { await db.wipe(); });

// Tokens werden hier direkt signiert statt über /api/auth/login geholt.
// Grund: der Login-Limiter lässt zehn Versuche je Viertelstunde zu, und
// diese Datei bräuchte mehr. Authentifizierung ist hier nicht das Thema —
// dass der Weg trotzdem trägt, prüft die zweite Kontrolle.
function tokenFuer(benutzer) {
  return jwt.sign({ id: benutzer._id.toString() }, process.env.JWT_SECRET, { expiresIn: '1h' });
}

async function zweiLageristen() {
  const anna  = await makeUser({ username: 'anna_lager',  name: 'Anna'  });
  const bernd = await makeUser({ username: 'bernd_lager', name: 'Bernd' });
  return { anna: tokenFuer(anna), bernd: tokenFuer(bernd) };
}

const kurzWarten = () => new Promise(r => { setTimeout(r, 5); });

async function standVon(id) {
  return Product.findById(id).lean();
}

// ── Kontrollen: müssen GRÜN sein ──────────────────────────────────
// Ist eine davon rot, trägt der ganze Plan nicht. Dann bitte melden,
// bevor irgendetwas am Code geändert wird.

test('Kontrolle: ein selbst signiertes Token wird akzeptiert', async () => {
  const { anna } = await zweiLageristen();
  const r = await req('/api/products', { token: anna });
  assert.equal(r.status, 200,
    `Token wurde nicht akzeptiert (${r.status}): ${r.text} — dann greifen die ` +
    `folgenden Tests aus dem falschen Grund nicht.`);
});

test('Kontrolle: updatedAt ändert sich bei jeder Bestandsänderung', async () => {
  const { anna } = await zweiLageristen();
  const p = await makeProduct({ currentStock: 10 });

  const vorher = await standVon(p._id);
  assert.ok(vorher.updatedAt instanceof Date,
    'Product hat kein updatedAt — ohne timestamps gibt es keine brauchbare Version.');

  await kurzWarten();
  const r = await req(`/api/products/${p._id}/stock`, {
    method: 'PATCH', token: anna, body: { currentStock: 7 }
  });
  assert.equal(r.status, 200, r.text);

  const nachher = await standVon(p._id);
  assert.notEqual(nachher.updatedAt.getTime(), vorher.updatedAt.getTime(),
    'updatedAt bleibt gleich — es taugt dann nicht als Version.');
});

test('Kontrolle: die Produktliste liefert updatedAt mit', async () => {
  const { anna } = await zweiLageristen();
  await makeProduct({ currentStock: 10 });

  const r = await req('/api/products', { token: anna });
  assert.equal(r.status, 200, r.text);

  const liste = Array.isArray(r.body) ? r.body : (r.body.products || r.body.items);
  assert.ok(Array.isArray(liste), `unerwartete Antwortform: ${JSON.stringify(r.body).slice(0, 200)}`);
  assert.ok(liste.length > 0, 'keine Produkte in der Antwort');
  assert.ok(liste[0].updatedAt,
    'Die Liste enthält kein updatedAt. Dann kann das Frontend gar keine ' +
    'Version mitschicken — die Korrektur müsste erst hier ansetzen.');
});

// ── Befund: die verlorene Zählung ─────────────────────────────────

// ── ROT ──
test('eine ältere Zählung überschreibt eine neuere nicht', async () => {
  const { anna, bernd } = await zweiLageristen();
  const p = await makeProduct({ currentStock: 10 });

  // Anna öffnet die Liste und sieht 10.
  const annasVersion = (await standVon(p._id)).updatedAt;

  // Bernd zählt in der Zwischenzeit und trägt 8 ein.
  await kurzWarten();
  const bernds = await req(`/api/products/${p._id}/stock`, {
    method: 'PATCH', token: bernd,
    body: { currentStock: 8, updatedAt: annasVersion.toISOString() }
  });
  assert.equal(bernds.status, 200, `Bernds Eintrag ging nicht durch: ${bernds.text}`);

  const nachBernd = await standVon(p._id);
  assert.notEqual(nachBernd.updatedAt.getTime(), annasVersion.getTime(),
    'updatedAt hat sich nicht geändert — dieser Test kann den Konflikt nicht auslösen.');

  // Anna trägt jetzt ihre Zählung ein — auf dem Stand von vorhin.
  const annas = await req(`/api/products/${p._id}/stock`, {
    method: 'PATCH', token: anna,
    body: { currentStock: 4, updatedAt: annasVersion.toISOString() }
  });

  assert.equal(annas.status, 409,
    `Annas veraltete Zählung wurde mit ${annas.status} angenommen. Bernds ` +
    `Zählung von 8 ist damit spurlos verschwunden — niemand erfährt davon.`);

  const ende = await standVon(p._id);
  assert.equal(ende.currentStock, 8, 'der Bestand wurde trotz Konflikt überschrieben');
});

// ── ROT ──
test('die 409-Antwort enthält den aktuellen Stand', async () => {
  const { anna, bernd } = await zweiLageristen();
  const p = await makeProduct({ currentStock: 10 });
  const annasVersion = (await standVon(p._id)).updatedAt;

  await kurzWarten();
  await req(`/api/products/${p._id}/stock`, {
    method: 'PATCH', token: bernd,
    body: { currentStock: 8, updatedAt: annasVersion.toISOString() }
  });
  const jetzt = await standVon(p._id);

  const annas = await req(`/api/products/${p._id}/stock`, {
    method: 'PATCH', token: anna,
    body: { currentStock: 4, updatedAt: annasVersion.toISOString() }
  });

  assert.equal(annas.status, 409, annas.text);

  // Ohne diese Angaben kann das Frontend nur "Fehler" anzeigen. Mit ihnen
  // kann es sagen: "Jemand hat gerade 8 eingetragen. Deine Zählung war 4.
  // Trotzdem übernehmen?" — und der zweite Versuch trägt die neue Version.
  assert.equal(annas.body.code, 'STOCK_CONFLICT',
    'ohne maschinenlesbares Kennzeichen kann das Frontend den Fall nicht erkennen');
  assert.equal(annas.body.currentStock, 8,
    'die Antwort nennt den aktuellen Bestand nicht');
  assert.ok(annas.body.updatedAt,
    'die Antwort nennt die neue Version nicht — ein zweiter Versuch wäre unmöglich');
  assert.equal(new Date(annas.body.updatedAt).getTime(), jetzt.updatedAt.getTime(),
    'die genannte Version passt nicht zum tatsächlichen Stand');
});

// ── Leitplanken: heute grün, müssen grün bleiben ──────────────────

test('mit der aktuellen Version geht die Änderung normal durch', async () => {
  const { anna } = await zweiLageristen();
  const p = await makeProduct({ currentStock: 10 });
  const version = (await standVon(p._id)).updatedAt;

  await kurzWarten();
  const r = await req(`/api/products/${p._id}/stock`, {
    method: 'PATCH', token: anna,
    body: { currentStock: 6, updatedAt: version.toISOString() }
  });

  assert.equal(r.status, 200, r.text);
  assert.equal((await standVon(p._id)).currentStock, 6);
});

test('mehrere Änderungen nacheinander funktionieren weiterhin', async () => {
  // Die Sperre darf normale Arbeit nicht behindern: wer jedes Mal die
  // frische Version mitschickt, kommt beliebig oft durch.
  const { anna, bernd } = await zweiLageristen();
  const p = await makeProduct({ currentStock: 20 });

  for (const [token, wert] of [[anna, 15], [bernd, 12], [anna, 9]]) {
    const version = (await standVon(p._id)).updatedAt;
    await kurzWarten();
    const r = await req(`/api/products/${p._id}/stock`, {
      method: 'PATCH', token,
      body: { currentStock: wert, updatedAt: version.toISOString() }
    });
    assert.equal(r.status, 200, `Schritt auf ${wert} scheiterte: ${r.text}`);
  }

  assert.equal((await standVon(p._id)).currentStock, 9);
});
EOF

ok "test/integration/stock-concurrency.test.js (7 Tests)"

echo
echo "── Selbstprüfung ───────────────────────────────────────────────"
node --check "$ZIEL" >/dev/null 2>&1 || die "Syntaxfehler in $ZIEL"
ok "syntaktisch gültig"

node -e "
  const { datenbankName } = require('./$BE/test/helpers/db-name');
  const n = datenbankName('$ZIEL');
  if (!/_test\$/.test(n)) { console.error('Datenbankname ungültig: ' + n); process.exit(1); }
  console.log('  \x1b[32m✓\x1b[0m eigene Testdatenbank: ' + n);
" || die "Ableitung des Datenbanknamens fehlgeschlagen"

( cd "$BE" && npm run lint ) >/dev/null 2>&1 && ok "Lint sauber" \
  || die "Lint meldet etwas — bitte 'npm run lint' im backend ansehen"

echo
echo "── Tests ───────────────────────────────────────────────────────"
echo
( cd "$BE" && npm run test:integration ) 2>&1 | grep -E "^(✔|✖|ℹ)" || true

echo
echo "── Erwartung ───────────────────────────────────────────────────"
echo
echo "  5 GRÜN   3 Kontrollen + 2 Leitplanken"
echo "  2 ROT    der eigentliche Befund"
echo "  Dazu unverändert: 65 Unit- und 57 bisherige Integrationstests."
echo "  Integration also 64 Tests, davon 2 rot."
echo
echo "  Wichtig: Sind die KONTROLLEN rot, trägt der Plan nicht."
echo "   · scheitert das selbst signierte Token, stimmt die Nutzlast nicht"
echo "   · ändert sich updatedAt nicht, taugt es nicht als Version"
echo "   · fehlt updatedAt in der Produktliste, kann das Frontend nichts"
echo "     mitschicken und die Korrektur müsste dort ansetzen"
echo "  In allen drei Fällen bitte nur die Ausgabe schicken."
echo
echo "  Rückgängig:  git checkout . && git clean -fd"
echo
