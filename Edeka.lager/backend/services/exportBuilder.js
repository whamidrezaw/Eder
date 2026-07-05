const ExcelJS     = require('exceljs');
const PDFDocument = require('pdfkit');

/** پالت رنگ برای دسته‌بندی‌ها — چرخشی، چون دسته‌بندی‌ها داینامیک هستند و تعدادشان از قبل معلوم نیست */
const PALETTE = [
  { bg: 'D9F0E6', text: '0B3D2E' },
  { bg: 'FBE8C9', text: '5C3D06' },
  { bg: 'E6E3FB', text: '332B70' },
  { bg: 'FBE3DA', text: '6E2E14' },
  { bg: 'DCEBFA', text: '0E3D63' },
  { bg: 'E3F0D0', text: '2C4C0E' },
  { bg: 'FBE0EA', text: '6E1F3C' },
  { bg: 'EDEBE3', text: '3A3935' }
];

/**
 * هر دو منبع داده (محصولات زنده‌ی Product و snapshot تاریخی DailyLog) را
 * به یک شکل یکسان تبدیل می‌کند تا توابع ساخت خروجی فقط یک‌بار نوشته شوند.
 */
function normalizeFromLiveProducts(products) {
  return products.map(p => ({
    emoji:    p.emoji || '📦',
    name:     p.name,
    category: p.category || 'Sonstige',
    unit:     p.unit || 'Kiste',
    isBio:    !!p.isBio,
    stock:    p.currentStock ?? 0,
    consumed: Math.max(0, (p.yesterdayStock ?? 0) - (p.currentStock ?? 0))
  }));
}

function normalizeFromSnapshot(snapshot) {
  return snapshot.map(p => ({
    emoji:    p.emoji || '📦',
    name:     p.productName,
    category: p.category || 'Sonstige',
    unit:     p.unit || 'Kiste',
    isBio:    !!p.isBio,
    stock:    p.closingStock ?? 0,
    consumed: p.consumed ?? 0
  }));
}

/** گروه‌بندی: دسته‌بندی → واحد → آیتم‌ها (چون نمی‌توان مثلاً Kiste و kg را با هم جمع زد) */
function groupRows(rows) {
  const categories = [...new Set(rows.map(r => r.category))];
  return categories.map((category, i) => {
    const catRows = rows.filter(r => r.category === category);
    const units = [...new Set(catRows.map(r => r.unit))];
    const groups = units.map(unit => {
      const items = catRows
        .filter(r => r.unit === unit)
        .sort((a, b) => (a.isBio === b.isBio ? a.name.localeCompare(b.name, 'de') : (a.isBio ? 1 : -1)));
      const subtotalStock    = items.reduce((s, r) => s + (r.stock || 0), 0);
      const subtotalConsumed = items.reduce((s, r) => s + (r.consumed || 0), 0);
      return { unit, items, subtotalStock, subtotalConsumed };
    });
    return { category, color: PALETTE[i % PALETTE.length], groups };
  });
}

async function buildExcelWorkbook(rows, meta = {}) {
  const workbook = new ExcelJS.Workbook();
  workbook.creator = 'EDEKA Lager';
  workbook.created = new Date();

  const sheet = workbook.addWorksheet(meta.sheetName || 'Bericht');
  sheet.columns = [
    { header: '',          key: 'emoji',    width: 5  },
    { header: 'Produkt',   key: 'name',     width: 26 },
    { header: 'Bio',       key: 'bio',      width: 9  },
    { header: 'Einheit',   key: 'unit',     width: 10 },
    { header: 'Bestand',   key: 'stock',    width: 12 },
    { header: 'Verbrauch', key: 'consumed', width: 12 }
  ];
  sheet.getRow(1).font = { bold: true };
  sheet.getRow(1).fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FF1A1A1A' } };
  sheet.getRow(1).eachCell(c => { c.font = { bold: true, color: { argb: 'FFFFFFFF' } }; });

  if (meta.subtitle) {
    sheet.insertRow(1, [meta.subtitle]);
    sheet.mergeCells('A1:F1');
    sheet.getRow(1).font = { italic: true, color: { argb: 'FF666666' } };
    sheet.getRow(2).font = { bold: true };
    sheet.getRow(2).fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FF1A1A1A' } };
    sheet.getRow(2).eachCell(c => { c.font = { bold: true, color: { argb: 'FFFFFFFF' } }; });
  }

  const sections = groupRows(rows);
  let grandStock = 0, grandConsumed = 0;

  sections.forEach(section => {
    // مقدار را مستقیماً در ستون A قرار می‌دهیم چون merge فقط مقدار سلول اول بازه را نگه می‌دارد
    const headerRow = sheet.addRow([]);
    headerRow.getCell(1).value = section.category;
    headerRow.font = { bold: true, color: { argb: `FF${section.color.text}` } };
    headerRow.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: `FF${section.color.bg}` } };
    sheet.mergeCells(`A${headerRow.number}:F${headerRow.number}`);

    section.groups.forEach(group => {
      group.items.forEach(item => {
        const row = sheet.addRow({
          emoji:    item.emoji,
          name:     item.name,
          bio:      item.isBio ? '🌱 Bio' : '—',
          unit:     item.unit,
          stock:    item.stock,
          consumed: item.consumed
        });
        if (item.isBio) row.getCell('bio').font = { color: { argb: 'FF2E7D32' }, bold: true };
        if ((item.stock || 0) <= 0) row.getCell('stock').font = { color: { argb: 'FFCC0000' }, bold: true };
      });

      const subRow = sheet.addRow({
        name:     `Zwischensumme (${group.unit})`,
        stock:    group.subtotalStock,
        consumed: group.subtotalConsumed
      });
      subRow.font = { italic: true, color: { argb: 'FF666666' } };
      grandStock    += group.subtotalStock;
      grandConsumed += group.subtotalConsumed;
    });
  });

  sheet.addRow({});
  const totalRow = sheet.addRow({ name: 'Gesamt', stock: grandStock, consumed: grandConsumed });
  totalRow.font = { bold: true };
  totalRow.eachCell(c => { c.border = { top: { style: 'thin' } }; });

  return workbook;
}

function buildPdfDocument(rows, meta = {}) {
  const doc = new PDFDocument({ margin: 40, size: 'A4' });
  const pageLeft  = 40;
  const pageWidth = doc.page.width - 80;
  const colX = { name: pageLeft + 6, bio: pageLeft + 230, unit: pageLeft + 300, stock: pageLeft + 370, consumed: pageLeft + 450 };

  function drawDocHeader() {
    doc.fontSize(16).font('Helvetica-Bold').fillColor('#000').text('EDEKA Lagerbericht', pageLeft, 40);
    if (meta.subtitle) {
      doc.fontSize(10).font('Helvetica').fillColor('#555').text(meta.subtitle, pageLeft, 62);
    }
    doc.y = 90;
  }

  function drawTableHeader() {
    doc.fontSize(9).font('Helvetica-Bold').fillColor('#000');
    const y = doc.y;
    doc.text('Produkt',   colX.name,     y, { width: 220 });
    doc.text('Bio',       colX.bio,      y, { width: 60 });
    doc.text('Einheit',   colX.unit,     y, { width: 60 });
    doc.text('Bestand',   colX.stock,    y, { width: 75, align: 'right' });
    doc.text('Verbrauch', colX.consumed, y, { width: 75, align: 'right' });
    doc.y = y + 14;
    doc.moveTo(pageLeft, doc.y).lineTo(pageLeft + pageWidth, doc.y).strokeColor('#cccccc').stroke();
    doc.y += 6;
  }

  function ensureSpace(neededHeight) {
    if (doc.y + neededHeight > doc.page.height - 60) {
      doc.addPage();
      drawDocHeader();
      drawTableHeader();
    }
  }

  drawDocHeader();
  drawTableHeader();

  const sections = groupRows(rows);
  let grandStock = 0, grandConsumed = 0;

  sections.forEach(section => {
    ensureSpace(26);
    const bandY = doc.y;
    doc.rect(pageLeft, bandY, pageWidth, 20).fill(`#${section.color.bg}`);
    doc.fillColor(`#${section.color.text}`).fontSize(11).font('Helvetica-Bold')
       .text(section.category, pageLeft + 8, bandY + 5);
    doc.fillColor('#000');
    doc.y = bandY + 26;

    section.groups.forEach(group => {
      group.items.forEach(item => {
        ensureSpace(16);
        const y = doc.y;
        doc.fontSize(9).font('Helvetica').fillColor('#000');
        // توجه: فونت پایه‌ی PDFKit (Helvetica) از ایموجی یونیکد پشتیبانی نمی‌کند
        // (در Excel مشکلی نیست، چون اکسل از فونت سیستم برای ایموجی استفاده می‌کند).
        // به‌جای ایموجی Bio، یک دایره‌ی کوچک سبز با ابزار وکتور رسم می‌کنیم.
        doc.text(item.name, colX.name, y, { width: 220 });
        if (item.isBio) {
          doc.circle(colX.bio + 4, y + 5, 3).fill('#2E7D32');
          doc.fillColor('#2E7D32').text('Bio', colX.bio + 12, y, { width: 50 });
          doc.fillColor('#000');
        } else {
          doc.fillColor('#999').text('—', colX.bio, y, { width: 50 });
          doc.fillColor('#000');
        }
        doc.text(item.unit, colX.unit, y, { width: 60 });
        doc.fillColor(item.stock <= 0 ? '#CC0000' : '#000')
           .text(String(item.stock), colX.stock, y, { width: 75, align: 'right' });
        doc.fillColor('#000')
           .text(String(item.consumed), colX.consumed, y, { width: 75, align: 'right' });
        doc.y = y + 15;
      });

      ensureSpace(16);
      doc.fontSize(9).font('Helvetica-Oblique').fillColor('#666666');
      doc.text(
        `Zwischensumme (${group.unit}): Bestand ${group.subtotalStock} · Verbrauch ${group.subtotalConsumed}`,
        colX.name, doc.y, { width: pageWidth - 20 }
      );
      doc.fillColor('#000');
      doc.y += 16;
      grandStock    += group.subtotalStock;
      grandConsumed += group.subtotalConsumed;
    });

    doc.y += 6;
  });

  ensureSpace(24);
  doc.moveTo(pageLeft, doc.y).lineTo(pageLeft + pageWidth, doc.y).strokeColor('#000').stroke();
  doc.y += 8;
  doc.fontSize(11).font('Helvetica-Bold').fillColor('#000');
  doc.text(`Gesamtbestand: ${grandStock}    Gesamtverbrauch: ${grandConsumed}`, pageLeft, doc.y);

  doc.end();
  return doc;
}

module.exports = {
  normalizeFromLiveProducts,
  normalizeFromSnapshot,
  buildExcelWorkbook,
  buildPdfDocument
};
