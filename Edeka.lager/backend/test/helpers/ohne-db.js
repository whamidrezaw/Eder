'use strict';
//
// Nur für test/integration/server-start.test.js: server.js starten, ohne
// eine Datenbank zu brauchen — geprüft wird dort das Lauschen (Adresse,
// belegter Port, Startabbruch), nicht die Datenbank.
//
// mongoose.connect meldet sofort Erfolg. Abfragen, die beim Start trotzdem
// losgehen (Nachholen des Tagesabschlusses), warten nur auf eine Verbindung,
// die nie kommt — der Test beendet den Prozess lange vorher.
//
const mongoose = require('mongoose');
mongoose.connect = async () => mongoose;
