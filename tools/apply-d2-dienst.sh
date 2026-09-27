#!/usr/bin/env bash
#
# apply-d2-dienst.sh — Phase D, Schritt 2: die App als Dienst (systemd)
#
# Heute beendete ein abgerissenes SSH ("client_loop: send disconnect:
# Connection reset") den Server, weil er im Vordergrund dieser Sitzung lief.
# Im Laden hieße das: ein WLAN-Aussetzer am Laptop — und die App ist für
# alle weg.
#
# Danach läuft die App unter systemd:
#   · unabhängig von jeder SSH-Sitzung
#   · startet beim Booten von selbst, nach MongoDB
#   · startet nach einem Absturz von selbst neu
#   · schreibt ins Journal:  journalctl -u edeka-lager
#
# Außerdem TRUST_PROXY=true in .env — erst JETZT sicher: seit Schritt 1
# lauscht die App nur auf 127.0.0.1, also erreicht sie nur der Tunnel. Danach
# sieht die App die echte Adresse der Nutzer statt 127.0.0.1, und die Warnung
# ERR_ERL_UNEXPECTED_X_FORWARDED_FOR verschwindet.
#
# Das Skript weist sich selbst nach: Start, Antwort der App, und ein
# absichtlicher Absturz (SIGKILL), nach dem systemd sie zurückholen muss.
#
# Ausführen im Wurzelverzeichnis des Repos, auf main:
#     bash apply-d2-dienst.sh
#
set -euo pipefail

BE="Edeka.lager/backend"
DIENST="edeka-lager"
UNIT="/etc/systemd/system/${DIENST}.service"
SELBST="$(basename "$0")"
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
die()  { printf '\n  \033[31m✗ %s\033[0m\n\n' "$1" >&2; exit 1; }

echo
echo "── Phase D, Schritt 2: die App als Dienst ──────────────────────"
echo

# ── 0  Voraussetzungen ───────────────────────────────────────────────
[ -f "$BE/server.js" ] || die "Bitte im Wurzelverzeichnis des Repos ausführen (cd ~/Eder)."
grep -q "listenHost" "$BE/server.js" \
  || die "Schritt 1 fehlt: server.js lauscht noch auf allen Adressen. TRUST_PROXY wäre damit unsicher."
[ -f "$BE/.env" ] || die "$BE/.env fehlt."
for c in systemctl journalctl curl node sudo; do
  command -v "$c" >/dev/null || die "Das Programm '$c' fehlt."
done

if command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
  BRANCH=$(git rev-parse --abbrev-ref HEAD)
  [ "$BRANCH" = "main" ] || die "Der Dienst startet, was ausgecheckt ist. Bitte zuerst: git checkout main && git pull"
  SCHMUTZ=$(git status --porcelain | grep -v -- "$SELBST" || true)
  [ -z "$SCHMUTZ" ] || { printf '%s\n' "$SCHMUTZ" | sed 's/^/     /'; die "Arbeitsverzeichnis nicht sauber (siehe oben)."; }
  ok "Branch main, Arbeitsverzeichnis sauber (ohne $SELBST)"
fi

NODE_BIN=$(readlink -f "$(command -v node)")
BACKEND_ABS=$(cd "$BE" && pwd)
NUTZER=$(id -un)
case "$NODE_BIN" in
  *"/.nvm/"*) warn "node stammt aus nvm ($NODE_BIN). Nach einem Versionswechsel dieses Skript erneut ausführen." ;;
  *) ok "node: $NODE_BIN" ;;
esac

MONGO_UNIT=$(systemctl list-unit-files --type=service --no-legend 'mongod.service' 'mongodb.service' 2>/dev/null \
             | awk '{print $1}' | head -1 || true)
if [ -n "$MONGO_UNIT" ]; then
  ok "MongoDB-Dienst: $MONGO_UNIT"
else
  warn "Kein MongoDB-Dienst gefunden — beim Booten wird nicht auf die Datenbank gewartet (Neustarts fangen das ab)."
fi

# Einstellungen so lesen, wie die App selbst sie liest (ihr eigenes dotenv).
# Ausgabe mit Markierung: dotenv kann eigene Zeilen auf stdout schreiben.
lies() { ( cd "$BE" && node -e "$1" ) | grep "^$2=" | head -1 | cut -d= -f2-; }
APP_PORT=$(lies "require('dotenv').config({ quiet: true }); console.log('PORT=' + (parseInt(process.env.PORT) || 3000))" PORT)
[ -n "$APP_PORT" ] || die "Konnte PORT aus .env nicht bestimmen."

# ── 1  Läuft noch ein von Hand gestarteter Server? ────────────────────
echo
echo "── Port $APP_PORT ────────────────────────────────────────────────────"
belegt() {
  node -e "const s = require('net').connect($APP_PORT, '127.0.0.1');
           s.on('connect', () => process.exit(0)); s.on('error', () => process.exit(1));
           setTimeout(() => process.exit(1), 1500);"
}
if systemctl is-active --quiet "$DIENST"; then
  ok "Dienst läuft schon — er wird mit den neuen Einstellungen neu gestartet"
elif belegt; then
  die "Auf Port $APP_PORT läuft schon ein Server — vermutlich der von Hand gestartete.
     Bitte in dessen Fenster Strg+C drücken und dieses Skript noch einmal starten."
else
  ok "Port $APP_PORT ist frei"
fi

# ── 2  .env: TRUST_PROXY=true ─────────────────────────────────────────
echo
echo "── .env ────────────────────────────────────────────────────────"
ENV="$BE/.env"
# Sicherung neben .env: *.bak steht in .gitignore, landet also nie auf
# GitHub — wichtig, denn darin stehen JWT_SECRET und die Datenbankadresse.
if [ ! -f "$ENV.d2.bak" ]; then
  cp -p "$ENV" "$ENV.d2.bak"
  chmod 600 "$ENV.d2.bak"
fi
if grep -qE '^[[:space:]]*TRUST_PROXY[[:space:]]*=' "$ENV"; then
  sed -i -E 's/^[[:space:]]*TRUST_PROXY[[:space:]]*=.*/TRUST_PROXY=true/' "$ENV"
else
  printf '\n# Phase D: Die App lauscht nur auf 127.0.0.1, davor der Tunnel.\nTRUST_PROXY=true\n' >> "$ENV"
fi

# Mit der Prüfung der App selbst nachsehen, ob sie so starten wird — sonst
# liefe gleich ein Dienst an, der sofort wieder abbricht.
PROBLEM=$(lies "require('dotenv').config({ quiet: true });
                const { checkProxyConfig } = require('./lib/validate');
                console.log('PROBLEM=' + (checkProxyConfig(process.env) || ''));" PROBLEM)
if [ -n "$PROBLEM" ]; then
  cp -p "$ENV.d2.bak" "$ENV"
  die "Mit dieser .env startete die App nicht: $PROBLEM
     .env wurde auf den vorigen Stand zurückgesetzt."
fi
ok "TRUST_PROXY=true — die App wird damit starten"

MODUS=$(stat -c %a "$ENV")
case "$MODUS" in
  600|400) ok ".env: nur für dich lesbar ($MODUS)" ;;
  *) chmod 600 "$ENV"; ok ".env: Rechte $MODUS → 600 (JWT_SECRET war für andere Konten lesbar)" ;;
esac
printf '  · Schlüssel in .env: %s\n' "$(grep -vE '^[[:space:]]*(#|$)' "$ENV" | cut -d= -f1 | tr -d ' ' | tr '\n' ' ')"

# ── 3  Unit-Datei ─────────────────────────────────────────────────────
echo
echo "── systemd ─────────────────────────────────────────────────────"
UNIT_TEXT="# Von tools/apply-d2-dienst.sh erzeugt — Änderungen bitte dort.
[Unit]
Description=EDEKA Lagerverwaltung
Documentation=https://github.com/whamidrezaw/Eder
Wants=network-online.target ${MONGO_UNIT}
After=network-online.target ${MONGO_UNIT}
# Fünf Abstürze in zwei Minuten: aufgeben statt endlos neu starten.
# Dann steht der Grund im Journal (journalctl -u ${DIENST}).
StartLimitIntervalSec=120
StartLimitBurst=5

[Service]
Type=simple
User=${NUTZER}
WorkingDirectory=${BACKEND_ABS}
Environment=NODE_ENV=production
ExecStart=${NODE_BIN} server.js
Restart=always
RestartSec=3
# Härtung, ohne der App etwas zu nehmen, das sie braucht.
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target"

printf '%s\n' "$UNIT_TEXT" | sudo tee "$UNIT" >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable "$DIENST" >/dev/null 2>&1
START=$(date '+%Y-%m-%d %H:%M:%S')
sudo systemctl restart "$DIENST"
ok "$UNIT geschrieben, Dienst aktiviert und gestartet"

# ── 4  Nachweise ──────────────────────────────────────────────────────
echo
echo "── Nachweise ───────────────────────────────────────────────────"
gesund() {
  local i
  for i in $(seq 1 "$1"); do
    curl -fsS --max-time 2 "http://127.0.0.1:${APP_PORT}/api/health" 2>/dev/null | grep -q '"status":"ok"' && return 0
    sleep 1
  done
  return 1
}
RUECK="Rückgängig:
       sudo systemctl disable --now ${DIENST}
       sudo rm ${UNIT} && sudo systemctl daemon-reload
       cp ${ENV}.d2.bak ${ENV}"

if ! gesund 30; then
  journalctl -u "$DIENST" -n 25 --no-pager 2>/dev/null | sed 's/^/    /'
  die "Die App antwortet nicht (Journal oben).
     $RUECK"
fi
ok "die App antwortet auf 127.0.0.1:${APP_PORT}"

if journalctl -u "$DIENST" --since "$START" --no-pager 2>/dev/null | grep -q "Server läuft auf 127.0.0.1:${APP_PORT}"; then
  ok "Journal: Server läuft auf 127.0.0.1:${APP_PORT}"
else
  warn "die Startzeile fehlt im Journal — bitte: journalctl -u ${DIENST} -n 20"
fi

VORHER=$(systemctl show -p NRestarts --value "$DIENST" 2>/dev/null || echo 0)
sudo systemctl kill -s SIGKILL "$DIENST"
sleep 1
if ! gesund 30; then
  journalctl -u "$DIENST" -n 25 --no-pager 2>/dev/null | sed 's/^/    /'
  die "Nach dem absichtlichen Absturz kam die App nicht zurück.
     $RUECK"
fi
NACHHER=$(systemctl show -p NRestarts --value "$DIENST" 2>/dev/null || echo 0)
if [ "${NACHHER:-0}" -gt "${VORHER:-0}" ]; then
  ok "Absturztest: SIGKILL — systemd hat die App zurückgeholt (Neustarts $VORHER → $NACHHER)"
else
  die "Die App antwortet, aber systemd zählt keinen Neustart ($VORHER → $NACHHER) — nicht nachgewiesen."
fi

[ "$(systemctl is-enabled "$DIENST" 2>/dev/null)" = "enabled" ] \
  && ok "startet beim Booten von selbst" \
  || die "Dienst ist nicht für den Systemstart aktiviert."

echo
echo "── Danach ──────────────────────────────────────────────────────"
echo
echo "  Die App läuft jetzt ohne dich. NICHT mehr von Hand 'npm start' —"
echo "  das zweite Exemplar bräche mit 'Kann nicht … lauschen: EADDRINUSE' ab."
echo
echo "    Zustand:       systemctl status ${DIENST}"
echo "    Log, laufend:  journalctl -u ${DIENST} -f"
echo "    Neu starten:   sudo systemctl restart ${DIENST}     (nach jedem git pull)"
echo "    Anhalten:      sudo systemctl stop ${DIENST}"
echo
echo "    mkdir -p tools && mv $SELBST tools/"
echo "    git add tools/$SELBST && git commit -m 'Phase D Schritt 2: App als systemd-Dienst'"
echo "    git push"
echo
echo "  $RUECK"
echo
