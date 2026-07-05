const mongoose = require('mongoose');

const loginEntrySchema = new mongoose.Schema({
  timestamp: { type: Date,   default: Date.now },
  // طول این دو فیلد اینجا هم محدود شده (علاوه بر اعتبارسنجی در routes/auth.js)
  // چون هر دو از هدرهای HTTP کلاینت می‌آیند و بعداً در پنل Login-Verlauf
  // نمایش داده می‌شوند — یک لایه‌ی دفاعی اضافه، نه جایگزین escaping.
  ip:        { type: String, default: '', maxlength: 45 },
  userAgent: { type: String, default: '', maxlength: 300 },
  action:    { type: String, enum: ['login', 'logout'], default: 'login' }
}, { _id: false });

const userSchema = new mongoose.Schema({
  username: {
    type: String, required: true, unique: true,
    trim: true, lowercase: true, maxlength: 60
  },
  password:       { type: String, required: true },
  name:           { type: String, required: true, trim: true, maxlength: 100 },
  role: {
    type: String,
    enum: ['admin', 'lagerist'],
    default: 'lagerist',
    index: true
  },
  telegramChatId: {
    type: String,
    default: null,
    // Telegram-Chat-IDs sind immer numerisch (Gruppen können negativ sein).
    // null/leer ist weiterhin erlaubt (Feld ist optional).
    match: [/^-?\d+$/, 'Telegram Chat-ID muss numerisch sein']
  },
  isActive:       { type: Boolean, default: true, index: true },
  lastLogin:      { type: Date,    default: null },
  loginHistory:   { type: [loginEntrySchema], default: [] }
}, {
  timestamps: true   // createdAt + updatedAt خودکار
});

/**
 * FIX #4: addLoginEntry واقعاً در auth.js route استفاده می‌شود.
 * این متد را در auth.js به جای findByIdAndUpdate مستقیم صدا بزنید:
 *
 *   const user = await User.findById(...);
 *   user.addLoginEntry({ ip, userAgent, action: 'login' });
 *   await user.save();
 */
userSchema.methods.addLoginEntry = function(entry) {
  this.loginHistory = [
    { timestamp: new Date(), ...entry },
    ...this.loginHistory
  ].slice(0, 50);
  this.lastLogin = new Date();
  return this;   // برای chaining
};

module.exports = mongoose.model('User', userSchema);
