#!/usr/bin/env bash
#
# apply-h1-doku.sh — Phase H, Schritt 1: eine Doku, die stimmt
#
# Bis hierher beschrieb backend/README.md einen Stand vom Juli: 5 von 13
# Einstellungen, DOMAIN "für CORS" (seit Phase E ist das CORS_ORIGINS), eine
# Liste "unveränderter" Dateien, die sich alle geändert hatten, und zum Start
# npm run dev statt systemd. Eine Doku, die nicht stimmt, führt mit
# Überzeugung in die falsche Richtung.
#
# Neu oder neu geschrieben:
#   Edeka.lager/BETRIEB.md            Betriebshandbuch
#   Edeka.lager/ENTSCHEIDUNGEN.md     die Entscheidungen und ihre Gründe
#   Edeka.lager/backend/README.md     aktueller Stand: Einstellungen, API, Prüfen
#   Edeka.lager/frontend/README.md    Regeln für neuen Code und ihre Tests
#   tools/README.md                   alle Skripte
#   Edeka.lager/backend/.env.example  ohne DOMAIN (wird nirgends gelesen)
#
# Dazu test/unit/doku.test.js: prüft — in beide Richtungen, wo es geht —, dass
# jede Einstellung, jede API-Route und jedes Skript beschrieben ist, dass jedes
# "npm run …" existiert, und dass keine Server-Adresse und kein DuckDNS-Name im
# öffentlichen Repository landet.
#
# Außerdem: tools/apply-s1-geheimnis.sh las das Textformat der Testausgabe und
# meldete auf dem Server einen grünen Test als rot. Dort zählt jetzt — wie in
# diesem Skript — der Exit-Code.
#
# Voraussetzung: G1, G2 und S1 sind in main gemergt.
# Legt den Branch phase-h1 an; muss dafür auf main gestartet werden.
#
# Ausführen im Wurzelverzeichnis des Repos:
#     bash apply-h1-doku.sh
#
set -euo pipefail

BE="Edeka.lager/backend"
SELBST="$(basename "$0")"
S1="tools/apply-s1-geheimnis.sh"
T="$BE/test/unit/doku.test.js"
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
die()  { printf '\n  \033[31m✗ %s\033[0m\n\n' "$1" >&2; exit 1; }
# Ergebnis eines Testlaufs = sein Exit-Code. Das Textformat der Ausgabe hängt
# von der Node-Version ab (TAP oder spec) — daran war S1 gescheitert.
gruen() { ( cd "$BE" && node --test "$@" >/dev/null 2>&1 ); }

echo
echo "── Phase H, Schritt 1: eine Doku, die stimmt ───────────────────"
echo

[ -f "$BE/server.js" ] || die "Bitte im Wurzelverzeichnis des Repos ausführen (cd ~/Eder)."
command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1 || die "Kein Git-Repository."

FEHLT=""
for f in tools/apply-g1-haertung.sh tools/apply-g2-html.sh "$S1" \
         "$BE/test/unit/schliessen-knoepfe.test.js" "$BE/test/unit/html-senken.test.js" \
         "$BE/test/unit/keine-geheimnisse.test.js"; do
  [ -f "$f" ] || FEHLT="$FEHLT $f"
done
[ -z "$FEHLT" ] || die "G1, G2 und S1 sind noch nicht in main:$FEHLT
     Bitte zuerst die Pull Requests phase-g, phase-g2 und phase-s1 auf GitHub
     mergen, dann:  git checkout main && git pull"

SCHMUTZ=$(git status --porcelain | grep -v -- "$SELBST" | grep -vE '^\?\? apply-[a-z0-9-]+\.sh$' || true)
[ -z "$SCHMUTZ" ] || { printf '%s\n' "$SCHMUTZ" | sed 's/^/     /'; die "Arbeitsverzeichnis nicht sauber (siehe oben)."; }
BRANCH=$(git rev-parse --abbrev-ref HEAD)
case "$BRANCH" in
  main) if git show-ref --verify --quiet refs/heads/phase-h1; then git checkout -q phase-h1; else git checkout -q -b phase-h1; fi ;;
  phase-h1) ;;
  *) die "Du bist auf '$BRANCH'. Bitte zuerst  git checkout main && git pull" ;;
esac
ok "Branch phase-h1, G1, G2 und S1 vorhanden, Arbeitsverzeichnis sauber"

# ── Alles oder nichts ────────────────────────────────────────────────
GEAENDERT=("$BE/README.md" "Edeka.lager/frontend/README.md" "tools/README.md" "$BE/.env.example" "$S1")
NEU=()
for f in Edeka.lager/BETRIEB.md Edeka.lager/ENTSCHEIDUNGEN.md "$T"; do [ -e "$f" ] || NEU+=("$f"); done
FERTIG=0
TMP=$(mktemp -d)
zurueck() {
  rm -rf "$TMP"
  if [ "$FERTIG" != "1" ]; then
    git checkout -q -- "${GEAENDERT[@]}" 2>/dev/null || true
    [ "${#NEU[@]}" -eq 0 ] || rm -f "${NEU[@]}"
    printf '  \033[33m!\033[0m abgebrochen — alle Dateien wieder im Ausgangszustand\n' >&2
  fi
}
trap zurueck EXIT

# ── 1  Test ──────────────────────────────────────────────────────────
echo
echo "── Test ────────────────────────────────────────────────────────"
cat > "$T" <<'__H1_TEST__'
'use strict';
//
// Die Dokumentation bleibt wahr.
//
// Bis Phase H beschrieb backend/README.md einen Stand vom Juli: 5 von 13
// Einstellungen, DOMAIN "für CORS" (längst CORS_ORIGINS), eine Liste
// "unveränderter" Dateien, die sich alle geändert hatten. Eine Doku, die nicht
// stimmt, führt mit Überzeugung in die falsche Richtung. Geprüft wird hier
// alles, was sich maschinell prüfen lässt — in beide Richtungen, wo es geht.
//
// Und weil das Repository öffentlich ist: keine Server-Adresse und kein
// DuckDNS-Name in der Doku, nur Platzhalter.
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const fs     = require('node:fs');
const path   = require('node:path');

const WURZEL = path.join(__dirname, '../../../..');
const BE     = path.join(WURZEL, 'Edeka.lager', 'backend');
const lies   = (rel) => fs.readFileSync(path.join(WURZEL, rel), 'utf8');

const DOKS = [
  'Edeka.lager/BETRIEB.md', 'Edeka.lager/ENTSCHEIDUNGEN.md',
  'Edeka.lager/backend/README.md', 'Edeka.lager/frontend/README.md',
  'Edeka.lager/backend/test/README.md', 'tools/README.md'
];
// Kommt mit seinem eigenen Commit; danach existiert es ohnehin.
const AUSSTEHEND = new Set(['apply-h1-doku.sh']);

const unterschied = (a, b) => [...a].filter(x => !b.has(x)).sort();

test('jedes "npm run …" in der Doku gibt es wirklich', () => {
  const skripte = new Set(Object.keys(JSON.parse(fs.readFileSync(path.join(BE, 'package.json'), 'utf8')).scripts));
  const fehlt = [];
  for (const d of DOKS) for (const m of lies(d).matchAll(/npm run ([a-z][a-z0-9:-]*)/g)) {
    if (!skripte.has(m[1])) fehlt.push(`${d}: npm run ${m[1]}`);
  }
  assert.deepEqual(fehlt, []);
});

test('jede Einstellung aus .env.example ist beschrieben — und umgekehrt', () => {
  const vorlage = new Set([...lies('Edeka.lager/backend/.env.example').matchAll(/^#?\s*([A-Z][A-Z0-9_]*)=/gm)].map(m => m[1]));
  const readme  = new Set([...lies('Edeka.lager/backend/README.md').matchAll(/^\|\s*`([A-Z][A-Z0-9_]*)`\s*\|/gm)].map(m => m[1]));
  assert.deepEqual(unterschied(vorlage, readme), [], 'in .env.example, aber nicht in der README');
  assert.deepEqual(unterschied(readme, vorlage), [], 'in der README, aber nicht in .env.example');
});

test('jede Route der API ist beschrieben — und umgekehrt', () => {
  const app = fs.readFileSync(path.join(BE, 'app.js'), 'utf8');
  const code = new Set();
  for (const m of app.matchAll(/app\.use\(\s*'(\/api\/[a-z]+)'\s*,\s*require\('\.\/routes\/([a-z]+)'\)/g)) {
    const src = fs.readFileSync(path.join(BE, 'routes', `${m[2]}.js`), 'utf8');
    for (const r of src.matchAll(/router\.(get|post|put|patch|delete)\(\s*'([^']*)'/g)) {
      code.add(`${r[1].toUpperCase()} ${m[1]}${r[2] === '/' ? '' : r[2]}`);
    }
  }
  for (const m of app.matchAll(/app\.(get|post)\(\s*'(\/api\/[^']*)'/g)) code.add(`${m[1].toUpperCase()} ${m[2]}`);
  assert.ok(code.size > 20, `nur ${code.size} Routen gefunden — Einlesen fehlgeschlagen?`);
  const doku = new Set([...lies('Edeka.lager/backend/README.md')
    .matchAll(/^\|\s*(GET|POST|PUT|PATCH|DELETE)\s*\|\s*`([^`]+)`\s*\|/gm)].map(m => `${m[1]} ${m[2]}`));
  assert.deepEqual(unterschied(code, doku), [], 'im Code, aber nicht in der README');
  assert.deepEqual(unterschied(doku, code), [], 'in der README, aber nicht im Code');
});

test('jedes Skript in tools/ ist in tools/README.md beschrieben', () => {
  const readme = lies('tools/README.md');
  const fehlt = fs.readdirSync(path.join(WURZEL, 'tools')).filter(f => f.endsWith('.sh') && !readme.includes(f));
  assert.deepEqual(fehlt, []);
});

test('Pfade unter tools/ in der Doku gibt es — oder sie sind angekündigt', () => {
  const fehlt = [];
  for (const d of DOKS) for (const m of lies(d).matchAll(/\btools\/([a-z0-9.-]+\.sh)\b/g)) {
    if (!fs.existsSync(path.join(WURZEL, 'tools', m[1])) && !AUSSTEHEND.has(m[1])) fehlt.push(`${d}: tools/${m[1]}`);
  }
  assert.deepEqual(fehlt, []);
});

test('keine Server-Adresse und kein DuckDNS-Name in der Doku', () => {
  const funde = [];
  (function lauf(dir) {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      if (['node_modules', '.git'].includes(e.name)) continue;
      const p = path.join(dir, e.name);
      if (e.isDirectory()) { lauf(p); continue; }
      if (!e.name.endsWith('.md')) continue;
      const rel = path.relative(WURZEL, p);
      const text = fs.readFileSync(p, 'utf8');
      for (const m of text.matchAll(/\b(?:\d{1,3}\.){3}\d{1,3}\b/g)) {
        if (!['127.0.0.1', '0.0.0.0'].includes(m[0])) funde.push(`${rel}: Adresse ${m[0]}`);
      }
      for (const m of text.matchAll(/\b([a-z0-9-]+)\.duckdns\.org\b/gi)) {
        if (m[1].toLowerCase() !== 'www') funde.push(`${rel}: DuckDNS-Name ${m[0]}`);
      }
    }
  })(WURZEL);
  assert.deepEqual(funde, [], 'öffentliches Repository — bitte Platzhalter <server> bzw. <name>.duckdns.org benutzen');
});
__H1_TEST__
node --check "$T" >/dev/null 2>&1 || die "Syntaxfehler in $T"
if gruen test/unit/doku.test.js; then VORHER="grün"; else VORHER="rot"; fi
[ "$VORHER" = "rot" ] && ok "doku.test.js: vorher rot — die alte Doku stimmt nicht" \
                     || ok "doku.test.js: schon grün (erneuter Lauf)"

# ── 2  Doku ──────────────────────────────────────────────────────────
echo
echo "── Doku ────────────────────────────────────────────────────────"
cat > "$TMP/datei0" <<'__H1_BETRIEB__'
# Betriebshandbuch — EDEKA Lagerverwaltung

Alles, was man für den Betrieb auf dem Server braucht: nachsehen, neu starten,
aktualisieren, sichern, zurückspielen — und was zu tun ist, wenn etwas
ausfällt. Für die Entwicklung siehe `backend/README.md`, für die Gründe hinter
den Entscheidungen `ENTSCHEIDUNGEN.md`.

> **Dieses Repository ist öffentlich.** Hier stehen keine Geheimnisse, keine
> Server-Adresse und kein DuckDNS-Name — nur Platzhalter: `<server>` und
> `<name>.duckdns.org`. Ein Test (`test/unit/doku.test.js`) achtet darauf.

Befehle in grauen Kästen sind zum Ausführen gedacht. `journalctl -f` und
`systemctl status` warten auf Eingabe — nicht zusammen mit anderen Befehlen
einfügen; `q` bzw. `Strg+C` beendet nur die Anzeige, nie die App.

## Überblick

```
Browser ──HTTPS──▶ nginx, Port 443, Zertifikat von Let's Encrypt
                      │  http leitet auf https um; kural bleibt der
                      │  Standard-Server auf Port 80 und ist davon unberührt
                      ▼
                   App: systemd-Dienst edeka-lager (Node/Express),
                        lauscht nur auf 127.0.0.1:3000
                      ▼
                   MongoDB 7: Docker-Container edeka-mongo, nur 127.0.0.1:27017,
                        Daten in den Volumes edeka-mongo-daten und edeka-mongo-config
```

Zeitgesteuert:

| Was | Wann | Wodurch |
|---|---|---|
| Tagesabschluss | täglich 00:00 (Berlin) | in der App (node-cron); nach einem Ausfall holt die App ihn beim Start nach |
| Datensicherung mit Wiederherstellungsprobe | täglich 02:30 (Berlin), 14 bleiben | `edeka-sicherung.timer` |
| DuckDNS-Adresse aktuell halten | stündlich | `edeka-duckdns.timer` |
| Zertifikat verlängern | zweimal täglich, verlängert erst kurz vor Ablauf | `certbot.timer` |

## Wo liegt was

| Was | Wo |
|---|---|
| Code | `~/Eder`, Branch `main` |
| Einstellungen | `~/Eder/Edeka.lager/backend/.env` — Rechte 600, nie ins Repository |
| App-Dienst | `/etc/systemd/system/edeka-lager.service`, dazu `edeka-lager.service.d/10-docker.conf` (startet nach Docker) |
| Sicherungen | `~/edeka-sicherungen/<Datum_Uhrzeit>/` |
| Sicherungsdienst | `/etc/systemd/system/edeka-sicherung.service` und `.timer`, Skript `tools/sicherung.sh` |
| DuckDNS | Name und Token in `/etc/edeka/duckdns.env` (Rechte 600), Skript `tools/duckdns.sh` |
| nginx | `/etc/nginx/sites-available/edeka-lager` |
| Zertifikat | `/etc/letsencrypt/live/<name>.duckdns.org/` |
| Firewall | `/etc/iptables/rules.v4` |

## Läuft alles?

```bash
systemctl is-active docker edeka-lager edeka-sicherung.timer
sudo docker ps --format '{{.Names}}  {{.Status}}'
curl -s http://127.0.0.1:3000/api/health; echo
```

Erwartet: dreimal `active`, `edeka-mongo  Up …` und `"status":"ok"`.
Von außen: `https://<name>.duckdns.org` im Browser, Schloss neben der Adresse — am
besten auf dem Handy über mobile Daten, dann kommt die Anfrage wirklich von außen.

## Protokolle

```bash
journalctl -u edeka-lager -n 50 --no-pager
```

Laufend mitlesen (allein einfügen, `Strg+C` beendet nur die Anzeige):

```bash
journalctl -u edeka-lager -f
```

## Neu starten

```bash
sudo systemctl restart edeka-lager
```

Nie zusätzlich von Hand `npm start`: das zweite Exemplar bricht mit
`Kann nicht … lauschen: EADDRINUSE` ab.

## Neue Version einspielen

```bash
cd ~/Eder
git checkout main
git pull
sudo systemctl restart edeka-lager
curl -s http://127.0.0.1:3000/api/health; echo
```

Nur wenn sich `Edeka.lager/backend/package-lock.json` geändert hat, vor dem
Neustart die Abhängigkeiten erneuern:

```bash
cd ~/Eder/Edeka.lager/backend && npm ci
```

Im Browser danach `Strg+F5`, damit die neuen Seiten geladen werden.

## Zur vorigen Version zurück

Den schuldigen Commit finden und rückgängig machen — das erzeugt einen neuen
Commit, die Geschichte bleibt ehrlich:

```bash
cd ~/Eder
git log --oneline -10
git revert --no-edit <commit>
git push
sudo systemctl restart edeka-lager
```

## Datensicherung

Jede Nacht um 02:30 sichert `tools/sicherung.sh` jede Anwendungsdatenbank und
spielt die Sicherung sofort probeweise zurück: Dokumente und Indizes jeder
Sammlung werden mit dem Original verglichen. Nur geprüfte Sicherungen bleiben
liegen, die 14 neuesten.

Nachsehen:

```bash
journalctl -u edeka-sicherung -n 5 --no-pager
ls -l ~/edeka-sicherungen
```

Sofort eine Sicherung anlegen — etwa vor einem Eingriff:

```bash
sudo systemctl start edeka-sicherung.service
systemctl show -p Result --value edeka-sicherung.service
```

Erwartet: `success`.

### Zurückspielen

**Überschreibt die Datenbank.** Vorher eine frische Sicherung anlegen (oben),
dann:

```bash
sudo systemctl stop edeka-lager
sudo docker exec -i edeka-mongo mongorestore --archive --gzip --drop < ~/edeka-sicherungen/<Datum_Uhrzeit>/edeka_lager.archive.gz
sudo systemctl start edeka-lager
```

In jedem Sicherungsordner steht in `edeka_lager.inhalt`, wie viele Dokumente
jede Sammlung hatte — zum Vergleich nach dem Zurückspielen.

### Offen: eine Kopie außerhalb des Servers

Alle Sicherungen liegen auf **demselben** Server. Fällt er ganz aus, sind sie
mit weg. Bis das geregelt ist, von Zeit zu Zeit eine Sicherung auf den eigenen
Rechner holen (PowerShell):

```powershell
scp -r -i "$HOME\.ssh\oracle_private.key" ubuntu@<server>:~/edeka-sicherungen/<Datum_Uhrzeit> .
```

## Der MongoDB-Container

Die Daten liegen in den **benannten** Volumes `edeka-mongo-daten` und
`edeka-mongo-config`. Ein neuer Container mit denselben Volumes sieht dieselben
Daten. So wird er angelegt — genau so, sonst fehlen die Daten:

```bash
sudo docker run -d --name edeka-mongo --restart unless-stopped -p 127.0.0.1:27017:27017 -v edeka-mongo-daten:/data/db -v edeka-mongo-config:/data/configdb mongo:7
```

Aktualisieren innerhalb von MongoDB 7: App anhalten, frische Sicherung,
`sudo docker pull mongo:7`, alten Container anhalten und entfernen, neu anlegen
wie oben, App starten. Nie über eine Hauptversion springen (7 → 8), ohne die
Hinweise von MongoDB zur Aktualisierung gelesen zu haben.

## HTTPS, DuckDNS, Zertifikat

```bash
sudo certbot renew --dry-run
sudo systemctl start edeka-duckdns.service
journalctl -u edeka-duckdns -n 3 --no-pager
```

Neuen DuckDNS-Token eintragen: `sudo rm /etc/edeka/duckdns.env`, dann
`bash tools/apply-d4-zugang.sh` erneut — es fragt nach Name und Token.

## Firewall

Offen sind 22 (SSH), 80 (kural und die Prüfung durch Let's Encrypt) und 443
(die App). Zwei Ebenen müssen zusammenpassen: die Security List in der
Oracle-Konsole und `iptables` auf dem Server.

`/etc/iptables/rules.v4` nur **von Hand** um einzelne Zeilen ergänzen, und nie
`netfilter-persistent save` benutzen: das schriebe auch Dockers Regeln aus dem
laufenden Betrieb hinein, die beim nächsten Start gegen Docker arbeiten.

## Systemupdates

Ubuntu meldet beim Anmelden verfügbare Sicherheitsupdates. Einspielen:

```bash
sudo apt update && sudo apt upgrade
```

Steht danach `*** System restart required ***` im Anmeldetext, oder gibt es
die Datei `/var/run/reboot-required`, neu starten. Alle Dienste kommen von
selbst wieder — zweimal nachgewiesen:

```bash
sudo reboot
```

Danach „Läuft alles?“ prüfen.

## Wenn etwas nicht geht

### Die App antwortet nicht

```bash
systemctl is-active edeka-lager
journalctl -u edeka-lager -n 50 --no-pager
```

Was im Protokoll steht, und was zu tun ist:

| Meldung | Ursache und Abhilfe |
|---|---|
| `Kann nicht … lauschen: EADDRINUSE` | Ein von Hand gestarteter Server läuft noch — in dessen Fenster `Strg+C`, dann neu starten |
| `MongoDB Verbindungsfehler` | `sudo docker ps -a`; läuft `edeka-mongo` nicht: `sudo docker start edeka-mongo`, dann die App neu starten |
| `Start abgebrochen: TRUST_PROXY=true, aber HOST=…` | `HOST` aus der `.env` entfernen (Standard 127.0.0.1) |
| `JWT_SECRET` wird abgelehnt | ein langer, zufälliger Wert ist Pflicht — siehe „Schlüssel austauschen“ |
| `start-limit-hit` | fünf Abstürze in zwei Minuten: Ursache beheben, dann `sudo systemctl reset-failed edeka-lager` und `sudo systemctl start edeka-lager` |

### Die Sicherung ist fehlgeschlagen

```bash
journalctl -u edeka-sicherung -n 30 --no-pager
df -h ~
```

Häufige Gründe: der Container läuft nicht, die Platte ist voll, oder der
Wächter in `sicherung.sh` hat einen unsicheren Zielordner abgelehnt.

### Nach einem Kernel-Update kommt der Server nicht hoch

Oracle-Konsole → Compute → Instances → die Instanz → „Console connection“ oder
„Reboot“. Im GRUB-Menü unter „Advanced options“ den vorigen Kernel wählen.

### Niemand kann sich mehr anmelden

Wurde `JWT_SECRET` ausgetauscht? Dann ist das gewollt: alle melden sich einmal
neu an.

## Sicherheit

- **`.env` und Archive nie ins Repository.** Vom 06.07. bis 28.09.2026 lag ein
  ZIP mit einer `.env` darin öffentlich im Repo. Seit S1 lehnt
  `test/unit/keine-geheimnisse.test.js` versionierte Archive und
  `.env`-Dateien ab.
- **Telegram:** Das ursprüngliche Bot-Token wurde einmal mit dem Projekt
  weitergegeben. Existiert der Bot noch, bei `@BotFather` mit `/revoke` ein
  neues Token erzeugen.
- **SSH-Schlüssel mit Passphrase schützen** (PowerShell, einmalig):
  `ssh-keygen -p -f "$HOME\.ssh\oracle_private.key"`
- **Passwörter:** Die App verlangt mindestens 6 Zeichen. Für Admin-Konten
  deutlich längere wählen.

### Schlüssel austauschen (JWT_SECRET)

Nötig, wenn der Schlüssel bekannt geworden sein könnte. Alle Anmeldungen werden
ungültig. Der neue Wert erscheint nirgends auf dem Bildschirm:

```bash
cd ~/Eder/Edeka.lager/backend
node -e 'const fs = require("fs"), c = require("crypto"); const t = fs.readFileSync(".env", "utf8"); if (!/^\s*JWT_SECRET\s*=/m.test(t)) { console.error("JWT_SECRET fehlt in .env"); process.exit(1); } fs.writeFileSync(".env", t.replace(/^\s*JWT_SECRET\s*=.*$/m, "JWT_SECRET=" + c.randomBytes(48).toString("base64url")), { mode: 0o600 }); console.log("ausgetauscht");'
sudo systemctl restart edeka-lager
```

## Aufräumen (fällig ab 04.10.2026)

Nach einer Woche ohne Auffälligkeiten seit dem Umzug der Daten:

```bash
sudo docker rm edeka-mongo-alt
sudo docker volume ls
```

Die alten, namenlosen Volumes (lange Zeichenfolgen) erst ansehen, dann einzeln
entfernen — nie blind `docker volume prune`. `cloudflared` wird nicht mehr
gebraucht: `sudo apt remove cloudflared`. Auf GitHub die gemergten
Branches löschen.
__H1_BETRIEB__
cat > "$TMP/datei1" <<'__H1_ENTSCHEIDUNGEN__'
# Entscheidungen — EDEKA Lagerverwaltung

Warum die App so gebaut ist, wie sie ist. Jede Entscheidung mit dem Anlass,
der Wahl und dem, was daraus folgt. Wer etwas davon ändern will, liest zuerst
hier nach — viele Regeln sehen umständlich aus und verhindern einen Fehler,
der schon einmal passiert ist.

Die Skripte, mit denen jede Änderung eingespielt wurde, liegen in `tools/`.

---

## 1. Gleichzeitige Bestandsänderungen: optimistische Sperre (Phase E)

**Anlass:** Zwei Geräte ändern denselben Bestand; die spätere Änderung
überschrieb die frühere unbemerkt.
**Entscheidung:** Jede Änderung schickt die Version mit, die sie gesehen hat
(`updatedAt`, Pflicht). Passt sie nicht mehr, antwortet der Server mit 409.
**Folgen:** Kein Wert geht still verloren. Der Browser zeigt einen Konflikt an
und lädt den aktuellen Stand.

## 2. Anmeldegrenzen je Benutzer, mit einer Decke je Adresse (Phase E)

**Anlass:** Eine ganze Filiale teilt sich eine öffentliche Adresse. Eine Grenze
nur je Adresse sperrt alle, sobald einer sich oft vertippt.
**Entscheidung:** Zuerst eine Grenze je Benutzername (10), dann eine hohe Decke
je Adresse (100 in 15 Minuten, `LOGIN_IP_LIMIT`).
**Folgen:** Rateversuche auf ein Konto werden gebremst, die Filiale nicht. Die
Zähler liegen im Speicher und beginnen nach einem Neustart neu — für einen
einzelnen Server annehmbar.

## 3. CORS standardmäßig geschlossen (Phase E)

**Anlass:** Die Oberfläche kommt vom selben Server und braucht keine Freigabe.
**Entscheidung:** Fremde Origins nur über `CORS_ORIGINS`, leer ist die Regel.
**Folgen:** Keine fremde Seite kann die API aus dem Browser eines angemeldeten
Nutzers heraus lesen.

## 4. Nur JSON als Eingabe (Phase E)

**Anlass:** Der Parser für Formulardaten war eingebunden, aber ungenutzt — eine
zweite, ungeprüfte Tür.
**Entscheidung:** Kein `express.urlencoded`; das Anmeldeformular sendet JSON.
**Folgen:** Eine Eingabeform weniger, die geprüft werden muss.

## 5. Bestand: Anzeige sofort, Speichern gebündelt

**Anlass:** Schnelles Klicken auf ± über eine langsame Verbindung schickte
mehrere Anfragen mit veralteter Version — der Server meldete Konflikte, die
keine waren.
**Entscheidung:** Kein Sperren der Knöpfe. Die Anzeige ändert sich sofort; nach
400 ms Ruhe geht **eine** Anfrage mit dem Endwert. Anfragen je Produkt
nacheinander, jede mit der Version der vorigen Antwort (`createBestandsschreiber`
in `shared.js`).
**Folgen:** Wer wartet, merkt nichts. Echte Konflikte mit anderen Geräten
bleiben sichtbar.

## 6. Kein JavaScript im Markup (Phase F)

**Anlass:** helmet setzt `script-src-attr 'none'`. Alle 70 `onclick="…"` der
Seiten waren deshalb von Anfang an tot. Ein Kategoriename mit Anführungszeichen
konnte außerdem aus einem `onclick`-Text ausbrechen.
**Entscheidung:** Seitenskripte in `assets/*.js`; Knöpfe tragen
`data-action="name"`, ein einziger Listener am Dokument ruft die registrierte
Funktion. Die CSP bleibt streng: `script-src-attr 'none'`, und seit G1
`script-src 'self'` ohne `'unsafe-inline'`.
**Folgen:** Eingeschleustes HTML kann keinen Code ausführen. Tests
(`inline-handler`, `csp-markup`, `csp-skripte`) halten Markup und CSP zusammen.

## 7. Alles aus Daten durch `escapeHtml` (Phasen F und G)

**Anlass:** Rohdaten im HTML brechen die Darstellung — und sind die erste Stufe
eines Angriffs, sobald eine andere Schutzschicht fehlt. Ein Einheitenname kam
über einen Umweg ohne einziges Tag ins HTML.
**Entscheidung:** Jeder Wert in `innerHTML` ist maskiert oder nachweislich
harmlos. `test/unit/html-senken.test.js` verfolgt jeden Wert bis zur Senke —
und prüft sich selbst an absichtlich unsicheren Beispielen.
**Folgen:** Neuer Code mit Rohdaten im HTML fällt im Test auf, nicht beim Kunden.

## 8. Die App lauscht nur auf 127.0.0.1 (Phase D)

**Anlass:** Der Server lauschte auf allen Adressen. Mit `TRUST_PROXY=true` hätte
jeder Client seine Adresse selbst angeben können.
**Entscheidung:** Standard `HOST=127.0.0.1`. `TRUST_PROXY=true` zusammen mit
einer Adresse im Netz verweigert den Start. Ein Fehler beim Lauschen beendet
den Prozess, statt Erfolg zu melden.
**Folgen:** Erreichbar nur über den Proxy auf demselben Rechner. Die App sieht
die echte Adresse der Nutzer.

## 9. Betrieb über systemd (Phase D)

**Anlass:** Ein abgerissenes SSH beendete den von Hand gestarteten Server.
**Entscheidung:** Dienst `edeka-lager`: startet beim Booten nach Docker,
startet nach einem Absturz neu, gibt nach fünf Abstürzen in zwei Minuten auf.
**Folgen:** Unabhängig von jeder Sitzung. Nachgewiesen mit einem absichtlichen
`SIGKILL` und zwei echten Neustarts des Servers.

## 10. MongoDB mit benannten Volumes (Phase D)

**Anlass:** Die Daten lagen in einem namenlosen Volume. Jedes `docker rm` hätte
den nächsten Container mit einer leeren Datenbank starten lassen — am 17.09.
ist das einmal geschehen.
**Entscheidung:** Umzug nach `edeka-mongo-daten` und `edeka-mongo-config`, mit
Prüfung jeder Sammlung und automatischer Rückkehr bei jedem Fehler.
**Folgen:** Container lassen sich ersetzen, ohne Daten zu verlieren.

## 11. Sicherungen, die ihre Wiederherstellung beweisen (Phase D)

**Anlass:** Eine Sicherung, die nie zurückgespielt wurde, ist eine Hoffnung.
**Entscheidung:** Jede nächtliche Sicherung wird sofort in eine eigene Datenbank
zurückgespielt und je Sammlung verglichen — Dokumente und Indizes. Nur dann
bleibt sie liegen. Die ausgewerteten Formate stammen aus dem Quelltext von
mongo-tools 100.18.0, nicht aus dem Gedächtnis.
**Folgen:** Jede vorhandene Sicherung ist nachweislich brauchbar. Offen: eine
Kopie außerhalb des Servers.

## 12. Zugang: DuckDNS, vorhandenes nginx, Let's Encrypt (Phase D)

**Anlass:** Die Adresse des Übergangs-Tunnels änderte sich bei jedem Neustart.
**Entscheidung:** Gegen Cloudflare mit eigener Domain (Kosten) und Tailscale
(App auf jedem Gerät): kostenlos, und nginx lief schon für kural. Zertifikat
per `webroot`, damit certbot die nginx-Konfiguration nicht selbst umschreibt;
zuerst ein Probelauf gegen die Testumgebung.
**Folgen:** Feste Adresse mit HTTPS. Port 443 muss in der Oracle-Konsole und in
`iptables` offen sein.

## 13. Firewall-Regeln von Hand, nie `netfilter-persistent save` (Phase D)

**Anlass:** Auf einem Server mit Docker enthält die laufende Firewall auch
Dockers eigene Regeln.
**Entscheidung:** `rules.v4` wird um genau die nötige Zeile ergänzt — vor dem
abschließenden `REJECT` — und vorher mit `iptables-restore --test` geprüft.
**Folgen:** Nach dem Neustart gelten genau die gewollten Regeln, ohne Reste aus
dem Betrieb.

## 14. Veröffentlichtes Geheimnis: austauschen statt Geschichte umschreiben (S1)

**Anlass:** Ein ZIP mit einer `.env` lag von Juli bis September öffentlich im
Repository; darin ein echter `JWT_SECRET`. Die Suche im Text hatte es nicht
gefunden — ein ZIP ist binär.
**Entscheidung:** Den Schlüssel des Servers mit dem veröffentlichten vergleichen
(nur im Speicher) und bei Gleichheit austauschen; das ZIP entfernen; versionierte
Archive und `.env`-Dateien per Test verbieten. Die Git-Geschichte bleibt, wie
sie ist — nach dem Austausch steht dort nur ein wertloser Wert. So empfiehlt es
auch GitHub: erst austauschen, dann bei Bedarf bereinigen.
**Folgen:** Kein gültiges Geheimnis im Repository. Alte Commits bleiben lesbar.

---

## Arbeitsweise

- **Jede Änderung als Skript** in `tools/`: prüft den Ausgangszustand, legt
  zuerst einen Test an, der rot ist, ändert alles oder nichts und zeigt den Test
  danach grün.
- **Merge-Commits statt Squash**, damit jeder Schritt einzeln nachvollziehbar
  bleibt.
- **Testergebnisse am Exit-Code ablesen, nie am Text:** Das Ausgabeformat von
  `node --test` hängt von der Node-Version ab. S1 las `# fail 0` und meldete auf
  dem Server einen grünen Test als rot.
- **Am echten Quelltext prüfen, nicht am Gedächtnis:** Formate von Werkzeugen
  aus deren Quellen, Anker am echten Repository, Wirkung im echten Browser.
__H1_ENTSCHEIDUNGEN__
cat > "$TMP/datei2" <<'__H1_BACKEND__'
# EDEKA Lagerverwaltung — Backend

Node.js mit Express 5 und MongoDB (Mongoose). Liefert die API unter `/api` und
die Oberfläche aus `../frontend` aus.

- Betrieb auf dem Server: [`../BETRIEB.md`](../BETRIEB.md)
- Warum es so gebaut ist: [`../ENTSCHEIDUNGEN.md`](../ENTSCHEIDUNGEN.md)
- Tests im Einzelnen: [`test/README.md`](test/README.md)

## Entwicklung

Voraussetzungen: Node.js 20.19 oder neuer (CI prüft mit 22) und eine MongoDB.
Lokal am einfachsten mit Docker:

```bash
docker run -d --name edeka-mongo-dev -p 127.0.0.1:27017:27017 mongo:7
```

Dann:

```bash
cd Edeka.lager/backend
npm ci
cp .env.example .env      # ausfüllen, siehe unten — mindestens JWT_SECRET
npm run seed              # Standard-Kategorien und -Einheiten
npm run create-admin      # erster Admin: node createAdmin.js <name> <passwort>
npm run dev               # mit automatischem Neustart; ohne: npm start
```

Die Oberfläche ist danach unter `http://127.0.0.1:3000` erreichbar.

## Prüfen

```bash
npm run test:unit          # ohne Datenbank
npm run test:integration   # braucht MongoDB; jede Testdatei bekommt eine eigene Datenbank
npm run lint               # ESLint über Backend und Frontend
npm test                   # alles
```

Dieselben Prüfungen laufen bei jedem Push in GitHub Actions.

## Aufbau

| Ort | Inhalt |
|---|---|
| `server.js` | Start: Pflichtprüfungen (`JWT_SECRET`, `TRUST_PROXY`), Datenbank, Lauschen, Tagesabschluss |
| `app.js` | die Express-App: Sicherheits-Header und CSP, CORS, Routen, Fehlerbehandlung |
| `routes/` | die API, je Bereich eine Datei |
| `models/` | Mongoose-Schemata |
| `services/` | `dailyClose.js` (Tagesabschluss), `exportBuilder.js` (Excel/PDF), `telegram.js` |
| `middleware/auth.js` | prüft den Anmelde-Token und lädt den Benutzer aus der Datenbank |
| `lib/` | Eingabeprüfung, Anmeldegrenzen, Fehlerbehandlung |
| `createAdmin.js`, `seed.js` | Einrichtung: erster Admin, Standarddaten |

## Einstellungen (`.env`)

Vorlage: `.env.example`. Die echte `.env` kommt nie ins Repository.

| Name | Standard | Bedeutung |
|---|---|---|
| `PORT` | `3000` | Port der App |
| `HOST` | `127.0.0.1` | Adresse, auf der die App lauscht. `0.0.0.0` nur bewusst und nie zusammen mit `TRUST_PROXY=true` — das verweigert den Start |
| `NODE_ENV` | `development` | auf dem Server `production` (setzt der Dienst): Fehlermeldungen an den Browser bleiben allgemein |
| `CORS_ORIGINS` | leer | fremde Origins, kommagetrennt, die die API aus dem Browser lesen dürfen. Leer lassen, solange es kein fremdes Frontend gibt |
| `TRUST_PROXY` | `false` | `true` hinter einem Proxy auf derselben Maschine (nginx): die App sieht dann die echte Adresse der Nutzer |
| `LOGIN_IP_LIMIT` | `100` | Decke für Anmeldeversuche je Adresse in 15 Minuten; die Grenze je Benutzername (10) gilt getrennt |
| `MONGODB_URI` | — | **Pflicht.** Verbindung zur Datenbank |
| `JWT_SECRET` | — | **Pflicht**, lang und zufällig — sonst startet der Server nicht. Erzeugen: `node -e "console.log(require('crypto').randomBytes(48).toString('base64url'))"` |
| `JWT_EXPIRES_IN` | `7d` | wie lange eine Anmeldung gilt |
| `TELEGRAM_BOT_TOKEN` | leer | optional: Bot für den Tagesbericht |
| `TELEGRAM_CHAT_ID` | leer | optional: Kanal, Gruppe oder Chat für den Tagesbericht |
| `ADMIN_PASSWORD` | leer | nur für `npm run create-admin` ohne Passwort-Argument; leer bricht ab statt ein schwaches Passwort zu setzen |

## API

Außer `/api/health` und `/api/auth/login` verlangen alle Routen eine
Anmeldung; welche Rolle was darf, prüft die jeweilige Route in `routes/`.

| Methode | Pfad | Zweck |
|---|---|---|
| GET | `/api/health` | Lebenszeichen |
| POST | `/api/auth/register` | Benutzer anlegen (nur Admin) |
| POST | `/api/auth/login` | Anmelden |
| GET | `/api/auth/me` | eigenes Profil |
| PUT | `/api/auth/change-password` | eigenes Passwort ändern |
| GET | `/api/categories` | Kategorien |
| POST | `/api/categories` | Kategorie anlegen |
| PUT | `/api/categories/:id` | Kategorie ändern |
| DELETE | `/api/categories/:id` | Kategorie löschen |
| GET | `/api/units` | Einheiten |
| POST | `/api/units` | Einheit anlegen |
| PUT | `/api/units/:id` | Einheit ändern |
| DELETE | `/api/units/:id` | Einheit löschen |
| GET | `/api/products` | Produkte |
| POST | `/api/products` | Produkt anlegen |
| PUT | `/api/products/:id` | Produkt ändern |
| PATCH | `/api/products/:id/stock` | Bestand setzen — mit Version, 409 bei fremder Änderung |
| DELETE | `/api/products/:id` | Produkt löschen |
| GET | `/api/reports/today` | Berichte von heute |
| GET | `/api/reports/analytics` | Verlauf für die Diagramme |
| POST | `/api/reports/send-now` | Bericht jetzt erstellen (und per Telegram senden, falls eingerichtet) |
| GET | `/api/reports/history` | ein Eintrag je Tag |
| GET | `/api/reports/export` | Excel oder PDF |
| POST | `/api/reports/reset-stock` | Bestände zurücksetzen (Werkzeug im Admin-Menü) |
| POST | `/api/reports/reset-logs` | Berichte löschen (Werkzeug im Admin-Menü) |
| POST | `/api/reports/close-day` | Tagesabschluss von Hand |
| GET | `/api/reports/:id` | ein einzelner Bericht |
| GET | `/api/users` | Benutzer |
| GET | `/api/users/:id` | ein Benutzer |
| POST | `/api/users` | Benutzer anlegen |
| PUT | `/api/users/:id` | Benutzer ändern |
| PUT | `/api/users/:id/reset-password` | Passwort zurücksetzen |
| DELETE | `/api/users/:id` | Benutzer löschen |

## Tagesabschluss

Jede Nacht um 00:00 (Berlin) hält `services/dailyClose.js` den Stand des Tages
fest und setzt den Vortagesbestand jedes Produkts auf den aktuellen Bestand —
die Grundlage für den „Verbrauch“ des nächsten Tages. War der Server um
Mitternacht aus, holt die App den fehlenden Abschluss beim nächsten Start nach;
ein zweiter Lauf für denselben Tag ändert nichts.
__H1_BACKEND__
cat > "$TMP/datei3" <<'__H1_FRONTEND__'
# EDEKA Lagerverwaltung — Frontend

Statische Seiten, vom Backend ausgeliefert. Kein Build-Schritt und keine
externen Quellen: Schriften und Chart.js liegen in `assets/`.

## Seiten

| Seite | Zweck | Skript |
|---|---|---|
| `index.html` | Anmeldung | `assets/index.js` — lädt `shared.js` bewusst nicht |
| `dashboard.html` | Bestand und Produkte | `assets/dashboard.js` |
| `analytics.html` | Analyse: Heute und Verlauf, Excel/PDF | `assets/analytics.js` |
| `reports.html` | Tagesberichte | `assets/reports.js` |
| `users.html` | Benutzerverwaltung (Admins) | `assets/users.js` |

`assets/shared.js` enthält, was alle angemeldeten Seiten brauchen: Anmeldung
und `api()`, `escapeHtml`, die Seitenleiste, den Aktionsverteiler, den
Bestandsschreiber und den Export. Gestaltung in `assets/shared.css`.

## Regeln für neuen Code

Jede dieser Regeln hat einen Grund in `../ENTSCHEIDUNGEN.md` — und einen Test,
der sie erzwingt.

**1. Kein JavaScript im HTML.** Kein `<script>` ohne `src`, kein `onclick="…"`,
keine `javascript:`-Adresse. Die CSP führt nichts davon aus.
Tests: `frontend-struktur`, `inline-handler`, `csp-markup`, `csp-skripte`.

**2. Knöpfe über `data-action`.**

```html
<button type="button" data-action="produktLoeschen" data-id="${escapeHtml(p._id)}">🗑️</button>
```

```js
registriereAktionen({
  produktLoeschen: (el) => confirmDeleteProduct(el.dataset.id)
});
```

Ein einziger Listener am Dokument (in `shared.js`) ruft die registrierte
Funktion — auch für Zeilen, die erst später gerendert werden. Ein Name ohne
Registrierung erscheint in der Konsole als `[Aktionen] unbekannte Aktion`.
Test: `aktionen`.

**3. Alles aus Daten durch `escapeHtml(...)`** — auch Zahlen und ids. Ohne
Maskierung erlaubt sind nur fester Text, Zahlen aus Rechnungen und die
Formatierer `fmtNum`, `fmtDate`, `fmtTime`, `fmtRelative`, `fmtDateOnly`.
Tests: `frontend-escaping`, `html-senken` — er verfolgt jeden Wert bis in
`innerHTML`.

**4. Bestand nur über den Bestandsschreiber** (`setStock`, `adjustStock` in
`dashboard.js`): Anzeige sofort, gebündeltes Speichern, Version mitschicken.
Test: `stock-writer`.

**5. Schließen-Knöpfe von Dialogen** als
`<button type="button" aria-label="Schließen">` — mit der Tastatur erreichbar
und vorlesbar. Test: `schliessen-knoepfe`.
__H1_FRONTEND__
cat > "$TMP/datei4" <<'__H1_TOOLS__'
# tools/

Die selbstanwendenden Skripte des Projekts, in der Reihenfolge ihrer
Entstehung — dazu zwei Hilfsskripte, die im Betrieb laufen.

## Hilfsskripte im Betrieb

| Skript | Zweck |
| --- | --- |
| `sicherung.sh` | nächtliche Sicherung mit Wiederherstellungsprobe (`edeka-sicherung.timer`); Zurückspielen siehe `Edeka.lager/BETRIEB.md` |
| `duckdns.sh` | hält `<name>.duckdns.org` auf der Adresse des Servers (`edeka-duckdns.timer`) |

## Die Schritte

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
| `apply-e4.sh` | Aufräumen, Lint in der CI |
| `apply-e1-tests.sh`, `apply-e1-fixes.sh` | Optimistische Sperre für Bestandsänderungen |
| `apply-e2e3-tests.sh`, `apply-e2e3-fixes.sh` | Mengenbegrenzung je Benutzer, CORS nur auf Liste |
| `apply-e5-tests.sh`, `apply-e5-fixes.sh` | Eingaben vereinheitlicht, nur noch JSON |
| `apply-csp-emoji.sh` | Ursache der 70 toten Knöpfe (script-src-attr), emoji maskiert |
| `apply-stockwriter.sh` | Bestandsschreiber: Anzeige sofort, Speichern gebündelt |
| `apply-f1-extract.sh`, `apply-f1-lint.sh` | Seitenskripte aus dem HTML nach assets/, erste Lint-Befunde |
| `apply-f2-dashboard.sh` | Dashboard ohne Inline-Handler, Aktionsverteiler |
| `apply-f3-rest.sh` | Übrige Seiten ohne Inline-Handler, script-src-attr wieder zu |
| `apply-d1-betrieb.sh` | Nur 127.0.0.1, Proxy-Prüfung, Serverfehler im Protokoll |
| `apply-d2-dienst.sh` | App als systemd-Dienst |
| `apply-d3-daten.sh` | Geprüfte Sicherung, Daten in benannten Volumes |
| `apply-d4-zugang.sh` | HTTPS über DuckDNS, nginx und Let's Encrypt |
| `apply-s1-geheimnis.sh` | Veröffentlichtes ZIP mit .env: Schlüssel vergleichen und austauschen, ZIP entfernen |
| `apply-g1-haertung.sh` | script-src ohne unsafe-inline, echte Schließen-Knöpfe, Löschschutz der Sicherung |
| `apply-g2-html.sh` | Keine Rohdaten im HTML, Prüfer für alle Senken |
| `apply-h1-doku.sh` | Betriebshandbuch, Entscheidungen, aktuelle READMEs, Doku-Test |

Sie sind hier als Dokumentation des Wegs abgelegt, nicht zur erneuten
Ausführung: jedes hat seine Änderungen bereits angewendet und prüft das
beim Start selbst. `apply-c3-fixes.sh` in Version 1 lag daneben — die
gültige Fassung ist `apply-c3-fixes-v2.sh`.

`apply-s1-geheimnis.sh` meldete auf dem Server „Test … nicht grün“, obwohl er
grün war: es las das Textformat der Testausgabe, und das hängt von der
Node-Version ab. Seit H1 zählt dort — wie überall — der Exit-Code.
__H1_TOOLS__
cat > "$TMP/datei5" <<'__H1_ENV__'
# ── Server ────────────────────────────────────────────────────────────
PORT=3000
# Adresse, auf der der Server lauscht. Standard 127.0.0.1: nur diese
# Maschine — nginx läuft auf demselben Rechner. 0.0.0.0 nur, wenn die App
# bewusst direkt im Netz erreichbar sein soll, und dann NICHT zusammen mit
# TRUST_PROXY=true: diese Kombination verweigert den Start.
# HOST=127.0.0.1
NODE_ENV=development

# Fremde Origins, die die API aus dem Browser heraus lesen dürfen,
# kommagetrennt. LEER LASSEN, solange kein fremdes Frontend existiert:
# das eigene kommt von derselben Adresse und braucht keine Freigabe.
# Beispiel: CORS_ORIGINS=http://localhost:5500,https://test.example
CORS_ORIGINS=

# Hinter einem Reverse Proxy auf DIESER Maschine (nginx): true. Dann sieht
# die App die echte Adresse des Browsers — für die Anmeldegrenzen und das
# Anmeldeprotokoll — statt der des Proxys.
# Nur zusammen mit HOST=127.0.0.1 (Standard) — sonst startet der Server nicht.
TRUST_PROXY=false

# Decke für Login-Versuche je IP in 15 Minuten (Standard 100). Muss so
# hoch sein, dass eine ganze Filiale hinter einer gemeinsamen Adresse sie
# im Alltag nie erreicht. Die Grenze je Benutzername (10) gilt getrennt.
# LOGIN_IP_LIMIT=100

# ── Datenbank ─────────────────────────────────────────────────────────
MONGODB_URI=mongodb://localhost:27017/edeka_lager

# ── Anmeldung ─────────────────────────────────────────────────────────
# Pflicht, lang und zufällig — sonst verweigert der Server den Start.
# Erzeugen:
#   node -e "console.log(require('crypto').randomBytes(48).toString('base64url'))"
# Nie ins Repository, nie in ein Archiv (siehe BETRIEB.md, Sicherheit).
JWT_SECRET=ein-sehr-langer-zufaelliger-string-hier-einfuegen
# Wie lange eine Anmeldung gilt.
JWT_EXPIRES_IN=7d

# ── Telegram-Bericht (optional: Bot-Token + Chat-ID) ──────────────────
TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=

# ── Nur für: npm run create-admin (ohne Passwort-Argument) ────────────
# Wenn leer: createAdmin.js bricht mit einer Fehlermeldung ab, statt einen
# schwachen Standardwert zu benutzen. Alternativ: node createAdmin.js admin IhrPasswort
ADMIN_PASSWORD=
__H1_ENV__
# Erst alles vorbereiten, dann alles an seinen Platz.
if cmp -s "$TMP/datei0" "Edeka.lager/BETRIEB.md"; then ok "Edeka.lager/BETRIEB.md: schon aktuell"; else cp "$TMP/datei0" "Edeka.lager/BETRIEB.md"; ok "Edeka.lager/BETRIEB.md"; fi
if cmp -s "$TMP/datei1" "Edeka.lager/ENTSCHEIDUNGEN.md"; then ok "Edeka.lager/ENTSCHEIDUNGEN.md: schon aktuell"; else cp "$TMP/datei1" "Edeka.lager/ENTSCHEIDUNGEN.md"; ok "Edeka.lager/ENTSCHEIDUNGEN.md"; fi
if cmp -s "$TMP/datei2" "Edeka.lager/backend/README.md"; then ok "Edeka.lager/backend/README.md: schon aktuell"; else cp "$TMP/datei2" "Edeka.lager/backend/README.md"; ok "Edeka.lager/backend/README.md"; fi
if cmp -s "$TMP/datei3" "Edeka.lager/frontend/README.md"; then ok "Edeka.lager/frontend/README.md: schon aktuell"; else cp "$TMP/datei3" "Edeka.lager/frontend/README.md"; ok "Edeka.lager/frontend/README.md"; fi
if cmp -s "$TMP/datei4" "tools/README.md"; then ok "tools/README.md: schon aktuell"; else cp "$TMP/datei4" "tools/README.md"; ok "tools/README.md"; fi
if cmp -s "$TMP/datei5" "Edeka.lager/backend/.env.example"; then ok "Edeka.lager/backend/.env.example: schon aktuell"; else cp "$TMP/datei5" "Edeka.lager/backend/.env.example"; ok "Edeka.lager/backend/.env.example"; fi

# ── 3  S1: Exit-Code statt Textformat ────────────────────────────────
echo
echo "── S1 berichtigen ──────────────────────────────────────────────"
python3 - "$S1" <<'__H1_PY__'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
paare = [
  ("""ROT=$( cd "$BE" && node --test test/unit/keine-geheimnisse.test.js 2>&1 | grep -cE '^# fail [1-9]' || true )""",
   """# Exit-Code statt Textformat: TAP oder spec hängt von der Node-Version ab.
ROT=0; ( cd "$BE" && node --test test/unit/keine-geheimnisse.test.js >/dev/null 2>&1 ) || ROT=1"""),
  ("""GRUEN=$( cd "$BE" && node --test test/unit/keine-geheimnisse.test.js 2>&1 | grep -cE '^# fail 0' || true )""",
   """GRUEN=0; ( cd "$BE" && node --test test/unit/keine-geheimnisse.test.js >/dev/null 2>&1 ) && GRUEN=1"""),
]
schon = all(neu in s for _, neu in paare)
if schon:
    print("schon")
    sys.exit(0)
for alt, neu in paare:
    if s.count(alt) != 1:
        print("unerwartet")
        sys.exit(1)
    s = s.replace(alt, neu)
open(p, 'w', encoding='utf-8').write(s)
print("berichtigt")
__H1_PY__
bash -n "$S1" || die "$S1 ist nach der Änderung syntaktisch ungültig"
ok "$S1: liest den Exit-Code statt des Textformats"

# ── 4  Nachweise ─────────────────────────────────────────────────────
echo
echo "── Nachweise ───────────────────────────────────────────────────"
gruen test/unit/doku.test.js || { ( cd "$BE" && node --test test/unit/doku.test.js 2>&1 | grep -vE '^\s*$' | tail -40 ); die "doku.test.js ist nicht grün"; }
if [ "$VORHER" = "rot" ]; then ok "doku.test.js: vorher rot, jetzt grün"; else ok "doku.test.js: grün"; fi

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
echo "── Danach ──────────────────────────────────────────────────────"
echo
echo "    mkdir -p tools && mv $SELBST tools/"
echo "    git add Edeka.lager tools/README.md $S1 tools/$SELBST"
echo "    git commit -m 'Phase H Schritt 1: Betriebshandbuch, Entscheidungen, aktuelle READMEs, Doku-Test'"
echo "    git push -u origin phase-h1"
echo
echo "  Kein Neustart nötig — nur Dokumentation."
echo
