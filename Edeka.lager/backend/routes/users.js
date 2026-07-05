const express = require('express');
const router  = express.Router();
const bcrypt  = require('bcryptjs');
const auth    = require('../middleware/auth');
const User    = require('../models/User');

// میدل‌ور: فقط admin مجاز است
function adminOnly(req, res, next) {
  if (req.user.role !== 'admin')
    return res.status(403).json({ message: 'Nur für Admins zugänglich' });
  next();
}

// GET /api/users  — لیست همه کاربران (بدون رمز)
router.get('/', auth, adminOnly, async (req, res) => {
  const users = await User.find({}, '-password').sort({ createdAt: -1 });
  res.json(users);
});

// GET /api/users/:id  — جزئیات یک کاربر + تاریخچه ورود
router.get('/:id', auth, adminOnly, async (req, res) => {
  const user = await User.findById(req.params.id, '-password');
  if (!user) return res.status(404).json({ message: 'Benutzer nicht gefunden' });
  res.json(user);
});

// POST /api/users  — ایجاد کاربر جدید
router.post('/', auth, adminOnly, async (req, res) => {
  const { username, password, name, role, telegramChatId, isActive } = req.body;

  if (!username || !password || !name)
    return res.status(400).json({ message: 'username, password und name sind erforderlich' });
  if (password.length < 6)
    return res.status(400).json({ message: 'Passwort mindestens 6 Zeichen' });

  const exists = await User.findOne({ username });
  if (exists) return res.status(400).json({ message: 'Benutzername bereits vergeben' });

  const hashed = await bcrypt.hash(password, 12);
  const user   = await User.create({
    username,
    password:       hashed,
    name,
    role:           role           || 'lagerist',
    telegramChatId: telegramChatId || null,
    isActive:       isActive !== false  // پیش‌فرض: فعال
  });

  res.status(201).json({
    message: '✅ Benutzer erstellt',
    user: {
      id:       user._id,
      username: user.username,
      name:     user.name,
      role:     user.role,
      isActive: user.isActive
    }
  });
});

// PUT /api/users/:id  — ویرایش مشخصات کاربر
router.put('/:id', auth, adminOnly, async (req, res) => {
  const allowed = ['name', 'role', 'isActive', 'telegramChatId'];
  const updates = {};
  allowed.forEach(k => { if (req.body[k] !== undefined) updates[k] = req.body[k]; });

  // یک ادمین نمی‌تواند نقش خودش را (در همین درخواست) از admin عوض کند —
  // چون middleware/auth.js کاربر را در هر درخواست از نو از DB می‌خواند،
  // اثر این تغییر بلافاصله از درخواست بعدی اعمال می‌شود و می‌تواند خود
  // ادمین را فوراً از تمام صفحات مدیریتی قفل کند. برای این حالت خاص باید
  // یک ادمین دیگر نقش را عوض کند.
  if (
    req.params.id === req.user._id.toString() &&
    updates.role !== undefined &&
    updates.role !== 'admin'
  ) {
    return res.status(400).json({ message: 'Sie können Ihre eigene Admin-Rolle nicht selbst entfernen. Lassen Sie das einen anderen Admin tun.' });
  }

  const user = await User.findByIdAndUpdate(
    req.params.id,
    updates,
    { returnDocument: 'after', select: '-password', runValidators: true }
  );
  if (!user) return res.status(404).json({ message: 'Benutzer nicht gefunden' });
  res.json(user);
});

// PUT /api/users/:id/reset-password  — ریست رمز توسط admin
router.put('/:id/reset-password', auth, adminOnly, async (req, res) => {
  const { newPassword } = req.body;
  if (!newPassword || newPassword.length < 6)
    return res.status(400).json({ message: 'Passwort mindestens 6 Zeichen' });

  const hashed = await bcrypt.hash(newPassword, 12);
  const user   = await User.findByIdAndUpdate(req.params.id, { password: hashed });
  if (!user) return res.status(404).json({ message: 'Benutzer nicht gefunden' });
  res.json({ message: '✅ Passwort zurückgesetzt' });
});

// DELETE /api/users/:id  — غیرفعال‌کردن یا حذف کامل
// ?permanent=true → حذف کامل از دیتابیس
// بدون پارامتر    → isActive=false (soft delete)
router.delete('/:id', auth, adminOnly, async (req, res) => {
  // جلوگیری از حذف خود
  if (req.params.id === req.user._id.toString())
    return res.status(400).json({ message: 'Sie können sich nicht selbst löschen' });

  const permanent = String(req.query.permanent || '').toLowerCase() === 'true';

  if (permanent) {
    const deleted = await User.findByIdAndDelete(req.params.id);
    if (!deleted) return res.status(404).json({ message: 'Benutzer nicht gefunden' });
    return res.json({ message: '🗑️ Benutzer endgültig gelöscht' });
  }

  // Soft delete: غیرفعال کردن
  const user = await User.findByIdAndUpdate(
    req.params.id,
    { isActive: false },
    { returnDocument: 'after', select: '-password' }
  );
  if (!user) return res.status(404).json({ message: 'Benutzer nicht gefunden' });
  res.json({ message: '✅ Benutzer deaktiviert', user });
});

module.exports = router;
