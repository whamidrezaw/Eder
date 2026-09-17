require('dotenv').config();
const mongoose = require('mongoose');
const app      = require('./app');
const { scheduleDailyClose } = require('./services/dailyClose');

// ── Fail-fast: ohne tragfähigen JWT_SECRET nicht starten ──────────
// Ohne Schlüssel startete der Server bisher normal und brach erst beim
// ersten Login mit einem 500er ab. Mit einem schwachen oder öffentlich
// bekannten Schlüssel liefe er sogar dauerhaft weiter — dann kann jeder
// ein Admin-Token fälschen. Beides ist schlimmer als ein Startabbruch.
const { checkJwtSecret } = require('./lib/validate');
const jwtProblem = checkJwtSecret(process.env.JWT_SECRET);
if (jwtProblem) {
  console.error('❌ Start abgebrochen: ' + jwtProblem);
  console.error('   Neuen Schlüssel erzeugen und in .env eintragen:');
  console.error('   node -e "console.log(\'JWT_SECRET=\' + require(\'crypto\').randomBytes(48).toString(\'base64url\'))" >> .env');
  process.exit(1);
}

// ── DB + Server Start ─────────────────────────────────────────────
mongoose.connect(process.env.MONGODB_URI, {
  serverSelectionTimeoutMS: 5000
})
  .then(() => {
    console.log('✅ MongoDB verbunden');
    scheduleDailyClose();   // بستن خودکار روز هر شب ۰۰:۰۰ (Europe/Berlin)
    const PORT = parseInt(process.env.PORT) || 3000;
    app.listen(PORT, () => {
      console.log(`✅ Server läuft auf Port ${PORT} [${process.env.NODE_ENV || 'development'}]`);
    });
  })
  .catch(err => {
    console.error('❌ MongoDB Verbindungsfehler:', err.message);
    process.exit(1);
  });

