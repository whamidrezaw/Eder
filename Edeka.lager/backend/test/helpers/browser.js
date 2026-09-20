'use strict';
//
// Lädt frontend/assets/shared.js in eine nachgebaute Browser-Umgebung.
//
// Bewusst mit node:vm statt jsdom: keine zusätzliche Abhängigkeit, und in
// einem eigenen vm-Context landen Funktionsdeklarationen der obersten Ebene
// ohnehin auf dem globalen Objekt. Ob shared.js sie zusätzlich auf window
// legt, ist damit egal.
//
const vm   = require('node:vm');
const fs   = require('node:fs');
const path = require('node:path');

const SHARED = path.join(__dirname, '../../../frontend/assets/shared.js');

/** Ein Response-ähnliches Objekt für die fetch-Attrappe. */
function antwort(status, koerper) {
  const text = typeof koerper === 'string' ? koerper : JSON.stringify(koerper);
  return {
    ok:         status >= 200 && status < 300,
    status,
    statusText: String(status),
    headers:    { get: () => 'application/json' },
    json:       async () => (typeof koerper === 'string' ? JSON.parse(koerper) : koerper),
    text:       async () => text,
    blob:       async () => ({ size: text.length, type: 'application/json' }),
    clone()     { return antwort(status, koerper); }
  };
}

function speicher(anfang = {}) {
  const daten = new Map(Object.entries(anfang).map(([k, v]) => [k, String(v)]));
  return {
    getItem:    k => (daten.has(k) ? daten.get(k) : null),
    setItem:    (k, v) => { daten.set(k, String(v)); },
    removeItem: k => { daten.delete(k); },
    clear:      () => { daten.clear(); },
    key:        i => [...daten.keys()][i] ?? null,
    get length() { return daten.size; },
    _daten:     daten
  };
}

function element() {
  const attrs = new Map();
  const el = {
    setAttribute:       (k, v) => attrs.set(k, String(v)),
    getAttribute:       k => (attrs.has(k) ? attrs.get(k) : null),
    removeAttribute:    k => attrs.delete(k),
    appendChild:        () => {},
    removeChild:        () => {},
    remove:             () => {},
    addEventListener:   () => {},
    removeEventListener:() => {},
    querySelector:      () => null,
    querySelectorAll:   () => [],
    focus:              () => {},
    click:              () => {},
    classList: { add() {}, remove() {}, toggle() {}, contains: () => false },
    style:   {},
    dataset: {},
    attributes: attrs,
    children: [],
    value:    '',
    checked:  false,
    textContent: '',
    innerHTML:   '',
    innerText:   ''
  };
  return el;
}

/**
 * @param {object} o
 * @param {string|null} o.token      Inhalt von sessionStorage.token
 * @param {string}      o.pathname   window.location.pathname
 * @param {object}      o.lokal      Startinhalt von localStorage
 * @param {function}    o.fetchStub  Attrappe für fetch
 */
function ladeShared({ token = null, pathname = '/dashboard.html', lokal = {}, fetchStub } = {}) {
  if (!fs.existsSync(SHARED)) {
    throw new Error(`shared.js nicht gefunden: ${SHARED}`);
  }

  const sessionStorage = speicher(token ? { token } : {});
  const localStorage   = speicher(lokal);
  const navigationen   = [];
  const fetchAufrufe   = [];

  const location = {
    pathname,
    search:   '',
    hash:     '',
    host:     'localhost:3000',
    origin:   'http://localhost:3000',
    protocol: 'http:',
    _href:    'http://localhost:3000' + pathname,
    get href() { return this._href; },
    set href(v) { navigationen.push(v); this._href = String(v); },
    assign(v)   { navigationen.push(v); this._href = String(v); },
    replace(v)  { navigationen.push(v); this._href = String(v); },
    reload()    { navigationen.push('[reload]'); }
  };

  const documentElement = element();
  const dokument = {
    documentElement,
    body:             element(),
    head:             element(),
    readyState:       'complete',
    getElementById:   () => null,
    querySelector:    () => null,
    querySelectorAll: () => [],
    createElement:    () => element(),
    addEventListener: () => {},
    cookie:           ''
  };

  const standardFetch = async (url, opts) => {
    fetchAufrufe.push({ url, opts });
    return antwort(200, {});
  };

  const sandbox = {
    console,
    document: dokument,
    sessionStorage,
    localStorage,
    location,
    navigator: { userAgent: 'node-test', language: 'de-DE' },
    fetch: fetchStub
      ? (async (url, opts) => { fetchAufrufe.push({ url, opts }); return fetchStub(url, opts); })
      : standardFetch,
    setTimeout, clearTimeout, setInterval, clearInterval,
    URL, URLSearchParams, Intl, Date, Math, JSON,
    Blob:     class Blob { constructor(t) { this.parts = t; } },
    FormData: class FormData {},
    alert:   () => {},
    confirm: () => true,
    prompt:  () => null,
    requestAnimationFrame: (fn) => setTimeout(fn, 0),
    Chart:   class Chart { constructor() {} destroy() {} update() {} }
  };
  sandbox.window     = sandbox;    // window.x und x sind dasselbe
  sandbox.globalThis = sandbox;
  sandbox.self       = sandbox;

  vm.createContext(sandbox);

  const quelle = fs.readFileSync(SHARED, 'utf8');
  try {
    vm.runInContext(quelle, sandbox, { filename: 'shared.js' });
  } catch (err) {
    throw new Error(
      `shared.js konnte in der Attrappe nicht geladen werden: ${err.message}\n` +
      `Wahrscheinlich fehlt in test/helpers/browser.js eine Nachbildung. ` +
      `Bitte diese Meldung schicken.`
    );
  }

  // Nachlauf: mit const/let deklarierte Funktionen landen nicht auf dem
  // globalen Objekt. Ein zweites Skript im selben Context sieht sie aber
  // und kann sie herüberlegen.
  const gesucht = [
    'api', 'logout', 'escapeHtml', 'toggleTheme', 'showToast',
    'fmtDate', 'fmtTime', 'fmtRelative', 'animVal', 'sendReportNow', 'downloadCSV'
  ];
  vm.runInContext(
    gesucht.map(n => `try { if (typeof ${n} === 'function') window.${n} = ${n}; } catch (e) {}`).join('\n'),
    sandbox
  );

  const gefunden = gesucht.filter(n => typeof sandbox[n] === 'function');

  return { sandbox, sessionStorage, localStorage, location, navigationen, fetchAufrufe, gefunden };
}

module.exports = { ladeShared, antwort, SHARED };
