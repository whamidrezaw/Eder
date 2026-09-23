// Ausgelagert aus dashboard.html (Phase F, Schritt A).
// Inhalt unveraendert — nur der Ort hat sich geaendert, damit ESLint und
// der vm-Harness diesen Code ueberhaupt sehen koennen.
// Ein Kommentar vor 'use strict' ist unschaedlich: die Direktive muss die
// erste ANWEISUNG sein, nicht die erste Zeile.
'use strict';

let allProducts  = [];
let categories   = [];
let units        = [];
let activeCategory = null; // null = Alle
let bioOnly = false;

function getProduct(id) { return allProducts.find(p => p._id === id); }

function categoryStep(unitName) {
  return (unitName === 'kg' || unitName === 'g') ? 0.5 : 1;
}

// ── Laden ──────────────────────────────────────────────────────
async function loadAll() {
  try {
    [allProducts, categories, units] = await Promise.all([
      api('/api/products'),
      loadCategories(),
      loadUnits()
    ]);
    renderUnitFilter();
    renderCategoryTabs();
    renderKpis();
    renderTable();
  } catch (e) {
    showToast('⚠️ ' + e.message, 'err');
  }
}

async function refreshAll() {
  try {
    allProducts = await api('/api/products');
    renderKpis();
    renderTable();
  } catch (e) {
    showToast('⚠️ ' + e.message, 'err');
  }
}

// ── KPI Cards ──────────────────────────────────────────────────
function fmtNum(n) {
  return Number(n ?? 0).toLocaleString('de-DE', { maximumFractionDigits: 1 });
}

function renderKpis() {
  // یک کارت به ازای هر دسته‌بندی — عدد اصلی = تعداد آرتیکل (نه جمع که با واحدهای مختلف بی‌معنی می‌شود)
  const catGrid = document.getElementById('category-kpi-grid');
  catGrid.innerHTML = categories.map(cat => {
    const items = allProducts.filter(p => p.category === cat.name);
    if (items.length === 0) {
      return `
        <div class="kpi-card">
          <div class="kpi-top"><span class="kpi-label">${escapeHtml(cat.emoji)} ${escapeHtml(cat.name)}</span></div>
          <div class="kpi-val" style="color:var(--color-text-faint)">0</div>
          <div class="kpi-delta">Keine Artikel</div>
        </div>`;
    }
    const byUnit = {};
    items.forEach(p => { byUnit[p.unit] = (byUnit[p.unit] || 0) + (p.currentStock || 0); });
    const breakdown = Object.entries(byUnit).map(([u, v]) => `${fmtNum(v)} ${u}`).join(' · ');
    return `
      <div class="kpi-card">
        <div class="kpi-top"><span class="kpi-label">${escapeHtml(cat.emoji)} ${escapeHtml(cat.name)}</span></div>
        <div class="kpi-val">${items.length}</div>
        <div class="kpi-delta">${breakdown}</div>
      </div>`;
  }).join('');

  // کارت‌های متقاطع: Bio/Konventionell (تعداد) و Kiste/kg (جمع، چون واحد یکسانه)
  const bioCount   = allProducts.filter(p => p.isBio).length;
  const normCount  = allProducts.filter(p => !p.isBio).length;
  const kisteTotal = allProducts.filter(p => p.unit === 'Kiste').reduce((s, p) => s + (p.currentStock || 0), 0);
  const kgTotal    = allProducts.filter(p => p.unit === 'kg').reduce((s, p) => s + (p.currentStock || 0), 0);

  document.getElementById('overall-kpi-grid').innerHTML = `
    <div class="kpi-card">
      <div class="kpi-top"><span class="kpi-label">🌱 Bio gesamt</span></div>
      <div class="kpi-val" style="color:var(--color-success)">${bioCount}</div>
      <div class="kpi-delta">Artikel</div>
    </div>
    <div class="kpi-card">
      <div class="kpi-top"><span class="kpi-label">Konventionell</span></div>
      <div class="kpi-val">${normCount}</div>
      <div class="kpi-delta">Artikel</div>
    </div>
    <div class="kpi-card">
      <div class="kpi-top"><span class="kpi-label">📦 In Kisten</span></div>
      <div class="kpi-val">${fmtNum(kisteTotal)}</div>
      <div class="kpi-delta">Kiste gesamt</div>
    </div>
    <div class="kpi-card">
      <div class="kpi-top"><span class="kpi-label">⚖️ In kg</span></div>
      <div class="kpi-val">${fmtNum(kgTotal)}</div>
      <div class="kpi-delta">kg gesamt</div>
    </div>
  `;
}

// ── Filter Tabs & Unit Filter ────────────────────────────────────
function renderCategoryTabs() {
  const wrap = document.getElementById('category-filter-tabs');
  const tabs = [{ name: null, label: 'Alle', emoji: '' }]
    .concat(categories.map(c => ({ name: c.name, label: c.name, emoji: c.emoji })));

  // FIX: t.name wird nicht mehr in einen onclick="..."-String eingebettet.
  // Ein Kategoriename mit einem Anführungszeichen konnte vorher aus dem
  // String ausbrechen und beliebiges JS ausführen (Stored XSS) — jeder
  // eingeloggte Nutzer darf Kategorien anlegen, nicht nur Admins. Der Name
  // bleibt jetzt als reiner JS-Wert im tabs-Array und wird nie zu Text
  // serialisiert; im Markup steht nur ein sicherer numerischer Index.
  wrap.innerHTML = tabs.map((t, i) => `
    <button class="filter-tab ${activeCategory === t.name && !bioOnly ? 'active' : ''}"
            data-cat-index="${i}">
      ${escapeHtml(t.emoji ? t.emoji + ' ' : '')}${escapeHtml(t.label)}
    </button>
  `).join('') + `
    <button class="filter-tab ${bioOnly ? 'active' : ''}" data-bio-toggle>🌱 Bio</button>
  `;

  wrap.querySelectorAll('[data-cat-index]').forEach(btn => {
    btn.addEventListener('click', () => setActiveCategory(tabs[Number(btn.dataset.catIndex)].name));
  });
  const bioBtn = wrap.querySelector('[data-bio-toggle]');
  if (bioBtn) bioBtn.addEventListener('click', toggleBioFilter);
}

function setActiveCategory(name) {
  activeCategory = name;
  bioOnly = false;
  renderCategoryTabs();
  renderTable();
}
window.setActiveCategory = setActiveCategory;

function toggleBioFilter() {
  bioOnly = !bioOnly;
  renderCategoryTabs();
  renderTable();
}
window.toggleBioFilter = toggleBioFilter;

function renderUnitFilter() {
  const sel = document.getElementById('unit-filter-select');
  sel.innerHTML = '<option value="">Alle Einheiten</option>' +
    units.map(u => `<option value="${escapeHtml(u.name)}">${escapeHtml(u.name)}</option>`).join('');
}

// ── Tabelle ──────────────────────────────────────────────────────
function renderTable() {
  const search = (document.getElementById('search-input').value || '').toLowerCase().trim();
  const unitFilterVal = document.getElementById('unit-filter-select').value;

  let rows = allProducts.filter(p => {
    if (activeCategory && p.category !== activeCategory) return false;
    if (bioOnly && !p.isBio) return false;
    if (unitFilterVal && p.unit !== unitFilterVal) return false;
    if (search && !p.name.toLowerCase().includes(search)) return false;
    return true;
  });

  rows.sort((a, b) => a.name.localeCompare(b.name, 'de') || (a.isBio === b.isBio ? 0 : (a.isBio ? 1 : -1)));

  document.getElementById('table-meta').textContent = `${rows.length} von ${allProducts.length} Artikeln`;

  const tbody = document.getElementById('product-tbody');
  const emptyState = document.getElementById('empty-state');

  if (rows.length === 0) {
    tbody.innerHTML = '';
    emptyState.style.display = 'flex';
    return;
  }
  emptyState.style.display = 'none';

  tbody.innerHTML = rows.map(p => {
    const consumed = Math.max(0, (p.yesterdayStock ?? 0) - (p.currentStock ?? 0));
    const step = categoryStep(p.unit);
    return `
    <tr data-id="${p._id}">
      <td>
        <div class="product-cell">
          <div class="product-emoji">${escapeHtml(p.emoji || '📦')}</div>
          <div>
            <div class="product-name">${escapeHtml(p.name)}</div>
            <div class="variant-tags">
              ${p.isBio ? '<span class="badge badge-ok"><span class="badge-dot"></span>Bio</span>' : ''}
              <span class="badge badge-neutral">${escapeHtml(p.unit)}</span>
            </div>
          </div>
        </div>
      </td>
      <td>
        <div class="stepper">
          <button class="step-btn minus" onclick="adjustStock('${p._id}', -${step})">−</button>
          <input class="step-val" type="number" step="${step}" min="0" value="${p.currentStock}"
                 onkeydown="if(event.key==='Enter'){this.blur();}"
                 onblur="setStock('${p._id}', this.value)">
          <button class="step-btn plus" onclick="adjustStock('${p._id}', ${step})">+</button>
        </div>
      </td>
      <td>${consumed > 0 ? `<span style="color:var(--color-text-muted)">−${fmtNum(consumed)}</span>` : '—'}</td>
      <td>
        <div class="row-acts">
          <button class="row-act" onclick="openEditModal('${p._id}')" title="Bearbeiten">✏️</button>
          <button class="row-act" onclick="confirmDeleteProduct('${p._id}')" title="Löschen">🗑️</button>
        </div>
      </td>
    </tr>`;
  }).join('');
}

// ── Bestand ändern ────────────────────────────────────────────────
// Die Schreiblogik liegt in assets/shared.js, damit sie ohne Browser
// geprüft werden kann (test/unit/stock-writer.test.js). Hier bleiben
// nur die beiden Namen, weil die Knöpfe sie direkt aufrufen.
// Alle Abhängigkeiten werden faul gereicht: dieser Aufruf läuft beim
// Laden, die Funktionen darunter gibt es zu dem Zeitpunkt vielleicht
// noch nicht.
const bestandsschreiber = createBestandsschreiber({
  holeProdukt: (id)   => getProduct(id),
  zeichne:     ()     => { renderKpis(); renderTable(); },
  melde:       (text) => showToast(text, 'err'),
  frage:       (text) => confirm(text),
  schreibe:    (id, wert, version) =>
    api(`/api/products/${id}/stock`, 'PATCH', { currentStock: wert, updatedAt: version })
});

function setStock(id, value) {
  const num = parseFloat(value);
  if (isNaN(num) || num < 0) { renderTable(); return; }
  bestandsschreiber.setzen(id, num);
}
window.setStock = setStock;

function adjustStock(id, delta) {
  bestandsschreiber.aendern(id, delta);
}
window.adjustStock = adjustStock;

// ── Produkt Hinzufügen/Bearbeiten ────────────────────────────────
function setupDynamicSelect(selectEl, items, isCategory) {
  fillSelectWithAddOption(selectEl, items);
  selectEl.onchange = async () => {
    if (selectEl.value !== '__add_new__') return;
    const label = isCategory ? 'Kategorie' : 'Einheit';
    const name = prompt(`Name der neuen ${label}:`);
    if (!name || !name.trim()) { selectEl.selectedIndex = 0; return; }
    try {
      const created = isCategory ? await createCategory(name.trim()) : await createUnit(name.trim());
      const fresh = isCategory ? await loadCategories(true) : await loadUnits(true);
      if (isCategory) categories = fresh; else units = fresh;
      fillSelectWithAddOption(selectEl, fresh, { selected: created.name });
      if (isCategory) renderCategoryTabs();
      else renderUnitFilter();
      showToast(`✅ ${label} hinzugefügt: ${created.name}`, 'ok');
    } catch (e) {
      showToast('⚠️ ' + e.message, 'err');
      selectEl.selectedIndex = 0;
    }
  };
}

function openAddModal() {
  document.getElementById('product-modal-title').textContent = 'Produkt hinzufügen';
  document.getElementById('product-id').value = '';
  document.getElementById('product-emoji').value = '📦';
  document.getElementById('product-name').value = '';
  document.getElementById('product-isbio').checked = false;
  document.getElementById('product-stock').value = 0;
  document.getElementById('stock-field-group').style.display = '';
  setupDynamicSelect(document.getElementById('product-category'), categories, true);
  setupDynamicSelect(document.getElementById('product-unit'), units, false);
  document.getElementById('product-modal').classList.add('open');
}
window.openAddModal = openAddModal;

function openEditModal(id) {
  const p = getProduct(id);
  if (!p) return;
  document.getElementById('product-modal-title').textContent = 'Produkt bearbeiten';
  document.getElementById('product-id').value = p._id;
  document.getElementById('product-emoji').value = p.emoji || '📦';
  document.getElementById('product-name').value = p.name;
  document.getElementById('product-isbio').checked = !!p.isBio;
  document.getElementById('stock-field-group').style.display = 'none';
  setupDynamicSelect(document.getElementById('product-category'), categories, true);
  setupDynamicSelect(document.getElementById('product-unit'), units, false);
  document.getElementById('product-category').value = p.category;
  document.getElementById('product-unit').value = p.unit;
  document.getElementById('product-modal').classList.add('open');
}
window.openEditModal = openEditModal;

function closeProductModal() {
  document.getElementById('product-modal').classList.remove('open');
}
window.closeProductModal = closeProductModal;

async function submitProductForm(evt) {
  evt.preventDefault();
  const id = document.getElementById('product-id').value;
  const payload = {
    emoji:    document.getElementById('product-emoji').value.trim() || '📦',
    name:     document.getElementById('product-name').value.trim(),
    category: document.getElementById('product-category').value,
    unit:     document.getElementById('product-unit').value,
    isBio:    document.getElementById('product-isbio').checked
  };
  if (!id) payload.currentStock = parseFloat(document.getElementById('product-stock').value) || 0;

  try {
    if (id) {
      await api(`/api/products/${id}`, 'PUT', payload);
      showToast('✅ Produkt aktualisiert', 'ok');
    } else {
      await api('/api/products', 'POST', payload);
      showToast('✅ Produkt hinzugefügt', 'ok');
    }
    closeProductModal();
    await refreshAll();
  } catch (e) {
    showToast('⚠️ ' + e.message, 'err');
  }
  return false;
}
window.submitProductForm = submitProductForm;

// ── Löschen ────────────────────────────────────────────────────────
let _confirmAction = null;

function openConfirm({ title, msg, icon = '⚠️', onConfirm }) {
  document.getElementById('confirm-title').textContent = title;
  document.getElementById('confirm-msg').textContent = msg;
  document.getElementById('confirm-icon').textContent = icon;
  _confirmAction = onConfirm;
  document.getElementById('confirm-overlay').classList.add('open');
}

function closeConfirm() {
  document.getElementById('confirm-overlay').classList.remove('open');
  _confirmAction = null;
}
window.closeConfirm = closeConfirm;

document.getElementById('confirm-action-btn').addEventListener('click', () => {
  if (_confirmAction) _confirmAction();
  closeConfirm();
});

function confirmDeleteProduct(id) {
  const p = getProduct(id);
  if (!p) return;
  openConfirm({
    title: 'Produkt entfernen?',
    msg: `„${p.name}" (${p.unit}${p.isBio ? ', Bio' : ''}) wird deaktiviert und aus der Liste entfernt.`,
    icon: '🗑️',
    onConfirm: async () => {
      try {
        await api(`/api/products/${id}`, 'DELETE');
        showToast('🗑️ Produkt entfernt', 'ok');
        await refreshAll();
      } catch (e) {
        showToast('⚠️ ' + e.message, 'err');
      }
    }
  });
}
window.confirmDeleteProduct = confirmDeleteProduct;

// ── Admin-Werkzeuge ──────────────────────────────────────────────
function openAdminTools() { document.getElementById('admin-modal').classList.add('open'); }
window.openAdminTools = openAdminTools;
function closeAdminTools() { document.getElementById('admin-modal').classList.remove('open'); }
window.closeAdminTools = closeAdminTools;

function adminResetStock(includeYesterday) {
  closeAdminTools();
  openConfirm({
    title: 'Bestände zurücksetzen?',
    msg: includeYesterday
      ? 'Alle aktuellen Bestände UND die Gestern-Basis werden auf 0 gesetzt.'
      : 'Alle aktuellen Bestände werden auf 0 gesetzt.',
    icon: '🔄',
    onConfirm: async () => {
      try {
        const res = await api('/api/reports/reset-stock', 'POST', { includeYesterday });
        showToast(`✅ ${res.count} Produkte zurückgesetzt`, 'ok');
        await refreshAll();
      } catch (e) {
        showToast('⚠️ ' + e.message, 'err');
      }
    }
  });
}
window.adminResetStock = adminResetStock;

// ── Init ───────────────────────────────────────────────────────────
document.addEventListener('DOMContentLoaded', () => {
  if (currentUser.role === 'admin') {
    document.getElementById('admin-tools-btn').style.display = '';
  }
  loadAll();
});

