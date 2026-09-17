'use strict';
//
// Reine Prüffunktionen ohne Seiteneffekte. Bewusst frei von Express und
// Mongoose, damit sie ohne Datenbank und ohne Server testbar sind.
//

/**
 * Datum im Format JJJJ-MM-TT. Gibt den geprüften String zurück, sonst null.
 *
 * Lehnt alles ab, was kein echter String ist — insbesondere Objekte wie
 * { $ne: null }. Genau dieser Wert hat in Batch B die gesamte Historie
 * gelöscht, weil er ungeprüft in einen Mongo-Filter gewandert ist.
 */
function parseIsoDate(value) {
  if (typeof value !== 'string') return null;
  const s = value.trim();
  if (!/^\d{4}-\d{2}-\d{2}$/.test(s)) return null;
  const [y, m, d] = s.split('-').map(Number);
  const probe = new Date(Date.UTC(y, m - 1, d));
  if (probe.getUTCFullYear() !== y || probe.getUTCMonth() !== m - 1 || probe.getUTCDate() !== d) {
    return null; // z. B. 2026-02-30
  }
  return s;
}

/**
 * Bestandswert. Gibt die Zahl zurück, sonst null.
 *
 * Wichtig ist die Typprüfung VOR Number(): Number([]) ist 0 und Number(["5"])
 * ist 5. Ohne diese Prüfung setzt ein leeres Array den Bestand still auf 0 —
 * so war es vor Batch A, und genau das hat der Test aufgedeckt.
 */
function parseStock(value) {
  if (typeof value === 'number') {
    return Number.isFinite(value) && value >= 0 ? value : null;
  }
  if (typeof value === 'string') {
    const s = value.trim();
    if (!/^\d+([.,]\d+)?$/.test(s)) return null;
    const n = Number(s.replace(',', '.'));
    return Number.isFinite(n) && n >= 0 ? n : null;
  }
  return null;
}

/**
 * Client-IP normalisieren und prüfen.
 *
 * Node liefert IPv4-Clients auf einem Dual-Stack-Socket als "::ffff:1.2.3.4".
 * Diese Form wird auf die reine IPv4 zurückgeführt, damit der Login-Verlauf
 * einheitlich bleibt und alte wie neue Einträge gleich aussehen.
 */
function normalizeIp(raw) {
  let ip = String(raw ?? '').trim();
  if (ip === '' || ip.length > 45) return '';

  const mapped = ip.match(/^::ffff:((?:\d{1,3}\.){3}\d{1,3})$/i);
  if (mapped) ip = mapped[1];

  if (/^(\d{1,3}\.){3}\d{1,3}$/.test(ip) && ip.split('.').every(o => Number(o) <= 255)) return ip;
  if (/^[0-9a-fA-F:]+$/.test(ip) && ip.includes(':')) return ip;
  return '';
}

// Werte, die als Platzhalter kursieren und niemals ein echter Schlüssel sind.
const BEISPIEL_SCHLUESSEL = [
  'ein-sehr-langer-zufaelliger-string-hier-einfuegen',
  'dein-geheimer-schluessel',
  'your-secret-key',
  'changeme', 'change-me', 'secret', 'geheim', 'test'
];

/**
 * Prüft JWT_SECRET beim Start. Gibt einen Fehlertext zurück oder null.
 * Ohne tragfähigen Schlüssel ist ein Abbruch besser als ein laufender
 * Server, dessen Tokens jeder fälschen kann.
 */
function checkJwtSecret(secret) {
  if (typeof secret !== 'string' || secret.trim() === '') {
    return 'JWT_SECRET ist nicht gesetzt.';
  }
  const s = secret.trim();
  if (BEISPIEL_SCHLUESSEL.includes(s.toLowerCase())) {
    return 'JWT_SECRET ist noch ein Beispielwert.';
  }
  if (s.length < 32) {
    return `JWT_SECRET ist zu kurz (${s.length} Zeichen, mindestens 32).`;
  }
  return null;
}

module.exports = { parseIsoDate, parseStock, normalizeIp, checkJwtSecret };
