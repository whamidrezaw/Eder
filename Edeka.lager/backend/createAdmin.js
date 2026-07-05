require('dotenv').config();
const mongoose = require('mongoose');
const bcrypt   = require('bcryptjs');
const User     = require('./models/User');

async function createAdmin() {
  // FIX #7: رمز از argument یا .env — hardcode نیست
  const username = process.argv[2] || 'admin';
  const password = process.argv[3] || process.env.ADMIN_PASSWORD;

  if (!password) {
    console.error('❌ Passwort erforderlich!');
    console.error('   Nutzung: node createAdmin.js [username] [password]');
    console.error('   Oder:    ADMIN_PASSWORD=... in .env setzen');
    process.exit(1);
  }

  if (password.length < 8) {
    console.error('❌ Passwort muss mindestens 8 Zeichen haben');
    process.exit(1);
  }

  await mongoose.connect(process.env.MONGODB_URI, { serverSelectionTimeoutMS: 5000 });
  console.log('✅ MongoDB verbunden');

  // FIX #8: User.create statt insertOne → Schema-Validierung greift
  const exists = await User.findOne({ username });
  if (exists) {
    console.log(`⚠️  Benutzer "${username}" existiert bereits`);
    // FIX #9: Verbindung sauber schließen
    await mongoose.disconnect();
    process.exit(0);
  }

  const hashedPassword = await bcrypt.hash(password, 12);
  const user = await User.create({
    username,
    password:   hashedPassword,
    name:       'Administrator',
    role:       'admin',
    isActive:   true,
    telegramChatId: null
  });

  console.log(`✅ Admin erfolgreich erstellt!`);
  console.log(`   Benutzername: ${user.username}`);
  console.log(`   Name:         ${user.name}`);
  console.log(`   Rolle:        ${user.role}`);
  console.log(`   ⚠️  Passwort sicher aufbewahren!`);

  await mongoose.disconnect();   // FIX #9
  process.exit(0);
}

createAdmin().catch(err => {
  console.error('❌ Fehler:', err.message);
  mongoose.disconnect().finally(() => process.exit(1));
});
