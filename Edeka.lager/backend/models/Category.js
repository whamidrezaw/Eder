const mongoose = require('mongoose');

/**
 * دسته‌بندی‌ها دیگر enum هاردکد نیستند — یک کالکشن کوچک و مدیریت‌پذیر هستند
 * تا کاربر بتواند هر وقت خواست از فرم افزودن محصول، دسته‌بندی جدید بسازد.
 */
const categorySchema = new mongoose.Schema({
  name:  { type: String, required: true, trim: true, unique: true, maxlength: 60 },
  emoji: { type: String, default: '📦', trim: true, maxlength: 16 },
  order: { type: Number, default: 0 }
}, {
  timestamps: true
});

module.exports = mongoose.model('Category', categorySchema);
