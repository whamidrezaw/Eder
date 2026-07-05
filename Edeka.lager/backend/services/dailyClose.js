const cron     = require('node-cron');
const Product  = require('../models/Product');
const DailyLog = require('../models/DailyLog');

const TIMEZONE = 'Europe/Berlin';

/** رشته‌ی YYYY-MM-DD یک تاریخ، به وقت برلین */
function berlinDateString(date) {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: TIMEZONE, year: 'numeric', month: '2-digit', day: '2-digit'
  }).format(date);
}

/**
 * تاریخ «دیروز» (روزی که الان در حال تمام‌شدن است) را به وقت برلین برمی‌گرداند.
 * با ظهر UTC کار می‌کنیم تا مشکلات DST (تغییر ساعت تابستانی/زمستانی در آلمان) ایجاد نشود.
 */
function yesterdayInBerlin() {
  const todayStr = berlinDateString(new Date());
  const [y, m, d] = todayStr.split('-').map(Number);
  const noonUTC = new Date(Date.UTC(y, m - 1, d - 1, 12)); // ظهرِ UTC روز قبل
  return berlinDateString(noonUTC);
}

/**
 * بستن یک روز: یک snapshot نهایی از وضعیت فعلی محصولات می‌سازد، آن را به‌عنوان
 * رکورد رسمی همان روز ذخیره می‌کند، و yesterdayStock را برای فردا برابر
 * currentStock امروز می‌کند. هم توسط cron نیمه‌شب و هم به‌صورت دستی (ادمین) صداز ده می‌شود.
 * هیچ پیام تلگرامی در این مرحله ارسال نمی‌شود — فقط ثبت داخلی.
 */
async function closeDay(dateStr) {
  const products = await Product.find({ isActive: true });

  const snapshot = products.map(p => ({
    productId:    p._id,
    productName:  p.name,
    emoji:        p.emoji,
    category:     p.category,
    unit:         p.unit,
    isBio:        !!p.isBio,
    openingStock: p.yesterdayStock ?? 0,
    closingStock: p.currentStock  ?? 0,
    consumed:     Math.max(0, (p.yesterdayStock ?? 0) - (p.currentStock ?? 0))
  }));

  const log = await DailyLog.create({
    date:       dateStr,
    sentAt:     new Date(),
    type:       'auto-midnight',
    snapshot,
    createdBy:  null,
    reportSent: false
  });

  await Promise.all(
    products.map(p => Product.findByIdAndUpdate(p._id, { yesterdayStock: p.currentStock }))
  );

  return { logId: log._id, date: dateStr, count: products.length };
}

/** زمان‌بندی بستن خودکار روز، هر شب ساعت ۰۰:۰۰ به وقت برلین */
function scheduleDailyClose() {
  cron.schedule('0 0 * * *', async () => {
    const dateStr = yesterdayInBerlin();
    try {
      const result = await closeDay(dateStr);
      console.log(`✅ Tag automatisch geschlossen: ${dateStr} (${result.count} Produkte)`);
    } catch (err) {
      console.error(`❌ Fehler beim automatischen Tagesabschluss (${dateStr}):`, err.message);
    }
  }, { timezone: TIMEZONE });

  console.log(`🕐 Automatischer Tagesabschluss geplant — täglich 00:00 (${TIMEZONE})`);
}

module.exports = { closeDay, scheduleDailyClose, yesterdayInBerlin, berlinDateString };
