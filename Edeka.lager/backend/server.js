require('dotenv').config();
const mongoose = require('mongoose');
const app      = require('./app');
const { scheduleDailyClose } = require('./services/dailyClose');

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

