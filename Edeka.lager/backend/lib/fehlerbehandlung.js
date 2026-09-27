'use strict';
//
// Globaler Fehler-Handler der App — vorher inline in app.js. Eigene Datei,
// damit er ohne Server und ohne Datenbank testbar ist
// (test/unit/fehlerbehandlung.test.js).
//
// همه‌ی روت‌ها حالا خطاهای async را به اینجا پاس می‌دهند (یا Express 5
// به‌صورت خودکار reject شدن یک async handler را به اینجا می‌فرستد) —
// یک نقطه‌ی واحد برای تعیین status code درست و مخفی‌کردن جزئیات داخلی
// در production، به‌جای تکرار همان منطق در تک‌تک روت‌ها.
// Der Parameter next wird hier nicht benutzt, MUSS aber stehen bleiben:
// Express erkennt einen Fehler-Handler an der Anzahl seiner Parameter.
// Ohne den vierten Parameter ist das hier eine ganz normale Middleware
// und Fehler laufen stumm daran vorbei.
function fehlerbehandlung(err, req, res, next) {
  let status = err.status || err.statusCode || 500;
  let message = err.message || 'Interner Serverfehler';

  // خطاهای شناخته‌شده‌ی Mongoose → status code درست به‌جای 500 عمومی
  if (err.name === 'CastError') {
    status = 400;
    message = 'Ungültige ID';
  } else if (err.name === 'ValidationError') {
    status = 400;
    message = Object.values(err.errors || {}).map(e => e.message).join(', ') || 'Ungültige Eingabe';
  } else if (err.code === 11000) {
    status = 409;
    message = 'Dieser Eintrag existiert bereits';
  }

  // Serverfehler IMMER protokollieren, auch in production — bisher nur
  // außerhalb davon, ein 500er im Laden hinterließ also keine Spur.
  // Unter systemd landet das im Journal (journalctl -u edeka-lager).
  // 4xx sind Fehler des Clients und bleiben in production still.
  if (status >= 500 || process.env.NODE_ENV !== 'production') {
    console.error(`[ERROR] ${req.method} ${req.path}:`, err.stack || err.message);
  }

  res.status(status).json({
    message: (status === 500 && process.env.NODE_ENV === 'production')
      ? 'Interner Serverfehler'
      : message
  });
}

module.exports = fehlerbehandlung;
