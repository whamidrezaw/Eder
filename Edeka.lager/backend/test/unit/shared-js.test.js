'use strict';
//
// Batch C3 — frontend/assets/shared.js
//
// Zwei Tests sind absichtlich ROT und mit "── ROT ──" markiert.
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const { ladeShared, antwort } = require('../helpers/browser');

// ── Kontrollen: müssen GRÜN sein ──────────────────────────────────
// Sind diese rot, stimmt etwas an der Browser-Attrappe nicht — dann bitte
// die Meldung schicken, bevor irgendetwas am Frontend geändert wird.

test('Kontrolle: shared.js lädt und stellt api() und logout() bereit', () => {
  const { gefunden, sandbox } = ladeShared({ token: 'T' });
  console.log('   gefundene Funktionen:', gefunden.join(', ') || '(keine)');

  assert.equal(typeof sandbox.api, 'function',
    `api() nicht gefunden. Vorhanden: ${gefunden.join(', ') || 'nichts'}`);
  assert.equal(typeof sandbox.logout, 'function',
    `logout() nicht gefunden. Vorhanden: ${gefunden.join(', ') || 'nichts'}`);
});

test('Kontrolle: ohne Token leitet shared.js zur Anmeldeseite', () => {
  const ohne = ladeShared({ token: null, pathname: '/dashboard.html' });
  assert.ok(ohne.navigationen.length > 0,
    'ohne Token müsste zur Anmeldeseite weitergeleitet werden');
  assert.match(ohne.navigationen[0], /index\.html/);

  const mit = ladeShared({ token: 'T', pathname: '/dashboard.html' });
  assert.deepEqual(mit.navigationen, [],
    'mit Token darf nicht weitergeleitet werden');
});

// ── Leitplanke: ein echter Sitzungsabbruch MUSS abmelden ──────────
// Dieser Test ist heute grün und muss nach der Korrektur grün bleiben.
// Er verhindert, dass wir die Abmeldung beim Reparieren ganz abschalten.

test('ein 401 auf einer normalen Route beendet die Sitzung', async () => {
  const u = ladeShared({
    token: 'T',
    lokal: { theme: 'dark' },
    fetchStub: async () => antwort(401, { message: 'Ungültiger Token' })
  });

  await assert.rejects(() => u.sandbox.api('/api/products'));

  assert.equal(u.sessionStorage.getItem('token'), null,
    'bei ungültigem Token muss die Sitzung beendet werden');
  assert.ok(u.navigationen.some(n => /index\.html/.test(n)),
    'bei ungültigem Token muss zur Anmeldeseite geleitet werden');
});

// ── Befund 1: Tippfehler beim Passwort wirft aus der Sitzung ──────

// ── ROT ──
test('ein falsches aktuelles Passwort beendet die Sitzung nicht', async () => {
  const u = ladeShared({
    token: 'T',
    lokal: { theme: 'dark' },
    fetchStub: async () => antwort(401, { message: 'Aktuelles Passwort falsch' })
  });

  await assert.rejects(() => u.sandbox.api(
    '/api/auth/change-password', 'PUT',
    { currentPassword: 'vertippt', newPassword: 'NeuesPasswort123' }
  ));

  assert.equal(u.fetchAufrufe.length, 1,
    'api() hat kein fetch ausgelöst — der Test greift nicht. Bitte Ausgabe schicken.');

  assert.equal(u.sessionStorage.getItem('token'), 'T',
    'Die Sitzung wurde beendet, obwohl nur das aktuelle Passwort falsch war. ' +
    'api() behandelt jeden 401 als abgelaufene Sitzung — ein Tippfehler im ' +
    'Passwortfeld wirft den Benutzer damit aus dem System.');
  assert.deepEqual(u.navigationen, [],
    'es wurde zur Anmeldeseite weitergeleitet');
});

// ── Befund 2: logout() räumt zu viel auf ──────────────────────────

// ── ROT ──
test('logout beendet die Sitzung, behält aber die Anzeige-Einstellungen', () => {
  const u = ladeShared({ token: 'T', lokal: { theme: 'dark' } });

  u.sandbox.logout();

  assert.equal(u.sessionStorage.getItem('token'), null,
    'die Sitzung muss beendet werden');
  assert.ok(u.navigationen.some(n => /index\.html/.test(n)),
    'nach dem Abmelden muss die Anmeldeseite folgen');

  assert.equal(u.localStorage.getItem('theme'), 'dark',
    'localStorage.clear() löscht auch das gespeicherte Farbschema — nach jedem ' +
    'Abmelden steht das Thema wieder auf dem Standard, obwohl es nichts mit ' +
    'der Sitzung zu tun hat.');
});

// ── Offene Frage: verschluckt escapeHtml die Null? ────────────────
// escapeHtml(0) gibt bei einer Prüfung auf Falsy-Werte '' zurück statt '0'.
// Ob das hier zutrifft, entscheidet der Test.

test('escapeHtml verschluckt die Null nicht', (t) => {
  const { sandbox } = ladeShared({ token: 'T' });
  if (typeof sandbox.escapeHtml !== 'function') {
    t.skip('escapeHtml ist nicht in shared.js definiert');
    return;
  }
  assert.equal(sandbox.escapeHtml(0), '0', 'die Zahl 0 wird zu einem leeren String');
  assert.equal(sandbox.escapeHtml(false), 'false');
  assert.equal(sandbox.escapeHtml(''), '');
  assert.equal(sandbox.escapeHtml(null), '');
  assert.equal(sandbox.escapeHtml('<b>x</b>'), '&lt;b&gt;x&lt;/b&gt;');
});
