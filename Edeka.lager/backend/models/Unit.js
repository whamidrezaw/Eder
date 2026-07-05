const mongoose = require('mongoose');

/**
 * واحدها هم مثل دسته‌بندی‌ها داینامیک هستند (Kiste, kg, Stück, Bund, ...)
 * و از فرم افزودن محصول قابل افزودن هستند.
 */
const unitSchema = new mongoose.Schema({
  name:  { type: String, required: true, trim: true, unique: true, maxlength: 30 },
  order: { type: Number, default: 0 }
}, {
  timestamps: true
});

module.exports = mongoose.model('Unit', unitSchema);
