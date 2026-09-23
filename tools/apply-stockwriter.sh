#!/usr/bin/env bash
#
# apply-stockwriter.sh — Weg B: Mehrfachklick auf ± ohne falsche Konflikte
#
# Befund (im Browser belegt, drei 409 hintereinander bei EINEM Benutzer):
# adjustStock rechnete mit p.currentStock und p.updatedAt, die erst mit der
# Antwort aktualisiert werden. Über den Tunnel dauert eine Anfrage einige
# hundert Millisekunden — drei Klicks in einer Sekunde schickten deshalb
# zweimal eine veraltete Version, bekamen 409, und die Rückfrage behauptete
# fälschlich, jemand anderes habe geschrieben.
#
#   1. Vertrag als Tests festhalten (ROT: die Funktion gibt es noch nicht)
#   2. createBestandsschreiber in shared.js
#   3. setStock/adjustStock im Dashboard darauf umstellen
#   4. Tests GRÜN, dann die ganze Suite
#
# Die Logik liegt bewusst in shared.js und nicht im Inline-Skript von
# dashboard.html: nur dort kann der vm-Harness sie prüfen. Erster kleiner
# Schritt von Phase F, auf dem heikelsten Weg der App.
#
# Ausführen im Wurzelverzeichnis des Repos:
#     bash apply-stockwriter.sh
#
set -euo pipefail

BE="Edeka.lager/backend"
FE="Edeka.lager/frontend"
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
die()  { printf '\n  \033[31m✗ %s\033[0m\n\n' "$1" >&2; exit 1; }

echo
echo "── Weg B: Klicks bündeln statt Konflikte erfinden ──────────────"
echo

[ -f "$FE/assets/shared.js" ]      || die "'$FE/assets/shared.js' nicht gefunden."
[ -f "$FE/dashboard.html" ]        || die "'$FE/dashboard.html' nicht gefunden."
[ -f "$BE/test/helpers/browser.js" ] || die "vm-Harness fehlt (test/helpers/browser.js)."

if command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
  BRANCH=$(git rev-parse --abbrev-ref HEAD)
  [ "$BRANCH" != "main" ] || die "Du bist auf main. Bitte auf phase-e wechseln."
  [ -z "$(git status --porcelain)" ] || die "Arbeitsverzeichnis nicht sauber. Bitte erst committen."
  ok "Branch '$BRANCH', Arbeitsverzeichnis sauber"
fi

# ── 1  Vertrag als Tests ─────────────────────────────────────────────
echo
echo "── Tests schreiben ─────────────────────────────────────────────"
mkdir -p "$BE/test/unit"
cat > "$BE/test/unit/stock-writer.test.js" <<'EOF'
'use strict';
//
// Vertrag des Bestandsschreibers.
//
// Diese Tests sind rot, weil createBestandsschreiber noch nicht existiert —
// sie beweisen den Befund nicht, sie beschreiben die Lösung. Der Beweis
// liegt schon vor: drei 409 hintereinander in der Browserkonsole, bei einem
// einzigen Benutzer und einem einzigen Produkt.
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const { ladeShared } = require('../helpers/browser');

const warte = (ms) => new Promise(r => { setTimeout(r, ms); });

function fehler409(stand, version) {
  const e = new Error('Konflikt');
  e.status = 409;
  e.data = { code: 'STOCK_CONFLICT', currentStock: stand, updatedAt: version };
  return e;
}

// Baut einen Schreiber mit Attrappen und gibt alles zurück, was ein Test
// beobachten will. antwortGeber bestimmt, wie der Server reagiert.
function aufbau(antwortGeber) {
  const { sandbox } = ladeShared({ token: 'test-token' });
  const bauen = sandbox.createBestandsschreiber;
  assert.equal(typeof bauen, 'function',
    'createBestandsschreiber fehlt in shared.js');

  const produkt  = { _id: 'p1', name: 'Äpfel', currentStock: 10, updatedAt: 'v1' };
  const anfragen = [];
  const meldungen = [];
  const fragen   = [];
  let jaSagen    = true;

  const schreiber = bauen({
    holeProdukt: () => produkt,
    zeichne:     () => {},
    melde:       (t) => meldungen.push(t),
    frage:       (t) => { fragen.push(t); return jaSagen; },
    schreibe: (id, wert, version) => {
      const a = { id, wert, version };
      anfragen.push(a);
      return antwortGeber
        ? antwortGeber(a)
        : Promise.resolve({ currentStock: wert, updatedAt: 'v' + (anfragen.length + 1) });
    },
    verzoegerung: 5
  });

  return {
    schreiber, produkt, anfragen, meldungen, fragen,
    nein: () => { jaSagen = false; }
  };
}

// ── Der Befund ────────────────────────────────────────────────────

test('drei schnelle Klicks ergeben EINE Anfrage mit dem Endwert', async () => {
  const t = aufbau();

  t.schreiber.aendern('p1', 1);
  t.schreiber.aendern('p1', 1);
  t.schreiber.aendern('p1', 1);

  // Die Anzeige springt sofort mit — der Nutzer wartet auf nichts.
  assert.equal(t.produkt.currentStock, 13, 'die Anzeige folgt dem Klick nicht sofort');

  await warte(40);
  assert.equal(t.anfragen.length, 1, `${t.anfragen.length} Anfragen statt einer`);
  assert.equal(t.anfragen[0].wert, 13);
  assert.equal(t.fragen.length, 0, 'es wurde ein Konflikt erfunden, den es nicht gab');
});

test('ein Klick während einer laufenden Anfrage benutzt danach die frische Version', async () => {
  let ersteAufloesen;
  const t = aufbau((a) => a.wert === 11
    ? new Promise(r => { ersteAufloesen = () => r({ currentStock: 11, updatedAt: 'v2' }); })
    : Promise.resolve({ currentStock: a.wert, updatedAt: 'v3' }));

  t.schreiber.aendern('p1', 1);          // 11
  await warte(20);
  assert.equal(t.anfragen.length, 1, 'die erste Anfrage läuft nicht');

  t.schreiber.aendern('p1', 1);          // 12, während die erste noch läuft
  await warte(20);
  assert.equal(t.anfragen.length, 1, 'zwei Anfragen gleichzeitig für dasselbe Produkt');

  ersteAufloesen();
  await warte(30);

  assert.equal(t.anfragen.length, 2);
  assert.equal(t.anfragen[1].wert, 12);
  assert.equal(t.anfragen[1].version, 'v2',
    'die zweite Anfrage schickt noch die alte Version — genau der Fehler von vorher');
  assert.equal(t.fragen.length, 0);
});

// ── Echte Konflikte müssen erhalten bleiben ───────────────────────

test('ein echter Konflikt fragt nach und schreibt dann mit der frischen Version', async () => {
  const t = aufbau((a) => a.version === 'v1'
    ? Promise.reject(fehler409(8, 'v9'))
    : Promise.resolve({ currentStock: a.wert, updatedAt: 'v10' }));

  t.schreiber.setzen('p1', 4);
  await warte(30);

  assert.equal(t.fragen.length, 1, 'es wurde nicht nachgefragt');
  assert.match(t.fragen[0], /8/, 'die Rückfrage nennt den aktuellen Stand nicht');

  await warte(30);
  assert.equal(t.anfragen.length, 2, 'nach dem Ja wurde nicht erneut geschrieben');
  assert.equal(t.anfragen[1].version, 'v9', 'der zweite Versuch benutzt nicht die frische Version');
  assert.equal(t.anfragen[1].wert, 4);
});

test('wer den Konflikt abbricht, überschreibt nichts', async () => {
  const t = aufbau((a) => a.version === 'v1'
    ? Promise.reject(fehler409(8, 'v9'))
    : Promise.resolve({ currentStock: a.wert, updatedAt: 'v10' }));
  t.nein();

  t.schreiber.setzen('p1', 4);
  await warte(40);

  assert.equal(t.anfragen.length, 1, 'trotz Abbruch wurde geschrieben');
  assert.equal(t.produkt.currentStock, 8, 'die Anzeige zeigt nicht den echten Stand');
});

// ── Andere Fehler ─────────────────────────────────────────────────

test('ein anderer Fehler meldet sich und nimmt die Anzeige zurück', async () => {
  const t = aufbau(() => {
    const e = new Error('Server kaputt');
    e.status = 500;
    return Promise.reject(e);
  });

  t.schreiber.aendern('p1', 5);          // Anzeige zeigt sofort 15
  await warte(40);

  assert.equal(t.meldungen.length, 1, 'der Fehler wurde nicht gemeldet');
  assert.match(t.meldungen[0], /Server kaputt/);
  assert.equal(t.produkt.currentStock, 10,
    'die Anzeige bleibt auf einem Wert stehen, den der Server nie bekommen hat');
});

test('ein Wert, der dem bestätigten Stand entspricht, erzeugt keine Anfrage', async () => {
  const t = aufbau();
  t.schreiber.aendern('p1', 1);
  t.schreiber.aendern('p1', -1);         // wieder 10
  await warte(40);
  assert.equal(t.anfragen.length, 0, 'es wurde ohne Änderung geschrieben');
});
EOF
ok "test/unit/stock-writer.test.js (6 Tests)"
node --check "$BE/test/unit/stock-writer.test.js" >/dev/null 2>&1 || die "Syntaxfehler im Testfile"

echo
echo "── Vorher: ROT erwartet ────────────────────────────────────────"
echo
( cd "$BE" && node --test --test-reporter=spec test/unit/stock-writer.test.js ) 2>&1 \
  | grep -E "^(✔|✖)|createBestandsschreiber fehlt" | head -12 || true

# ── 2 + 3  Quelltext ─────────────────────────────────────────────────
echo
echo "── Korrekturen (alles oder nichts) ─────────────────────────────"
node - "$FE" <<'NODE_SW'
const fs = require('fs'), path = require('path');
const FE = process.argv[2];
const dateien = new Map(), fehler = [], meldungen = [];
const lade = (f) => {
  if (!dateien.has(f)) dateien.set(f, { original: fs.readFileSync(f, 'utf8'), aktuell: fs.readFileSync(f, 'utf8') });
  return dateien.get(f);
};

// ── shared.js: der Schreiber ──────────────────────────────────────
{
  const f = path.join(FE, 'assets', 'shared.js');
  const e = lade(f);
  if (/createBestandsschreiber/.test(e.aktuell)) {
    meldungen.push('\x1b[90m·\x1b[0m shared.js: schon vorhanden');
  } else {
    const anker = /\n\/\/ 9\. csv_export/;
    if (!anker.test(e.aktuell)) {
      fehler.push('shared.js: der Abschnitt "// 9. csv_export" wurde nicht gefunden');
    } else {
      const block = `
// 8b. bestandsschreiber
// Schreibt Bestände gebündelt und je Produkt nacheinander.
//
// Warum: das Formular nimmt eine ABSOLUTE Zählung, und die ± Knöpfe rechnen
// sie aus dem zuletzt bekannten Stand aus. Ohne Bündelung schickten drei
// Klicks in einer Sekunde dreimal dieselbe veraltete Version mit, bekamen
// 409 und behaupteten, jemand anderes habe geschrieben — obwohl es derselbe
// Nutzer war. Jetzt gilt:
//   · die Anzeige folgt dem Klick sofort (der Nutzer wartet auf nichts)
//   · nach kurzer Ruhe geht EINE Anfrage mit dem Endwert
//   · je Produkt läuft immer nur eine Anfrage; die nächste nimmt die
//     Version, die deren Antwort zurückgegeben hat
//   · ein 409 bedeutet damit wirklich: jemand anderes war schneller
//
// Alles von außen hereingereicht, damit test/unit/stock-writer.test.js das
// ohne Browser prüfen kann.
function createBestandsschreiber({ holeProdukt, zeichne, melde, frage, schreibe, verzoegerung = 400 }) {
  const zustaende = new Map();

  function zustand(id) {
    if (!zustaende.has(id)) {
      zustaende.set(id, { ziel: null, timer: null, laeuft: false, bestaetigt: undefined });
    }
    return zustaende.get(id);
  }

  function setzen(id, wert) {
    const p = holeProdukt(id);
    if (!p) return;
    const s = zustand(id);
    // Der zuletzt vom Server bestätigte Stand — die Anzeige läuft ihm voraus.
    if (s.bestaetigt === undefined) s.bestaetigt = p.currentStock;
    p.currentStock = wert;
    s.ziel = wert;
    zeichne();
    if (s.timer) clearTimeout(s.timer);
    s.timer = setTimeout(function () { s.timer = null; abarbeiten(id); }, verzoegerung);
  }

  function aendern(id, delta) {
    const p = holeProdukt(id);
    if (!p) return;
    setzen(id, Math.max(0, Math.round(((p.currentStock || 0) + delta) * 10) / 10));
  }

  async function abarbeiten(id) {
    const s = zustand(id);
    if (s.laeuft) return;            // die laufende Schleife holt sich das Ziel selbst
    s.laeuft = true;
    try {
      while (s.ziel !== null) {
        const wert = s.ziel;
        s.ziel = null;
        const p = holeProdukt(id);
        if (!p) break;
        if (wert === s.bestaetigt) continue;

        try {
          const neu   = await schreibe(id, wert, p.updatedAt);
          const offen = s.ziel;      // in der Zwischenzeit weitergeklickt?
          Object.assign(p, neu);
          s.bestaetigt = neu.currentStock;
          if (offen !== null) p.currentStock = offen;
          zeichne();
        } catch (e) {
          if (e && e.status === 409 && e.data && e.data.code === 'STOCK_CONFLICT') {
            p.currentStock = e.data.currentStock;
            p.updatedAt    = e.data.updatedAt;
            s.bestaetigt   = e.data.currentStock;
            s.ziel = null;
            zeichne();
            const weiter = frage(
              'Jemand anderes hat den Bestand inzwischen auf ' + e.data.currentStock + ' geändert.' +
              '\\n\\nDeine Zählung war ' + wert + '.' +
              '\\n\\nTrotzdem ' + wert + ' eintragen?'
            );
            if (weiter) { p.currentStock = wert; s.ziel = wert; zeichne(); }
          } else {
            s.ziel = null;
            if (s.bestaetigt !== undefined) p.currentStock = s.bestaetigt;
            melde('⚠️ ' + ((e && e.message) || 'Fehler'));
            zeichne();
          }
        }
      }
    } finally {
      s.laeuft = false;
    }
  }

  return { setzen, aendern };
}
window.createBestandsschreiber = createBestandsschreiber;
`;
      e.aktuell = e.aktuell.replace(anker, block + '\n// 9. csv_export');
      meldungen.push('\x1b[32m✓\x1b[0m shared.js: createBestandsschreiber ergänzt');
    }
  }
}

// ── dashboard.html: setStock/adjustStock umstellen ────────────────
{
  const f = path.join(FE, 'dashboard.html');
  const e = lade(f);
  if (/bestandsschreiber/.test(e.aktuell)) {
    meldungen.push('\x1b[90m·\x1b[0m dashboard.html: schon umgestellt');
  } else {
    const L = e.aktuell.split('\n');
    const a = L.findIndex(l => /^async function setStock\(id, value\) \{/.test(l));
    const b = L.findIndex((l, i) => i > a && /^window\.adjustStock = adjustStock;/.test(l));
    if (a === -1 || b === -1) {
      fehler.push('dashboard.html: setStock/adjustStock nicht abgrenzbar');
    } else {
      const neu = [
        '// Die Schreiblogik liegt in assets/shared.js, damit sie ohne Browser',
        '// geprüft werden kann (test/unit/stock-writer.test.js). Hier bleiben',
        '// nur die beiden Namen, weil die Knöpfe sie direkt aufrufen.',
        '// Alle Abhängigkeiten werden faul gereicht: dieser Aufruf läuft beim',
        '// Laden, die Funktionen darunter gibt es zu dem Zeitpunkt vielleicht',
        '// noch nicht.',
        'const bestandsschreiber = createBestandsschreiber({',
        '  holeProdukt: (id)   => getProduct(id),',
        '  zeichne:     ()     => { renderKpis(); renderTable(); },',
        '  melde:       (text) => showToast(text, \'err\'),',
        '  frage:       (text) => confirm(text),',
        '  schreibe:    (id, wert, version) =>',
        '    api(`/api/products/${id}/stock`, \'PATCH\', { currentStock: wert, updatedAt: version })',
        '});',
        '',
        'function setStock(id, value) {',
        '  const num = parseFloat(value);',
        '  if (isNaN(num) || num < 0) { renderTable(); return; }',
        '  bestandsschreiber.setzen(id, num);',
        '}',
        'window.setStock = setStock;',
        '',
        'function adjustStock(id, delta) {',
        '  bestandsschreiber.aendern(id, delta);',
        '}',
        'window.adjustStock = adjustStock;'
      ];
      e.aktuell = [...L.slice(0, a), ...neu, ...L.slice(b + 1)].join('\n');
      meldungen.push('\x1b[32m✓\x1b[0m dashboard.html: setStock/adjustStock umgestellt');
    }
  }
}

// ── Abschlussprüfung vor dem Schreiben ────────────────────────────
function bloecke(html) {
  const out = [];
  for (const m of html.matchAll(/<script(\s[^>]*)?>([\s\S]*?)<\/script>/gi)) {
    const attr = m[1] || '';
    if (/\bsrc\s*=/.test(attr) || /type\s*=\s*["']module["']/i.test(attr)) continue;
    out.push(m[2]);
  }
  return out;
}
const parst = (c) => { try { new Function(c); return true; } catch { return false; } };
for (const [f, e] of dateien) {
  if (e.aktuell === e.original) continue;
  if (f.endsWith('.js')) {
    if (!parst(e.aktuell)) fehler.push(path.basename(f) + ': nach der Änderung nicht mehr gültig');
  } else {
    const v = bloecke(e.original), n = bloecke(e.aktuell);
    n.forEach((b, i) => {
      if (v[i] !== undefined && parst(v[i]) && !parst(b)) {
        fehler.push(path.basename(f) + `: Skriptblock ${i + 1} ist nach der Änderung nicht mehr gültig`);
      }
    });
  }
}

if (fehler.length) {
  console.log('\n  \x1b[31mEs wurde NICHTS geändert:\x1b[0m');
  fehler.forEach(x => console.log('  \x1b[31m✗\x1b[0m ' + x));
  console.log('');
  process.exit(1);
}
meldungen.forEach(m => console.log('  ' + m));
for (const [f, e] of dateien) {
  if (e.aktuell === e.original) continue;
  if (!fs.existsSync(f + '.sw.bak')) fs.writeFileSync(f + '.sw.bak', e.original);
  fs.writeFileSync(f, e.aktuell);
}
NODE_SW

node --check "$FE/assets/shared.js" >/dev/null 2>&1 || die "Syntaxfehler in shared.js — rückgängig mit: git checkout ."
ok "shared.js syntaktisch gültig"
( cd "$BE" && npm run lint ) >/dev/null 2>&1 && ok "Lint sauber" \
  || { ( cd "$BE" && npm run lint ) 2>&1 | grep -v '^>' ; die "Lint meldet etwas — siehe oben"; }

# ── 4  Grün ──────────────────────────────────────────────────────────
lauf() {
  local aus
  aus=$( cd "$BE" && npm run "$1" 2>&1 || true )
  printf '%s\n' "$aus" | grep -E "^(ℹ|#) (tests|pass|fail) " | sed "s/^/    [$1] /" >&2 || true
  printf '%s\n' "$aus" | grep -E "^(ℹ|#) fail " | awk '{print $3}' | tail -1 || true
}

echo
echo "── Nachher: GRÜN erwartet ──────────────────────────────────────"
echo
( cd "$BE" && node --test --test-reporter=spec test/unit/stock-writer.test.js ) 2>&1 \
  | grep -vE "^\s+(at |actual:|expected:|operator:|code:|generatedMessage:|diff:|\})" | head -25 || true
echo
U=$(lauf test:unit); I=$(lauf test:integration)
echo "  Unit: fail=${U:-?}   Integration: fail=${I:-?}"
[ "${U:-1}" = "0" ] && [ "${I:-1}" = "0" ] || die "Nicht alles grün — bitte die Ausgabe oben schicken. Rückgängig: git checkout ."
ok "alles grün"

echo
echo "── Danach ──────────────────────────────────────────────────────"
echo
echo "  Erwartet: 72 Unit- und 85 Integrationstests grün."
echo
echo "  Im Browser (App in Fenster 1 neu starten, Tunnel bleibt, Strg+F5):"
echo "   1. dreimal schnell auf +  ->  Zahl springt sofort auf +3,"
echo "      danach EINE Anfrage, keine Rückfrage"
echo "   2. Netzwerk-Tab: nur ein PATCH statt drei"
echo "   3. zwei Tabs: in A auf 8 setzen, in B ohne Neuladen auf 4"
echo "      ->  die Rückfrage erscheint und nennt 8 (echter Konflikt)"
echo "   4. eine Zahl direkt ins Feld tippen und das Feld verlassen"
echo
echo "    git mv apply-stockwriter.sh tools/"
echo "    git add -A && git commit -m 'Bestandsänderungen bündeln statt Konflikte erfinden'"
echo "    git push"
echo
echo "  Rückgängig:  git checkout . && git clean -fd"
echo
