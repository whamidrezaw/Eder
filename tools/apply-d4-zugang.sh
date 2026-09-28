#!/usr/bin/env bash
#
# apply-d4-zugang.sh — Phase D, Schritt 4: fester Zugang über HTTPS
#
#   https://<name>.duckdns.org  →  nginx (Port 443, Let's Encrypt)
#                               →  App auf 127.0.0.1:3000
#
# Ersetzt den Übergangs-Tunnel, dessen Adresse sich bei jedem Neustart
# änderte. Am Server gemessen (27.09.2026), nicht angenommen:
#
#   · nginx 1.24: "http2 on;" gibt es erst ab 1.25 — hier also
#     "listen 443 ssl http2;".
#   · kural ist default_server auf Port 80. Der neue Block antwortet NUR auf
#     den DuckDNS-Namen; kural wird weder gelesen noch geändert.
#   · Die Firewall-Kette INPUT endet mit REJECT (Regel 6). Die Regel für 443
#     muss DAVOR stehen — dahinter wäre sie wirkungslos.
#   · "netfilter-persistent save" würde auch Dockers Laufzeitregeln in
#     rules.v4 schreiben, die beim Booten dann gegen Docker arbeiten. Deshalb
#     wird rules.v4 um genau EINE Zeile ergänzt und vorher mit
#     iptables-restore --test geprüft.
#
# Das Zertifikat kommt per "webroot": nginx liefert die Prüfdatei von Let's
# Encrypt aus, certbot fasst die nginx-Konfiguration nicht an. Zuerst ein
# Probelauf gegen die Testumgebung von Let's Encrypt, dann der echte.
#
# Fragt nach dem DuckDNS-Namen und dem Token. Der Token wird unsichtbar
# eingegeben, nur in /etc/edeka/duckdns.env (Rechte 600) gespeichert und
# curl über stdin übergeben — er steht nie in der Prozessliste und nie im Repo.
#
# Ausführen im Wurzelverzeichnis des Repos, auf main:
#     bash apply-d4-zugang.sh
#
set -euo pipefail

SELBST="$(basename "$0")"
REPO=$(pwd)
DUCK="$REPO/tools/duckdns.sh"
KONF=/etc/edeka/duckdns.env
WEBROOT=/var/www/letsencrypt
SITE=/etc/nginx/sites-available/edeka-lager
SITE_AN=/etc/nginx/sites-enabled/edeka-lager
RULES=/etc/iptables/rules.v4
R80='-A INPUT -p tcp -m tcp --dport 80 -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT'
R443='-A INPUT -p tcp -m tcp --dport 443 -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT'
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
die()  { printf '\n  \033[31m✗ %s\033[0m\n\n' "$1" >&2; exit 1; }

echo
echo "── Phase D, Schritt 4: fester Zugang über HTTPS ────────────────"
echo

# ── 0  Voraussetzungen ───────────────────────────────────────────────
[ -f Edeka.lager/backend/server.js ] && [ -d tools ] || die "Bitte im Wurzelverzeichnis des Repos ausführen (cd ~/Eder)."
for c in nginx curl sudo systemctl iptables getent openssl; do
  command -v "$c" >/dev/null || die "Das Programm '$c' fehlt."
done
if command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
  [ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || die "Bitte auf main: git checkout main && git pull"
  SCHMUTZ=$(git status --porcelain | grep -v -- "$SELBST" | grep -v "tools/duckdns.sh" || true)
  [ -z "$SCHMUTZ" ] || { printf '%s\n' "$SCHMUTZ" | sed 's/^/     /'; die "Arbeitsverzeichnis nicht sauber (siehe oben)."; }
  ok "Branch main, Arbeitsverzeichnis sauber"
fi
curl -fsS --max-time 3 http://127.0.0.1:3000/api/health 2>/dev/null | grep -q '"status":"ok"' \
  || die "Die App antwortet auf 127.0.0.1:3000 nicht — zuerst: systemctl status edeka-lager --no-pager"
systemctl is-active --quiet nginx || die "nginx läuft nicht."
ok "App und nginx laufen"

# Was kural jetzt ausliefert — am Ende muss es genau gleich sein.
KURAL_VOR=$(curl -s -o /dev/null -w '%{http_code} %{size_download}' --max-time 5 http://127.0.0.1/ || echo "keine Antwort")

# ── 1  Name und Token ─────────────────────────────────────────────────
echo
echo "── DuckDNS ─────────────────────────────────────────────────────"
SUB="${EDEKA_SUBDOMAIN:-}"
if [ -z "$SUB" ]; then read -r -p "  DuckDNS-Name (nur der Name, ohne .duckdns.org): " SUB; fi
SUB=$(printf '%s' "$SUB" | tr '[:upper:]' '[:lower:]' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/\.duckdns\.org$//')
[[ "$SUB" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || die "'$SUB' ist kein gültiger DuckDNS-Name (Kleinbuchstaben, Ziffern, Bindestrich)."
FQDN="$SUB.duckdns.org"

TOKEN="${EDEKA_DUCKDNS_TOKEN:-}"
if [ -z "$TOKEN" ] && sudo test -f "$KONF" && sudo grep -qx "DUCKDNS_DOMAIN=$SUB" "$KONF"; then
  TOKEN=$(sudo sed -n 's/^DUCKDNS_TOKEN=//p' "$KONF")
  ok "Token für $SUB aus $KONF übernommen"
fi
if [ -z "$TOKEN" ]; then
  read -r -s -p "  DuckDNS-Token (Eingabe bleibt unsichtbar): " TOKEN; echo
fi
TOKEN=$(printf '%s' "$TOKEN" | tr -d '[:space:]')
[[ "$TOKEN" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
  || die "Das sieht nicht wie ein DuckDNS-Token aus (Form: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)."

sudo install -d -m 700 /etc/edeka
( umask 077; printf 'DUCKDNS_DOMAIN=%s\nDUCKDNS_TOKEN=%s\n' "$SUB" "$TOKEN" | sudo tee "$KONF" >/dev/null )
sudo chmod 600 "$KONF"
unset TOKEN

cat > "$DUCK" <<'DUCK_EOF'
#!/usr/bin/env bash
#
# tools/duckdns.sh — hält <name>.duckdns.org auf der öffentlichen IP dieses Servers
#
# Stündlich per systemd (edeka-duckdns.timer). Angelegt von
# tools/apply-d4-zugang.sh. Name und Token stehen in /etc/edeka/duckdns.env
# (Rechte 600) — nie hier, nie im Repo.
#
# Antwort mit verbose=true laut duckdns.org/spec.jsp, eine Angabe je Zeile:
#   OK | KO,  IPv4,  IPv6 (darf leer sein),  UPDATED | NOCHANGE
# Ohne ip= erkennt DuckDNS die Adresse selbst — die dieses Servers.
#
set -euo pipefail
KONF="${KONF:-/etc/edeka/duckdns.env}"
URL="${DUCKDNS_URL:-https://www.duckdns.org/update}"

# shellcheck disable=SC1090
. "$KONF"
[ -n "${DUCKDNS_DOMAIN:-}" ] && [ -n "${DUCKDNS_TOKEN:-}" ] || { echo "✗ $KONF unvollständig" >&2; exit 1; }

# Über stdin an curl, nicht als Argument: so erscheint der Token nie in "ps".
ANTWORT=$(printf 'url = "%s?domains=%s&token=%s&ip=&verbose=true"\n' "$URL" "$DUCKDNS_DOMAIN" "$DUCKDNS_TOKEN" \
          | curl -fsS --max-time 20 -K -) || { echo "✗ DuckDNS nicht erreichbar" >&2; exit 1; }
STATUS=$(printf '%s\n' "$ANTWORT" | sed -n 1p)
IP=$(printf '%s\n' "$ANTWORT" | sed -n 2p)
STAND=$(printf '%s\n' "$ANTWORT" | sed -n 4p)
[ "$STATUS" = "OK" ] || { echo "✗ DuckDNS lehnt ab — Name oder Token falsch?" >&2; exit 1; }
echo "✓ ${DUCKDNS_DOMAIN}.duckdns.org → ${IP} (${STAND})"
echo "IP=${IP}"
DUCK_EOF
chmod 755 "$DUCK"

if ! AUS=$(sudo env DUCKDNS_URL="${DUCKDNS_URL:-https://www.duckdns.org/update}" "$DUCK" 2>&1); then
  printf '%s\n' "$AUS" | sed 's/^/    /' >&2
  sudo rm -f "$KONF"
  die "DuckDNS hat die Aktualisierung abgelehnt — der gespeicherte Token wurde wieder gelöscht."
fi
printf '%s\n' "$AUS" | grep -v '^IP=' | sed 's/^/  /'
IP=$(printf '%s\n' "$AUS" | sed -n 's/^IP=//p')
[[ "$IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "DuckDNS meldete keine IPv4-Adresse ('$IP')."

AUFGELOEST=""
for _ in $(seq 1 90); do
  AUFGELOEST=$(getent ahostsv4 "$FQDN" 2>/dev/null | awk 'NR == 1 { print $1 }' || true)
  [ "$AUFGELOEST" = "$IP" ] && break
  sleep 2
done
[ "$AUFGELOEST" = "$IP" ] || die "$FQDN zeigt noch nicht auf $IP (sondern auf '${AUFGELOEST:-nichts}'). In ein paar Minuten erneut versuchen."
ok "$FQDN zeigt auf diesen Server ($IP)"

# ── 2  Firewall: Port 443 ─────────────────────────────────────────────
echo
echo "── Firewall ────────────────────────────────────────────────────"
if sudo iptables -C INPUT -p tcp -m tcp --dport 443 -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT 2>/dev/null; then
  ok "Port 443 ist in der laufenden Firewall schon offen"
else
  POS=$(sudo iptables -L INPUT -n --line-numbers | awk '$2 == "REJECT" { print $1; exit }')
  [ -n "$POS" ] || die "Keine REJECT-Regel in INPUT gefunden — Firewall anders als erwartet, bitte melden."
  sudo iptables -I INPUT "$POS" -p tcp -m tcp --dport 443 -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT
  ok "Port 443 geöffnet — als Regel $POS, vor dem REJECT"
fi
if sudo grep -qxF -- "$R443" "$RULES"; then
  ok "rules.v4 enthält die Regel schon (bleibt nach dem Neustart)"
else
  sudo grep -qxF -- "$R80" "$RULES" || die "In $RULES fehlt die erwartete Regel für Port 80 — nichts verändert."
  [ -f "$RULES.d4.bak" ] || sudo cp -p "$RULES" "$RULES.d4.bak"
  NEU=$(mktemp)
  sudo cat "$RULES" | awk -v r80="$R80" -v r443="$R443" '{ print } $0 == r80 && !fertig { print r443; fertig = 1 }' > "$NEU"
  grep -qxF -- "$R443" "$NEU" || die "Einfügen in rules.v4 fehlgeschlagen — nichts verändert."
  sudo iptables-restore --test < "$NEU" || { rm -f "$NEU"; die "Die neue rules.v4 ist ungültig — nichts verändert."; }
  sudo install -m 640 -o root -g root "$NEU" "$RULES"
  rm -f "$NEU"
  ok "rules.v4 um genau eine Zeile ergänzt, direkt nach Port 80 (vorher geprüft)"
fi

# ── 3  nginx, Stufe 1: nur der Nachweis für Let's Encrypt ──────────────
echo
echo "── nginx und Zertifikat ────────────────────────────────────────"
sudo install -d -m 755 "$WEBROOT/.well-known/acme-challenge"

http_block() {
  cat <<EOF
# Von tools/apply-d4-zugang.sh erzeugt — Änderungen bitte dort.
# EDEKA Lagerverwaltung unter https://${FQDN}
# kural bleibt default_server auf Port 80 und wird hier nicht berührt.

server {
    listen 80;
    listen [::]:80;
    server_name ${FQDN};

    # Let's Encrypt prüft über diesen Pfad, dass die Domain zu diesem Server
    # gehört — auch bei jeder Verlängerung. Deshalb bleibt er über http offen.
    location ^~ /.well-known/acme-challenge/ {
        root ${WEBROOT};
        default_type text/plain;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF
}
https_block() {
  cat <<EOF

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${FQDN};

    ssl_certificate     /etc/letsencrypt/live/${FQDN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${FQDN}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_timeout 1d;
    ssl_session_cache   shared:EdekaTLS:10m;

    client_max_body_size 5m;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host              \$host;
        # Überschreiben statt anhängen: was ein Browser selbst als
        # X-Forwarded-For schickt, erreicht die App nie. Mit TRUST_PROXY=true
        # nimmt sie genau diese eine, von nginx gesetzte Adresse.
        proxy_set_header X-Forwarded-For   \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 60s;
    }
}
EOF
}

# Neue nginx-Konfiguration nur übernehmen, wenn "nginx -t" sie annimmt;
# sonst den vorigen Stand zurücklegen — kural läuft in jedem Fall weiter.
uebernehme() {
  local neu vorher=""; neu=$(mktemp)
  cat > "$neu"
  sudo test -f "$SITE" && vorher=$(mktemp) && sudo cat "$SITE" > "$vorher"
  sudo install -m 644 "$neu" "$SITE"; rm -f "$neu"
  sudo ln -sfn "$SITE" "$SITE_AN"
  if ! sudo nginx -t >/tmp/nginx-t.$$ 2>&1; then
    sed 's/^/    /' /tmp/nginx-t.$$ >&2
    if [ -n "$vorher" ]; then sudo install -m 644 "$vorher" "$SITE"; else sudo rm -f "$SITE" "$SITE_AN"; fi
    rm -f "$vorher" /tmp/nginx-t.$$
    die "nginx lehnt die Konfiguration ab — vorigen Stand wiederhergestellt, kural unverändert."
  fi
  rm -f "$vorher" /tmp/nginx-t.$$
  sudo systemctl reload nginx
}

# "systemctl reload nginx" wartet NICHT, bis nginx die neue Konfiguration
# übernommen hat: es schickt nur das Signal. Alte Worker nehmen noch kurz
# Anfragen an. Deshalb wird nach jedem Neuladen bis zu 15 s geprüft statt
# einmal. (Im ersten Lauf auf dem Server scheiterte genau diese Stelle — der
# Sandkasten hatte die Pause versehentlich selbst eingebaut und so verdeckt.)
warte_auf() { local n="$1" i; shift; for i in $(seq 1 "$n"); do "$@" && return 0; sleep 1; done; return 1; }

pruefdatei_da() {
  [ "$(curl -s --max-time 3 -H "Host: $FQDN" "http://127.0.0.1/.well-known/acme-challenge/$PROBE" || true)" = "$PROBE" ]
}
# Scheitert es auch nach 15 s, liegt es nicht am Timing — dann zeigen, woran.
# Der Pfad im Fehlerlog verrät, welcher server-Block geantwortet hat:
# /var/www/kural/… heißt "unser Block ist nicht aktiv", /var/www/letsencrypt/…
# heißt "unser Block ja, aber die Datei ist nicht lesbar".
diagnose_pruefdatei() {
  {
    echo "    Diagnose:"
    echo "      Antwort:      $(curl -s -o /dev/null -w 'HTTP %{http_code}' --max-time 3 -H "Host: $FQDN" "http://127.0.0.1/.well-known/acme-challenge/$PROBE" || echo 'keine')"
    echo "      Zugriffslog:  $(sudo tail -n 1 /var/log/nginx/access.log 2>/dev/null)"
    echo "      Fehlerlog zur Prüfdatei:"
    sudo grep -F "$PROBE" /var/log/nginx/error.log 2>/dev/null | tail -n 3 | sed 's/^/        /' || true
    echo "      Rechte auf dem Weg zur Datei:"
    namei -l "$WEBROOT/.well-known/acme-challenge/$PROBE" 2>/dev/null | sed 's/^/        /' || true
    echo "      server_name in der geladenen Konfiguration:"
    sudo nginx -T 2>/dev/null | grep -E '^\s*server_name' | sed 's/^/        /' || true
  } >&2
}
https_gesund() {
  curl -fsS --max-time 5 --resolve "$FQDN:443:127.0.0.1" "https://$FQDN/api/health" 2>/dev/null | grep -q '"status":"ok"'
}
umleitung_da() {
  [ "$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 5 --resolve "$FQDN:80:127.0.0.1" "http://$FQDN/lager" || true)" = "301 https://$FQDN/lager" ]
}

ZERT="/etc/letsencrypt/live/${FQDN}/fullchain.pem"
if sudo test -f "$ZERT" && sudo openssl x509 -checkend 2592000 -noout -in "$ZERT" >/dev/null 2>&1; then
  ok "gültiges Zertifikat für $FQDN liegt schon vor"
else
  http_block | uebernehme
  PROBE="probe-$$-$(date +%s)"
  echo "$PROBE" | sudo tee "$WEBROOT/.well-known/acme-challenge/$PROBE" >/dev/null
  if ! warte_auf 15 pruefdatei_da; then
    diagnose_pruefdatei
    sudo rm -f "$WEBROOT/.well-known/acme-challenge/$PROBE"
    die "nginx liefert die Prüfdatei auch nach 15 s nicht aus — Let's Encrypt würde scheitern (Diagnose oben)."
  fi
  sudo rm -f "$WEBROOT/.well-known/acme-challenge/$PROBE"
  ok "nginx liefert den Prüfpfad für $FQDN aus (kural antwortet weiter auf alles andere)"

  command -v certbot >/dev/null || { sudo NEEDRESTART_MODE=a apt-get install -y -qq certbot >/dev/null; ok "certbot installiert"; }
  CERTBOT_ARGE=( certonly --webroot -w "$WEBROOT" -d "$FQDN" --non-interactive --agree-tos
                 --register-unsafely-without-email --deploy-hook "systemctl reload nginx" )
  sudo certbot "${CERTBOT_ARGE[@]}" --dry-run >/tmp/certbot.$$ 2>&1 \
    || { sed 's/^/    /' /tmp/certbot.$$ >&2; rm -f /tmp/certbot.$$; die "Probelauf bei Let's Encrypt fehlgeschlagen — noch KEIN echter Versuch verbraucht."; }
  ok "Probelauf gegen die Testumgebung von Let's Encrypt erfolgreich"
  sudo certbot "${CERTBOT_ARGE[@]}" >/tmp/certbot.$$ 2>&1 \
    || { sed 's/^/    /' /tmp/certbot.$$ >&2; rm -f /tmp/certbot.$$; die "Let's Encrypt hat kein Zertifikat ausgestellt."; }
  rm -f /tmp/certbot.$$
  ok "Zertifikat ausgestellt"
fi

# ── 4  nginx, Stufe 2: HTTPS ──────────────────────────────────────────
{ http_block; https_block; } | uebernehme
ok "nginx: $FQDN auf 443, http leitet auf https um"

# ── 5  Nachweise ──────────────────────────────────────────────────────
echo
echo "── Nachweise ───────────────────────────────────────────────────"
if ! warte_auf 15 https_gesund; then
  curl -sS --max-time 5 --resolve "$FQDN:443:127.0.0.1" "https://$FQDN/api/health" 2>&1 | head -n 2 | sed 's/^/    /' >&2 || true
  die "https://$FQDN/api/health antwortet auch nach 15 s nicht (lokal geprüft, Grund oben)."
fi
ok "https://$FQDN/api/health — die App antwortet, Zertifikat passt zum Namen"
warte_auf 15 umleitung_da || die "http leitet nicht auf https um."
ok "http://$FQDN leitet auf https um"
KURAL_NACH=$(curl -s -o /dev/null -w '%{http_code} %{size_download}' --max-time 5 http://127.0.0.1/ || echo "keine Antwort")
[ "$KURAL_NACH" = "$KURAL_VOR" ] || die "kural antwortet anders als vorher ($KURAL_VOR → $KURAL_NACH)."
ok "kural unverändert ($KURAL_NACH)"
AUSSTELLER=$(sudo openssl x509 -issuer -noout -in "$ZERT" 2>/dev/null | sed 's/^issuer= *//')
BIS=$(sudo openssl x509 -enddate -noout -in "$ZERT" 2>/dev/null | sed 's/^notAfter=//')
case "$AUSSTELLER" in *"Let's Encrypt"*) ok "Zertifikat von Let's Encrypt, gültig bis $BIS" ;;
                                        *) warn "Aussteller: $AUSSTELLER (gültig bis $BIS)" ;; esac

# ── 6  Dauerbetrieb: DuckDNS stündlich, Zertifikat verlängert sich selbst ─
echo
echo "── Dauerbetrieb ────────────────────────────────────────────────"
printf '%s\n' \
  "# Von tools/apply-d4-zugang.sh erzeugt — Änderungen bitte dort." \
  "[Unit]" \
  "Description=EDEKA Lagerverwaltung — DuckDNS-Adresse aktuell halten" \
  "Wants=network-online.target" \
  "After=network-online.target" \
  "" \
  "[Service]" \
  "Type=oneshot" \
  "ExecStart=${DUCK}" \
  "NoNewPrivileges=true" \
  "PrivateTmp=true" \
  | sudo tee /etc/systemd/system/edeka-duckdns.service >/dev/null
printf '%s\n' \
  "# Von tools/apply-d4-zugang.sh erzeugt — Änderungen bitte dort." \
  "[Unit]" \
  "Description=EDEKA Lagerverwaltung — DuckDNS stündlich" \
  "" \
  "[Timer]" \
  "OnCalendar=hourly" \
  "RandomizedDelaySec=300" \
  "Persistent=true" \
  "" \
  "[Install]" \
  "WantedBy=timers.target" \
  | sudo tee /etc/systemd/system/edeka-duckdns.timer >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable --now edeka-duckdns.timer >/dev/null 2>&1
[ "$(systemctl is-enabled edeka-duckdns.timer 2>/dev/null)" = "enabled" ] || die "DuckDNS-Timer nicht aktiviert."
ok "DuckDNS wird stündlich aktualisiert"
[ "$(systemctl is-enabled certbot.timer 2>/dev/null)" = "enabled" ] \
  && ok "certbot.timer verlängert das Zertifikat selbst" \
  || warn "certbot.timer ist nicht aktiv — bitte melden"
sudo certbot renew --dry-run >/tmp/renew.$$ 2>&1 \
  && ok "Verlängerung probeweise durchgespielt — nginx wird danach neu geladen" \
  || { sed 's/^/    /' /tmp/renew.$$ >&2; warn "Die Probe-Verlängerung schlug fehl — bitte melden"; }
rm -f /tmp/renew.$$

if systemctl is-active --quiet edeka-tunnel 2>/dev/null; then
  sudo systemctl stop edeka-tunnel
  ok "Übergangs-Tunnel beendet — er wird nicht mehr gebraucht"
fi

echo
echo "── Danach ──────────────────────────────────────────────────────"
echo
echo "  Die App:  https://${FQDN}"
echo
echo "  Von deinem Rechner aus prüfen (PowerShell) — erst jetzt lässt sich"
echo "  die Freigabe für 443 in der Oracle-Konsole wirklich testen:"
echo "    Test-NetConnection ${FQDN} -Port 443 -WarningAction SilentlyContinue | Select-Object TcpTestSucceeded"
echo
echo "    mkdir -p tools && mv $SELBST tools/"
echo "    git add tools/$SELBST tools/duckdns.sh"
echo "    git commit -m 'Phase D Schritt 4: fester Zugang über HTTPS'"
echo "    git push"
echo
