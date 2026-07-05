const mongoose = require('mongoose');

/**
 * تغییرات نسبت به نسخه‌ی قبلی:
 *  - minStock حذف شد — دیگر مفهوم «حد نصاب / کمبود» وجود ندارد، فقط گزارش‌گیری از موجودی.
 *  - isLoose حذف شد — همان اطلاعات از طریق فیلد unit مشخص می‌شود (kg/g = کیلویی، Kiste/Stück/... = بسته‌بندی‌شده).
 *  - name دیگر به‌تنهایی unique نیست — یک محصول می‌تواند چند واریانت داشته باشد
 *    (مثلاً «Orange» هم Bio هم معمولی، هم در Kiste هم به‌صورت kg).
 *    یکتایی واقعی روی ترکیب (name + isBio + unit) است؛ یعنی این ۴ رکورد همزمان معتبرند:
 *      Orange / isBio:true  / unit:'Kiste'
 *      Orange / isBio:false / unit:'Kiste'
 *      Orange / isBio:true  / unit:'kg'
 *      Orange / isBio:false / unit:'kg'
 *  - category و unit دیگر enum هاردکد نیستند؛ مقدارشان باید در کالکشن‌های
 *    Category و Unit موجود باشد (اعتبارسنجی در routes/products.js انجام می‌شود).
 */
const productSchema = new mongoose.Schema({
  emoji:          { type: String, default: '📦', maxlength: 16 },
  name:           { type: String, required: true, trim: true, maxlength: 100 },
  category:       { type: String, required: true, trim: true, index: true, maxlength: 60 },
  unit:           { type: String, required: true, trim: true, default: 'Kiste', maxlength: 30 },
  isBio:          { type: Boolean, default: false, index: true },
  currentStock:   { type: Number, default: 0, min: 0 },
  yesterdayStock: { type: Number, default: 0, min: 0 },
  isActive:       { type: Boolean, default: true, index: true },
  updatedBy:      { type: mongoose.Schema.Types.ObjectId, ref: 'User' }
}, {
  timestamps: true,
  toJSON:   { virtuals: true },
  toObject: { virtuals: true }
});

// یکتایی واقعی روی ترکیب نام + Bio + واحد (نه فقط نام)
productSchema.index({ name: 1, isBio: 1, unit: 1 }, { unique: true });

// «مصرف» = چقدر از پایه‌ی نیمه‌شب (yesterdayStock) تا الان کم شده
productSchema.virtual('consumed').get(function () {
  return Math.max(0, (this.yesterdayStock ?? 0) - (this.currentStock ?? 0));
});

module.exports = mongoose.model('Product', productSchema);
