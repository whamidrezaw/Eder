/**
 * ارسال گزارش به تلگرام — همان مکانیزم قبلی (ربات/کانال با Bot Token + Chat ID از .env)
 * بدون واتس‌اپ. این فایل عمداً ساده مانده تا فقط همین یک کار را به‌خوبی انجام دهد.
 */

// نام دسته/محصول/واحد از فرم "افزودن جدید" می‌آیند و هیچ محدودیت کاراکتری
// ندارند. اگر یکی از این‌ها کاراکتر ویژه‌ی Markdown تلگرام (_ * ` [) داشته
// باشد و escape نشود، تلگرام کل پیام را با خطای «entity ناقص» رد می‌کند —
// یعنی همه‌ی گزارش به‌خاطر یک نام محصول ارسال نمی‌شود، نه فقط همان خط.
function escapeMarkdown(text) {
  return String(text ?? '').replace(/([_*`[])/g, '\\$1');
}

async function sendTelegram(text, chatId = null) {
  const botToken  = process.env.TELEGRAM_BOT_TOKEN;
  const defaultId = process.env.TELEGRAM_CHAT_ID;
  const target    = chatId || defaultId;

  if (!botToken || !target) {
    throw new Error('Telegram nicht konfiguriert (.env fehlt: TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID)');
  }

  const url = `https://api.telegram.org/bot${botToken}/sendMessage`;
  const res = await fetch(url, {
    method:  'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      chat_id:    target,
      text,
      parse_mode: 'Markdown'
    })
  });

  const data = await res.json().catch(() => null);
  if (!res.ok || !data?.ok) {
    throw new Error(data?.description || `Telegram-Fehler (${res.status})`);
  }
  return data;
}

/**
 * متن گزارش تلگرام را از لیست محصولات زنده (Product[]) می‌سازد.
 * مصرف نسبت به yesterdayStock (پایه‌ی نیمه‌شب) حساب می‌شود — تجمعی از نیمه‌شب تا الان،
 * نه نسبت به گزارش قبلیِ همان روز.
 */
function buildTelegramText(products) {
  const now = new Date();
  const dateLabel = now.toLocaleDateString('de-DE', {
    weekday: 'long', year: 'numeric', month: 'long', day: 'numeric'
  });
  const timeLabel = now.toLocaleTimeString('de-DE');

  const totalStock    = products.reduce((s, p) => s + (p.currentStock ?? 0), 0);
  const totalConsumed = products.reduce(
    (s, p) => s + Math.max(0, (p.yesterdayStock ?? 0) - (p.currentStock ?? 0)), 0
  );

  const lines = [
    `🛒 *EDEKA Lagerbericht*`,
    `📅 ${dateLabel}`,
    `🕐 ${timeLabel} Uhr`,
    ``,
    `📦 Gesamtbestand: *${totalStock}*`,
    `📉 Verbrauch seit Mitternacht: *${totalConsumed}*`,
    ``
  ];

  const categories = [...new Set(products.map(p => p.category))];
  categories.forEach(cat => {
    lines.push(`*${escapeMarkdown(cat)}*`);
    products
      .filter(p => p.category === cat)
      .forEach(p => {
        const consumed = Math.max(0, (p.yesterdayStock ?? 0) - (p.currentStock ?? 0));
        const bioTag = p.isBio ? '🌱 ' : '';
        let line = `  ${p.emoji || '📦'} ${bioTag}${escapeMarkdown(p.name)} (${escapeMarkdown(p.unit)}): *${p.currentStock}*`;
        if (consumed > 0) line += ` (−${consumed})`;
        lines.push(line);
      });
    lines.push(``);
  });

  lines.push(`⏰ _Gesendet um ${timeLabel} Uhr_`);
  return lines.join('\n');
}

module.exports = { sendTelegram, buildTelegramText, escapeMarkdown };
