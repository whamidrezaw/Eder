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
    {
      // Typprüfung VOR Number(): Number([]) ist 0, Number(["5"]) ist 5.
      // Ohne diese Zeile setzt ein leeres Array den Bestand still auf null.
      const geprueft = require('../lib/validate').parseStock(currentStock ?? 0);
      if (geprueft === null) {
        return res.status(400).json({ message: 'Ungültiger Bestandswert. Erwartet wird eine Zahl ab 0.' });
      }
    }

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
  const { currentStock, updatedAt } = req.body;

  // Typprüfung VOR Number(): Number([]) ist 0, Number(["5"]) ist 5.
  // Ohne sie setzt ein leeres Array den Bestand still auf null.
  // Die Bestandsprüfung steht bewusst VOR der Versionsprüfung: ein
  // unsinniger Wert ist ein unsinniger Wert, egal welche Version dabei
  // liegt.
  const wert = require('../lib/validate').parseStock(currentStock);
  if (wert === null) {
    return res.status(400).json({ message: 'Ungültiger Bestandswert. Erwartet wird eine Zahl ab 0.' });
  }

  // ── Optimistische Sperre ──────────────────────────────────────
  // Das Formular nimmt eine ABSOLUTE Zählung entgegen ("ich sehe 4 im
  // Regal"), keine Bewegung. Zählen zwei Lageristen gleichzeitig, darf
  // die ältere Zählung die neuere nicht überschreiben — und schon gar
  // nicht lautlos. Beides zusammenzurechnen wäre falsch: dabei käme ein
  // dritter Wert heraus, den niemand im Regal gesehen hat.
  //
  // Als Version dient updatedAt. Mongoose pflegt es bei jedem Update
  // (timestamps: true). __v taugt nicht: findByIdAndUpdate zählt es
  // nicht hoch, es bliebe also immer gleich.
  if (updatedAt === undefined || updatedAt === null || updatedAt === '') {
    return res.status(400).json({
      message: 'Es fehlt der Stand, auf dem die Eingabe beruht (updatedAt).',
      code: 'VERSION_REQUIRED'
    });
  }
  const erwartet = new Date(updatedAt);
  if (Number.isNaN(erwartet.getTime())) {
    return res.status(400).json({ message: 'Ungültiger Wert für updatedAt.', code: 'VERSION_REQUIRED' });
  }

  // Prüfen und Schreiben in EINER Operation: zwischen einem getrennten
  // Lesen und Schreiben passte sonst genau der Konflikt, den wir hier
  // verhindern wollen.
  const product = await Product.findOneAndUpdate(
    { _id: req.params.id, updatedAt: erwartet },
    { currentStock: wert, updatedBy: req.user._id },
    { returnDocument: 'after', runValidators: true }
  );
  if (product) return res.json(product);

  // Kein Treffer heißt zweierlei: das Produkt gibt es nicht, oder
  // jemand war schneller. Die Fälle müssen unterschieden werden.
  const aktuell = await Product.findById(req.params.id).lean();
  if (!aktuell) return res.status(404).json({ message: 'Produkt nicht gefunden' });

  // Der aktuelle Stand geht mit: ohne ihn kann der Aufrufer nur
  // "Fehler" anzeigen, mit ihm kann er fragen und es erneut versuchen.
  return res.status(409).json({
    message: `Der Bestand wurde inzwischen auf ${aktuell.currentStock} geändert.`,
    code: 'STOCK_CONFLICT',
    currentStock: aktuell.currentStock,
    updatedAt: aktuell.updatedAt
  });
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
