'use strict';
//
// Was in innerHTML landet, ist maskiert oder nachweislich harmlos.
//
// Seit Phase G führt die CSP eingeschleusten Code nicht mehr aus. Rohe Daten
// im HTML bleiben trotzdem ein Fehler: ein Produkt "<b>Milch</b>" erscheint
// fett, eine Einheit "<i" verschluckt den Rest der Zeile — und jede solche
// Stelle ist der erste Schritt eines Angriffs, sobald eine andere Schutzschicht
// einmal fehlt.
//
// Dieser Test verfolgt jeden Wert, der eine Senke erreicht — innerHTML,
// outerHTML, insertAdjacentHTML — rückwärts durch Vorlagen, Bedingungen,
// .map().join(), Variablen und lokale Funktionen. Erlaubt sind nur:
// escapeHtml(...), Zahlen, fester Text und Formatierer, die ihr Ergebnis
// allein aus Number oder Date bauen. So fiel "breakdown" in dashboard.js auf:
// die Vorlage dort enthält kein einziges Tag, landet aber doch im HTML.
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const fs     = require('node:fs');
const path   = require('node:path');
// Der Parser von ESLint — über ESLint aufgelöst, damit er sicher da ist.
const espree = require(require.resolve('espree', { paths: [path.dirname(require.resolve('eslint'))] }));

const FE = path.join(__dirname, '../../../frontend/assets');

// Am Quelltext geprüft (28.09.2026): diese Funktionen können keine Rohdaten
// zurückgeben. Wer eine Funktion hier ergänzt, prüft sie vorher genauso.
const SICHERE_FUNKTIONEN = new Set([
  'escapeHtml',                                        // maskiert & < > " '
  'fmtNum',                                            // Number(n ?? 0).toLocaleString(…)
  'fmtDate', 'fmtTime', 'fmtRelative', 'fmtDateOnly',  // aus new Date(…)
  'categoryStep'                                       // liefert 0.5 oder 1
]);
const ITERATION = new Set(['map', 'flatMap', 'forEach', 'filter']);

function eltern(node, p = null) {
  if (!node || typeof node.type !== 'string') return;
  node.parent = p;
  for (const k of Object.keys(node)) {
    if (k === 'parent') continue;
    const v = node[k];
    if (Array.isArray(v)) v.forEach(c => eltern(c, node));
    else if (v && typeof v.type === 'string') eltern(v, node);
  }
}
const istFunktion = (n) => /^(FunctionDeclaration|FunctionExpression|ArrowFunctionExpression)$/.test(n.type);
const imMuster = (muster, name) => {
  if (!muster) return false;
  if (muster.type === 'Identifier') return muster.name === name;
  if (muster.type === 'ArrayPattern') return muster.elements.some(e => imMuster(e, name));
  if (muster.type === 'ObjectPattern') return muster.properties.some(p => imMuster(p.value || p.argument, name));
  if (muster.type === 'AssignmentPattern') return imMuster(muster.left, name);
  if (muster.type === 'RestElement') return imMuster(muster.argument, name);
  return false;
};
function istIterationsRueckruf(fn) {
  const c = fn.parent;
  return c && c.type === 'CallExpression' && c.arguments[0] === fn &&
         c.callee.type === 'MemberExpression' && !c.callee.computed && ITERATION.has(c.callee.property.name);
}

// Woher kommt ein Name? { art: 'index' | 'init' | 'parameter' | 'funktion' | 'unbekannt' }
function aufloesen(id) {
  const name = id.name;
  for (let n = id.parent; n; n = n.parent) {
    if (istFunktion(n)) {
      const k = n.params.findIndex(p => imMuster(p, name));
      if (k !== -1) {
        const p = n.params[k];
        // Der zweite Parameter eines map/forEach-Rückrufs ist der Index — eine Zahl.
        if (k === 1 && p.type === 'Identifier' && istIterationsRueckruf(n)) return { art: 'index' };
        return { art: 'parameter' };
      }
    }
    const koerper = n.type === 'Program' || n.type === 'BlockStatement' ? n.body
                  : n.type === 'SwitchCase' ? n.consequent : null;
    if (!koerper) continue;
    for (const s of koerper) {
      if (s.type === 'FunctionDeclaration' && s.id && s.id.name === name) return { art: 'funktion', node: s };
      if (s.type !== 'VariableDeclaration') continue;
      for (const d of s.declarations) {
        if (d.id.type === 'Identifier' && d.id.name === name && d.range[1] <= id.range[0]) {
          if (d.init && istFunktion(d.init)) return { art: 'funktion', node: d.init };
          return d.init ? { art: 'init', node: d.init } : { art: 'unbekannt' };
        }
        if (d.id.type !== 'Identifier' && imMuster(d.id, name)) return { art: 'parameter' };
      }
    }
  }
  return { art: 'unbekannt' };
}

function rueckgaben(fn) {
  if (fn.body.type !== 'BlockStatement') return [fn.body];
  const out = [];
  (function such(n) {
    if (!n || typeof n.type !== 'string') return;
    if (n !== fn && istFunktion(n)) return;
    if (n.type === 'ReturnStatement' && n.argument) out.push(n.argument);
    for (const k of Object.keys(n)) {
      if (k === 'parent') continue;
      const v = n[k];
      if (Array.isArray(v)) v.forEach(such); else if (v && typeof v.type === 'string') such(v);
    }
  })(fn.body);
  return out;
}

// Liefert die Stellen, an denen Rohdaten durchkommen (leer = harmlos).
function pruefe(e, ctx, gesehen = new Set()) {
  const roh = (grund) => [{ zeile: e.loc.start.line, text: ctx.src.slice(e.range[0], e.range[1]).replace(/\s+/g, ' ').slice(0, 90), grund }];
  switch (e.type) {
    case 'Literal': return [];
    case 'TemplateLiteral': return e.expressions.flatMap(x => pruefe(x, ctx, gesehen));
    case 'ConditionalExpression': return [...pruefe(e.consequent, ctx, gesehen), ...pruefe(e.alternate, ctx, gesehen)];
    case 'LogicalExpression':
      // "a && b" liefert a nur, wenn a falsch ist — '', 0, null … sind harmlos.
      return e.operator === '&&' ? pruefe(e.right, ctx, gesehen)
                                 : [...pruefe(e.left, ctx, gesehen), ...pruefe(e.right, ctx, gesehen)];
    case 'BinaryExpression':
      return e.operator === '+' ? [...pruefe(e.left, ctx, gesehen), ...pruefe(e.right, ctx, gesehen)] : [];
    case 'UnaryExpression': return [];
    case 'ChainExpression': return pruefe(e.expression, ctx, gesehen);
    case 'MemberExpression':
      return !e.computed && e.property.name === 'length' ? [] : roh('Rohdaten aus einem Feld');
    case 'CallExpression': {
      const c = e.callee;
      if (c.type === 'Identifier' && SICHERE_FUNKTIONEN.has(c.name)) return [];
      if (c.type === 'MemberExpression' && !c.computed) {
        if (c.object.type === 'Identifier' && c.object.name === 'Math') return [];
        if (c.property.name === 'toFixed') return [];
        if (c.property.name === 'join' && c.object.type === 'CallExpression' && c.object.callee.type === 'MemberExpression'
            && ['map', 'flatMap'].includes(c.object.callee.property.name) && c.object.arguments[0] && istFunktion(c.object.arguments[0])) {
          const trenner = e.arguments[0] ? pruefe(e.arguments[0], ctx, gesehen) : [];
          return [...trenner, ...rueckgaben(c.object.arguments[0]).flatMap(r => pruefe(r, ctx, gesehen))];
        }
      }
      if (c.type === 'Identifier') {
        const a = aufloesen(c);
        if (a.art === 'funktion' && !gesehen.has(a.node)) {
          gesehen.add(a.node);
          return rueckgaben(a.node).flatMap(r => pruefe(r, ctx, gesehen));
        }
      }
      return roh('Ergebnis eines Aufrufs, nicht nachweislich harmlos');
    }
    case 'Identifier': {
      if (['undefined', 'NaN', 'Infinity'].includes(e.name)) return [];
      const a = aufloesen(e);
      if (a.art === 'index') return [];
      if (a.art === 'init' && !gesehen.has(a.node)) { gesehen.add(a.node); return pruefe(a.node, ctx, gesehen); }
      if (a.art === 'init') return [];
      return roh(a.art === 'parameter' ? 'Parameter mit Rohdaten' : 'Herkunft unbekannt');
    }
    default: return roh(`unbekannte Form (${e.type})`);
  }
}

function senken(src, datei) {
  const ast = espree.parse(src, { ecmaVersion: 'latest', sourceType: 'script', loc: true, range: true });
  eltern(ast);
  const ctx = { src };
  const funde = []; let anzahl = 0;
  (function lauf(n) {
    if (!n || typeof n.type !== 'string') return;
    if (n.type === 'AssignmentExpression' && n.left.type === 'MemberExpression' && !n.left.computed
        && ['innerHTML', 'outerHTML'].includes(n.left.property.name)) {
      anzahl++; funde.push(...pruefe(n.right, ctx));
    }
    if (n.type === 'CallExpression' && n.callee.type === 'MemberExpression' && !n.callee.computed
        && n.callee.property.name === 'insertAdjacentHTML' && n.arguments[1]) {
      anzahl++; funde.push(...pruefe(n.arguments[1], ctx));
    }
    for (const k of Object.keys(n)) {
      if (k === 'parent') continue;
      const v = n[k];
      if (Array.isArray(v)) v.forEach(lauf); else if (v && typeof v.type === 'string') lauf(v);
    }
  })(ast);
  return { anzahl, funde: funde.map(f => ({ datei, ...f })) };
}

test('der Prüfer selbst: er erkennt Rohdaten auch auf Umwegen', () => {
  const faelle = [
    ['el.innerHTML = `<b>${p.name}</b>`;', 1],
    ['const x = `${fmtNum(v)} ${u}`; function f(u, v) {} el.innerHTML = `<i>${x}</i>`;', 1],
    ['el.innerHTML = rows.map(r => `<li>${r.label}</li>`).join("");', 1],
    ['el.innerHTML = ok ? `<b>${escapeHtml(n)}</b>` : "—";', 0],
    ['el.innerHTML = list.map((p, i) => `<li data-i="${i}">${escapeHtml(p)}</li>`).join("");', 0],
    ['function zeile(u) { return `<td>${u.name}</td>`; } el.innerHTML = zeile(x);', 1],
    ['el.insertAdjacentHTML("beforeend", `<p>${msg}</p>`);', 1]
  ];
  for (const [code, soll] of faelle) {
    const { funde } = senken(code, 'probe.js');
    assert.equal(funde.length, soll, `${soll} erwartet, ${funde.length} gefunden: ${code}`);
  }
});

test('was in innerHTML landet, ist maskiert oder nachweislich harmlos', () => {
  let senkenGesamt = 0; const alle = [];
  for (const f of fs.readdirSync(FE).filter(x => x.endsWith('.js') && x !== 'chart.umd.min.js')) {
    const { anzahl, funde } = senken(fs.readFileSync(path.join(FE, f), 'utf8'), f);
    senkenGesamt += anzahl; alle.push(...funde);
  }
  assert.ok(senkenGesamt >= 20, `nur ${senkenGesamt} Senken gefunden — hat das Einlesen versagt?`);
  assert.deepEqual(alle.map(f => `${f.datei}:${f.zeile}  ${f.text}  (${f.grund})`), [],
    `${alle.length} Stelle(n) mit Rohdaten im HTML`);
});
