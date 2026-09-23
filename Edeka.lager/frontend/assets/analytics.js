// Ausgelagert aus analytics.html (Phase F, Schritt A).
// Inhalt unveraendert — nur der Ort hat sich geaendert, damit ESLint und
// der vm-Harness diesen Code ueberhaupt sehen koennen.
// Ein Kommentar vor 'use strict' ist unschaedlich: die Direktive muss die
// erste ANWEISUNG sein, nicht die erste Zeile.
'use strict';

let trendChart = null;

function switchTab(tab) {
  document.getElementById('tab-today').classList.toggle('active', tab === 'today');
  document.getElementById('tab-trend').classList.toggle('active', tab === 'trend');
  document.getElementById('tab-btn-today').classList.toggle('active', tab === 'today');
  document.getElementById('tab-btn-trend').classList.toggle('active', tab === 'trend');
  if (tab === 'trend' && !trendChart) loadTrend();
}
window.switchTab = switchTab;

async function handleSendReport() {
  await sendReportNow();
  await loadToday();
}
window.handleSendReport = handleSendReport;

// ── Heute ────────────────────────────────────────────────────────
function fmtNum(n) {
  return Number(n ?? 0).toLocaleString('de-DE', { maximumFractionDigits: 1 });
}

async function loadToday() {
  try {
    const data = await api('/api/reports/today');
    const list = document.getElementById('today-list');
    const empty = document.getElementById('today-empty');

    document.getElementById('today-meta').textContent =
      data.reports.length > 0 ? `${data.reports.length} Bericht(e) heute` : '';

    if (data.reports.length === 0) {
      list.innerHTML = '';
      empty.style.display = 'flex';
      return;
    }
    empty.style.display = 'none';

    list.innerHTML = data.reports.slice().reverse().map(r => `
      <div class="report-item">
        <div class="report-time">${fmtTime(r.sentAt)}</div>
        <div class="report-meta">
          📦 ${fmtNum(r.totalStock)} gesamt · 📉 −${fmtNum(r.totalConsumed)} seit Mitternacht · ${r.productCount} Artikel
          ${r.reportSent ? '' : ' · <span style="color:var(--color-error)">Telegram fehlgeschlagen</span>'}
        </div>
        <div class="report-acts">
          <button class="row-act" title="Excel" onclick="downloadReportFile('excel', {logId:'${r._id}'})">📊</button>
          <button class="row-act" title="PDF" onclick="downloadReportFile('pdf', {logId:'${r._id}'})">📄</button>
        </div>
      </div>
    `).join('');
  } catch (e) {
    showToast('⚠️ ' + e.message, 'err');
  }
}

// ── Verlauf ──────────────────────────────────────────────────────
function getChartColors() {
  const dark = document.documentElement.getAttribute('data-theme') === 'dark';
  return {
    grid: dark ? 'rgba(255,255,255,0.06)' : 'rgba(0,0,0,0.06)',
    text: dark ? '#7a7974' : '#6b6a66'
  };
}

function fmtShort(dateStr) {
  const d = new Date(dateStr + 'T12:00:00');
  return d.toLocaleDateString('de-DE', { day: '2-digit', month: '2-digit' });
}

async function loadTrend() {
  const days = parseInt(document.getElementById('period-select').value) || 14;
  try {
    const data = await api(`/api/reports/analytics?days=${days}`);
    renderTrendKpis(data.summary || {});
    renderTrendChart(data.trend || []);
    renderTopProducts(data.topProducts || []);
    renderCategoryBreakdown(data.summary?.categoryBreakdown || {});
  } catch (e) {
    showToast('⚠️ ' + e.message, 'err');
  }
}
window.loadTrend = loadTrend;

function renderTrendKpis(summary) {
  document.getElementById('trend-kpi-grid').innerHTML = `
    <div class="kpi-card">
      <div class="kpi-top"><span class="kpi-label">Erfasste Tage</span></div>
      <div class="kpi-val">${summary.totalDays ?? 0}</div>
    </div>
    <div class="kpi-card">
      <div class="kpi-top"><span class="kpi-label">Verbrauch gesamt</span></div>
      <div class="kpi-val">${fmtNum(summary.totalConsumed ?? 0)}</div>
    </div>
    <div class="kpi-card">
      <div class="kpi-top"><span class="kpi-label">Ø pro Tag</span></div>
      <div class="kpi-val">${fmtNum(summary.avgDailyConsumed ?? 0)}</div>
    </div>
  `;
}

function renderTrendChart(trend) {
  const colors = getChartColors();
  const ctx = document.getElementById('trend-chart').getContext('2d');
  if (trendChart) trendChart.destroy();

  if (trend.length === 0) {
    return;
  }

  trendChart = new Chart(ctx, {
    type: 'bar',
    data: {
      labels: trend.map(t => fmtShort(t.date)),
      datasets: [{
        label: 'Verbrauch',
        data: trend.map(t => t.totalConsumed),
        backgroundColor: 'rgba(226,0,26,0.7)',
        borderColor: 'rgba(226,0,26,1)',
        borderWidth: 0,
        borderRadius: 4,
        borderSkipped: false
      }]
    },
    options: {
      responsive: true,
      maintainAspectRatio: true,
      plugins: {
        legend: { display: false },
        tooltip: {
          backgroundColor: document.documentElement.getAttribute('data-theme') === 'dark' ? '#1c1c1a' : '#1a1a1a',
          titleColor: '#fff',
          bodyColor: 'rgba(255,255,255,0.7)',
          padding: 10,
          callbacks: { label: c => fmtNum(c.parsed.y) + ' Einheiten' }
        }
      },
      scales: {
        x: { grid: { color: colors.grid }, ticks: { color: colors.text, font: { size: 11 } } },
        y: { grid: { color: colors.grid }, ticks: { color: colors.text, font: { size: 11 } }, beginAtZero: true }
      }
    }
  });
}

function renderTopProducts(products) {
  const container = document.getElementById('top-products-list');
  if (!products.length) {
    container.innerHTML = '<div class="empty-state" style="padding:20px"><div class="empty-icon">📭</div><div class="empty-desc">Keine Daten im gewählten Zeitraum</div></div>';
    return;
  }
  const max = products[0]?.totalConsumed || 1;
  container.innerHTML = products.map((p, i) => `
    <div class="top-item">
      <div class="top-rank">${i + 1}</div>
      <div class="top-info">
        <div class="top-name">${escapeHtml(p.emoji || '📦')} ${escapeHtml(p.name)}${p.isBio ? ' 🌱' : ''}</div>
        <div class="top-cat">${escapeHtml(p.category)} · ${escapeHtml(p.unit)}</div>
      </div>
      <div class="top-bar-wrap">
        <div class="top-bar"><div class="top-bar-fill" style="width:${Math.round((p.totalConsumed / max) * 100)}%"></div></div>
      </div>
      <div class="top-val">${fmtNum(p.totalConsumed)}</div>
    </div>
  `).join('');
}

function renderCategoryBreakdown(breakdown) {
  const entries = Object.entries(breakdown).sort((a, b) => b[1] - a[1]);
  const grid = document.getElementById('category-breakdown-grid');
  if (entries.length === 0) {
    grid.innerHTML = '<div class="empty-state" style="padding:20px; grid-column:1/-1"><div class="empty-desc">Keine Daten im gewählten Zeitraum</div></div>';
    return;
  }
  grid.innerHTML = entries.map(([cat, val]) => `
    <div class="kpi-card">
      <div class="kpi-top"><span class="kpi-label">${escapeHtml(cat)}</span></div>
      <div class="kpi-val">${fmtNum(val)}</div>
      <div class="kpi-delta">Verbrauch im Zeitraum</div>
    </div>
  `).join('');
}

// ── Init ───────────────────────────────────────────────────────────
document.addEventListener('DOMContentLoaded', loadToday);

