# Tests

## Ausführen

```bash
cd Edeka.lager/backend

npm run test:unit          # schnell, keine Datenbank nötig
npm run test:integration   # braucht eine laufende MongoDB
npm test                   # alles
npm run test:coverage      # mit Abdeckungsbericht
```

## Datenbanken für die Integrationstests

`MONGODB_TEST_URI` ist eine **Vorlage**, keine feste Datenbank. Standard ist
`mongodb://127.0.0.1:27017/edeka_lager_test`. Jede Testdatei bekommt daraus
ihre eigene Datenbank, abgeleitet aus dem Dateinamen:

| Datei                                     | Datenbank                        |
| ----------------------------------------- | -------------------------------- |
| `test/integration/auth.test.js`           | `edeka_auth_test`                |
| `test/integration/daily-close.test.js`    | `edeka_daily_close_test`         |
| `test/integration/analytics.test.js`      | `edeka_analytics_test`           |

Der Grund: `node --test` startet jede Datei in einem eigenen Prozess und
führt mehrere davon gleichzeitig aus. Mit einer gemeinsamen Datenbank löschte
jede Datei in `beforeEach` die Daten der anderen. Auf einer Maschine mit
einem Kern fiel das nie auf, auf einem Runner mit vier Kernen sofort.

Jede Datenbank wird am Ende ihres Laufs verworfen. Zum Nachsehen nach einem
Fehlschlag:

```bash
KEEP_TEST_DB=1 npm run test:integration
```

Der abgeleitete Name endet immer auf `_test`; andernfalls bricht
`test/helpers/db.js` ab, bevor überhaupt verbunden wird. Die Ableitung selbst
ist in `test/unit/db-name.test.js` abgesichert.

Telegram wird in Tests nie kontaktiert: `TELEGRAM_BOT_TOKEN` ist leer gesetzt,
wodurch `sendTelegram()` sofort ohne Netzwerkaufruf abbricht.
