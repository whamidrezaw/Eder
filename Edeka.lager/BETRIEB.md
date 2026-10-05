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
| Verschlüsselte Kopie außer Haus | nach jeder erfolgreichen Sicherung | `edeka-extern.service` |
| Lebenszeichen der App über die öffentliche Adresse | alle 5 Minuten | `edeka-herzschlag.timer` |
| Restlaufzeit des Zertifikats | täglich 09:00 (Berlin) | `edeka-zertifikat.timer` |
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
| Kopie außer Haus | privates GitHub-Repository `<sicherungs-repo>`, Arbeitskopie `~/edeka-extern`, Skript `tools/extern-sicherung.sh` |
| Einstellungen der Kopie | `/etc/edeka/extern.env` (Rechte 600): Repository, öffentlicher Schlüssel, Deploy-Key `~/.ssh/edeka_extern_ed25519` |
| Überwachung | Healthchecks.io, vier Prüfungen; Ping-Adressen in `/etc/edeka/alarm.env` (Rechte 640, root:ubuntu); Skript `tools/alarm.sh` |
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

## Überwachung und Alarme

Healthchecks.io erwartet vier Lebenszeichen von diesem Server. Bleibt eines aus
— auch weil der Server ganz ausgefallen ist — oder meldet der Server einen
Fehler, schickt Healthchecks.io eine Nachricht: per E-Mail und, wenn dort
eingerichtet, per Telegram. Auf diesem Server liegt dafür kein Bot-Token.

| Prüfung | erwartet | bei Alarm zuerst |
|---|---|---|
| `edeka-sicherung` | täglich nach 02:30 (Berlin), spätestens 1 Stunde später | „Die Sicherung ist fehlgeschlagen“ |
| `edeka-extern` | nach jeder Sicherung, spätestens 2 Stunden später | „Die Kopie außer Haus ist fehlgeschlagen“ |
| `edeka-app` | alle 5 Minuten über die **öffentliche** Adresse, spätestens 10 Minuten später | „Die App antwortet nicht“ |
| `edeka-zertifikat` | täglich 09:00, mindestens 14 Tage Restlaufzeit | `sudo certbot renew --dry-run` |

Die Meldungen der Sicherungsdienste enthalten ihre letzten Protokollzeilen.
Vom Protokoll der App verlässt nichts den Server — die Meldung nennt nur den
Befehl, mit dem man auf dem Server nachsieht.

Probealarm — kommt die Nachricht an?

```bash
bash ~/Eder/tools/alarm.sh probe
```

Die Entwarnung folgt mit dem nächsten Herzschlag, spätestens nach 5 Minuten —
sofort mit `sudo systemctl start edeka-herzschlag.service`.

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

### Die Kopie außer Haus

Nach jeder erfolgreichen Sicherung schiebt `tools/extern-sicherung.sh` jede
geprüfte Sicherung, die dort noch fehlt, verschlüsselt in ein privates
GitHub-Repository — verpasste Nächte werden nachgeholt. Verschlüsselt wird mit
dem **öffentlichen** age-Schlüssel: entschlüsseln kann nur, wer den privaten
hat. Dieser Server kann es nicht.

```bash
systemctl show -p Result --value edeka-extern.service
journalctl -u edeka-extern -n 3 --no-pager
```

Erwartet: `success`, und im Protokoll `im Repository bestätigt` oder `nichts Neues`.

### Wenn der Server verloren ist

1. Einen neuen Server nach diesem Handbuch einrichten: App und MongoDB-Container.
2. Das Sicherungs-Repository mit dem **eigenen** GitHub-Zugang holen:
   `git clone git@github.com:<sicherungs-repo>.git sicherung`
3. Die Datei mit dem privaten Schlüssel (die Zeile `AGE-SECRET-KEY-…`) kurz auf
   den Server legen, zum Beispiel als `~/schluessel.txt`, dann entschlüsseln und
   prüfen:

   ```bash
   cd sicherung/<Datum_Uhrzeit>
   age -d -i ~/schluessel.txt -o edeka_lager.archive.gz edeka_lager.archive.gz.age
   sha256sum -c edeka_lager.sha256
   ```

   Erwartet: `edeka_lager.archive.gz: OK`.
4. Zurückspielen wie oben unter „Zurückspielen“ — mit dieser Datei.
5. Den privaten Schlüssel wieder vom Server löschen: `shred -u ~/schluessel.txt`

Zusätzlich lässt sich jederzeit von Hand eine Sicherung auf den eigenen Rechner
holen (PowerShell):

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

### Die Kopie außer Haus ist fehlgeschlagen

```bash
journalctl -u edeka-extern -n 20 --no-pager
```

Häufige Gründe: keine Verbindung zu GitHub; der Deploy-Key wurde entfernt oder
hat kein Schreibrecht mehr; das Repository wurde umbenannt. Danach
`bash tools/apply-h3-extern.sh` erneut — es prüft alles und übernimmt, was
schon stimmt. Die lokale Sicherung ist davon nicht betroffen.

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
- **Der private age-Schlüssel** (`AGE-SECRET-KEY-…`) liegt nur beim Betreiber,
  an zwei Orten — etwa im Passwortmanager und offline auf einem USB-Stick oder
  auf Papier. Ohne ihn ist die Kopie außer Haus wertlos, und niemand kann ihn
  wiederherstellen.
- **Der Deploy-Key** dieses Servers darf nur ins Sicherungs-Repository
  schreiben. Wer den Server übernimmt, könnte dort aber auch löschen. Mit
  GitHub Pro — für Studierende im GitHub Student Developer Pack enthalten —
  lässt sich `main` dieses Repositorys gegen Force-Push und Löschen schützen.
- **Die Ping-Adressen** in `/etc/edeka/alarm.env` sind Geheimnisse: Wer sie
  kennt, kann falsche Entwarnungen schicken. Sie kommen nie ins Repository. Die
  Prüfungen nehmen nur POST an — ein bloß aufgerufener Link zählt nicht.

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
