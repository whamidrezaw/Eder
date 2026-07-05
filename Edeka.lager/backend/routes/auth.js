const express   = require('express');
const router    = express.Router();
const jwt       = require('jsonwebtoken');
const bcrypt    = require('bcryptjs');
const rateLimit = require('express-rate-limit');
const User      = require('../models/User');
const auth      = require('../middleware/auth');

// ── Rate Limiting برای Login ────────────────────────────────────────
// قبلاً هیچ محدودیتی روی تلاش‌های ورود نبود (brute-force ممکن بود)، درحالی
// که فرانت‌اند (index.html) از قبل منتظر یک پاسخ 429 بود و پیام مخصوص آن
// را نمایش می‌داد — یعنی این محدودیت وجود نداشت ولی از آن انتظار می‌رفت.
// کلید محدودیت IP کلاینت است (req.ip؛ به تنظیم trust proxy در server.js
// احترام می‌گذارد)، نه یوزرنیم، تا هم brute-force روی یک حساب و هم
// password-spraying روی چند حساب از یک IP را محدود کند.
const loginLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 10,
  standardHeaders: true,
  legacyHeaders: false,
  message: { message: 'Zu viele Login-Versuche. Bitte versuchen Sie es in einigen Minuten erneut.' }
});

// یک IP که ظاهر IPv4/IPv6 معتبر ندارد ذخیره نمی‌شود — هدف جلوگیری از این
// است که یک مقدار جعلی/دستکاری‌شده بعداً در پنل «Login-Verlauf» رندر شود
// (دفاع در عمق؛ سمت فرانت‌اند هم escapeHtml روی این فیلد اعمال می‌شود).
function safeIp(raw) {
  const ip = String(raw || '').trim();
  if (/^(\d{1,3}\.){3}\d{1,3}$/.test(ip) && ip.split('.').every(o => Number(o) <= 255)) return ip;
  if (/^[0-9a-fA-F:]+$/.test(ip) && ip.includes(':') && ip.length <= 45) return ip;
  return '';
}

// POST /api/auth/register  — فقط admin می‌تواند کاربر بسازد
// توجه: برای ایجاد کاربر کامل (با telegramChatId و isActive) از /api/users استفاده کنید
router.post('/register', auth, async (req, res) => {
  if (req.user.role !== 'admin')
    return res.status(403).json({ message: 'Nur Admins dürfen Benutzer erstellen' });

  const { username, password, name, role, telegramChatId, isActive } = req.body;

  if (!username || !password || !name)
    return res.status(400).json({ message: 'username, password und name sind erforderlich' });
  if (password.length < 6)
    return res.status(400).json({ message: 'Passwort mindestens 6 Zeichen' });

  const exists = await User.findOne({ username });
  if (exists) return res.status(400).json({ message: 'Benutzername bereits vergeben' });

  const hashedPassword = await bcrypt.hash(password, 12);
  const user = await User.create({
    username,
    password: hashedPassword,
    name,
    role: role || 'lagerist',
    telegramChatId: telegramChatId || null,
    isActive: isActive !== false  // پیش‌فرض: فعال
  });

  res.status(201).json({
    message: 'Benutzer erstellt',
    user: {
      id: user._id,
      username: user.username,
      name: user.name,
      role: user.role,
      isActive: user.isActive
    }
  });
});

// POST /api/auth/login
router.post('/login', loginLimiter, async (req, res) => {
  const { username, password } = req.body;

  if (!username || !password)
    return res.status(400).json({ message: 'Benutzername und Passwort erforderlich' });

  const ip        = safeIp(req.ip);
  const userAgent = String(req.headers['user-agent'] || '').slice(0, 300);

  const user = await User.findOne({ username });
  if (!user || !user.isActive)
    return res.status(401).json({ message: 'Benutzername oder Passwort falsch' });

  const valid = await bcrypt.compare(password, user.password);
  if (!valid)
    return res.status(401).json({ message: 'Benutzername oder Passwort falsch' });

  // Login-Log speichern (über die Model-Methode, wie im User-Model vorgesehen)
  user.addLoginEntry({ ip, userAgent, action: 'login' });
  await user.save();

  const token = jwt.sign(
    { id: user._id },
    process.env.JWT_SECRET,
    { expiresIn: process.env.JWT_EXPIRES_IN || '7d' }
  );

  res.json({
    token,
    user: {
      id: user._id,
      name: user.name,
      username: user.username,
      role: user.role
    }
  });
});

// GET /api/auth/me  — اطلاعات کاربر جاری (بدون رمز و loginHistory)
router.get('/me', auth, async (req, res) => {
  const user = await User.findById(req.user._id).select('-password -loginHistory');
  if (!user) return res.status(404).json({ message: 'Benutzer nicht gefunden' });
  res.json(user);
});

// PUT /api/auth/change-password  — تغییر رمز توسط کاربر خودش
router.put('/change-password', auth, async (req, res) => {
  const { currentPassword, newPassword } = req.body;

  if (!currentPassword)
    return res.status(400).json({ message: 'Aktuelles Passwort erforderlich' });
  if (!newPassword || newPassword.length < 6)
    return res.status(400).json({ message: 'Neues Passwort muss mindestens 6 Zeichen haben' });

  const user = await User.findById(req.user._id);
  if (!user) return res.status(404).json({ message: 'Benutzer nicht gefunden' });

  const valid = await bcrypt.compare(currentPassword, user.password);
  if (!valid)
    return res.status(401).json({ message: 'Aktuelles Passwort falsch' });

  const hashed = await bcrypt.hash(newPassword, 12);
  await User.findByIdAndUpdate(user._id, { password: hashed });
  res.json({ message: '✅ Passwort erfolgreich geändert' });
});

module.exports = router;
