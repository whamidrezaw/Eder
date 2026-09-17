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
/**
 * Schließt einen Tag ab: legt die endgültige Momentaufnahme als offizielles
 * Protokoll dieses Tages an und setzt yesterdayStock als Basislinie für den
 * Folgetag. Wird vom Mitternachts-Cron, vom Nachholen beim Start und von der
 * Admin-Route benutzt. Verschickt nichts an Telegram.
 *
 * Idempotent: Ein Tag wird nur einmal geschlossen. Ohne diese Prüfung setzte
 * ein zweiter Aufruf yesterdayStock auf den AKTUELLEN Bestand und löschte
 * damit den bis dahin gemessenen Tagesverbrauch — ein Klick auf
 * "Tag manuell schließen" um 09:00 Uhr kostete den ganzen Vormittag.
 *
 * options.force = true schließt einen bereits geschlossenen Tag erneut.
 * Das ist für echte Korrekturen gedacht: Das bestehende Protokoll wird
 * überschrieben (nicht verdoppelt) und die Basislinie neu gesetzt.
 */
async function closeDay(dateStr, options = {}) {
  const force = options.force === true;

  const vorhanden = await DailyLog
    .findOne({ date: dateStr, type: 'auto-midnight' })
    .select('_id')
    .lean();

  if (vorhanden && !force) {
    return { skipped: true, reason: 'already-closed', logId: vorhanden._id, date: dateStr, count: 0 };
  }

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

  let logId;
  if (vorhanden) {
    // force-Pfad: bestehendes Protokoll aktualisieren. Ein zweites anzulegen
    // würde am eindeutigen Index scheitern — und wäre auch fachlich falsch.
    await DailyLog.updateOne(
      { _id: vorhanden._id },
      { $set: { sentAt: new Date(), snapshot, reportSent: false } }
    );
    logId = vorhanden._id;
  } else {
    try {
      const log = await DailyLog.create({
        date:       dateStr,
        sentAt:     new Date(),
        type:       'auto-midnight',
        snapshot,
        createdBy:  null,
        reportSent: false
      });
      logId = log._id;
    } catch (err) {
      // Zwei Prozesse gleichzeitig: der eindeutige Index lässt nur einen
      // durch. Der andere hat nichts zu tun — das ist kein Fehlerfall.
      if (err && err.code === 11000) {
        return { skipped: true, reason: 'race-already-closed', date: dateStr, count: 0 };
      }
      throw err;
    }
  }

  // Basislinie in EINER atomaren Operation. Die Pipeline liest currentStock
  // im Moment des Schreibens — nicht aus den oben gelesenen Dokumenten.
  // Vorher standen hier N einzelne findByIdAndUpdate mit vorab gelesenen
  // Werten: bei 40 Produkten 40 Rundreisen, und eine gleichzeitige
  // Bestandsänderung erzeugte am nächsten Tag einen Verbrauch, den es
  // nie gab.
  const basislinie = await Product.updateMany(
    { isActive: true },
    [{ $set: { yesterdayStock: '$currentStock' } }]
  );

  return {
    logId,
    date:            dateStr,
    count:           products.length,
    forced:          force,
    baselineUpdated: basislinie.modifiedCount ?? 0
  };
}

/**
 * Holt einen verpassten Tagesabschluss beim Start nach.
 *
 * War der Server um 00:00 aus, lief der Cron-Job nie. yesterdayStock blieb
 * dann auf dem Wert des Vortags und die Anzeige "Verbrauch seit Mitternacht"
 * war den ganzen folgenden Tag falsch, ohne dass es auffiel.
 *
 * Läuft absichtlich still, wenn es nichts zu tun gibt.
 */
async function catchUpIfNeeded() {
  const dateStr = yesterdayInBerlin();

  const vorhanden = await DailyLog
    .findOne({ date: dateStr, type: 'auto-midnight' })
    .select('_id')
    .lean();
  if (vorhanden) return { skipped: true, reason: 'already-closed', date: dateStr };

  const anzahl = await Product.countDocuments({ isActive: true });
  if (anzahl === 0) return { skipped: true, reason: 'no-products', date: dateStr };

  console.log(`⏳ Tagesabschluss für ${dateStr} fehlt — wird nachgeholt`);
  const ergebnis = await closeDay(dateStr);
  console.log(`✅ Tagesabschluss nachgeholt: ${dateStr} (${ergebnis.count} Produkte)`);
  return ergebnis;
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

module.exports = { closeDay, catchUpIfNeeded, scheduleDailyClose, yesterdayInBerlin, berlinDateString };
