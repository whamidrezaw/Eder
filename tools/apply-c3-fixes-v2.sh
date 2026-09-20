#!/usr/bin/env bash
#
# apply-c3-fixes.sh — Batch C3, Schritt 2: die Korrekturen
#
#   C3.1  routes/auth.js   die 401er wegen falscher Zugangsdaten bekommen
#                          code: 'BAD_CREDENTIALS'
#   C3.2  shared.js  api() meldet nur noch bei einem 401 OHNE diese
#                          Kennzeichnung ab
#   C3.3  shared.js  logout() behält die Anzeige-Einstellungen
#   C3.4  shared.js  escapeHtml() verschluckt die 0 nicht mehr
#   +     zwei Integrationstests für die Kennzeichnung
#
# Warum die Kennzeichnung auf der Zugangsdaten-Seite sitzt und nicht auf der
# Sitzungs-Seite: Ein 401 ohne Kennzeichen führt weiterhin zum Abmelden.
# Vergisst jemand später eine Kennzeichnung, ist das schlimmste Ergebnis das
# heutige Verhalten — der Fehler fällt also auf die sichere Seite.
#
# Ausführen im Wurzelverzeichnis des Repos:
#     bash apply-c3-fixes.sh
#
set -euo pipefail

BE="Edeka.lager/backend"
FE="Edeka.lager/frontend"
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
skip() { printf '  \033[90m·\033[0m %s\n' "$1"; }
die()  { printf '\n  \033[31m✗ %s\033[0m\n\n' "$1" >&2; exit 1; }

echo
echo "── Batch C3, Schritt 2: Korrekturen ────────────────────────────"
echo

[ -f "$FE/assets/shared.js" ] || die "'$FE/assets/shared.js' nicht gefunden."
[ -f "$BE/routes/auth.js" ]   || die "'$BE/routes/auth.js' nicht gefunden."
[ -f "$BE/test/unit/shared-js.test.js" ] || die "C3-Tests fehlen. Bitte zuerst apply-c3-tests.sh ausführen."

if command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
  [ -z "$(git status --porcelain)" ] || die "Arbeitsverzeichnis nicht sauber. Bitte erst committen."
  ok "Arbeitsverzeichnis sauber"
fi

echo
echo "── Planen und anwenden (alles oder nichts) ─────────────────────"

node - "$BE" "$FE" <<'NODE_C3'
const fs   = require('fs');
const path = require('path');
const BE   = process.argv[2];
const FE   = process.argv[3];

const plan    = [];
const fehler  = [];
const dateien = new Map();

function pfad(datei) {
  return datei.startsWith('frontend/')
    ? path.join(FE, ...datei.replace(/^frontend\//, '').split('/'))
    : path.join(BE, ...datei.split('/'));
}

function hole(datei) {
  if (!dateien.has(datei)) {
    const f = pfad(datei);
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

function patch({ name, datei, schonDa, suche, ersetze, hinweis, naehe, mindestens = 1 }) {
  const e = hole(datei);
  if (!e) { fehler.push({ name, datei, hinweis: 'Datei nicht gefunden', ausschnitt: '' }); return; }
  if (schonDa && schonDa.test(e.aktuell)) { plan.push({ datei, name, geaendert: false }); return; }

  let treffer = 0;
  const neu = e.aktuell.replace(suche, (...args) => {
    treffer++;
    return typeof ersetze === 'function' ? ersetze(...args) : ersetze;
  });
  if (treffer < mindestens) {
    fehler.push({ name, datei,
                  hinweis: `${hinweis} (${treffer} von mindestens ${mindestens} Stellen gefunden)`,
                  ausschnitt: naehe ? umgebung(e.aktuell, naehe) : '' });
    return;
  }
  e.aktuell = neu;
  plan.push({ datei, name, geaendert: true, treffer });
}

// ── C3.1  Zugangsdaten-401er kennzeichnen ─────────────────────────
patch({
  name: 'C3.1  Login-401 bekommt code: BAD_CREDENTIALS',
  datei: 'routes/auth.js',
  schonDa: /BAD_CREDENTIALS/,
  suche: /return res\.status\(401\)\.json\(\{ message: 'Benutzername oder Passwort falsch' \}\);/g,
  ersetze:
    "return res.status(401).json({\n" +
    "      message: 'Benutzername oder Passwort falsch',\n" +
    "      // Kennzeichnet einen Fehler bei den ZUGANGSDATEN, nicht bei der\n" +
    "      // Sitzung. Der Browser meldet sich bei einem so gekennzeichneten\n" +
    "      // 401 nicht ab — ein Tippfehler soll niemanden aus dem System werfen.\n" +
    "      code: 'BAD_CREDENTIALS'\n" +
    "    });",
  mindestens: 2,
  hinweis: 'Die 401-Antworten in /login sehen anders aus als erwartet.',
  naehe: /Benutzername oder Passwort/
});

patch({
  name: 'C3.1  change-password-401 bekommt code: BAD_CREDENTIALS',
  datei: 'routes/auth.js',
  schonDa: /Aktuelles Passwort falsch',\s*\n\s*code/,
  suche: /return res\.status\(401\)\.json\(\{ message: 'Aktuelles Passwort falsch' \}\);/,
  ersetze:
    "return res.status(401).json({\n" +
    "      message: 'Aktuelles Passwort falsch',\n" +
    "      code: 'BAD_CREDENTIALS'\n" +
    "    });",
  hinweis: 'Die 401-Antwort in /change-password sieht anders aus als erwartet.',
  naehe: /Aktuelles Passwort falsch/
});

// ── C3.2  api(): Antwort zuerst lesen, dann entscheiden ───────────
// Bewusst EIN Vorgang statt zwei: der 401-Block und die json()-Zeile werden
// zusammen ersetzt. Als zwei Vorgänge hat der zweite sein eigenes
// "schon angewendet"-Kennzeichen im Kommentar des ersten gefunden und sich
// selbst übersprungen — api() wertete die Antwort danach zweimal aus.
patch({
  name: 'C3.2  api() unterscheidet Sitzungs- und Zugangsdaten-401',
  datei: 'frontend/assets/shared.js',
  schonDa: /BAD_CREDENTIALS/,
  suche: /  if \(res\.status === 401\) \{\r?\n    logout\(\);\r?\n    throw new Error\('Session abgelaufen'\);\r?\n  \}\r?\n\r?\n  const data = await res\.json\(\)\.catch\(\(\) => \(\{\}\)\);/,
  ersetze: [
    '  const data = await res.json().catch(() => ({}));',
    '',
    '  // Nur ein 401 aus der Token-Prüfung beendet die Sitzung.',
    '  //',
    '  // Vorher führte JEDER 401 zum Abmelden. /api/auth/change-password läuft',
    '  // aber selbst durch die Token-Prüfung und antwortet zusätzlich mit 401,',
    '  // wenn das eingegebene aktuelle Passwort falsch ist — ein Tippfehler in',
    '  // diesem Feld warf den Benutzer damit aus dem System.',
    '  //',
    "  // Unterschieden wird über das Feld code: 'BAD_CREDENTIALS' kennzeichnet",
    '  // einen Fehler bei den Zugangsdaten. Ein 401 OHNE dieses Kennzeichen gilt',
    '  // weiterhin als abgelaufene Sitzung — vergisst jemand später eine',
    '  // Kennzeichnung, ist das Ergebnis das alte Verhalten und nicht eine',
    '  // Sitzung, die nie endet.',
    "  if (res.status === 401 && data.code !== 'BAD_CREDENTIALS') {",
    '    logout();',
    "    throw new Error('Session abgelaufen');",
    '  }'
  ].join('\n'),
  hinweis: 'Der 401-Block samt folgender json()-Zeile in api() sieht anders aus als erwartet.',
  naehe: /res\.status === 401/
});

// ── C3.3  logout(): Anzeige-Einstellungen behalten ────────────────
patch({
  name: 'C3.3  logout() behält die Anzeige-Einstellungen',
  datei: 'frontend/assets/shared.js',
  schonDa: /anzeigeEinstellungen/,
  suche: /  sessionStorage\.clear\(\);\r?\n  localStorage\.clear\(\);/,
  ersetze: [
    '  sessionStorage.clear();',
    '',
    '  // localStorage.clear() hat auch das gespeicherte Farbschema gelöscht:',
    '  // nach jedem Abmelden stand das Thema wieder auf dem Standard, obwohl es',
    '  // zum Gerät gehört und nicht zur Sitzung.',
    '  //',
    '  // Alles Übrige wird weiterhin entfernt — das war die Absicht hinter dem',
    '  // ursprünglichen clear() und bleibt richtig, damit nichts vom vorigen',
    '  // Benutzer auf einem gemeinsam genutzten Gerät zurückbleibt.',
    "  const anzeigeEinstellungen = ['theme'];",
    '  const gemerkt = {};',
    '  anzeigeEinstellungen.forEach(schluessel => {',
    '    const wert = localStorage.getItem(schluessel);',
    '    if (wert !== null) gemerkt[schluessel] = wert;',
    '  });',
    '  localStorage.clear();',
    '  Object.keys(gemerkt).forEach(schluessel => {',
    '    localStorage.setItem(schluessel, gemerkt[schluessel]);',
    '  });'
  ].join('\n'),
  hinweis: 'Der Rumpf von logout() sieht anders aus als erwartet.',
  naehe: /localStorage\.clear/
});

// ── C3.4  escapeHtml(): die 0 nicht verschlucken ──────────────────
patch({
  name: 'C3.4  escapeHtml() verschluckt die 0 nicht mehr',
  datei: 'frontend/assets/shared.js',
  schonDa: /str === null \|\| str === undefined/,
  suche: /function escapeHtml\(str\) \{\r?\n  if \(!str\) return '';/,
  ersetze: [
    'function escapeHtml(str) {',
    '  // Vorher: if (!str) return \'\' — damit wurden auch die Zahl 0 und false',
    '  // zu einem leeren String. In einer Lagerverwaltung ist 0 ein häufiger',
    '  // und wichtiger Wert: ein Bestand von 0 verschwand aus jeder Anzeige,',
    '  // die durch diese Funktion lief.',
    "  if (str === null || str === undefined) return '';"
  ].join('\n'),
  hinweis: 'Der Anfang von escapeHtml() sieht anders aus als erwartet.',
  naehe: /function escapeHtml/
});

// ── C3.5  Vorlage im Frontend-Test an den neuen Vertrag anpassen ──
// Der rote Test 4 nimmt eine Server-Antwort an. Diese Antwort ändert sich
// durch C3.1 — ohne code-Feld würde api() korrekt abmelden und der Test
// blieb rot, aus dem falschen Grund. Geändert wird nur die Vorlage, nicht
// die Aussage des Tests. Dass der Server genau das schickt, halten zwei
// Tests in test/integration/change-password.test.js fest.
//
// Der Leitplanken-Test 3 bleibt ausdrücklich unangetastet: seine Vorlage hat
// kein code-Feld und muss weiterhin zum Abmelden führen.
patch({
  name: 'C3.5  Vorlage in test/unit/shared-js.test.js an den Vertrag angepasst',
  datei: 'test/unit/shared-js.test.js',
  schonDa: /BAD_CREDENTIALS/,
  suche: /    fetchStub: async \(\) => antwort\(401, \{ message: 'Aktuelles Passwort falsch' \}\)/,
  ersetze: [
    '    // Genau diese Antwort schickt der Server seit C3.1 — festgehalten in',
    '    // test/integration/change-password.test.js.',
    '    fetchStub: async () => antwort(401, {',
    "      message: 'Aktuelles Passwort falsch',",
    "      code:    'BAD_CREDENTIALS'",
    '    })'
  ].join('\n'),
  hinweis: 'Die fetch-Vorlage im Passwort-Test wurde nicht gefunden.',
  naehe: /Aktuelles Passwort falsch/
});

// ── Abschlussprüfung, noch in der Planphase ───────────────────────
// Diese Prüfung hat in der ersten Fassung falsch Alarm geschlagen: sie zählte
// "await res.json()" im GANZEN File. shared.js benutzt diese Zeile aber auch
// in anderen Funktionen — der Alarm kam also von fremdem Code, während api()
// korrekt gepatcht war. Geprüft wird jetzt nur der Rumpf von api().
{
  const sh = dateien.get('frontend/assets/shared.js');
  if (sh) {
    const zeilen = sh.aktuell.split('\n');
    const start  = zeilen.findIndex(l => /^\s*async function api\s*\(/.test(l));
    const einzug = start === -1 ? '' : (zeilen[start].match(/^\s*/) || [''])[0];
    const ende   = start === -1 ? -1 : zeilen.findIndex((l, i) => i > start && l === einzug + '}');

    if (start === -1 || ende === -1) {
      fehler.push({
        name: 'Abschlussprüfung',
        datei: 'frontend/assets/shared.js',
        hinweis: 'Der Rumpf von api() ließ sich nicht abgrenzen',
        ausschnitt: umgebung(sh.aktuell, /async function api/, 6)
      });
    } else {
      const rumpfZeilen = zeilen.slice(start, ende + 1);
      const rumpf = rumpfZeilen.filter(l => !/^\s*\/\//.test(l)).join('\n');
      const n = (rumpf.match(/await res\.json\(\)/g) || []).length;
      if (n !== 1) {
        fehler.push({
          name: 'Abschlussprüfung',
          datei: 'frontend/assets/shared.js',
          hinweis: `api() wertet die Antwort ${n}-mal aus, erwartet genau 1 — ` +
                   'ein zweites res.json() auf derselben Antwort liefert einen Fehler',
          ausschnitt: rumpfZeilen.map((l, k) => `      ${start + 1 + k}| ${l}`).join('\n')
        });
      } else {
        const imGanzenFile = (sh.aktuell.match(/await res\.json\(\)/g) || []).length;
        console.log(`  \x1b[90m·\x1b[0m api() liest die Antwort genau einmal ` +
                    `(im ganzen File ${imGanzenFile}x — andere Funktionen sind davon unberührt)`);
      }
    }
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
  const zusatz = p.treffer > 1 ? ` (${p.treffer} Stellen)` : '';
  console.log(`  \x1b[32m✓\x1b[0m ${p.name}${zusatz}`);
}

for (const [datei, e] of dateien) {
  if (e.aktuell === e.original) continue;
  const f = pfad(datei);
  if (!fs.existsSync(f + '.c3.bak')) fs.writeFileSync(f + '.c3.bak', e.original);
  fs.writeFileSync(f, e.aktuell);
  console.log(`  \x1b[90m→\x1b[0m geschrieben: ${datei}`);
}
NODE_C3

echo
echo "── Neue Tests für die Kennzeichnung ────────────────────────────"

ZIEL="$BE/test/integration/change-password.test.js"
if grep -q 'BAD_CREDENTIALS' "$ZIEL"; then
  skip "schon vorhanden"
else
  cat >> "$ZIEL" <<'EOF'

// ── Neu in C3: die Kennzeichnung ──────────────────────────────────
// Diese beiden Tests halten den Vertrag fest, auf dem api() im Browser
// aufbaut. Ohne sie wäre die Attrappe im Frontend-Test nur eine Behauptung.

test('ein 401 wegen Zugangsdaten ist als solcher gekennzeichnet', async () => {
  await makeUser({ username: 'anna' });
  const { token } = await login('anna');

  const passwortFehler = await req('/api/auth/change-password', {
    method: 'PUT', token,
    body: { currentPassword: 'vertippt', newPassword: NEU }
  });
  assert.equal(passwortFehler.status, 401);
  assert.equal(passwortFehler.body.code, 'BAD_CREDENTIALS',
    'ohne diese Kennzeichnung kann der Browser den Fall nicht von einer ' +
    'abgelaufenen Sitzung unterscheiden');

  const loginFehler = await req('/api/auth/login', {
    method: 'POST', body: { username: 'anna', password: 'falsch' }
  });
  assert.equal(loginFehler.status, 401);
  assert.equal(loginFehler.body.code, 'BAD_CREDENTIALS');
});

test('ein 401 aus der Token-Prüfung trägt diese Kennzeichnung NICHT', async () => {
  const r = await req('/api/products', { token: 'voelligKaputt' });
  assert.equal(r.status, 401);
  assert.notEqual(r.body.code, 'BAD_CREDENTIALS',
    'sonst würde eine abgelaufene Sitzung nicht mehr zum Abmelden führen — ' +
    'genau die Leitplanke, die das verhindern soll');
});
EOF
  ok "2 Tests ergänzt"
fi

echo
echo "── Selbstprüfung ───────────────────────────────────────────────"
for f in "$FE/assets/shared.js" "$BE/routes/auth.js" "$ZIEL"; do
  node --check "$f" >/dev/null 2>&1 || die "Syntaxfehler in $f — rückgängig mit: git checkout ."
done
ok "syntaktisch gültig"

n=$(grep -c "BAD_CREDENTIALS" "$BE/routes/auth.js" || true)
[ "$n" -ge 3 ] || die "erwartet mindestens 3 Kennzeichnungen in routes/auth.js, gefunden $n"
ok "routes/auth.js kennzeichnet $n Zugangsdaten-401er"

grep -q "data.code !== 'BAD_CREDENTIALS'" "$FE/assets/shared.js" \
  || die "api() prüft die Kennzeichnung nicht — git checkout ."
ok "api() prüft die Kennzeichnung"

echo
echo "── Tests ───────────────────────────────────────────────────────"
echo
( cd "$BE" && npm run test:unit ) || true
echo
( cd "$BE" && npm run test:integration ) || true

echo
echo "── Danach ──────────────────────────────────────────────────────"
echo
echo "  Erwartet: alle Unit- und Integrationstests grün."
echo
echo "  Im Browser bitte einmal von Hand nachstellen:"
echo "   1. anmelden, Thema auf dunkel stellen, abmelden — das Thema bleibt"
echo "   2. anmelden, Passwort ändern mit FALSCHEM aktuellem Passwort —"
echo "      es erscheint eine Fehlermeldung, die Sitzung bleibt bestehen"
echo "   3. Passwort ändern mit richtigem aktuellem Passwort — es klappt"
echo "   4. ein Produkt mit Bestand 0 anzeigen — die 0 ist sichtbar"
echo
echo "  Ein Punkt bleibt bewusst offen: api() baut den Authorization-Header"
echo "  aus dem beim Laden gelesenen token, nicht aus sessionStorage zur"
echo "  Laufzeit. Solange nach dem Anmelden die Seite wechselt, fällt das"
echo "  nicht auf. Ohne Test, der einen Schaden zeigt, fasse ich es nicht an."
echo
echo "  Rückgängig:  git checkout . && git clean -fd"
echo
