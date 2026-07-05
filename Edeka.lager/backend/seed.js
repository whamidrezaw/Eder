require('dotenv').config();
const mongoose  = require('mongoose');
const Category  = require('./models/Category');
const Unit      = require('./models/Unit');

const DEFAULT_CATEGORIES = [
  { name: 'Obst',          emoji: '🍎' },
  { name: 'Gemüse',        emoji: '🥦' },
  { name: 'Zitrusfrüchte', emoji: '🍊' },
  { name: 'Exotisch',      emoji: '🥭' },
  { name: 'Beeren',        emoji: '🫐' },
  { name: 'Kräuter',       emoji: '🌿' },
  { name: 'Pilze',         emoji: '🍄' },
  { name: 'Sonstige',      emoji: '📦' }
];

const DEFAULT_UNITS = [
  'Kiste', 'kg', 'g', 'Stück', 'Bund', 'Beutel', 'Karton', 'Netz', 'Sack', 'Steige'
];

async function seed() {
  await mongoose.connect(process.env.MONGODB_URI, { serverSelectionTimeoutMS: 5000 });
  console.log('✅ MongoDB verbunden');

  for (let i = 0; i < DEFAULT_CATEGORIES.length; i++) {
    const c = DEFAULT_CATEGORIES[i];
    const exists = await Category.findOne({ name: c.name });
    if (!exists) {
      await Category.create({ ...c, order: i });
      console.log(`  + Kategorie angelegt: ${c.emoji} ${c.name}`);
    }
  }

  for (let i = 0; i < DEFAULT_UNITS.length; i++) {
    const name = DEFAULT_UNITS[i];
    const exists = await Unit.findOne({ name });
    if (!exists) {
      await Unit.create({ name, order: i });
      console.log(`  + Einheit angelegt: ${name}`);
    }
  }

  console.log('✅ Seed abgeschlossen — Kategorien und Einheiten sind bereit.');
  console.log('   Beides ist später jederzeit über das Produktformular erweiterbar.');
  await mongoose.disconnect();
  process.exit(0);
}

seed().catch(err => {
  console.error('❌ Fehler beim Seed:', err.message);
  mongoose.disconnect().finally(() => process.exit(1));
});
