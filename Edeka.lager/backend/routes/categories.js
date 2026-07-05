const express  = require('express');
const router   = express.Router();
const auth     = require('../middleware/auth');
const Category = require('../models/Category');
const Product  = require('../models/Product');

// GET /api/categories — لیست همه دسته‌بندی‌ها
router.get('/', auth, async (req, res) => {
  const categories = await Category.find().sort({ order: 1, name: 1 });
  res.json(categories);
});

// POST /api/categories — افزودن دسته‌بندی جدید (هر کاربر لاگین‌شده، نه فقط ادمین)
router.post('/', auth, async (req, res, next) => {
  try {
    const { name, emoji } = req.body;
    if (!name || !name.trim())
      return res.status(400).json({ message: 'Name der Kategorie erforderlich' });

    const exists = await Category.findOne({ name: name.trim() });
    if (exists) return res.status(400).json({ message: 'Diese Kategorie existiert bereits' });

    const category = await Category.create({
      name:  name.trim(),
      emoji: emoji || '📦'
    });
    res.status(201).json(category);
  } catch (err) {
    if (err.code === 11000) return res.status(400).json({ message: 'Diese Kategorie existiert bereits' });
    next(err);
  }
});

// PUT /api/categories/:id — ویرایش (فقط ادمین) — نام/ایموجی/ترتیب
router.put('/:id', auth, async (req, res, next) => {
  try {
    if (req.user.role !== 'admin')
      return res.status(403).json({ message: 'Nur Admins dürfen Kategorien bearbeiten' });

    const oldCategory = await Category.findById(req.params.id);
    if (!oldCategory) return res.status(404).json({ message: 'Kategorie nicht gefunden' });

    const { name, emoji, order } = req.body;
    const updates = {};
    if (name  !== undefined && name.trim()) updates.name  = name.trim();
    if (emoji !== undefined) updates.emoji = emoji;
    if (order !== undefined) updates.order = order;

    const category = await Category.findByIdAndUpdate(req.params.id, updates, { returnDocument: 'after', runValidators: true });

    // اگر نام دسته عوض شد، محصولاتی که این دسته را دارند هم به‌روزرسانی شوند
    if (updates.name && updates.name !== oldCategory.name) {
      await Product.updateMany({ category: oldCategory.name }, { category: updates.name });
    }

    res.json(category);
  } catch (err) {
    if (err.code === 11000) return res.status(400).json({ message: 'Diese Kategorie existiert bereits' });
    next(err);
  }
});

// DELETE /api/categories/:id — حذف (فقط ادمین، فقط اگر هیچ محصول فعالی از آن استفاده نکند)
router.delete('/:id', auth, async (req, res) => {
  if (req.user.role !== 'admin')
    return res.status(403).json({ message: 'Nur Admins dürfen Kategorien löschen' });

  const category = await Category.findById(req.params.id);
  if (!category) return res.status(404).json({ message: 'Kategorie nicht gefunden' });

  const inUse = await Product.countDocuments({ category: category.name, isActive: true });
  if (inUse > 0) {
    return res.status(400).json({
      message: `Diese Kategorie wird von ${inUse} Produkt(en) verwendet. Bitte zuerst diese Produkte umkategorisieren.`
    });
  }

  await Category.findByIdAndDelete(req.params.id);
  res.json({ message: '🗑️ Kategorie gelöscht' });
});

module.exports = router;
