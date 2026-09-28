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
