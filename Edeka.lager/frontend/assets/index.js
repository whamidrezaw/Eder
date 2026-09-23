// Diese Funktionen werden aus Inline-Handlern im HTML aufgerufen, das
// ESLint nicht liest. Bis Schritt B sie per addEventListener anbindet,
// sagt die folgende Zeile ESLint, dass sie benutzt werden.
/* exported clearError */
// Ausgelagert aus index.html (Phase F, Schritt A).
// Inhalt unveraendert — nur der Ort hat sich geaendert, damit ESLint und
// der vm-Harness diesen Code ueberhaupt sehen koennen.
// Ein Kommentar vor 'use strict' ist unschaedlich: die Direktive muss die
// erste ANWEISUNG sein, nicht die erste Zeile.
/* ── BEREITS EINGELOGGT? ── */
(function () {
  const t = sessionStorage.getItem('token');
  if (t) window.location.href = 'dashboard.html';
})();

/* ── THEME TOGGLE ── */
(function () {
  const btn = document.getElementById('theme-toggle');
  const root = document.documentElement;
  const stored = localStorage.getItem('theme');
  let theme = stored || (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light');
  root.setAttribute('data-theme', theme);

  const sun = `<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
    <circle cx="12" cy="12" r="5"/>
    <path d="M12 1v2M12 21v2M4.22 4.22l1.42 1.42M18.36 18.36l1.42 1.42M1 12h2M21 12h2M4.22 19.78l1.42-1.42M18.36 5.64l1.42-1.42"/>
  </svg>`;
  const moon = `<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
    <path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/>
  </svg>`;

  function applyTheme() {
    root.setAttribute('data-theme', theme);
    btn.innerHTML = theme === 'dark' ? sun : moon;
    localStorage.setItem('theme', theme);
  }

  applyTheme();
  btn.addEventListener('click', () => {
    theme = theme === 'dark' ? 'light' : 'dark';
    applyTheme();
  });
})();

/* ── PASSWORD VISIBILITY ── */
(function () {
  const input = document.getElementById('password');
  const toggle = document.getElementById('pwd-toggle');
  let visible = false;
  toggle.addEventListener('click', () => {
    visible = !visible;
    input.type = visible ? 'text' : 'password';
    toggle.textContent = visible ? '🙈' : '👁';
    toggle.title = visible ? 'Passwort verbergen' : 'Passwort anzeigen';
    input.focus();
  });
})();

/* ── ERROR CLEAR ── */
function clearError() {
  document.getElementById('error-msg').classList.remove('visible');
  document.getElementById('username').classList.remove('has-error');
  document.getElementById('password').classList.remove('has-error');
}

/* ── LOGIN FORM ── */
document.getElementById('login-form').addEventListener('submit', async function (e) {
  e.preventDefault();
  const btn      = document.getElementById('login-btn');
  const errorEl  = document.getElementById('error-msg');
  const errorTxt = document.getElementById('error-text');
  const usernameEl = document.getElementById('username');
  const passwordEl = document.getElementById('password');
  const username = usernameEl.value.trim();
  const password = passwordEl.value;

  /* Client-side validation */
  if (!username || !password) {
    errorTxt.textContent = 'Bitte alle Felder ausfüllen.';
    errorEl.classList.add('visible');
    if (!username) usernameEl.classList.add('has-error');
    if (!password) passwordEl.classList.add('has-error');
    return;
  }

  btn.classList.add('loading');
  btn.disabled = true;
  errorEl.classList.remove('visible');

  try {
    const res = await fetch('/api/auth/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username, password })
    });

    const data = await res.json().catch(() => ({}));

    if (!res.ok) {
      let msg = data.message || 'Anmeldung fehlgeschlagen.';
      if (res.status === 401) msg = 'Benutzername oder Passwort falsch.';
      if (res.status === 403) msg = 'Ihr Konto ist deaktiviert. Bitte wenden Sie sich an den Administrator.';
      if (res.status === 429) msg = 'Zu viele Versuche. Bitte warten Sie kurz.';
      if (res.status >= 500) msg = 'Serverfehler. Bitte versuchen Sie es später erneut.';
      errorTxt.textContent = msg;
      errorEl.classList.add('visible');
      passwordEl.classList.add('has-error');
      passwordEl.value = '';
      passwordEl.focus();
      return;
    }

    /* Erfolg — Token speichern */
    sessionStorage.setItem('token', data.token);
    sessionStorage.setItem('user', JSON.stringify(data.user));

    /* Sanfte Weiterleitungsanimation */
    btn.classList.remove('loading');
    btn.style.background = '#2e7d32';
    btn.querySelector('.btn-text').style.display = 'flex';
    btn.querySelector('.btn-text').textContent = '✓ Angemeldet';
    btn.querySelector('.spinner').style.display = 'none';

    setTimeout(() => { window.location.href = 'dashboard.html'; }, 500);

  } catch (err) {
    console.error('[index] Unerwarteter Fehler:', err);
    errorTxt.textContent = 'Verbindungsfehler. Bitte Internetverbindung prüfen.';
    errorEl.classList.add('visible');
    btn.classList.remove('loading');
    btn.disabled = false;
  } finally {
    if (!window.location.href.includes('dashboard')) {
      btn.classList.remove('loading');
      btn.disabled = false;
    }
  }
});

/* ── ENTER KEY SHORTCUTS ── */
document.getElementById('username').addEventListener('keydown', e => {
  if (e.key === 'Enter') { e.preventDefault(); document.getElementById('password').focus(); }
});

