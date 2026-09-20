#!/usr/bin/env bash
#
# apply-e4.sh — Phase E, Schritt 1: Aufräumen und Lint erzwingen
#
#   E4.1  app.js: die beiden ungenutzten require-Zeilen aus dem B0-Split
#   E4.2  app.js: dotenv wird nur noch einmal geladen
#   E4.3  app.js: die wirkungslose eslint-disable-Anweisung wird durch einen
#                 Kommentar ersetzt, der die eigentliche Absicht festhält
#   E4.4  middleware/auth.js: der verschluckte Fehler wird protokolliert
#   E4.5  test/helpers/http.js: kein Rückgabewert im Promise-Executor
#   E4.6  package.json: engines auf das, was Mongoose 9 wirklich braucht
#   E4.7  Altlasten: .bak-Dateien entfernen, apply-*.sh nach tools/
#   E4.8  Lint in der CI erzwingen — aber nur, wenn oben alles sauber ist
#
# Ausführen im Wurzelverzeichnis des Repos:
#     bash apply-e4.sh
#
set -euo pipefail

BE="Edeka.lager/backend"
EL="Edeka.lager"
SELBST="$(basename "$0")"
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
skip() { printf '  \033[90m·\033[0m %s\n' "$1"; }
die()  { printf '\n  \033[31m✗ %s\033[0m\n\n' "$1" >&2; exit 1; }

echo
echo "── Phase E, Schritt 1: Aufräumen ───────────────────────────────"
echo

[ -f "$BE/app.js" ]             || die "'$BE/app.js' nicht gefunden — bist du auf der richtigen Branch?"
[ -f "$BE/middleware/auth.js" ] || die "'$BE/middleware/auth.js' nicht gefunden."
[ -f "$EL/eslint.config.js" ]   || die "eslint.config.js fehlt. Bitte zuerst apply-eslint.sh ausführen."

if command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
  BRANCH=$(git rev-parse --abbrev-ref HEAD)
  [ "$BRANCH" != "main" ] || die "Du bist auf main. Bitte auf phase-e wechseln."
  [ -z "$(git status --porcelain)" ] || die "Arbeitsverzeichnis nicht sauber. Bitte erst committen."
  ok "Branch '$BRANCH', Arbeitsverzeichnis sauber"
fi

echo
echo "── Quelltext (alles oder nichts) ───────────────────────────────"

node - "$BE" <<'NODE_E4'
const fs   = require('fs');
const path = require('path');
const BE   = process.argv[2];
const P    = (...p) => path.join(BE, ...p);

const plan = [], fehler = [], dateien = new Map();

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
  const i = lines.findIndex(l => muster.test(l));
  if (i === -1) return '      (keine ähnliche Zeile gefunden)';
  return lines.slice(Math.max(0, i - 2), i + zeilen)
              .map((l, k) => `      ${i - 1 + k}| ${l}`).join('\n');
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

// ── E4.1  ungenutzte require-Zeilen ───────────────────────────────
patch({
  name: 'E4.1  app.js: ungenutztes require von mongoose entfernt',
  datei: 'app.js',
  schonDa: /^(?![\s\S]*const mongoose = require\('mongoose'\);)/,
  suche: /^const mongoose\s*=\s*require\('mongoose'\);\r?\n/m,
  ersetze: '',
  hinweis: "Die mongoose-require-Zeile in app.js wurde nicht gefunden.",
  naehe: /mongoose/
});

patch({
  name: 'E4.1  app.js: ungenutztes require von scheduleDailyClose entfernt',
  datei: 'app.js',
  schonDa: /^(?![\s\S]*const \{ scheduleDailyClose \} = require\('\.\/services\/dailyClose'\);)/,
  suche: /^const \{ scheduleDailyClose \} = require\('\.\/services\/dailyClose'\);\r?\n/m,
  ersetze: '',
  hinweis: "Die dailyClose-require-Zeile in app.js wurde nicht gefunden.",
  naehe: /dailyClose/
});

// ── E4.2  dotenv nur noch einmal ──────────────────────────────────
// server.js lädt dotenv, BEVOR es ./app verlangt — app.js sieht die
// Variablen also ohnehin. Die Tests setzen ihre Werte selbst in
// test/helpers/env.js, ebenfalls vor dem require. Der zweite Aufruf war
// nur Lärm ("injected env (2)" gefolgt von "injected env (0)").
patch({
  name: 'E4.2  app.js: doppeltes Laden von dotenv entfernt',
  datei: 'app.js',
  schonDa: /^(?![\s\S]*require\('dotenv'\)\.config\(\);)/,
  suche: /^require\('dotenv'\)\.config\(\);\r?\n/m,
  ersetze:
    "// dotenv wird bewusst NICHT hier geladen: server.js tut das, bevor es\n" +
    "// diese Datei verlangt, und die Tests setzen ihre Werte in\n" +
    "// test/helpers/env.js. Ein zweiter Aufruf änderte nichts und erzeugte\n" +
    "// nur eine zweite Meldung beim Start.\n",
  hinweis: "Die dotenv-Zeile in app.js wurde nicht gefunden.",
  naehe: /dotenv/
});

// ── E4.3  wirkungslose eslint-disable-Anweisung ───────────────────
// Sie stand über dem globalen Fehler-Handler wegen des ungenutzten
// Parameters next. Mit args:'none' in der ESLint-Konfiguration ist sie
// wirkungslos — aber einfach zu löschen wäre ein Verlust: Express erkennt
// einen Fehler-Handler an der ANZAHL seiner Parameter. Fällt next weg,
// ist es kein Fehler-Handler mehr und Fehler laufen stumm ins Leere.
// Der Zaun bleibt also, nur das Werkzeug wechselt.
patch({
  name: 'E4.3  app.js: eslint-disable durch erklärenden Kommentar ersetzt',
  datei: 'app.js',
  schonDa: /Express erkennt einen Fehler-Handler/,
  suche: /^\s*\/\/\s*eslint-disable-next-line\s+no-unused-vars\s*\r?\n/m,
  ersetze:
    "// Der Parameter next wird hier nicht benutzt, MUSS aber stehen bleiben:\n" +
    "// Express erkennt einen Fehler-Handler an der Anzahl seiner Parameter.\n" +
    "// Ohne den vierten Parameter ist das hier eine ganz normale Middleware\n" +
    "// und Fehler laufen stumm daran vorbei.\n",
  hinweis: "Keine eslint-disable-next-line-Zeile in app.js gefunden.",
  naehe: /eslint-disable/
});

// ── E4.4  verschluckter Fehler in der Token-Prüfung ───────────────
// Die bekannten Fälle (abgelaufen, ungültig) werden weiter oben einzeln
// behandelt. Was hier ankommt, ist also unerwartet: ein Fehler in der
// Bibliothek, eine Datenbank, die während findById wegbricht, ein Bug.
// Der Benutzer bekam einen allgemeinen 401 und nirgends blieb eine Spur.
patch({
  name: 'E4.4  middleware/auth.js: unerwarteter Fehler wird protokolliert',
  datei: 'middleware/auth.js',
  schonDa: /\[AUTH\]/,
  suche: /\} catch \(err\) \{\r?\n(\s*)return res\.status\(401\)\.json\(\{ message: 'Authentifizierung fehlgeschlagen' \}\);/,
  ersetze: (_t, einzug) => [
    '} catch (err) {',
    einzug + '// Hier landen nur unerwartete Fehler — abgelaufene und ungültige',
    einzug + '// Token werden oben einzeln behandelt. Ohne diese Zeile blieb von',
    einzug + '// einem echten Defekt nirgends eine Spur, der Benutzer sah nur 401.',
    einzug + "console.error('[AUTH] Unerwarteter Fehler bei der Token-Prüfung:', err.message);",
    einzug + "return res.status(401).json({ message: 'Authentifizierung fehlgeschlagen' });"
  ].join('\n'),
  hinweis: 'Der catch-Block in middleware/auth.js sieht anders aus als erwartet.',
  naehe: /Authentifizierung fehlgeschlagen/
});

// ── E4.5  Rückgabewert im Promise-Executor ────────────────────────
// server.close(res) gibt den Server zurück, die Pfeilfunktion reicht ihn
// weiter. Hier harmlos, aber es ist genau das Muster, das einen Fehler
// verdeckt, sobald jemand resolve mit einem Wert verwechselt.
patch({
  name: 'E4.5  test/helpers/http.js: Promise-Executor gibt nichts mehr zurück',
  datei: 'test/helpers/http.js',
  schonDa: /server\.close\(res\);\s*\}\)/,
  suche: /await new Promise\(res => server\.close\(res\)\);/,
  ersetze: 'await new Promise(res => { server.close(res); });',
  hinweis: 'Die close-Zeile in test/helpers/http.js wurde nicht gefunden.',
  naehe: /server\.close/
});

// ── Bericht ───────────────────────────────────────────────────────
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
for (const [datei, e] of dateien) {
  if (e.aktuell === e.original) continue;
  const f = P(...datei.split('/'));
  if (!fs.existsSync(f + '.e4.bak')) fs.writeFileSync(f + '.e4.bak', e.original);
  fs.writeFileSync(f, e.aktuell);
  console.log(`  \x1b[90m→\x1b[0m geschrieben: ${datei}`);
}
NODE_E4

# ── E4.6  engines ────────────────────────────────────────────────────
echo
echo "── package.json ────────────────────────────────────────────────"
node - "$BE" <<'NODE_ENG'
const fs = require('fs');
const p = process.argv[2] + '/package.json';
const pkg = JSON.parse(fs.readFileSync(p, 'utf8'));
const soll = '>=20.19.0';
// Mongoose 9 und der mongodb-Treiber verlangen mindestens 20.19. Die alte
// Angabe >=18 versprach etwas, das nicht mehr stimmt.
if (pkg.engines && pkg.engines.node === soll) {
  console.log('  \x1b[90m·\x1b[0m engines schon korrekt');
} else {
  const alt = pkg.engines ? pkg.engines.node : '(keine Angabe)';
  pkg.engines = Object.assign({}, pkg.engines, { node: soll });
  fs.writeFileSync(p, JSON.stringify(pkg, null, 2) + '\n');
  console.log(`  \x1b[32m✓\x1b[0m engines.node: ${alt} -> ${soll}`);
}
NODE_ENG

# ── E4.7  Altlasten ──────────────────────────────────────────────────
echo
echo "── Altlasten ───────────────────────────────────────────────────"

ANZ_BAK=$(find "$EL" -name '*.bak' -type f 2>/dev/null | wc -l)
if [ "$ANZ_BAK" -gt 0 ]; then
  # Acht dieser Dateien sind versehentlich in main gelandet: sie wurden
  # committet, bevor *.bak in .gitignore stand — und .gitignore entfernt
  # nichts, was schon verfolgt wird. Jede frühere Fassung steht in der
  # Git-Historie, hier geht also nichts verloren.
  find "$EL" -name '*.bak' -type f -print0 | while IFS= read -r -d '' f; do
    if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
      git rm -q -f "$f"
    else
      rm -f "$f"
    fi
  done
  ok "$ANZ_BAK .bak-Datei(en) entfernt"
else
  skip "keine .bak-Dateien vorhanden"
fi

mkdir -p tools
ANZ_MV=0
for f in apply-*.sh; do
  [ -e "$f" ] || continue
  # Das laufende Skript nicht verschieben: bash liest es stückweise ein.
  [ "$f" = "$SELBST" ] && continue
  if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
    git mv "$f" "tools/$f"
  else
    mv "$f" "tools/$f"
  fi
  ANZ_MV=$((ANZ_MV + 1))
done
[ "$ANZ_MV" -gt 0 ] && ok "$ANZ_MV Skript(e) nach tools/ verschoben" || skip "nichts zu verschieben"

cat > tools/README.md <<'EOF'
# tools/

Die selbstanwendenden Skripte aus der Review- und Bugfix-Runde, in der
Reihenfolge ihrer Entstehung.

| Skript | Zweck |
| --- | --- |
| `apply-batch-b.sh` | Testfundament: app.js/server.js-Split, Testrunner, erste Suites |
| `apply-batch-a.sh` | Sicherheits- und Validierungsfixes |
| `apply-batch-a2.sh` | Nachtrag: Datumsprüfung in /export |
| `apply-c1-tests.sh`, `apply-c1-tests-fix.sh` | Beweise für den Tagesabschluss |
| `apply-c1-fixes.sh`, `apply-c1-hotfix.sh` | Idempotenter Abschluss, atomare Basislinie |
| `apply-c2-tests.sh`, `apply-c2-fixes.sh`, `apply-c2-history.sh` | Auswertungen |
| `apply-c3-tests.sh`, `apply-c3-fixes-v2.sh` | Frontend-Befunde |
| `apply-test-isolation.sh` | Eine Testdatenbank je Datei |
| `apply-eslint.sh` | Statische Prüfung |

Sie sind hier als Dokumentation des Wegs abgelegt, nicht zur erneuten
Ausführung: jedes hat seine Änderungen bereits angewendet und prüft das
beim Start selbst. `apply-c3-fixes.sh` in Version 1 lag daneben — die
gültige Fassung ist `apply-c3-fixes-v2.sh`.
EOF
ok "tools/README.md"

# ── Selbstprüfung ────────────────────────────────────────────────────
echo
echo "── Selbstprüfung ───────────────────────────────────────────────"
for f in "$BE/app.js" "$BE/middleware/auth.js" "$BE/test/helpers/http.js"; do
  node --check "$f" >/dev/null 2>&1 || die "Syntaxfehler in $f — rückgängig mit: git checkout ."
done
ok "syntaktisch gültig"

grep -q "eslint-disable" "$BE/app.js" && die "es steht noch eine eslint-disable-Zeile in app.js" \
  || ok "keine wirkungslose eslint-disable-Anweisung mehr"

echo
echo "── Lint ────────────────────────────────────────────────────────"
echo
LINT_OK=0
( cd "$BE" && npm run lint ) 2>&1 | grep -v "^> " || true
if ( cd "$BE" && npm run lint ) >/dev/null 2>&1; then LINT_OK=1; fi

# ── E4.8  Lint in der CI — nur bei sauberem Befund ───────────────────
echo
echo "── CI ──────────────────────────────────────────────────────────"
if [ "$LINT_OK" -ne 1 ]; then
  skip "Lint ist noch nicht sauber — die CI-Stufe wird NICHT eingetragen"
  echo "     Erst den Befund oben schließen, dann erzwingen."
elif grep -q "npm run lint" .github/workflows/ci.yml 2>/dev/null; then
  skip "Lint-Stufe schon in der CI"
else
  node - <<'NODE_CI'
const fs = require('fs');
const p = '.github/workflows/ci.yml';
const t = fs.readFileSync(p, 'utf8');
const anker = /(\n(\s*)- name: Unit-Tests)/;
if (!anker.test(t)) {
  console.log('  \x1b[31m✗\x1b[0m Anker "- name: Unit-Tests" nicht gefunden — nichts geändert');
  process.exit(1);
}
fs.writeFileSync(p, t.replace(anker, (_m, treffer, einzug) =>
  `\n${einzug}- name: Lint\n${einzug}  run: npm run lint\n` + treffer));
console.log('  \x1b[32m✓\x1b[0m Lint-Stufe vor den Tests eingetragen');
NODE_CI
fi

# ── Was bewusst offen bleibt ─────────────────────────────────────────
echo
echo "── Noch offen: Dokumentation ───────────────────────────────────"
echo
echo "  Diese beiden Dateien widersprechen sich, werden hier aber NICHT"
echo "  geändert — ihr Inhalt ist mir nicht bekannt, und blind zu patchen"
echo "  war schon einmal ein Fehler. Hier ist, was drinsteht:"
echo
for f in "$BE/README.md" "$BE/.env.example"; do
  if [ -f "$f" ]; then
    echo "  ── $f ──"
    sed -n '1,40p' "$f" | sed 's/^/    /'
    echo
  else
    echo "  ($f existiert nicht)"
  fi
done

echo
echo "── Tests ───────────────────────────────────────────────────────"
echo
( cd "$BE" && npm run test:unit ) 2>&1 | tail -8 || true
echo
( cd "$BE" && npm run test:integration ) 2>&1 | tail -8 || true

echo
echo "── Danach ──────────────────────────────────────────────────────"
echo
echo "  Erwartet: Lint sauber, 65 Unit- und 57 Integrationstests grün."
echo
echo "  Dieses Skript hat sich selbst nicht nach tools/ verschoben —"
echo "  bash liest ein laufendes Skript stückweise ein. Von Hand:"
echo
echo "    git mv $SELBST tools/"
echo "    git add -A && git commit -m 'E4: Aufräumen, Lint in der CI'"
echo "    git push -u origin \$(git rev-parse --abbrev-ref HEAD)"
echo
echo "  Rückgängig:  git checkout . && git clean -fd"
echo
