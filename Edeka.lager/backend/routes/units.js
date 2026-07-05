const express = require('express');
const router  = express.Router();
const auth    = require('../middleware/auth');
const Unit    = require('../models/Unit');
const Product = require('../models/Product');

// GET /api/units — لیست همه واحدها
router.get('/', auth, async (req, res) => {
  const units = await Unit.find().sort({ order: 1, name: 1 });
  res.json(units);
});

// POST /api/units — افزودن واحد جدید (هر کاربر لاگین‌شده)
router.post('/', auth, async (req, res, next) => {
  try {
    const { name } = req.body;
    if (!name || !name.trim())
      return res.status(400).json({ message: 'Name der Einheit erforderlich' });

    const exists = await Unit.findOne({ name: name.trim() });
    if (exists) return res.status(400).json({ message: 'Diese Einheit existiert bereits' });

    const unit = await Unit.create({ name: name.trim() });
    res.status(201).json(unit);
  } catch (err) {
    if (err.code === 11000) return res.status(400).json({ message: 'Diese Einheit existiert bereits' });
    next(err);
  }
});

// PUT /api/units/:id — ویرایش (فقط ادمین)
router.put('/:id', auth, async (req, res, next) => {
  try {
    if (req.user.role !== 'admin')
      return res.status(403).json({ message: 'Nur Admins dürfen Einheiten bearbeiten' });

    const oldUnit = await Unit.findById(req.params.id);
    if (!oldUnit) return res.status(404).json({ message: 'Einheit nicht gefunden' });

    const { name, order } = req.body;
    const updates = {};
    if (name  !== undefined && name.trim()) updates.name  = name.trim();
    if (order !== undefined) updates.order = order;

    const unit = await Unit.findByIdAndUpdate(req.params.id, updates, { returnDocument: 'after', runValidators: true });

    if (updates.name && updates.name !== oldUnit.name) {
      await Product.updateMany({ unit: oldUnit.name }, { unit: updates.name });
    }

    res.json(unit);
  } catch (err) {
    if (err.code === 11000) return res.status(400).json({ message: 'Diese Einheit existiert bereits' });
    next(err);
  }
});

// DELETE /api/units/:id — حذف (فقط ادمین، فقط اگر هیچ محصول فعالی از آن استفاده نکند)
router.delete('/:id', auth, async (req, res) => {
  if (req.user.role !== 'admin')
    return res.status(403).json({ message: 'Nur Admins dürfen Einheiten löschen' });

  const unit = await Unit.findById(req.params.id);
  if (!unit) return res.status(404).json({ message: 'Einheit nicht gefunden' });

  const inUse = await Product.countDocuments({ unit: unit.name, isActive: true });
  if (inUse > 0) {
    return res.status(400).json({
      message: `Diese Einheit wird von ${inUse} Produkt(en) verwendet. Bitte zuerst diese Produkte ändern.`
    });
  }

  await Unit.findByIdAndDelete(req.params.id);
  res.json({ message: '🗑️ Einheit gelöscht' });
});

module.exports = router;
