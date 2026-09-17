'use strict';
require('./env');
const bcrypt  = require('bcryptjs');
const User    = require('../../models/User');
const Product = require('../../models/Product');
const { req } = require('./http');

const DEFAULT_PASSWORD = 'TestPasswort123';

async function makeUser({
  username,
  password = DEFAULT_PASSWORD,
  name     = 'Test Benutzer',
  role     = 'lagerist',
  isActive = true
} = {}) {
  // Kostenfaktor 4 statt 12: identische Semantik, aber ~250x schneller.
  // Tests sollen die Route prüfen, nicht bcrypt.
  const hashed = await bcrypt.hash(password, 4);
  return User.create({ username, password: hashed, name, role, isActive, telegramChatId: null });
}

async function login(username, password = DEFAULT_PASSWORD) {
  const r = await req('/api/auth/login', { method: 'POST', body: { username, password } });
  return { token: r.body && r.body.token, status: r.status, body: r.body };
}

async function makeAdminToken(username = 'admin_test') {
  await makeUser({ username, role: 'admin', name: 'Admin Test' });
  const { token } = await login(username);
  return token;
}

async function makeLageristToken(username = 'lager_test') {
  await makeUser({ username, role: 'lagerist', name: 'Lagerist Test' });
  const { token } = await login(username);
  return token;
}

async function makeProduct(over = {}) {
  return Product.create({
    name: 'Apfel', category: 'Obst', unit: 'Kiste', emoji: '🍎',
    isBio: false, currentStock: 10, yesterdayStock: 12, isActive: true, ...over
  });
}

module.exports = { makeUser, login, makeAdminToken, makeLageristToken, makeProduct, DEFAULT_PASSWORD };
