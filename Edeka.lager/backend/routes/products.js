const express  = require('express');
const router   = express.Router();
const auth     = require('../middleware/auth');
const Product  = require('../models/Product');
const Category = require('../models/Category');
const Unit     = require('../models/Unit');

// GET /api/products — همه محصولات فعال (هر واریانت Bio/واحد یک رکورد جداست)
router.get('/', auth, async (req, res) => {
  const filter = { isActive: true };
  if (req.query.category) filter.category = req.query.category;
  if (req.query.unit)     filter.unit     = req.query.unit;
  if (req.query.isBio === 'true')  filter.isBio = true;
  if (req.query.isBio === 'false') filter.isBio = false;

  const products = await Product.find(filter).sort({ category: 1, name: 1, isBio: 1, unit: 1 });
  res.json(products);
});

// POST /api/products — واریانت جدید یک محصول (نام + Bio + واحد باید ترکیب یکتا باشد)
router.post('/', auth, async (req, res, next) => {
  try {
    const { emoji, name, category, currentStock, unit, isBio } = req.body;

    if (!name || !name.trim())
      return res.status(400).json({ message: 'Produktname erforderlich' });
    if (!category)
      return res.status(400).json({ message: 'Kategorie erforderlich' });
    if (!unit)
      return res.status(400).json({ message: 'Einheit erforderlich' });

    const [catExists, unitExists] = await Promise.all([
      Category.findOne({ name: category }),
      Unit.findOne({ name: unit })
    ]);
    if (!catExists)  return res.status(400).json({ message: `Unbekannte Kategorie: ${category}` });
    if (!unitExists) return res.status(400).json({ message: `Unbekannte Einheit: ${unit}` });

    const startStock = Number(currentStock) || 0;

    const product = await Product.create({
      emoji:          emoji || '📦',
      name:           name.trim(),
      category,
      unit,
      isBio:          !!isBio,
      currentStock:   startStock,
      yesterdayStock: startStock,
      isActive:       true,
      updatedBy:      req.user._id
    });

    res.status(201).json(product);
  } catch (err) {
    if (err.code === 11000) {
      return res.status(400).json({ message: 'Diese Variante (Name + Bio + Einheit) existiert bereits' });
    }
    next(err);
  }
});

// PUT /api/products/:id — ویرایش مشخصات واریانت (نام، ایموجی، دسته، واحد، Bio)
router.put('/:id', auth, async (req, res, next) => {
  try {
    const allowed = ['name', 'emoji', 'unit', 'category', 'isBio'];
    const updates = {};
    allowed.forEach(k => { if (req.body[k] !== undefined) updates[k] = req.body[k]; });

    if (updates.category) {
      const catExists = await Category.findOne({ name: updates.category });
      if (!catExists) return res.status(400).json({ message: `Unbekannte Kategorie: ${updates.category}` });
    }
    if (updates.unit) {
      const unitExists = await Unit.findOne({ name: updates.unit });
      if (!unitExists) return res.status(400).json({ message: `Unbekannte Einheit: ${updates.unit}` });
    }
    if (updates.name) updates.name = updates.name.trim();

    updates.updatedBy = req.user._id;

    const product = await Product.findByIdAndUpdate(
      req.params.id,
      updates,
      { returnDocument: 'after', runValidators: true }
    );
    if (!product) return res.status(404).json({ message: 'Produkt nicht gefunden' });
    res.json(product);
  } catch (err) {
    if (err.code === 11000) {
      return res.status(400).json({ message: 'Diese Variante (Name + Bio + Einheit) existiert bereits' });
    }
    next(err);
  }
});

// PATCH /api/products/:id/stock — به‌روزرسانی موجودی فعلی (همان عملکرد گزارش‌گیری روزمره)
router.patch('/:id/stock', auth, async (req, res) => {
  const { currentStock } = req.body;

  // FIX: "currentStock < 0" به‌تنهایی مقادیر نامعتبر مثل NaN یا رشته را رد
  // نمی‌کرد (NaN < 0 هم false است)، پس اینجا صراحتاً یک عدد متناهی و غیرمنفی
  // می‌خواهیم.
  const value = Number(currentStock);
  if (currentStock === undefined || currentStock === null || !Number.isFinite(value) || value < 0)
    return res.status(400).json({ message: 'Ungültiger Bestandswert' });

  const product = await Product.findByIdAndUpdate(
    req.params.id,
    { currentStock: value, updatedBy: req.user._id },
    { returnDocument: 'after', runValidators: true }
  );
  if (!product) return res.status(404).json({ message: 'Produkt nicht gefunden' });
  res.json(product);
});

// DELETE /api/products/:id — غیرفعال‌کردن (پیش‌فرض) یا حذف کامل (?permanent=true, فقط ادمین)
router.delete('/:id', auth, async (req, res) => {
  const permanent = String(req.query.permanent || '').toLowerCase() === 'true';

  if (permanent) {
    if (req.user.role !== 'admin')
      return res.status(403).json({ message: 'Nur Admins dürfen Produkte endgültig löschen' });
    const deleted = await Product.findByIdAndDelete(req.params.id);
    if (!deleted) return res.status(404).json({ message: 'Produkt nicht gefunden' });
    return res.json({ message: '🗑️ Produkt endgültig gelöscht' });
  }

  const product = await Product.findByIdAndUpdate(
    req.params.id,
    { isActive: false, updatedBy: req.user._id },
    { returnDocument: 'after' }
  );
  if (!product) return res.status(404).json({ message: 'Produkt nicht gefunden' });
  res.json({ message: 'Produkt deaktiviert' });
});

module.exports = router;
