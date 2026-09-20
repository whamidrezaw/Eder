'use strict';
// Muss VOR dem ersten require('../../app') laufen.
// dotenv überschreibt bereits gesetzte Variablen nicht — deshalb gewinnt das hier.
process.env.NODE_ENV           = 'test';
process.env.JWT_SECRET         = process.env.JWT_SECRET || 'test-only-secret-0123456789-nicht-in-produktion-verwenden';
process.env.JWT_EXPIRES_IN     = process.env.JWT_EXPIRES_IN || '1h';
process.env.TRUST_PROXY        = 'false';
// Leer lassen: sendTelegram() wirft dann sofort "Telegram nicht konfiguriert",
// ohne echten Netzwerkaufruf. Tests dürfen niemals in einen echten Kanal posten.
process.env.TELEGRAM_BOT_TOKEN = '';
process.env.TELEGRAM_CHAT_ID   = '';
