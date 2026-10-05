# tools/

Die selbstanwendenden Skripte des Projekts, in der Reihenfolge ihrer
Entstehung — dazu die Hilfsskripte für den Betrieb.

## Hilfsskripte im Betrieb

| Skript | Zweck |
| --- | --- |
| `sicherung.sh` | nächtliche Sicherung mit Wiederherstellungsprobe (`edeka-sicherung.timer`); Zurückspielen siehe `Edeka.lager/BETRIEB.md` |
| `duckdns.sh` | hält `<name>.duckdns.org` auf der Adresse des Servers (`edeka-duckdns.timer`) |
| `extern-sicherung.sh` | verschlüsselte Kopie jeder geprüften Sicherung ins private Sicherungs-Repository (`edeka-extern.service`, nach jeder erfolgreichen Sicherung) |
| `alarm.sh` | Lebenszeichen und Fehlermeldungen an Healthchecks.io (Herzschlag, Zertifikat, nach Sicherung und Kopie) |
| `abnahme.sh` | läuft alles? Eine Prüfung über den ganzen Betrieb — liest nur, jede Zeile ✓ oder ✗ |

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
| `apply-h3-extern.sh` | Kopie außer Haus: verschlüsselt in ein privates GitHub-Repository |
| `apply-h2-alarm.sh` | Überwachung von außen: Healthchecks.io als Totmannschalter |
| `apply-h4-abschluss.sh` | Aufräumen, Systemupdates, Endabnahme |

Sie sind hier als Dokumentation des Wegs abgelegt, nicht zur erneuten
Ausführung: jedes hat seine Änderungen bereits angewendet und prüft das
beim Start selbst. `apply-c3-fixes.sh` in Version 1 lag daneben — die
gültige Fassung ist `apply-c3-fixes-v2.sh`.

`apply-s1-geheimnis.sh` meldete auf dem Server „Test … nicht grün“, obwohl er
grün war: es las das Textformat der Testausgabe, und das hängt von der
Node-Version ab. Seit H1 zählt dort — wie überall — der Exit-Code.
