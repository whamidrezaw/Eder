'use strict';
require('./env');
const { once } = require('node:events');
const app = require('../../app');

let server = null;
let base   = '';

async function start() {
  if (server) return base;
  server = app.listen(0, '127.0.0.1');
  await once(server, 'listening');
  base = `http://127.0.0.1:${server.address().port}`;
  return base;
}

async function stop() {
  if (!server) return;
  await new Promise(res => { server.close(res); });
  server = null;
  base   = '';
}

/**
 * Minimaler HTTP-Client auf Basis des eingebauten fetch — bewusst ohne
 * zusätzliche Abhängigkeit (kein supertest).
 * Gibt { status, body, text, headers } zurück; body ist null, wenn die
 * Antwort kein JSON ist (z. B. bei Excel/PDF-Downloads).
 */
async function req(path, { method = 'GET', token, body, raw = false } = {}) {
  const headers = {};
  if (token) headers.Authorization = `Bearer ${token}`;
  if (body !== undefined) headers['Content-Type'] = 'application/json';

  const res = await fetch(base + path, {
    method,
    headers,
    body: body !== undefined ? JSON.stringify(body) : undefined,
    redirect: 'manual'
  });

  if (raw) return { status: res.status, headers: res.headers, res };

  const text = await res.text();
  let parsed = null;
  try { parsed = JSON.parse(text); } catch { /* kein JSON — ok */ }
  return { status: res.status, body: parsed, text, headers: res.headers };
}

module.exports = { start, stop, req };
