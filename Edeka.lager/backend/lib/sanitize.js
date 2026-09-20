'use strict';
//
// Weist Request-Daten ab, die Mongo-Operatoren enthalten.
//
// Absichtlich ABWEISEND statt bereinigend: Ein stillschweigend entfernter
// Operator sieht für den Aufrufer aus wie ein Erfolg. Ein 400 ist laut und
// taucht in den Logs auf.
//
// Diese Middleware ersetzt keine Validierung pro Route — sie ist die
// Grundsicherung darunter und gilt auch für Routen, die es noch nicht gibt.

const MAX_TIEFE = 8;

function findeOperatorSchluessel(wert, tiefe = 0) {
  if (tiefe > MAX_TIEFE) return '(zu tief verschachtelt)';

  if (Array.isArray(wert)) {
    for (const eintrag of wert) {
      const treffer = findeOperatorSchluessel(eintrag, tiefe + 1);
      if (treffer) return treffer;
    }
    return null;
  }

  if (wert && typeof wert === 'object' && !(wert instanceof Date)) {
    for (const schluessel of Object.keys(wert)) {
      if (schluessel.startsWith('$') || schluessel.includes('.')) return schluessel;
      const treffer = findeOperatorSchluessel(wert[schluessel], tiefe + 1);
      if (treffer) return treffer;
    }
  }

  return null;
}

function rejectMongoOperators(req, res, next) {
  for (const quelle of [req.body, req.query, req.params]) {
    if (!quelle) continue;
    const treffer = findeOperatorSchluessel(quelle);
    if (treffer) {
      return res.status(400).json({ message: `Ungültiges Feld im Request: "${treffer}"` });
    }
  }
  next();
}

module.exports = { rejectMongoOperators, findeOperatorSchluessel };
