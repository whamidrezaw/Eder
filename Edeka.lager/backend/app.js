// dotenv wird bewusst NICHT hier geladen: server.js tut das, bevor es
// diese Datei verlangt, und die Tests setzen ihre Werte in
// test/helpers/env.js. Ein zweiter Aufruf änderte nichts und erzeugte
// nur eine zweite Meldung beim Start.
const express  = require('express');
const cors     = require('cors');
const helmet   = require('helmet');
const path     = require('path');

const app = express();

// ── Trust Proxy ──────────────────────────────────────────────────
// اگر پشت یک reverse proxy واقعی (nginx, Caddy, ...) دیپلوی می‌شود، این
// env را روی true بگذارید تا req.ip واقعاً IP کلاینت باشد نه IP پروکسی.
// پیش‌فرض false است: هدر X-Forwarded-For هرگز کورکورانه اعتماد نمی‌شود،
// چون هر کلاینتی می‌تواند این هدر را جعل کند (ببینید routes/auth.js).
if (String(process.env.TRUST_PROXY || '').toLowerCase() === 'true') {
  app.set('trust proxy', 1);
}

// ── Security ─────────────────────────────────────────────────────
// همه‌ی فایل‌های فرانت‌اند (فونت + Chart.js) اکنون لوکال سرو می‌شوند،
// پس دیگر نیازی به بازکردن CSP روی دامنه‌های خارجی (Google Fonts,
// jsDelivr) نیست — این هم امن‌تر است هم بدون وابستگی به اینترنت کار می‌کند.
app.use(helmet({
  contentSecurityPolicy: {
    directives: {
      defaultSrc:  ["'self'"],
      scriptSrc:   ["'self'", "'unsafe-inline'"],
      // script-src-attr ausdrücklich 'none': kein onclick="…" im Markup wird
      // ausgeführt. Bis Phase F stand hier vorübergehend 'unsafe-inline', weil
      // das Frontend seine Knöpfe mit solchen Attributen baute; seit Phase F
      // hängt jeder Knopf an data-action (shared.js). Ausdrücklich gesetzt statt
      // der Voreinstellung von helmet überlassen: eine neue Version soll das
      // nicht still ändern können. csp-markup.test.js hält CSP und Markup
      // zusammen.
      scriptSrcAttr: ["'none'"],
      styleSrc:    ["'self'", "'unsafe-inline'"],
      imgSrc:      ["'self'", "data:"],
      connectSrc:  ["'self'"],
      fontSrc:     ["'self'", "data:"],
      objectSrc:   ["'none'"],
      baseUri:     ["'self'"],
      formAction:  ["'self'"],
      frameAncestors: ["'none'"],
      upgradeInsecureRequests: process.env.NODE_ENV === 'production' ? [] : null
    }
  },
  crossOriginEmbedderPolicy: false   // برای Excel/PDF download
}));

// ── CORS ─────────────────────────────────────────────────────────
// CORS entscheidet, welche ANDEREN Websites aus dem Browser heraus die
// Antworten dieser API lesen dürfen. Es schützt NICHT den Server: eine
// Anfrage aus einem Skript oder mit curl kümmert sich nicht darum.
//
// Die frühere Begründung für "alle Origins" bleibt richtig: angemeldet
// wird über einen Authorization-Header, nicht über ein Cookie, und das
// Token in sessionStorage ist für fremde Seiten unerreichbar. Das
// Schließen hier ist Verteidigung in der Tiefe, kein offenes Leck.
//
// Das eigene Frontend kommt von derselben Adresse und braucht gar keine
// Freigabe — der Browser prüft CORS nur zwischen VERSCHIEDENEN Origins.
// Es läuft also über IP, Domain und jeden Port weiter, ohne dass etwas
// in .env stehen muss. Das war das Ziel der alten Regel; es bleibt.
//
// Wer doch eine fremde Origin braucht, etwa einen eigenen Entwicklungs-
// server, trägt sie kommagetrennt in CORS_ORIGINS ein.
//
// credentials:true bleibt bewusst weg: es gibt keine Cookies, und die
// Option würde nur ein künftiges Risiko öffnen.
const erlaubteOrigins = String(process.env.CORS_ORIGINS || '')
  .split(',')
  .map(s => s.trim())
  .filter(Boolean);

app.use(cors({
  // Ohne Origin-Header (gleiche Adresse, curl, Server-zu-Server) gibt es
  // nichts zu entscheiden. Ist eine gesetzt, zählt allein die Liste.
  origin: (origin, callback) => callback(null, !origin || erlaubteOrigins.includes(origin))
}));

// ── Body Parsing ─────────────────────────────────────────────────
// Nur JSON. Das Frontend schickt ausschließlich JSON — api() in
// shared.js und das Login-Formular in index.html. Der frühere
// urlencoded-Parser wurde von niemandem gebraucht, verarbeitete aber
// jeden solchen Körper VOR jeder Anmeldung mit qs. body-parser 2 nutzt
// qs auch bei extended:false; nur das Entfernen nimmt qs aus dem Weg.
app.use(express.json({ limit: '10kb' }));

// In Express 5 bleibt req.body undefined, wenn kein Parser den Körper
// gelesen hat — in Express 4 war es {}. Routen wie /login zerlegen
// req.body direkt und stürzten dann mit einem TypeError ab: aus einem
// Fehler des Aufrufers (400) wurde ein Serverfehler (500), samt
// Stacktrace im Log und ohne Anmeldung auslösbar. Hier wird der
// Express-4-Zustand wiederhergestellt, für alle Routen auf einmal.
app.use((req, res, next) => {
  if (req.body === undefined) req.body = {};
  next();
});

// ── Static Frontend ───────────────────────────────────────────────
app.use(express.static(path.join(__dirname, '../frontend')));

// ── API Routes ────────────────────────────────────────────────────

// ── Grundsicherung gegen Mongo-Operatoren ─────────────────────────
// Muss nach express.json() und vor den API-Routen stehen.
app.use(require('./lib/sanitize').rejectMongoOperators);

app.use('/api/auth',       require('./routes/auth'));
app.use('/api/products',   require('./routes/products'));
app.use('/api/reports',    require('./routes/reports'));
app.use('/api/users',      require('./routes/users'));
app.use('/api/categories', require('./routes/categories'));
app.use('/api/units',      require('./routes/units'));

// ── Health Check ──────────────────────────────────────────────────
app.get('/api/health', (req, res) => {
  res.json({
    status:    'ok',
    uptime:    Math.floor(process.uptime()),
    timestamp: new Date().toISOString()
  });
});

// ── SPA Fallback (Express 5 Syntax) ───────────────────────────────
app.get('/{*path}', (req, res) => {
  res.sendFile(path.join(__dirname, '../frontend/index.html'));
});

// ── Global Error Handler ──────────────────────────────────────────
// Steht in lib/fehlerbehandlung.js, damit er Tests hat. Muss die letzte
// Middleware bleiben: nur so erreichen ihn die Fehler aller Routen.
app.use(require('./lib/fehlerbehandlung'));

// ── Export ───────────────────────────────────────────────────────
// Diese Datei baut die Express-App nur auf. Sie verbindet sich NICHT mit
// der Datenbank, startet KEINEN Listener und plant KEINEN Cron-Job — das
// macht server.js. Dadurch kann die App im Test geladen werden, ohne dass
// dabei ein echter Server auf Port 3000 und der Mitternachts-Cron starten.
//
// Hinweis: 'mongoose' und 'scheduleDailyClose' werden hier eventuell noch
// importiert, aber nicht mehr benutzt. Das ist Absicht — der Kopf der Datei
// bleibt für diesen Schritt unangetastet (kleinstmögliche Änderung).
// Aufräumen erfolgt in Batch C.
module.exports = app;
