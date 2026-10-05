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
