#!/usr/bin/env bash
#
# apply-csp-emoji.sh — Weg C: Knöpfe jetzt bedienbar, sauber in Phase F
#
#   1. Zwei Tests schreiben und ROT zeigen
#   2. app.js: script-src-attr vorübergehend erlauben
#   3. Frontend: jede emoji-Einfügung durch escapeHtml
#   4. Dieselben Tests GRÜN zeigen, dann die ganze Suite
#
# Warum Rot und Grün in EINEM Lauf: Der Befund ist bereits bewiesen, und
# zwar von der stärksten Stelle — der Konsole des Browsers:
#   "Executing inline event handler violates … 'script-src-attr 'none''"
# Die Reihenfolge Rot-vor-Grün bleibt trotzdem erhalten und sichtbar.
#
# Ausführen im Wurzelverzeichnis des Repos:
#     bash apply-csp-emoji.sh
#
set -euo pipefail

BE="Edeka.lager/backend"
FE="Edeka.lager/frontend"
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
skip() { printf '  \033[90m·\033[0m %s\n' "$1"; }
die()  { printf '\n  \033[31m✗ %s\033[0m\n\n' "$1" >&2; exit 1; }

echo
echo "── Weg C: Knöpfe bedienbar, emoji sicher ───────────────────────"
echo

[ -f "$BE/app.js" ]             || die "'$BE/app.js' nicht gefunden."
[ -f "$FE/dashboard.html" ]     || die "'$FE/dashboard.html' nicht gefunden."
[ -f "$BE/test/helpers/http.js" ] || die "Test-Harness fehlt."

if command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
  BRANCH=$(git rev-parse --abbrev-ref HEAD)
  [ "$BRANCH" != "main" ] || die "Du bist auf main. Bitte auf phase-e wechseln."
  [ -z "$(git status --porcelain)" ] || die "Arbeitsverzeichnis nicht sauber. Bitte erst committen."
  ok "Branch '$BRANCH', Arbeitsverzeichnis sauber"
fi

# ── 1  Tests ─────────────────────────────────────────────────────────
echo
echo "── Tests schreiben ─────────────────────────────────────────────"
mkdir -p "$BE/test/unit" "$BE/test/integration"

cat > "$BE/test/unit/frontend-escaping.test.js" <<'EOF'
'use strict';
//
// Jede Einfügung eines emoji-Werts in HTML muss durch escapeHtml laufen.
//
// emoji war das einzige vom Benutzer gesetzte Feld, das im Frontend
// ungeschützt ins HTML ging — Name und Einheit direkt daneben wurden
// maskiert. In Batch A wurde nur die Telegram-Hälfte geschlossen.
//
// Das ist eine Prüfung am Quelltext, kein Verhaltenstest: die Inline-
// Skripte in den HTML-Dateien lassen sich im Harness noch nicht laden.
// Das ändert sich mit Phase F.
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const fs     = require('node:fs');
const path   = require('node:path');

const FE = path.join(__dirname, '../../../frontend');

function dateien(dir) {
  const out = [];
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) out.push(...dateien(p));
    else if (/\.(html|js)$/.test(e.name) && e.name !== 'chart.umd.min.js') out.push(p);
  }
  return out;
}

test('jede emoji-Einfügung in HTML läuft durch escapeHtml', () => {
  const offen = [];
  for (const f of dateien(FE)) {
    fs.readFileSync(f, 'utf8').split('\n').forEach((zeile, i) => {
      for (const m of zeile.matchAll(/\$\{([^{}]*emoji[^{}]*)\}/gi)) {
        if (!m[1].trim().startsWith('escapeHtml(')) {
          offen.push(`${path.relative(FE, f)}:${i + 1}  \${${m[1].trim()}}`);
        }
      }
    });
  }
  assert.deepEqual(offen, [],
    `${offen.length} emoji-Einfügung(en) ohne escapeHtml:\n    ` + offen.join('\n    '));
});
EOF
ok "test/unit/frontend-escaping.test.js"

cat > "$BE/test/integration/csp-markup.test.js" <<'EOF'
'use strict';
//
// CSP und Markup müssen zueinander passen.
//
// Dieser Test prüft keinen Zustand, sondern eine GLEICHUNG:
//   Inline-Handler im Frontend vorhanden  <=>  CSP erlaubt sie
//
// Stimmt die linke Seite und die rechte nicht, sind alle Knöpfe tot —
// genau so war es von Anfang an: helmet setzt script-src-attr 'none', das
// Frontend baut seine Knöpfe mit onclick="…". Aufgefallen ist es erst beim
// ersten echten Klick im Browser.
//
// Stimmt die rechte Seite und die linke nicht mehr, ist Phase F fertig
// (alle Handler über addEventListener) — dann erzwingt dieser Test, dass
// die vorübergehende Lockerung wieder zurückgenommen wird.
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const fs     = require('node:fs');
const path   = require('node:path');
const { start, stop, req } = require('../helpers/http');

const FE = path.join(__dirname, '../../../frontend');

test.before(async () => { await start(); });
test.after (async () => { await stop(); });

function inlineHandler(dir = FE) {
  const treffer = [];
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) { treffer.push(...inlineHandler(p)); continue; }
    if (!/\.(html|js)$/.test(e.name) || e.name === 'chart.umd.min.js') continue;
    fs.readFileSync(p, 'utf8').split('\n').forEach((zeile, i) => {
      // on…=" bzw. on…=' — also Attribute, nicht el.onclick = () => …
      for (const m of zeile.matchAll(/\s(on[a-z]+)\s*=\s*["']/gi)) {
        treffer.push(`${path.relative(FE, p)}:${i + 1} ${m[1]}`);
      }
    });
  }
  return treffer;
}

// Erlaubt die CSP Inline-Handler? Fehlt script-src-attr, gilt script-src,
// danach default-src — genau wie im Browser.
function handlerErlaubt(csp) {
  const d = {};
  for (const teil of csp.split(';').map(s => s.trim()).filter(Boolean)) {
    const [name, ...werte] = teil.split(/\s+/);
    d[name.toLowerCase()] = werte;
  }
  const massgeblich = d['script-src-attr'] || d['script-src'] || d['default-src'] || [];
  return massgeblich.includes("'unsafe-inline'");
}

test('CSP und Markup passen zusammen', async () => {
  const handler = inlineHandler();
  const r = await req('/index.html');
  const csp = r.headers.get('content-security-policy');
  assert.ok(csp, 'kein Content-Security-Policy-Header');

  const erlaubt = handlerErlaubt(csp);

  if (handler.length > 0) {
    assert.ok(erlaubt,
      `${handler.length} Inline-Handler im Frontend (etwa ${handler.slice(0, 3).join(', ')}), ` +
      `aber die CSP verbietet sie — jeder dieser Knöpfe ist tot.`);
  } else {
    assert.ok(!erlaubt,
      "Es gibt keine Inline-Handler mehr — Phase F ist fertig. Dann muss die " +
      "vorübergehende Zeile scriptSrcAttr in app.js wieder raus.");
  }
});
EOF
ok "test/integration/csp-markup.test.js"

for f in "$BE/test/unit/frontend-escaping.test.js" "$BE/test/integration/csp-markup.test.js"; do
  node --check "$f" >/dev/null 2>&1 || die "Syntaxfehler in $f"
done

# ── 2  ROT zeigen ────────────────────────────────────────────────────
echo
echo "── Vorher: ROT erwartet ────────────────────────────────────────"
echo
( cd "$BE" && node --test --test-reporter=spec test/unit/frontend-escaping.test.js test/integration/csp-markup.test.js ) 2>&1 \
  | grep -E "^(✔|✖)|Inline-Handler|emoji-Einfügung|^\s+[a-z].*\.(html|js):[0-9]+" | head -30 || true

# ── 3  Korrekturen (alles oder nichts) ───────────────────────────────
echo
echo "── Korrekturen (alles oder nichts) ─────────────────────────────"
node - "$BE" "$FE" <<'NODE_FIX'
const fs = require('fs'), path = require('path');
const BE = process.argv[2], FE = process.argv[3];
const dateien = new Map(), fehler = [], meldungen = [];

function lade(f) {
  if (!dateien.has(f)) { const t = fs.readFileSync(f, 'utf8'); dateien.set(f, { original: t, aktuell: t }); }
  return dateien.get(f);
}

// ── app.js: script-src-attr vorübergehend öffnen ──────────────────
{
  const e = lade(path.join(BE, 'app.js'));
  if (/scriptSrcAttr/.test(e.aktuell)) {
    meldungen.push('\x1b[90m·\x1b[0m app.js: scriptSrcAttr schon vorhanden');
  } else {
    const anker = /(\n([ \t]*)scriptSrc:\s*\["'self'",\s*"'unsafe-inline'"\],)/;
    if (!anker.test(e.aktuell)) {
      fehler.push("app.js: die Zeile scriptSrc: [\"'self'\", \"'unsafe-inline'\"], wurde nicht gefunden");
    } else {
      e.aktuell = e.aktuell.replace(anker, (_m, zeile, ein) => zeile + [
        '',
        ein + '// VORÜBERGEHEND bis Phase F.',
        ein + '// helmet setzt von sich aus script-src-attr \'none\' und verbietet damit',
        ein + '// jedes onclick="…" im Markup — obwohl scriptSrc oben \'unsafe-inline\'',
        ein + '// erlaubt: für Attribute hat script-src-attr Vorrang. Das Frontend baut',
        ein + '// fast alle Knöpfe mit solchen Attributen; ohne diese Zeile war keiner',
        ein + '// davon je bedienbar.',
        ein + '//',
        ein + '// Der Preis: Inline-Handler sind wieder ein möglicher XSS-Weg. Deshalb',
        ein + '// läuft jede emoji-Einfügung jetzt durch escapeHtml. In Phase F werden',
        ein + '// die Handler durch addEventListener ersetzt und diese Zeile entfernt;',
        ein + '// test/integration/csp-markup.test.js erzwingt das dann von selbst.',
        ein + 'scriptSrcAttr: ["\'unsafe-inline\'"],'
      ].join('\n'));
      meldungen.push('\x1b[32m✓\x1b[0m app.js: script-src-attr vorübergehend erlaubt');
    }
  }
}

// ── Frontend: jede emoji-Einfügung durch escapeHtml ───────────────
function frontendDateien(dir) {
  const out = [];
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) out.push(...frontendDateien(p));
    else if (/\.(html|js)$/.test(e.name) && e.name !== 'chart.umd.min.js') out.push(p);
  }
  return out;
}
// Nur die bekannte, eindeutige Form: ${objekt.emoji} oder ${objekt.emoji || '…'}.
// Alles andere bleibt unangetastet — und fällt dann in der Prüfung unten auf.
const EMOJI = /\$\{\s*((?:[A-Za-z_$][\w$]*\.)+emoji(?:\s*\|\|\s*(['"])[^'"]*\2)?)\s*\}/g;
let gesamt = 0;
for (const f of frontendDateien(FE)) {
  const e = lade(f);
  let n = 0;
  e.aktuell = e.aktuell.replace(EMOJI, (_m, ausdruck) => { n++; return '${escapeHtml(' + ausdruck + ')}'; });
  if (n) { gesamt += n; meldungen.push(`\x1b[32m✓\x1b[0m ${path.relative(FE, f)}: ${n} emoji-Einfügung(en) maskiert`); }
}
if (gesamt === 0) meldungen.push('\x1b[90m·\x1b[0m keine unmaskierte emoji-Einfügung (mehr) gefunden');

// ── Abschlussprüfung, noch vor dem Schreiben ──────────────────────
// Dieselbe Erkennung wie im Test: bleibt nach der Ersetzung etwas übrig,
// hatte es eine Form, die das Muster oben nicht kennt. Dann wird NICHTS
// geschrieben — besser anhalten als halb geschützt.
const rest = [];
for (const [f, e] of dateien) {
  if (!f.startsWith(FE)) continue;
  e.aktuell.split('\n').forEach((zeile, i) => {
    for (const m of zeile.matchAll(/\$\{([^{}]*emoji[^{}]*)\}/gi)) {
      if (!m[1].trim().startsWith('escapeHtml(')) rest.push(`${path.relative(FE, f)}:${i + 1}  \${${m[1].trim()}}`);
    }
  });
}
if (rest.length) fehler.push('emoji-Einfügungen in unbekannter Form, bitte schicken:\n       ' + rest.join('\n       '));

if (fehler.length) {
  console.log('\n  \x1b[31mEs wurde NICHTS geändert:\x1b[0m');
  fehler.forEach(f => console.log('  \x1b[31m✗\x1b[0m ' + f));
  console.log('');
  process.exit(1);
}
meldungen.forEach(m => console.log('  ' + m));
for (const [f, e] of dateien) {
  if (e.aktuell === e.original) continue;
  if (!fs.existsSync(f + '.csp.bak')) fs.writeFileSync(f + '.csp.bak', e.original);
  fs.writeFileSync(f, e.aktuell);
}
NODE_FIX

node --check "$BE/app.js" >/dev/null 2>&1 || die "Syntaxfehler in app.js — rückgängig mit: git checkout ."
( cd "$BE" && npm run lint ) >/dev/null 2>&1 && ok "Lint sauber" \
  || { ( cd "$BE" && npm run lint ) 2>&1 | grep -v '^>' ; die "Lint meldet etwas — siehe oben"; }

# ── 4  GRÜN zeigen, dann alles ───────────────────────────────────────
# Versteht beide Ausgabeformate des Node-Testrunners: "ℹ fail 0" (spec) und
# "# fail 0" (TAP). Welches kommt, hängt von der Node-Version ab und davon,
# ob die Ausgabe in eine Pipe geht. Nur eines zu kennen hieß: bei gleichem
# Ergebnis mal "grün", mal ein falscher Alarm — und ein Alarm, der grundlos
# losgeht, bringt einem bei, Alarme zu übergehen.
lauf() {
  local aus
  aus=$( cd "$BE" && npm run "$1" 2>&1 || true )
  printf '%s\n' "$aus" | grep -E "^(ℹ|#) (tests|pass|fail) " | sed "s/^/    [$1] /" >&2 || true
  printf '%s\n' "$aus" | grep -E "^(ℹ|#) fail " | awk '{print $3}' | tail -1 || true
}

echo
echo "── Nachher: GRÜN erwartet ──────────────────────────────────────"
echo
( cd "$BE" && node --test --test-reporter=spec test/unit/frontend-escaping.test.js test/integration/csp-markup.test.js ) 2>&1 \
  | grep -E "^(✔|✖)" || true
echo
U=$(lauf test:unit); I=$(lauf test:integration)
echo "  Unit: fail=${U:-?}   Integration: fail=${I:-?}"
[ "${U:-1}" = "0" ] && [ "${I:-1}" = "0" ] || die "Nicht alles grün — bitte die Ausgabe oben schicken. Rückgängig: git checkout ."
ok "alles grün"

echo
echo "── Danach ──────────────────────────────────────────────────────"
echo
echo "  Erwartet: 66 Unit- und 85 Integrationstests grün."
echo
echo "  Im Browser wirksam machen:"
echo "   1. Fenster 1: Ctrl+C, dann erneut:  NODE_ENV=production npm start"
echo "   2. Fenster 2 (Tunnel) NICHT anfassen — die Adresse bleibt dieselbe"
echo "   3. Im Browser Strg+F5 (neu laden ohne Zwischenspeicher)"
echo "   4. F12 → Console: die Zeilen mit 'script-src-attr' dürfen nicht mehr"
echo "      erscheinen. Die Permissions-Policy-Hinweise kommen von Cloudflare"
echo "      und sind harmlos."
echo
echo "    git mv apply-csp-emoji.sh tools/"
echo "    git add -A && git commit -m 'Knöpfe bedienbar (script-src-attr bis Phase F), emoji maskiert'"
echo "    git push"
echo
echo "  Rückgängig:  git checkout . && git clean -fd"
echo
