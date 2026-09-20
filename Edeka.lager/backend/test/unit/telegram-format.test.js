'use strict';
const test   = require('node:test');
const assert = require('node:assert/strict');
const { escapeMarkdown, buildTelegramText } = require('../../services/telegram');

test('Markdown-Sonderzeichen werden maskiert', () => {
  assert.equal(escapeMarkdown('Bio_Apfel'),  'Bio\\_Apfel');
  assert.equal(escapeMarkdown('*Extra*'),    '\\*Extra\\*');
  assert.equal(escapeMarkdown('A[B]C'),      'A\\[B]C');
  assert.equal(escapeMarkdown('`code`'),     '\\`code\\`');
});

test('null/undefined ergeben einen leeren String, keinen Absturz', () => {
  assert.equal(escapeMarkdown(null), '');
  assert.equal(escapeMarkdown(undefined), '');
});

const product = (over = {}) => ({
  name: 'Apfel', unit: 'kg', category: 'Obst', emoji: '🍎',
  isBio: false, currentStock: 3, yesterdayStock: 5, ...over
});

test('Produktname mit Sonderzeichen wird maskiert', () => {
  const txt = buildTelegramText([product({ name: 'Apfel_Bio' })]);
  assert.match(txt, /Apfel\\_Bio/);
});

test('Verbrauch wird angezeigt, Auffüllen ergibt keine negative Zahl', () => {
  assert.match(buildTelegramText([product({ currentStock: 3, yesterdayStock: 5 })]), /\(−2\)/);
  const refill = buildTelegramText([product({ currentStock: 9, yesterdayStock: 5 })]);
  assert.doesNotMatch(refill, /−/);
});

// ── ROT: Fehler, der in Batch A behoben wird ─────────────────────────
// Jedes Feld im Telegram-Text läuft durch escapeMarkdown() — außer `emoji`.
// Ein einzelnes "*" dort erzeugt eine ungerade Zahl an Sternchen, woraufhin
// Telegram die GESAMTE Nachricht mit einem Parse-Fehler ablehnt, nicht nur
// diese eine Zeile.
test('Emoji-Feld wird ebenfalls maskiert', () => {
  const txt = buildTelegramText([product({ emoji: '*' })]);
  const stars = (txt.match(/(?<!\\)\*/g) || []).length;
  assert.equal(stars % 2, 0, `ungerade Anzahl unmaskierter "*" (${stars}) — Telegram lehnt die Nachricht ab`);
});
