# Tests

## Ausführen

```bash
cd Edeka.lager/backend

npm run test:unit          # schnell, keine Datenbank nötig
npm run test:integration   # braucht eine laufende MongoDB
npm test                   # alles
npm run test:coverage      # mit Abdeckungsbericht
```

## Datenbank für die Integrationstests

Standard ist `mongodb://127.0.0.1:27017/edeka_lager_test`. Abweichend:

```bash
MONGODB_TEST_URI=mongodb://127.0.0.1:27017/mein_test npm run test:integration
```

Der Name **muss auf `_test` enden** — sonst bricht `test/helpers/db.js` ab,
bevor überhaupt verbunden wird. Die Tests leeren nach jedem Fall alle
Collections; dieser Guard verhindert, dass das je die echte Datenbank trifft.

Telegram wird in Tests nie kontaktiert: `TELEGRAM_BOT_TOKEN` ist leer gesetzt,
wodurch `sendTelegram()` sofort ohne Netzwerkaufruf abbricht.

## Warum manche Tests rot sind

Sechs Tests schlagen absichtlich fehl. Sie beschreiben Fehler, die in
**Batch A** behoben werden — sie sind der Beweis, dass die Fehler existieren,
und werden nach den Korrekturen grün. Jeder davon ist im Quelltext mit
`── ROT:` markiert.

Ein Test, der nach einer Korrektur grün wird, ist der Nachweis. Ein Test, der
von Anfang an grün ist, beweist nichts über die Korrektur.
