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
