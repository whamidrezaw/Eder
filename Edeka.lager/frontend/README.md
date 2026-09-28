# EDEKA Lagerverwaltung — Frontend

Statische Seiten, vom Backend ausgeliefert. Kein Build-Schritt und keine
externen Quellen: Schriften und Chart.js liegen in `assets/`.

## Seiten

| Seite | Zweck | Skript |
|---|---|---|
| `index.html` | Anmeldung | `assets/index.js` — lädt `shared.js` bewusst nicht |
| `dashboard.html` | Bestand und Produkte | `assets/dashboard.js` |
| `analytics.html` | Analyse: Heute und Verlauf, Excel/PDF | `assets/analytics.js` |
| `reports.html` | Tagesberichte | `assets/reports.js` |
| `users.html` | Benutzerverwaltung (Admins) | `assets/users.js` |

`assets/shared.js` enthält, was alle angemeldeten Seiten brauchen: Anmeldung
und `api()`, `escapeHtml`, die Seitenleiste, den Aktionsverteiler, den
Bestandsschreiber und den Export. Gestaltung in `assets/shared.css`.

## Regeln für neuen Code

Jede dieser Regeln hat einen Grund in `../ENTSCHEIDUNGEN.md` — und einen Test,
der sie erzwingt.

**1. Kein JavaScript im HTML.** Kein `<script>` ohne `src`, kein `onclick="…"`,
keine `javascript:`-Adresse. Die CSP führt nichts davon aus.
Tests: `frontend-struktur`, `inline-handler`, `csp-markup`, `csp-skripte`.

**2. Knöpfe über `data-action`.**

```html
<button type="button" data-action="produktLoeschen" data-id="${escapeHtml(p._id)}">🗑️</button>
```

```js
registriereAktionen({
  produktLoeschen: (el) => confirmDeleteProduct(el.dataset.id)
});
```

Ein einziger Listener am Dokument (in `shared.js`) ruft die registrierte
Funktion — auch für Zeilen, die erst später gerendert werden. Ein Name ohne
Registrierung erscheint in der Konsole als `[Aktionen] unbekannte Aktion`.
Test: `aktionen`.

**3. Alles aus Daten durch `escapeHtml(...)`** — auch Zahlen und ids. Ohne
Maskierung erlaubt sind nur fester Text, Zahlen aus Rechnungen und die
Formatierer `fmtNum`, `fmtDate`, `fmtTime`, `fmtRelative`, `fmtDateOnly`.
Tests: `frontend-escaping`, `html-senken` — er verfolgt jeden Wert bis in
`innerHTML`.

**4. Bestand nur über den Bestandsschreiber** (`setStock`, `adjustStock` in
`dashboard.js`): Anzeige sofort, gebündeltes Speichern, Version mitschicken.
Test: `stock-writer`.

**5. Schließen-Knöpfe von Dialogen** als
`<button type="button" aria-label="Schließen">` — mit der Tastatur erreichbar
und vorlesbar. Test: `schliessen-knoepfe`.
