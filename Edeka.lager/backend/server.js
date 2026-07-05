require('dotenv').config();
const express  = require('express');
const mongoose = require('mongoose');
const cors     = require('cors');
const helmet   = require('helmet');
const path     = require('path');
const { scheduleDailyClose } = require('./services/dailyClose');

const app = express();

// ── Trust Proxy ──────────────────────────────────────────────────
// اگر پشت یک reverse proxy واقعی (nginx, Caddy, ...) دیپلوی می‌شود، این
// env را روی true بگذارید تا req.ip واقعاً IP کلاینت باشد نه IP پروکسی.
// پیش‌فرض false است: هدر X-Forwarded-For هرگز کورکورانه اعتماد نمی‌شود،
// چون هر کلاینتی می‌تواند این هدر را جعل کند (ببینید routes/auth.js).
if (String(process.env.TRUST_PROXY || '').toLowerCase() === 'true') {
  app.set('trust proxy', 1);
}

// ── Security ─────────────────────────────────────────────────────
// همه‌ی فایل‌های فرانت‌اند (فونت + Chart.js) اکنون لوکال سرو می‌شوند،
// پس دیگر نیازی به بازکردن CSP روی دامنه‌های خارجی (Google Fonts,
// jsDelivr) نیست — این هم امن‌تر است هم بدون وابستگی به اینترنت کار می‌کند.
app.use(helmet({
  contentSecurityPolicy: {
    directives: {
      defaultSrc:  ["'self'"],
      scriptSrc:   ["'self'", "'unsafe-inline'"],
      styleSrc:    ["'self'", "'unsafe-inline'"],
      imgSrc:      ["'self'", "data:"],
      connectSrc:  ["'self'"],
      fontSrc:     ["'self'", "data:"],
      objectSrc:   ["'none'"],
      baseUri:     ["'self'"],
      formAction:  ["'self'"],
      frameAncestors: ["'none'"],
      upgradeInsecureRequests: process.env.NODE_ENV === 'production' ? [] : null
    }
  },
  crossOriginEmbedderPolicy: false   // برای Excel/PDF download
}));

// ── CORS ─────────────────────────────────────────────────────────
// این اپ توکن را در هدر Authorization می‌فرستد (نه کوکی)، پس محدودیت
// سخت‌گیرانه‌ی Origin اینجا ارزش امنیتی واقعی اضافه نمی‌کند — یک سایت
// مخالف به توکن شما در sessionStorage دسترسی ندارد، چه CORS باز باشد چه بسته.
// به همین خاطر هر Origin (آی‌پی سرور، دامنه، با/بدون پورت) را قبول می‌کنیم
// تا محدود به یک آدرس از پیش‌تعیین‌شده در .env نباشید.
// توجه: credentials:true عمداً *حذف* شده — این اپ هیچ کوکی‌ای ست نمی‌کند،
// پس آن گزینه فقط می‌توانست در آینده (اگر روزی کوکی اضافه شود) به‌صورت
// ناخواسته یک آسیب‌پذیری CSRF/کراس‌اورجین باز کند. اگر واقعاً یک روز
// احراز هویت مبتنی بر کوکی اضافه کردید، اینجا را به یک allow-list واقعی
// از Originهای مورد اعتماد تغییر دهید.
app.use(cors({
  origin: (origin, callback) => callback(null, true)
}));

// ── Body Parsing ─────────────────────────────────────────────────
app.use(express.json({ limit: '10kb' }));
app.use(express.urlencoded({ extended: true, limit: '10kb' }));

// ── Static Frontend ───────────────────────────────────────────────
app.use(express.static(path.join(__dirname, '../frontend')));

// ── API Routes ────────────────────────────────────────────────────
app.use('/api/auth',       require('./routes/auth'));
app.use('/api/products',   require('./routes/products'));
app.use('/api/reports',    require('./routes/reports'));
app.use('/api/users',      require('./routes/users'));
app.use('/api/categories', require('./routes/categories'));
app.use('/api/units',      require('./routes/units'));

// ── Health Check ──────────────────────────────────────────────────
app.get('/api/health', (req, res) => {
  res.json({
    status:    'ok',
    uptime:    Math.floor(process.uptime()),
    timestamp: new Date().toISOString(),
    env:       process.env.NODE_ENV || 'development'
  });
});

// ── SPA Fallback (Express 5 Syntax) ───────────────────────────────
app.get('/{*path}', (req, res) => {
  res.sendFile(path.join(__dirname, '../frontend/index.html'));
});

// ── Global Error Handler ──────────────────────────────────────────
// همه‌ی روت‌ها حالا خطاهای async را به اینجا پاس می‌دهند (یا Express 5
// به‌صورت خودکار reject شدن یک async handler را به اینجا می‌فرستد) —
// یک نقطه‌ی واحد برای تعیین status code درست و مخفی‌کردن جزئیات داخلی
// در production، به‌جای تکرار همان منطق در تک‌تک روت‌ها.
// eslint-disable-next-line no-unused-vars
app.use((err, req, res, next) => {
  let status = err.status || err.statusCode || 500;
  let message = err.message || 'Interner Serverfehler';

  // خطاهای شناخته‌شده‌ی Mongoose → status code درست به‌جای 500 عمومی
  if (err.name === 'CastError') {
    status = 400;
    message = 'Ungültige ID';
  } else if (err.name === 'ValidationError') {
    status = 400;
    message = Object.values(err.errors || {}).map(e => e.message).join(', ') || 'Ungültige Eingabe';
  } else if (err.code === 11000) {
    status = 409;
    message = 'Dieser Eintrag existiert bereits';
  }

  if (process.env.NODE_ENV !== 'production') {
    console.error(`[ERROR] ${req.method} ${req.path}:`, err.stack || err.message);
  }

  res.status(status).json({
    message: (status === 500 && process.env.NODE_ENV === 'production')
      ? 'Interner Serverfehler'
      : message
  });
});

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
