#!/usr/bin/env bash
#
# apply-i1-abschluss.sh — Phase I: bereit für den Laden
#
# 1. „Bericht senden“ ohne Telegram: Telegram ist auf dem Server absichtlich
#    nicht eingerichtet. Bis hierher bekam trotzdem jeder, der „Bericht senden“
#    drückte, eine rote Meldung mit .env-Variablennamen — jedes Mal. Jetzt:
#    nicht eingerichtet = gespeichert, grün, ohne Versuch. Ein gescheiterter
#    Versand bei eingerichtetem Telegram bleibt eine Warnung.
# 2. Edeka.lager/KURZANLEITUNG.md für die Kolleginnen und Kollegen — mit einem
#    Test: jede zitierte Beschriftung muss wörtlich in der Oberfläche stehen.
# 3. README.md als Startseite des Repositorys.
#
# Voraussetzung: H4 ist in main. Legt den Branch phase-i1 an.
#
#     bash apply-i1-abschluss.sh
#
set -euo pipefail

BE="Edeka.lager/backend"
SELBST="$(basename "$0")"
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
die()  { printf '\n  \033[31m✗ %s\033[0m\n\n' "$1" >&2; exit 1; }
gruen() { ( cd "$BE" && node --test "$@" >/dev/null 2>&1 ); }

echo
echo "── Phase I: bereit für den Laden ───────────────────────────────"
echo

[ -f "$BE/server.js" ] || die "Bitte im Wurzelverzeichnis des Repos ausführen (cd ~/Eder)."
command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1 || die "Kein Git-Repository."
git ls-files --error-unmatch tools/abnahme.sh >/dev/null 2>&1 || die "H4 fehlt in main — bitte zuerst  git checkout main && git pull"

TEIL1_DATEIEN=(README.md Edeka.lager/KURZANLEITUNG.md Edeka.lager/BETRIEB.md Edeka.lager/ENTSCHEIDUNGEN.md
               tools/README.md "$BE/test/unit/doku.test.js" "$BE/test/unit/kurzanleitung.test.js"
               "$BE/test/unit/bericht-meldung.test.js" "$BE/test/integration/bericht-telegram.test.js"
               "$BE/services/telegram.js" "$BE/routes/reports.js" Edeka.lager/frontend/assets/shared.js)
BRANCH=$(git rev-parse --abbrev-ref HEAD)
SCHMUTZ=$(git status --porcelain | grep -v -- "$SELBST" | grep -vE '^\?\? apply-[a-z0-9-]+\.sh$' || true)
if [ "$BRANCH" = "phase-i1" ]; then
  for f in "${TEIL1_DATEIEN[@]}"; do SCHMUTZ=$(printf '%s\n' "$SCHMUTZ" | grep -vxE "(\?\?| M|M |MM|A ) $f" || true); done
fi
[ -z "$SCHMUTZ" ] || { printf '%s\n' "$SCHMUTZ" | sed 's/^/     /'; die "Arbeitsverzeichnis nicht sauber (siehe oben)."; }
REPARATUR=0
case "$BRANCH" in
  main)
    if git ls-files --error-unmatch Edeka.lager/KURZANLEITUNG.md >/dev/null 2>&1; then REPARATUR=1
    elif git show-ref --verify --quiet refs/heads/phase-i1; then git checkout -q phase-i1
    else git checkout -q -b phase-i1; fi ;;
  phase-i1) ;;
  *) die "Du bist auf '$BRANCH'. Bitte zuerst  git checkout main && git pull" ;;
esac
if [ "$REPARATUR" = "1" ]; then ok "Phase I ist schon in main — Prüflauf auf main"
else ok "Branch phase-i1, Arbeitsverzeichnis sauber"; fi

FERTIG=0
TMP=$(mktemp -d); chmod 700 "$TMP"
zurueck() {
  rm -rf "$TMP"
  if [ "$FERTIG" != "1" ]; then
    for f in "${TEIL1_DATEIEN[@]}"; do
      if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then git checkout -q -- "$f" 2>/dev/null || true
      else rm -f "$f"; fi
    done
    printf '  \033[33m!\033[0m abgebrochen — alle Dateien wieder im Ausgangszustand\n' >&2
  fi
}
trap zurueck EXIT

echo
echo "── Tests zuerst ────────────────────────────────────────────────"
cat > "$TMP/TEST_TG" <<'__I1_TG__'
'use strict';
//
// „Bericht senden“, wenn Telegram nicht eingerichtet ist.
//
// Auf dem Server ist Telegram absichtlich nicht eingerichtet. Bis Phase I
// bekam trotzdem jeder, der „Bericht senden“ drückte, eine rote Meldung:
// „Telegram-Versand fehlgeschlagen: Telegram nicht konfiguriert (.env fehlt …)“
// — jedes Mal. Nicht eingerichtet ist kein Fehler: der Bericht wird
// gespeichert, ohne Warnung und ohne Versuch, Telegram zu erreichen. Ein
// gescheiterter Versand bei eingerichtetem Telegram bleibt eine Warnung (207).
//
// Telegram wird nie wirklich erreicht: eine Attrappe fängt nur Aufrufe an
// api.telegram.org ab — alle anderen (auch die dieses Tests an die App)
// gehen unverändert durch.
//
const test     = require('node:test');
const assert   = require('node:assert/strict');
const jwt      = require('jsonwebtoken');
const db       = require('../helpers/db');
const { start, stop, req } = require('../helpers/http');
const { makeUser, makeProduct } = require('../helpers/factories');
const DailyLog = require('../../models/DailyLog');

test.before(async () => { await db.connect(); await start(); });
test.after (async () => { await stop(); await db.disconnect(); });
test.beforeEach(async () => { await db.wipe(); });

const tokenFuer = (u) => jwt.sign({ id: u._id.toString() }, process.env.JWT_SECRET, { expiresIn: '1h' });
const echtesFetch = global.fetch;
const ENV = { token: process.env.TELEGRAM_BOT_TOKEN, chat: process.env.TELEGRAM_CHAT_ID };

function telegram(t, { token = '', chat = '', antwort }) {
  const aufrufe = [];
  process.env.TELEGRAM_BOT_TOKEN = token;
  process.env.TELEGRAM_CHAT_ID = chat;
  global.fetch = async (url, opts) => {
    if (!String(url).startsWith('https://api.telegram.org/')) return echtesFetch(url, opts);
    aufrufe.push({ url: String(url), body: JSON.parse(opts.body) });
    return antwort();
  };
  t.after(() => { global.fetch = echtesFetch; process.env.TELEGRAM_BOT_TOKEN = ENV.token; process.env.TELEGRAM_CHAT_ID = ENV.chat; });
  return aufrufe;
}

async function senden(name) {
  const u = await makeUser({ username: `${name}_tg`, name });
  await makeProduct({});
  const r = await req('/api/reports/send-now', { method: 'POST', token: tokenFuer(u) });
  return { r, logs: await DailyLog.find({}).lean() };
}

test('ohne Telegram: gespeichert, keine Warnung, kein Versuch', async (t) => {
  const aufrufe = telegram(t, { antwort: () => { throw new Error('darf nie aufgerufen werden'); } });
  const { r, logs } = await senden('kim');
  assert.equal(r.status, 201, JSON.stringify(r.body));
  assert.equal(r.body.telegram, 'aus');
  assert.equal(r.body.telegramError, undefined);
  assert.match(r.body.message, /gespeichert/);
  assert.doesNotMatch(r.body.message, /gesendet|fehlgeschlagen/);
  assert.equal(aufrufe.length, 0, 'ohne Einrichtung kein einziger Versuch, Telegram zu erreichen');
  assert.equal(logs.length, 1);
  assert.equal(logs[0].reportSent, false);
});

test('Telegram eingerichtet, Versand scheitert: gespeichert, aber eine Warnung (207)', async (t) => {
  const aufrufe = telegram(t, { token: 'test-token', chat: '42', antwort: () => { throw new Error('Netz weg'); } });
  const { r, logs } = await senden('lea');
  assert.equal(r.status, 207, JSON.stringify(r.body));
  assert.equal(r.body.telegram, 'fehler');
  assert.match(r.body.telegramError, /Netz weg/);
  assert.equal(aufrufe.length, 1);
  assert.equal(logs.length, 1);
  assert.equal(logs[0].reportSent, false);
});

test('Telegram eingerichtet, Versand klappt: gesendet und gespeichert', async (t) => {
  const aufrufe = telegram(t, { token: 'test-token', chat: '42',
    antwort: () => ({ ok: true, status: 200, json: async () => ({ ok: true, result: {} }) }) });
  const { r, logs } = await senden('max');
  assert.equal(r.status, 201, JSON.stringify(r.body));
  assert.equal(r.body.telegram, 'gesendet');
  assert.match(r.body.message, /gesendet und gespeichert/);
  assert.equal(aufrufe.length, 1);
  assert.equal(aufrufe[0].body.chat_id, '42');
  assert.equal(logs[0].reportSent, true);
});
__I1_TG__
cat > "$TMP/TEST_MG" <<'__I1_MG__'
'use strict';
//
// Was der Browser nach „Bericht senden“ zeigt.
//
// Ohne eingerichtetes Telegram meldet der Server telegram: "aus". Dann ist
// die Meldung grün — „Bericht gespeichert“ —, und nirgends steht „gesendet“:
// es wurde ja nichts gesendet. Nur ein echter Fehler beim Versand ist rot.
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const { ladeShared, antwort } = require('../helpers/browser');

async function meldungen(status, koerper) {
  const b = ladeShared({ token: 'x', fetchStub: async () => antwort(status, koerper) });
  const gezeigt = [];
  b.sandbox.showToast = (text, art) => gezeigt.push([art, text]);
  await b.sandbox.sendReportNow();
  return gezeigt;
}

test('ohne Telegram: grün „Bericht gespeichert“ — kein Rot, kein „gesendet“', async () => {
  const m = await meldungen(201, { message: '✅ Bericht gespeichert', telegram: 'aus', log: {} });
  assert.deepEqual(m.at(-1), ['ok', '✅ Bericht gespeichert!']);
  assert.ok(!m.some(([art]) => art === 'err'), JSON.stringify(m));
  assert.ok(!m.some(([, text]) => /gesendet/.test(text)), JSON.stringify(m));
});

test('Versand gescheitert: weiterhin die Warnung', async () => {
  const m = await meldungen(207, { telegram: 'fehler', telegramError: 'Netz weg', log: {} });
  assert.deepEqual(m.at(-1), ['err', '⚠️ Bericht gespeichert, Telegram-Versand fehlgeschlagen: Netz weg']);
});

test('gesendet: grün „gesendet und gespeichert“', async () => {
  const m = await meldungen(201, { telegram: 'gesendet', log: {} });
  assert.deepEqual(m.at(-1), ['ok', '✅ Bericht gesendet und gespeichert!']);
});
__I1_MG__
cat > "$TMP/TEST_KA" <<'__I1_KA__'
'use strict';
//
// Die Kurzanleitung nennt nur, was es in der Oberfläche wirklich gibt.
//
// Jede Beschriftung, die sie in „…“ zitiert, muss wörtlich in den Seiten oder
// Skripten des Frontends stehen — als ganzes Wort („Admin“ zählt nicht, nur
// weil es „🔑 Admins“ gibt) und nicht bloß in einem Kommentar. HTML-Entitäten
// werden aufgelöst; „…“ mitten in einem Zitat steht für einen Platzhalter, etwa
// eine Zahl. Benennt jemand einen Knopf um, wird dieser Test rot, bis die
// Anleitung nachzieht.
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const fs     = require('node:fs');
const path   = require('node:path');

const WURZEL   = path.join(__dirname, '../../../..');
const FRONTEND = path.join(WURZEL, 'Edeka.lager', 'frontend');
const ANLEITUNG = path.join(WURZEL, 'Edeka.lager', 'KURZANLEITUNG.md');

const entitaeten = (s) => s.replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"');
function oberflaeche() {
  const teile = [];
  (function lauf(dir) {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, e.name);
      if (e.isDirectory()) lauf(p);
      else if (/\.(html|js)$/.test(e.name) && !e.name.includes('.min.')) {
        // Kommentarzeilen sind keine Oberfläche.
        const ohneKommentare = fs.readFileSync(p, 'utf8').split('\n')
          .filter(z => !/^\s*(\/\/|\/\*|\*)/.test(z)).join('\n');
        teile.push(entitaeten(ohneKommentare.replace(/<!--[\s\S]*?-->/g, '')));
      }
    }
  })(FRONTEND);
  return teile.join('\n');
}

test('jede zitierte Beschriftung gibt es in der Oberfläche', () => {
  const text = fs.readFileSync(ANLEITUNG, 'utf8');
  const zitate = [...text.replace(/\n/g, ' ').matchAll(/„([^“]+)“/g)].map(m => m[1]);
  assert.ok(zitate.length > 30, `nur ${zitate.length} Zitate gefunden — Einlesen fehlgeschlagen?`);
  const ui = oberflaeche();
  const maskiert = (t) => t.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const alsWort = (teil) => new RegExp(`(?<![\\p{L}\\p{N}])${maskiert(teil)}(?![\\p{L}\\p{N}])`, 'u').test(ui);
  const fehlt = zitate.filter(z => !z.split('…').map(s => s.trim()).filter(Boolean).every(alsWort));
  assert.deepEqual([...new Set(fehlt)], [], 'in der Anleitung zitiert, in der Oberfläche nicht vorhanden');
});

test('die Anleitung verrät keine Adresse — sie wird von Hand eingetragen', () => {
  const text = fs.readFileSync(ANLEITUNG, 'utf8');
  assert.match(text, /\*\*Adresse der App:\*\* _{20,}/);
  assert.doesNotMatch(text, /https?:\/\//);
});
__I1_KA__
cat > "$TMP/ANL" <<'__I1_ANL__'
# Kurzanleitung — EDEKA Lagerverwaltung

Für alle, die mit der App arbeiten. Zum Ausdrucken.

**Adresse der App:** ______________________________________________

Am besten als Lesezeichen speichern. Auf dem Handy lässt sich die Seite über
das Menü des Browsers auch auf den Startbildschirm legen.

## Anmelden

Adresse öffnen, „Benutzername“ und „Passwort“ eingeben, „Anmelden“.

Dein Konto legt jemand mit der Rolle „Administrator“ an — dort bekommst du auch
ein neues Passwort, wenn du es vergessen hast. Nach zu vielen falschen Versuchen
ist die Anmeldung für deinen Namen eine Weile gesperrt: kurz warten, dann noch
einmal.

Auf dem Handy öffnet „☰“ oben die Seitenleiste mit allen Seiten.

## Bestand ändern

Auf der „Bestandsübersicht“ ist jede Zeile ein Produkt.

- „−“ und „+“ ändern den Bestand in Schritten. Schnell mehrmals drücken ist
  kein Problem.
- In das Feld dazwischen kannst du die Zahl auch direkt eintippen — mit Enter
  bestätigen oder einfach das Feld verlassen.

Gespeichert wird von selbst; einen eigenen Knopf dafür gibt es nicht.

Ändert jemand anderes denselben Bestand zur gleichen Zeit, erscheint
„Jemand anderes hat den Bestand inzwischen auf … geändert.“ Dann gilt die
angezeigte Zahl — prüf sie und ändere sie bei Bedarf noch einmal.

**Neues Produkt:** „+ Produkt hinzufügen“, dann „Produktname“, „Kategorie“,
„Einheit“ und „Anfangsbestand“ ausfüllen, zum Schluss „Speichern“.
**Produkt ändern:** in der Zeile auf ✏️ („Bearbeiten“).

## Tagesbericht

„📤 Bericht senden“ hält den aktuellen Stand als Tagesbericht fest. Außerdem
schließt die App jeden Tag um Mitternacht von selbst ab — niemand muss daran
denken.

## Auswerten

„Analyse & Berichte“: „📅 Heute“ zeigt den heutigen Tag, „📈 Verlauf“ die
Entwicklung über die Tage. „📊 Excel (Live)“ und „📄 PDF (Live)“ laden den
aktuellen Stand herunter.

„Tagesberichte“: jeder gespeicherte Bericht, jeweils mit „📊 Excel“ und
„📄 PDF“.

## Hell oder dunkel

„🌓“ oben schaltet zwischen hellem und dunklem Aussehen um.

## Abmelden

Ganz unten in der Seitenleiste stehen dein Name und deine Rolle. Das kleine
Symbol rechts daneben meldet dich ab — zeigt man mit der Maus darauf, erscheint
„Abmelden“. Auf fremden oder geteilten Geräten immer abmelden.

## Wenn etwas nicht geht

1. Seite neu laden — am Computer mit Strg+F5.
2. Abmelden und wieder anmelden.
3. Hilft das nicht: Bescheid geben — mit Uhrzeit und dem, was du gerade
   gemacht hast.

---

## Für die Rolle „Administrator“

In der Seitenleiste steht zusätzlich „Benutzerverwaltung“; auf der
„Bestandsübersicht“ und bei den „Tagesberichte“ zusätzlich „⚙️“.

**Neues Konto:** „Benutzerverwaltung“ → „＋ Neuer Benutzer“ → „Name“,
„Benutzername“, „Passwort“ und „Rolle“ ausfüllen → „Speichern“. Das Passwort
braucht mindestens 6 Zeichen — besser deutlich mehr. Fürs Lager die Rolle
„Lagerist“; „Administrator“ nur, wer Konten verwalten soll. „Telegram Chat-ID“
leer lassen.

**Neues Passwort:** beim Konto „Bearbeiten“, dort „Neues Passwort“ ausfüllen,
„Speichern“. Selbst ändern kann man das eigene Passwort in der App nicht —
neue Passwörter setzt immer ein Administrator.

**Jemand verlässt das Team:** beim Konto „Bearbeiten“ und den „Status“ auf
„Deaktiviert“ setzen, statt „Endgültig löschen“. Wer deaktiviert ist, kann sich
nicht mehr anmelden; das Konto lässt sich später wieder auf „Aktiv“ setzen.

**Nur für Administratoren:** Produkte löschen (🗑️), Kategorien und Einheiten
ändern oder löschen, „🔄 Alle Bestände auf 0 setzen“, Logs löschen und
„🌙 Gestern manuell abschließen“. Diese Werkzeuge stehen hinter „⚙️“ und fragen
vor dem Ausführen mit „Bestätigen“ nach.
__I1_ANL__
cat > "$TMP/START" <<'__I1_START__'
# EDEKA Lagerverwaltung

Bestandsführung für eine EDEKA-Filiale: Bestände im Laden per Handy oder
Computer pflegen, täglicher Abschluss um Mitternacht, Auswertungen mit Excel-
und PDF-Export, Konten mit den Rollen Administrator und Lagerist.

Node.js mit Express 5 und MongoDB; die Oberfläche kommt ohne Build-Schritt
und ohne fremde Quellen aus. Betrieben auf einem eigenen Server hinter nginx mit
HTTPS — mit geprüften Sicherungen, einer verschlüsselten Kopie außer Haus und
einer Überwachung von außen.

| Für wen | Was |
|---|---|
| Mitarbeitende | [Kurzanleitung](Edeka.lager/KURZANLEITUNG.md) |
| Betrieb | [Betriebshandbuch](Edeka.lager/BETRIEB.md) — und eine Prüfung über alles: `bash tools/abnahme.sh` |
| Entwicklung | [Backend](Edeka.lager/backend/README.md), [Frontend](Edeka.lager/frontend/README.md), [Tests](Edeka.lager/backend/test/README.md) |
| Hintergründe | [Entscheidungen](Edeka.lager/ENTSCHEIDUNGEN.md), [die Schritte als Skripte](tools/README.md) |

## Stand

Abgeschlossen und im Betrieb, Oktober 2026. Jede Änderung läuft durch Unit- und
Integrationstests und ESLint, bei jedem Push auch in GitHub Actions; der Betrieb
wird mit `tools/abnahme.sh` geprüft.
__I1_START__
cat > "$TMP/code.py" <<'__I1_CODE__'
# Telegram ist optional: nicht eingerichtet ist kein Fehler. Jeder Anker genau einmal.
import sys

def ersetze(pfad, merkmal, paare):
    s = open(pfad, encoding='utf-8').read()
    if merkmal in s:
        print(f"schon  {pfad}"); return
    for alt, neu in paare:
        n = s.count(alt)
        if n != 1:
            sys.exit(f"Anker {n}× statt 1× in {pfad}: {alt[:70]!r}")
        s = s.replace(alt, neu)
    open(pfad, 'w', encoding='utf-8').write(s)
    print(f"neu    {pfad}")

ersetze('Edeka.lager/backend/services/telegram.js', 'function telegramEingerichtet', [
  ("module.exports = { sendTelegram, buildTelegramText, escapeMarkdown };",
   "// Eingerichtet heißt: Bot-Token UND Standard-Chat sind gesetzt. Ohne beides ist\n"
   "// Telegram absichtlich aus — das ist kein Fehler.\n"
   "function telegramEingerichtet() {\n"
   "  return Boolean(process.env.TELEGRAM_BOT_TOKEN && process.env.TELEGRAM_CHAT_ID);\n"
   "}\n\n"
   "module.exports = { sendTelegram, buildTelegramText, escapeMarkdown, telegramEingerichtet };"),
])

ersetze('Edeka.lager/backend/routes/reports.js', 'telegramEingerichtet()', [
  ("const { sendTelegram, buildTelegramText } = require('../services/telegram');",
   "const { sendTelegram, buildTelegramText, telegramEingerichtet } = require('../services/telegram');"),
  ("  // این try/catch داخلی عمداً نگه داشته شده: خطای ارسال تلگرام نباید مانع\n"
   "  // ذخیره‌شدن گزارش شود، پس جدا از بقیه‌ی هندلر مدیریت می‌شود.\n"
   "  let telegramError = null;\n"
   "  let reportSent = false;\n"
   "  try {\n"
   "    await sendTelegram(buildTelegramText(products));\n"
   "    reportSent = true;\n"
   "  } catch (err) {\n"
   "    telegramError = err.message;\n"
   "  }\n",
   "  // Telegram ist optional. Nicht eingerichtet: nur speichern, ohne Versuch und\n"
   "  // ohne Warnung. Eingerichtet: senden — ein Fehler dabei darf das Speichern\n"
   "  // nicht verhindern und wird als Warnung (207) gemeldet.\n"
   "  let telegramError = null;\n"
   "  let reportSent = false;\n"
   "  const telegram = telegramEingerichtet();\n"
   "  if (telegram) {\n"
   "    try {\n"
   "      await sendTelegram(buildTelegramText(products));\n"
   "      reportSent = true;\n"
   "    } catch (err) {\n"
   "      telegramError = err.message;\n"
   "    }\n"
   "  }\n"),
  ("    return res.status(207).json({\n"
   "      message: '⚠️ Bericht gespeichert, aber Telegram-Versand fehlgeschlagen',\n"
   "      telegramError,\n"
   "      log\n"
   "    });\n"
   "  }\n\n"
   "  res.status(201).json({ message: '✅ Bericht gesendet und gespeichert', log });",
   "    return res.status(207).json({\n"
   "      message: '⚠️ Bericht gespeichert, aber Telegram-Versand fehlgeschlagen',\n"
   "      telegram: 'fehler',\n"
   "      telegramError,\n"
   "      log\n"
   "    });\n"
   "  }\n"
   "  if (!telegram) {\n"
   "    return res.status(201).json({ message: '✅ Bericht gespeichert', telegram: 'aus', log });\n"
   "  }\n\n"
   "  res.status(201).json({ message: '✅ Bericht gesendet und gespeichert', telegram: 'gesendet', log });"),
])

ersetze('Edeka.lager/frontend/assets/shared.js', "result.telegram === 'aus'", [
  ("  showToast('📤 Bericht wird erstellt und gesendet...', 'info');",
   "  showToast('📤 Bericht wird erstellt …', 'info');"),
  ("    if (result.telegramError) {\n"
   "      showToast('⚠️ Bericht gespeichert, Telegram-Versand fehlgeschlagen: ' + result.telegramError, 'err');\n"
   "    } else {\n",
   "    if (result.telegramError) {\n"
   "      showToast('⚠️ Bericht gespeichert, Telegram-Versand fehlgeschlagen: ' + result.telegramError, 'err');\n"
   "    } else if (result.telegram === 'aus') {\n"
   "      // Telegram ist nicht eingerichtet — gespeichert, aber nichts gesendet.\n"
   "      showToast('✅ Bericht gespeichert!', 'ok');\n"
   "    } else {\n"),
])
__I1_CODE__
cat > "$TMP/doku.py" <<'__I1_DOKU__'
# Gezielte Ergänzungen der Doku für I1 — jeder Anker genau einmal.
import sys

def ergaenze(pfad, merkmal, paare):
    s = open(pfad, encoding='utf-8').read()
    if merkmal in s:
        print(f"schon  {pfad}"); return
    for alt, neu in paare:
        n = s.count(alt)
        if n != 1:
            sys.exit(f"Anker {n}× statt 1× in {pfad}: {alt[:70]!r}")
        s = s.replace(alt, neu)
    open(pfad, 'w', encoding='utf-8').write(s)
    print(f"neu    {pfad}")

ergaenze('Edeka.lager/BETRIEB.md', 'KURZANLEITUNG.md', [
  ("den Entscheidungen `ENTSCHEIDUNGEN.md`.\n",
   "den Entscheidungen `ENTSCHEIDUNGEN.md`, für die Arbeit im Laden\n`KURZANLEITUNG.md`.\n"),
])
ergaenze('Edeka.lager/ENTSCHEIDUNGEN.md', '## 18. Telegram ist eine Zugabe', [
  ("---\n\n## Arbeitsweise\n",
   "## 18. Telegram ist eine Zugabe, kein Muss (I)\n\n"
   "**Anlass:** Telegram ist auf dem Server absichtlich nicht eingerichtet. Trotzdem\n"
   "bekam jeder, der „Bericht senden“ drückte, eine rote Meldung mit den Namen von\n"
   "`.env`-Variablen — jedes Mal. Wer täglich rote Meldungen sieht, übersieht bald\n"
   "auch die echten.\n"
   "**Entscheidung:** Nicht eingerichtet ist kein Fehler: Der Bericht wird\n"
   "gespeichert, ohne Versuch und ohne Warnung (`telegram: \"aus\"`). Nur ein\n"
   "gescheiterter Versand bei eingerichtetem Telegram bleibt eine Warnung (207).\n"
   "**Folgen:** Rot heißt wieder „hier stimmt etwas nicht“. Wer Telegram später\n"
   "will, trägt Bot-Token und Chat in die `.env` ein — ohne Codeänderung.\n\n"
   "---\n\n## Arbeitsweise\n"),
])
ergaenze('tools/README.md', '`apply-i1-abschluss.sh`', [
  ("| `apply-h4-abschluss.sh` | Aufräumen, Systemupdates, Endabnahme |\n",
   "| `apply-h4-abschluss.sh` | Aufräumen, Systemupdates, Endabnahme |\n"
   "| `apply-i1-abschluss.sh` | Bericht ohne Telegram-Warnung, Kurzanleitung, Startseite des Repositorys |\n"),
])
ergaenze('Edeka.lager/backend/test/unit/doku.test.js', "'apply-i1-abschluss.sh'", [
  ("  'Edeka.lager/backend/test/README.md', 'tools/README.md'\n];",
   "  'Edeka.lager/backend/test/README.md', 'tools/README.md',\n  'README.md', 'Edeka.lager/KURZANLEITUNG.md'\n];"),
  ("const AUSSTEHEND = new Set(['apply-h1-doku.sh', 'apply-h3-extern.sh', 'apply-h2-alarm.sh', 'apply-h4-abschluss.sh']);",
   "const AUSSTEHEND = new Set(['apply-h1-doku.sh', 'apply-h3-extern.sh', 'apply-h2-alarm.sh', 'apply-h4-abschluss.sh',\n                            'apply-i1-abschluss.sh']);"),
])
__I1_DOKU__
lege() { if cmp -s "$TMP/$1" "$2"; then ok "$2: schon aktuell"; else cp "$TMP/$1" "$2"; ok "$2"; fi; }
lege TEST_TG "Edeka.lager/backend/test/integration/bericht-telegram.test.js"
lege TEST_MG "Edeka.lager/backend/test/unit/bericht-meldung.test.js"
lege TEST_KA "Edeka.lager/backend/test/unit/kurzanleitung.test.js"
NEUE_TESTS=(test/integration/bericht-telegram.test.js test/unit/bericht-meldung.test.js test/unit/kurzanleitung.test.js)
if gruen "${NEUE_TESTS[@]}"; then VORHER="grün"; else VORHER="rot"; fi
[ "$VORHER" = "rot" ] && ok "die neuen Tests: vorher rot — der Fehler ist da" || ok "die neuen Tests: schon grün (erneuter Lauf)"

echo
echo "── Behebung, Kurzanleitung, Startseite ─────────────────────────"
python3 "$TMP/code.py" | sed 's/^/    /' || die "Code-Anker passen nicht (siehe oben)"
lege ANL Edeka.lager/KURZANLEITUNG.md
lege START README.md
python3 "$TMP/doku.py" | sed 's/^/    /' || die "Doku-Anker passen nicht (siehe oben)"

echo
echo "── Nachweise ───────────────────────────────────────────────────"
gruen "${NEUE_TESTS[@]}" || { ( cd "$BE" && node --test "${NEUE_TESTS[@]}" 2>&1 | tail -40 ); die "die neuen Tests sind nicht grün"; }
if [ "$VORHER" = "rot" ]; then ok "die neuen Tests: vorher rot, jetzt grün (8 Tests)"; else ok "die neuen Tests: grün"; fi
gruen test/unit/doku.test.js || { ( cd "$BE" && node --test test/unit/doku.test.js 2>&1 | tail -30 ); die "doku.test.js ist nicht grün"; }
ok "doku.test.js: grün — auch für Startseite und Kurzanleitung"
zaehle() { grep -oE '(ℹ|#) (tests|fail) [0-9]+' "$1" | sed -E 's/^(ℹ|#) //' | tr '\n' ' '; }
set +e
( cd "$BE" && npm run test:unit ) > "$TMP/unit.txt" 2>&1; U=$?
( cd "$BE" && npm run test:integration ) > "$TMP/int.txt" 2>&1; I=$?
( cd "$BE" && npm run lint ) > "$TMP/lint.txt" 2>&1; L=$?
set -e
echo "    Unit:        $(zaehle "$TMP/unit.txt")"
echo "    Integration: $(zaehle "$TMP/int.txt")"
[ "$U" -eq 0 ] || { grep -E '✖|not ok' "$TMP/unit.txt" | head -10; die "Unit-Tests nicht grün"; }
[ "$I" -eq 0 ] || { grep -E '✖|not ok|ECONNREFUSED' "$TMP/int.txt" | head -10; die "Integrationstests nicht grün (läuft MongoDB?)"; }
ok "alle Tests grün"
[ "$L" -eq 0 ] || { grep -vE '^>|^$' "$TMP/lint.txt"; die "Lint meldet etwas"; }
ok "Lint sauber"
FERTIG=1

echo
if [ "$REPARATUR" = "1" ]; then echo "  Nichts zu committen — Phase I war schon in main."; echo; exit 0; fi
echo "── Danach ──────────────────────────────────────────────────────"
echo
echo "    mkdir -p tools && mv $SELBST tools/"
echo "    git add README.md Edeka.lager tools/README.md tools/$SELBST"
echo "    git commit -m 'Phase I: Bericht ohne Telegram-Warnung, Kurzanleitung, Startseite'"
echo "    git push -u origin phase-i1"
echo
echo "  Pull Request anlegen und mergen, danach auf dem Server:"
echo "      git checkout main && git pull"
echo "      sudo systemctl restart edeka-lager"
echo "      bash tools/apply-h4-abschluss.sh      (das Aufräumen nachholen — bei der Liste: j)"
echo "      bash tools/abnahme.sh                 (erwartet: 24 von 24)"
echo
