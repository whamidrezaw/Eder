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
| `apply-e4.sh` | Aufräumen, Lint in der CI |
| `apply-e1-tests.sh`, `apply-e1-fixes.sh` | Optimistische Sperre für Bestandsänderungen |
| `apply-e2e3-tests.sh`, `apply-e2e3-fixes.sh` | Mengenbegrenzung je Benutzer, CORS nur auf Liste |

Sie sind hier als Dokumentation des Wegs abgelegt, nicht zur erneuten
Ausführung: jedes hat seine Änderungen bereits angewendet und prüft das
beim Start selbst. `apply-c3-fixes.sh` in Version 1 lag daneben — die
gültige Fassung ist `apply-c3-fixes-v2.sh`.
