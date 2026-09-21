'use strict';
//
// Alle Mengenbegrenzungen an einer Stelle.
//
// Die Begrenzer werden EINMAL beim Laden erzeugt und gelten dann für alle
// Anfragen — ihr Zählerstand lebt im Prozess. Deshalb dürfen sie nie
// innerhalb eines Handlers neu angelegt werden.
//
const { rateLimit } = require('express-rate-limit');

const MINUTE        = 60 * 1000;
const VIERTELSTUNDE = 15 * MINUTE;

function zahlAusUmgebung(name, standard) {
  const n = Number(process.env[name]);
  return Number.isInteger(n) && n > 0 ? n : standard;
}

// Unverändert übernommen: index.html wartet auf genau diesen 429 und zeigt
// dazu eine eigene Meldung an.
const LOGIN_NACHRICHT = {
  message: 'Zu viele Login-Versuche. Bitte versuchen Sie es in einigen Minuten erneut.'
};

// ── Login, Stufe 1: je Benutzername ─────────────────────────────────
// Schützt das einzelne Konto gegen Durchprobieren. Der Name wird wie im
// User-Schema kleingeschrieben und getrimmt — sonst bekäme "ANNA" einen
// frischen Topf mit zehn neuen Versuchen für dasselbe Konto.
const loginJeName = rateLimit({
  windowMs: VIERTELSTUNDE,
  limit: 10,
  standardHeaders: true,
  legacyHeaders: false,
  message: LOGIN_NACHRICHT,
  keyGenerator: (req) => 'login-name:' + String(req.body?.username ?? '').toLowerCase().trim()
});

// ── Login, Stufe 2: Decke je IP ─────────────────────────────────────
// Bremst das Streuen über viele Konten von einer Adresse aus. Hoch genug,
// dass eine Filiale hinter einer gemeinsamen Adresse sie im Alltag nie
// erreicht. Standard 100; im Test über LOGIN_IP_LIMIT niedriger gestellt.
// Die Standard-Schlüsselbildung nutzt req.ip und beachtet damit
// TRUST_PROXY aus app.js.
const loginJeIp = rateLimit({
  windowMs: VIERTELSTUNDE,
  limit: zahlAusUmgebung('LOGIN_IP_LIMIT', 100),
  standardHeaders: true,
  legacyHeaders: false,
  message: LOGIN_NACHRICHT
});

// ── Aufwendige Aktionen: je Benutzer ────────────────────────────────
// Diese Begrenzer stehen HINTER auth — erst dort gibt es req.user.
function jeBenutzer(bereich, limit, text) {
  return rateLimit({
    windowMs: MINUTE,
    limit,
    standardHeaders: true,
    legacyHeaders: false,
    message: { message: text },
    keyGenerator: (req) => bereich + ':' + String(req.user?._id ?? 'ohne-anmeldung')
  });
}

// send-now schreibt jedes Mal eine vollständige Momentaufnahme und ruft
// Telegram; export baut eine komplette Excel- oder PDF-Datei.
const sendNowJeBenutzer = jeBenutzer('send-now', 10,
  'Zu viele Berichte in kurzer Zeit. Bitte eine Minute warten.');
const exportJeBenutzer  = jeBenutzer('export', 10,
  'Zu viele Exporte in kurzer Zeit. Bitte eine Minute warten.');

module.exports = { loginJeName, loginJeIp, sendNowJeBenutzer, exportJeBenutzer };
