const express   = require('express');
const router    = express.Router();
const auth      = require('../middleware/auth');
const Product   = require('../models/Product');
const DailyLog  = require('../models/DailyLog');

const { sendTelegram, buildTelegramText } = require('../services/telegram');
const { closeDay, yesterdayInBerlin, berlinDateString } = require('../services/dailyClose');
const {
  normalizeFromLiveProducts,
  normalizeFromSnapshot,
  buildExcelWorkbook,
  buildPdfDocument
} = require('../services/exportBuilder');

/**
 * چون «مصرف» در هر گزارش از نیمه‌شب تجمعی است (نه نسبت به گزارش قبلی همان روز)،
 * هیچ‌گاه نباید چند گزارش یک روز را با هم جمع زد — وگرنه عدد مصرف چندبرابر می‌شود.
 * این تابع برای هر تاریخ فقط یک رکورد «نماینده» انتخاب می‌کند:
 * ترجیحاً رکورد auto-midnight (بستن رسمی شب)، وگرنه آخرین گزارش دستی همان روز.
 */
function pickDailyRepresentatives(logs) {
  const byDate = {};
  logs.forEach(log => {
    const existing = byDate[log.date];
    if (!existing) {
      byDate[log.date] = log;
    } else if (existing.type !== 'auto-midnight' && log.type === 'auto-midnight') {
      byDate[log.date] = log;
    } else if (existing.type === log.type && log.sentAt > existing.sentAt) {
      byDate[log.date] = log;
    }
  });
  return Object.values(byDate).sort((a, b) => b.date.localeCompare(a.date));
}

// ── GET /api/reports/today ───────────────────────────────────────
// همه‌ی گزارش‌هایی که امروز دستی ارسال شده‌اند (ممکن است چندتا باشند)
router.get('/today', auth, async (req, res) => {
  const dateStr = berlinDateString(new Date());
  const logs = await DailyLog.find({ date: dateStr }).sort({ sentAt: 1 });

  const reports = logs.map(l => ({
    _id:           l._id,
    sentAt:        l.sentAt,
    type:          l.type,
    reportSent:    l.reportSent,
    totalStock:    l.snapshot.reduce((s, p) => s + (p.closingStock || 0), 0),
    totalConsumed: l.snapshot.reduce((s, p) => s + (p.consumed || 0), 0),
    productCount:  l.snapshot.length
  }));

  res.json({ date: dateStr, reports });
});

// ── GET /api/reports/analytics?days=14 ───────────────────────────
router.get('/analytics', auth, async (req, res) => {
  const days = Math.min(parseInt(req.query.days) || 14, 90);
  const rawLogs = await DailyLog.find().sort({ date: -1, sentAt: -1 }).limit(days * 8);
  const repLogs = pickDailyRepresentatives(rawLogs).slice(0, days);

  if (repLogs.length === 0) {
    return res.json({ trend: [], topProducts: [], allProducts: [], summary: {} });
  }

  const trend = repLogs
    .map(l => ({
      date:          l.date,
      totalStock:    l.snapshot.reduce((s, p) => s + (p.closingStock || 0), 0),
      totalConsumed: l.snapshot.reduce((s, p) => s + (p.consumed || 0), 0),
      productCount:  l.snapshot.length
    }))
    .sort((a, b) => a.date.localeCompare(b.date));

  const productMap = {};
  repLogs.forEach(log => {
    log.snapshot.forEach(p => {
      const key = `${p.productName}__${p.isBio}__${p.unit}`;
      if (!productMap[key]) {
        productMap[key] = {
          name: p.productName, emoji: p.emoji, category: p.category,
          unit: p.unit, isBio: !!p.isBio, totalConsumed: 0, days: 0
        };
      }
      productMap[key].totalConsumed += p.consumed || 0;
      productMap[key].days += 1;
    });
  });

  const allProducts = Object.values(productMap).map(p => ({
    ...p,
    avgConsumed: parseFloat((p.totalConsumed / p.days).toFixed(1))
  }));

  const topProducts = [...allProducts].sort((a, b) => b.totalConsumed - a.totalConsumed).slice(0, 10);

  const categoryBreakdown = {};
  allProducts.forEach(p => {
    categoryBreakdown[p.category] = (categoryBreakdown[p.category] || 0) + p.totalConsumed;
  });

  res.json({
    trend,
    topProducts,
    allProducts,
    summary: {
      totalDays:         repLogs.length,
      totalConsumed:     trend.reduce((s, d) => s + d.totalConsumed, 0),
      avgDailyConsumed:  parseFloat((trend.reduce((s, d) => s + d.totalConsumed, 0) / trend.length).toFixed(1)),
      categoryBreakdown
    }
  });
});

// ── POST /api/reports/send-now ───────────────────────────────────
// گزارش لحظه‌ای: snapshot می‌گیرد، به تلگرام می‌فرستد، و به‌عنوان رکورد دستی ذخیره می‌کند.
// yesterdayStock را تغییر نمی‌دهد — فقط بستن خودکار نیمه‌شب این کار را می‌کند.
router.post('/send-now', auth, async (req, res) => {
  const products = await Product.find({ isActive: true }).sort({ category: 1, name: 1 });
  if (products.length === 0) {
    return res.status(400).json({ message: 'Keine aktiven Produkte vorhanden' });
  }

  const dateStr = berlinDateString(new Date());
  const snapshot = products.map(p => ({
    productId:    p._id,
    productName:  p.name,
    emoji:        p.emoji,
    category:     p.category,
    unit:         p.unit,
    isBio:        !!p.isBio,
    openingStock: p.yesterdayStock ?? 0,
    closingStock: p.currentStock ?? 0,
    consumed:     Math.max(0, (p.yesterdayStock ?? 0) - (p.currentStock ?? 0))
  }));

  // این try/catch داخلی عمداً نگه داشته شده: خطای ارسال تلگرام نباید مانع
  // ذخیره‌شدن گزارش شود، پس جدا از بقیه‌ی هندلر مدیریت می‌شود.
  let telegramError = null;
  let reportSent = false;
  try {
    await sendTelegram(buildTelegramText(products));
    reportSent = true;
  } catch (err) {
    telegramError = err.message;
  }

  const log = await DailyLog.create({
    date: dateStr, sentAt: new Date(), type: 'manual',
    snapshot, createdBy: req.user._id, reportSent
  });

  if (telegramError) {
    // Bericht ist trotzdem gespeichert — nur der Telegram-Versand ist fehlgeschlagen
    return res.status(207).json({
      message: '⚠️ Bericht gespeichert, aber Telegram-Versand fehlgeschlagen',
      telegramError,
      log
    });
  }

  res.status(201).json({ message: '✅ Bericht gesendet und gespeichert', log });
});

// ── GET /api/reports/history?limit=30 ───────────────────────────
// یک ردیف به ازای هر روز (نماینده‌ی همان روز) — برای صفحه‌ی تاریخچه
router.get('/history', auth, async (req, res) => {
  const limit = Math.min(parseInt(req.query.limit) || 30, 365);
  const rawLogs = await DailyLog.find().sort({ date: -1, sentAt: -1 }).limit(limit * 8);
  const repLogs = pickDailyRepresentatives(rawLogs).slice(0, limit);

  const result = repLogs.map(log => ({
    _id:           log._id,
    date:          log.date,
    type:          log.type,
    sentAt:        log.sentAt,
    totalStock:    log.snapshot.reduce((s, p) => s + (p.closingStock || 0), 0),
    totalConsumed: log.snapshot.reduce((s, p) => s + (p.consumed || 0), 0),
    productCount:  log.snapshot.length,
    categories:    [...new Set(log.snapshot.map(p => p.category).filter(Boolean))],
    reportsToday:  rawLogs.filter(l => l.date === log.date && l.type === 'manual').length,
    reportSent:    log.reportSent || false
  }));

  res.json(result);
});

// ── GET /api/reports/export?type=excel|pdf&date=YYYY-MM-DD&logId=... ─────
// بدون date/logId → خروجی از وضعیت زنده‌ی فعلی انبار
router.get('/export', auth, async (req, res) => {
  const { type, date, logId } = req.query;
  if (type !== 'excel' && type !== 'pdf') {
    return res.status(400).json({ message: 'type=excel oder type=pdf erforderlich' });
  }

  let rows, subtitle, filenameDate;

  if (logId) {
    const log = await DailyLog.findById(logId);
    if (!log) return res.status(404).json({ message: 'Bericht nicht gefunden' });
    rows = normalizeFromSnapshot(log.snapshot);
    subtitle = `${log.date} · ${new Date(log.sentAt).toLocaleString('de-DE')}`;
    filenameDate = log.date;
  } else if (date) {
    const logs = await DailyLog.find({ date }).sort({ sentAt: -1 });
    if (logs.length === 0) return res.status(404).json({ message: 'Keine Daten für dieses Datum gefunden' });
    const rep = logs.find(l => l.type === 'auto-midnight') || logs[0];
    rows = normalizeFromSnapshot(rep.snapshot);
    subtitle = `${date} · Stand ${new Date(rep.sentAt).toLocaleString('de-DE')}`;
    filenameDate = date;
  } else {
    const products = await Product.find({ isActive: true });
    if (products.length === 0) return res.status(404).json({ message: 'Keine Produkte vorhanden' });
    rows = normalizeFromLiveProducts(products);
    subtitle = `Live-Stand · ${new Date().toLocaleString('de-DE')}`;
    filenameDate = berlinDateString(new Date());
  }

  if (type === 'excel') {
    const workbook = await buildExcelWorkbook(rows, { subtitle, sheetName: filenameDate });
    res.setHeader('Content-Type', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
    res.setHeader('Content-Disposition', `attachment; filename=EDEKA_Lager_${filenameDate}.xlsx`);
    await workbook.xlsx.write(res);
    return res.end();
  }

  res.setHeader('Content-Type', 'application/pdf');
  res.setHeader('Content-Disposition', `attachment; filename=EDEKA_Lager_${filenameDate}.pdf`);
  const doc = buildPdfDocument(rows, { subtitle });
  doc.pipe(res);
});

// ── POST /api/reports/reset-stock ───────────────────────────────
router.post('/reset-stock', auth, async (req, res) => {
  if (req.user.role !== 'admin') {
    return res.status(403).json({ message: 'Nur Admins dürfen Bestände zurücksetzen' });
  }
  const { includeYesterday = false } = req.body || {};
  const products = await Product.find({ isActive: true });

  await Promise.all(products.map(p => Product.findByIdAndUpdate(p._id, {
    currentStock: 0,
    ...(includeYesterday ? { yesterdayStock: 0 } : {}),
    updatedBy: req.user._id
  })));

  res.json({
    message: '✅ Bestände zurückgesetzt',
    count: products.length,
    yesterdayCleared: !!includeYesterday
  });
});

// ── POST /api/reports/reset-logs ────────────────────────────────
router.post('/reset-logs', auth, async (req, res) => {
  if (req.user.role !== 'admin') {
    return res.status(403).json({ message: 'Nur Admins dürfen Logs löschen' });
  }
  const scope    = (req.body?.scope || req.query?.scope || 'daily').toLowerCase();
  const todayStr = berlinDateString(new Date());
  let filter = {};

  if (scope === 'daily') {
    filter = { date: req.body?.date || req.query?.date || todayStr };
  } else if (scope === 'weekly') {
    const since = new Date(); since.setDate(since.getDate() - 7);
    filter = { date: { $gte: berlinDateString(since) } };
  } else if (scope === 'monthly') {
    const since = new Date(); since.setDate(since.getDate() - 30);
    filter = { date: { $gte: berlinDateString(since) } };
  } else if (scope === 'all') {
    filter = {};
  } else {
    return res.status(400).json({ message: `Ungültiger scope: ${scope}. Erlaubt: daily, weekly, monthly, all` });
  }

  const deleted = await DailyLog.deleteMany(filter);
  res.json({ message: '✅ Logs zurückgesetzt', scope, deletedCount: deleted.deletedCount || 0 });
});

// ── POST /api/reports/close-day ─────────────────────────────────
// نسخه‌ی دستی همان کاری که cron نیمه‌شب انجام می‌دهد — برای تست یا ترمیم (فقط ادمین)
router.post('/close-day', auth, async (req, res) => {
  if (req.user.role !== 'admin') {
    return res.status(403).json({ message: 'Nur Admins dürfen den Tag manuell schließen' });
  }
  const dateStr = req.body?.date || yesterdayInBerlin();
  const result = await closeDay(dateStr);
  res.json({ message: `✅ Tag ${dateStr} manuell geschlossen`, ...result });
});

// ── GET /api/reports/:id ────────────────────────────────────────
// جزئیات کامل یک گزارش مشخص (snapshot کامل) — این روت همیشه باید آخر بماند
// چون وگرنه مسیرهای بالا (today, analytics, history, ...) را قاپ می‌زند
router.get('/:id', auth, async (req, res) => {
  const log = await DailyLog.findById(req.params.id);
  if (!log) return res.status(404).json({ message: 'Bericht nicht gefunden' });
  res.json(log);
});

module.exports = router;
