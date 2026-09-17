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

/**
 * Bestimmt für die letzten `anzahl` Tage je Tag das maßgebliche Protokoll
 * und gibt nur deren IDs zurück.
 *
 * Vorher wurde das Fenster mit limit(anzahl * 8) begrenzt — also nach der
 * ANZAHL der Protokolle statt nach dem Datum. Die Annahme "höchstens acht
 * Berichte pro Tag" ist nirgends zugesichert: bei zwanzig Berichten am Tag
 * deckten 112 geladene Protokolle nur sechs von vierzehn Tagen ab, und die
 * älteren Tage verschwanden ohne jeden Hinweis aus dem Diagramm.
 *
 * Die Auswahlregel bleibt dieselbe wie in pickDailyRepresentatives:
 * auto-midnight schlägt manual, sonst gewinnt der späteste Bericht des
 * Tages. Die Momentaufnahmen werden hier bewusst NICHT geladen, damit die
 * Auswahl unabhängig von der Datenmenge bleibt.
 */
async function repraesentantenIds(anzahl) {
  const zeilen = await DailyLog.aggregate([
    { $project: { date: 1, type: 1, sentAt: 1 } },
    { $addFields: { istAuto: { $eq: ['$type', 'auto-midnight'] } } },
    { $sort: { date: -1, istAuto: -1, sentAt: -1 } },
    { $group: { _id: '$date', logId: { $first: '$_id' } } },
    { $sort: { _id: -1 } },
    { $limit: anzahl }
  ]);
  return zeilen.map(z => z.logId);
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
  const days = require('../lib/validate')
    .parseRangeInt(req.query.days, { min: 1, max: 90, standard: 14 });
  if (days === null) {
    return res.status(400).json({
      message: 'Ungültiger Wert für days. Erwartet wird eine ganze Zahl von 1 bis 90.'
    });
  }

  const logIds = await repraesentantenIds(days);
  if (logIds.length === 0) {
    return res.json({ trend: [], topProducts: [], allProducts: [], summary: {} });
  }

  // Trend: je Tag eine Zeile. Die Summen entstehen in der Datenbank.
  // Vorher wurden dafür alle Momentaufnahmen nach Node geladen und dort
  // aufaddiert — bei 20 Tagen mit je 100 Produkten über 2000 Positionen,
  // um am Ende höchstens 100 Ergebniszeilen zu berechnen.
  const trend = await DailyLog.aggregate([
    { $match: { _id: { $in: logIds } } },
    { $project: {
        _id:           0,
        date:          1,
        totalStock:    { $sum: '$snapshot.closingStock' },
        totalConsumed: { $sum: '$snapshot.consumed' },
        productCount:  { $size: { $ifNull: ['$snapshot', []] } }
    } },
    { $sort: { date: 1 } }
  ]);

  // Produkte: gruppiert nach productId, nicht nach Namen.
  //
  // Momentaufnahmen halten den Namen des jeweiligen Tages fest — das ist
  // richtig und soll so bleiben. Falsch war, daraus den Gruppierungs-
  // schlüssel zu bilden: eine Umbenennung zerlegte die Historie in zwei
  // Zeitreihen, und zwei verschiedene Produkte mit gleichem Namen wurden
  // zusammengeworfen. Die productId steht in jeder Momentaufnahme.
  //
  // Für alte Einträge ohne productId bleibt der Name als Notschlüssel.
  // $last liefert wegen der Sortierung nach Datum den jüngsten Namen.
  const gruppen = await DailyLog.aggregate([
    { $match: { _id: { $in: logIds } } },
    { $sort: { date: 1 } },
    { $unwind: '$snapshot' },
    { $addFields: {
        gruppe: { $ifNull: [
          '$snapshot.productId',
          { $concat: [
            { $ifNull: ['$snapshot.productName', '?'] }, '__',
            { $toString: { $ifNull: ['$snapshot.isBio', false] } }, '__',
            { $ifNull: ['$snapshot.unit', '?'] }
          ] }
        ] }
    } },
    { $group: {
        _id:           '$gruppe',
        productId:     { $first: '$snapshot.productId' },
        name:          { $last: '$snapshot.productName' },
        emoji:         { $last: '$snapshot.emoji' },
        category:      { $last: '$snapshot.category' },
        unit:          { $last: '$snapshot.unit' },
        isBio:         { $last: '$snapshot.isBio' },
        totalConsumed: { $sum: { $ifNull: ['$snapshot.consumed', 0] } },
        days:          { $sum: 1 }
    } }
  ]);

  const allProducts = gruppen.map(g => ({
    productId:     g.productId ?? null,
    name:          g.name,
    emoji:         g.emoji || '📦',
    category:      g.category || 'Sonstige',
    unit:          g.unit || 'Kiste',
    isBio:         !!g.isBio,
    totalConsumed: g.totalConsumed,
    days:          g.days,
    avgConsumed:   parseFloat((g.totalConsumed / g.days).toFixed(1))
  }));

  const topProducts = [...allProducts]
    .sort((a, b) => b.totalConsumed - a.totalConsumed)
    .slice(0, 10);

  const categoryBreakdown = {};
  allProducts.forEach(p => {
    categoryBreakdown[p.category] = (categoryBreakdown[p.category] || 0) + p.totalConsumed;
  });

  const gesamtVerbrauch = trend.reduce((s, d) => s + d.totalConsumed, 0);

  res.json({
    trend,
    topProducts,
    allProducts,
    summary: {
      totalDays:        trend.length,
      totalConsumed:    gesamtVerbrauch,
      avgDailyConsumed: trend.length
        ? parseFloat((gesamtVerbrauch / trend.length).toFixed(1))
        : 0,
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
  // Fenster nach Datum, nicht nach Protokollanzahl — siehe
  // repraesentantenIds(). Vorher fielen bei vielen Berichten pro Tag
  // die älteren Tage still aus der Liste.
  const repIds  = await repraesentantenIds(limit);
  const repLogs = await DailyLog.find({ _id: { $in: repIds } }).sort({ date: -1 });

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
  {
    // Ein fehlerhaft formatiertes Datum ist ein kaputter Request (400),
    // kein leeres Ergebnis (404). Werden beide Fälle vermischt, bleibt ein
    // Fehler im Frontend für immer unsichtbar. reset-logs weist denselben
    // Wert ebenfalls mit 400 ab — zwei Routen, ein Parameter, eine Regel.
    // Fehlt das Datum ganz, bleibt das Verhalten unverändert.
    const rohDatum = req.query?.date;
    if (rohDatum !== undefined && rohDatum !== '' &&
        !require('../lib/validate').parseIsoDate(rohDatum)) {
      return res.status(400).json({ message: 'Ungültiges Datum. Erwartet wird JJJJ-MM-TT.' });
    }
  }
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
    {
      // Ungeprüft wanderte dieser Wert direkt in den Mongo-Filter. Mit
      // { $ne: null } wurde aus "lösche heute" ein "lösche alles" — die
      // Antwort meldete weiterhin scope: "daily".
      const rohDatum = req.body?.date ?? req.query?.date ?? todayStr;
      const gutesDatum = require('../lib/validate').parseIsoDate(rohDatum);
      if (!gutesDatum) {
        return res.status(400).json({ message: 'Ungültiges Datum. Erwartet wird JJJJ-MM-TT.' });
      }
      filter = { date: gutesDatum };
    }
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
  const rohDatum = req.body?.date;
  if (rohDatum !== undefined && rohDatum !== '' &&
      !require('../lib/validate').parseIsoDate(rohDatum)) {
    return res.status(400).json({ message: 'Ungültiges Datum. Erwartet wird JJJJ-MM-TT.' });
  }
  const dateStr = rohDatum || yesterdayInBerlin();

  // force muss ausdrücklich gesetzt werden. Ohne die Option ist ein zweiter
  // Abschluss ein No-op — genau das schützt den Verbrauch des laufenden Tages.
  const force  = req.body?.force === true;
  const result = await closeDay(dateStr, { force });

  const message = result.skipped
    ? `ℹ️ Tag ${dateStr} war bereits geschlossen — nichts geändert. Mit "force": true erneut schließen.`
    : `✅ Tag ${dateStr} ${force ? 'erneut ' : 'manuell '}geschlossen`;
  res.json({ message, ...result });
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

// Nur für Tests exportiert. Der Router selbst bleibt der Default-Export,
// damit app.js unverändert `require('./routes/reports')` benutzen kann.
module.exports.__test__ = { pickDailyRepresentatives };
