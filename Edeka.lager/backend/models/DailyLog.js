const mongoose = require('mongoose');

/**
 * تغییرات نسبت به نسخه‌ی قبلی:
 *  - date دیگر unique نیست — چند گزارش در یک روز مجاز است (هر چندبار که دستی گزارش بفرستید).
 *  - sentAt اضافه شد: تایم‌استمپ دقیق لحظه‌ی ثبت/ارسال این گزارش به‌خصوص.
 *  - type: 'manual' = شما دکمه‌ی «ارسال گزارش» را زدید · 'auto-midnight' = بستن خودکار روز توسط سرور در ۰۰:۰۰.
 *  - minStock و isLoose از snapshotItemSchema حذف شدند (چون از Product هم حذف شدند).
 */
const snapshotItemSchema = new mongoose.Schema({
  productId:    { type: mongoose.Schema.Types.ObjectId, ref: 'Product' },
  productName:  { type: String, required: true },
  emoji:        { type: String, default: '📦' },
  category:     { type: String, default: 'Sonstige' },
  unit:         { type: String, default: 'Kiste' },
  isBio:        { type: Boolean, default: false },
  openingStock: { type: Number, default: 0 },
  closingStock: { type: Number, default: 0 },
  consumed:     { type: Number, default: 0 }
}, { _id: false });

const dailyLogSchema = new mongoose.Schema({
  date: {
    type:     String,
    required: true,
    match:    /^\d{4}-\d{2}-\d{2}$/   // فرمت YYYY-MM-DD
  },
  sentAt: { type: Date, required: true, default: Date.now },
  type: {
    type:    String,
    enum:    ['manual', 'auto-midnight'],
    default: 'manual'
  },
  snapshot:   { type: [snapshotItemSchema], default: [] },
  createdBy:  { type: mongoose.Schema.Types.ObjectId, ref: 'User', default: null },
  reportSent: { type: Boolean, default: false }   // آیا ارسال به تلگرام موفق بود
}, {
  timestamps: true
});

// کوئری سریع روی روز + ترتیب زمانی درون همان روز
dailyLogSchema.index({ date: -1, sentAt: -1 });

module.exports = mongoose.model('DailyLog', dailyLogSchema);
