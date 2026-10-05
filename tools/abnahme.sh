#!/usr/bin/env bash
#
# abnahme.sh — läuft alles? Eine Prüfung über den ganzen Betrieb.
#
# Liest nur, ändert nichts. Jede Zeile ✓ oder ✗; am Ende die Summe. Der
# Rückgabewert ist 0 nur, wenn alles stimmt. Gedacht für: nach einem
# Neustart, nach jeder Änderung, und immer, wenn man es wissen will.
#
#     bash ~/Eder/tools/abnahme.sh
#
# Nach einem Neustart zwei Minuten warten: der erste Herzschlag kommt
# 2 Minuten nach dem Start.
#
set -uo pipefail

REPO="${ABNAHME_REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
DUCKDNS_KONF="${DUCKDNS_KONF:-/etc/edeka/duckdns.env}"
EXTERN_KONF="${EXTERN_KONF:-/etc/edeka/extern.env}"
ALARM_KONF="${ALARM_KONF:-/etc/edeka/alarm.env}"
RULES_V4="${RULES_V4:-/etc/iptables/rules.v4}"
ZIEL="${SICHERUNG_ZIEL:-$HOME/edeka-sicherungen}"
EXTERN="${EXTERN_ARBEIT:-$HOME/edeka-extern}"

OK=0; FEHL=0
gut()      { printf '  \033[32m✓\033[0m %s\n' "$1"; OK=$((OK + 1)); }
schlecht() { printf '  \033[31m✗\033[0m %s\n' "$1"; FEHL=$((FEHL + 1)); }
hinweis()  { printf '  \033[33m!\033[0m %s\n' "$1"; }
pruefe()   { local text=$1; shift; if "$@" >/dev/null 2>&1; then gut "$text"; else schlecht "$text"; fi; }

DOMAIN=$(sudo sed -n 's/^DUCKDNS_DOMAIN=//p' "$DUCKDNS_KONF" 2>/dev/null)
FQDN="${DOMAIN:-unbekannt}.duckdns.org"

echo
echo "── Abnahme: EDEKA Lagerverwaltung ──────────────────────────────"

echo
echo "── Dienste ─────────────────────────────────────────────────────"
for d in docker edeka-lager; do pruefe "$d läuft" systemctl is-active --quiet "$d"; done
for t in edeka-sicherung edeka-duckdns edeka-herzschlag edeka-zertifikat certbot; do
  pruefe "$t.timer aktiv" systemctl is-active --quiet "$t.timer"
done

echo
echo "── App ─────────────────────────────────────────────────────────"
gesund() { curl -fsS -m 15 "$1" | grep -q '"status":"ok"'; }
pruefe "lokal: 127.0.0.1:3000" gesund http://127.0.0.1:3000/api/health
pruefe "öffentlich: https://$FQDN — Zertifikat geprüft, durch die Security List" gesund "https://$FQDN/api/health"
umleitung() { [ "$(curl -s -o /dev/null -m 10 -w '%{http_code} %{redirect_url}' "http://$FQDN/")" = "301 https://$FQDN/" ]; }
pruefe "http leitet auf https um" umleitung
csp() {
  local kopf skript
  kopf=$(curl -fsSI -m 10 "https://$FQDN/" | tr -d '\r' | grep -i '^content-security-policy:') || return 1
  skript=$(printf '%s\n' "$kopf" | tr ';' '\n' | sed 's/^[^:]*: //; s/^ *//' | grep -E '^script-src ') || return 1
  [[ "$skript" == *"'self'"* && "$skript" != *unsafe-inline* ]] || return 1
  printf '%s\n' "$kopf" | tr ';' '\n' | grep -qE "^ *script-src-attr 'none'"
}
pruefe "CSP: kein Inline-Skript, keine Inline-Handler" csp
ZERT_TAGE=""
zertifikat() {
  local ende
  ende=$(timeout 20 openssl s_client -connect "$FQDN:443" -servername "$FQDN" </dev/null 2>/dev/null \
         | openssl x509 -noout -enddate 2>/dev/null | sed 's/^notAfter=//')
  [ -n "$ende" ] || return 1
  ZERT_TAGE=$(( ( $(date -d "$ende" +%s) - $(date +%s) ) / 86400 ))
  [ "$ZERT_TAGE" -ge 14 ]
}
if zertifikat; then gut "Zertifikat: noch $ZERT_TAGE Tage"; else schlecht "Zertifikat: ${ZERT_TAGE:-nicht lesbar} Tage — mindestens 14"; fi

echo
echo "── Daten ───────────────────────────────────────────────────────"
mongo() {
  [ "$(sudo docker inspect -f '{{.State.Running}}' edeka-mongo)" = true ] || return 1
  sudo docker inspect -f '{{range .Mounts}}{{.Name}} {{end}}' edeka-mongo | grep -qw edeka-mongo-daten
}
pruefe "MongoDB läuft, Daten im Volume edeka-mongo-daten" mongo
nur_lokal() {
  local fremd
  fremd=$(ss -ltnH | awk '{print $4}' | grep -E ':(3000|27017)$' | grep -vE '^(127\.0\.0\.1|\[::1\]):' || true)
  [ -z "$fremd" ]
}
pruefe "App (3000) und MongoDB (27017) nur auf 127.0.0.1" nur_lokal
JUENGSTE=""; ALTER=""
sicherung() {
  JUENGSTE=$(find "$ZIEL" -maxdepth 1 -type d -name '20[0-9][0-9]-*' ! -name '*.unfertig' -printf '%f\n' 2>/dev/null | sort | tail -1)
  [ -n "$JUENGSTE" ] || return 1
  ALTER=$(( ( $(date +%s) - $(stat -c %Y "$ZIEL/$JUENGSTE") ) / 3600 ))
  [ "$ALTER" -lt 26 ]
}
if sicherung; then gut "geprüfte Sicherung $JUENGSTE (vor $ALTER Std.)"
else schlecht "keine geprüfte Sicherung der letzten 26 Stunden (jüngste: ${JUENGSTE:-keine})"; fi
extern_hat() { [ -n "$JUENGSTE" ] && git -C "$EXTERN" ls-tree --name-only HEAD | grep -qx -- "$JUENGSTE"; }
pruefe "Kopie außer Haus enthält ${JUENGSTE:-die jüngste Sicherung}" extern_hat
extern_gleich() {
  local key dort
  key=$(sudo sed -n 's/^EXTERN_SSH_KEY=//p' "$EXTERN_KONF")
  dort=$(GIT_SSH_COMMAND="ssh -i $key -o IdentitiesOnly=yes -o BatchMode=yes" git -C "$EXTERN" ls-remote origin refs/heads/main | cut -f1)
  [ -n "$dort" ] && [ "$dort" = "$(git -C "$EXTERN" rev-parse HEAD)" ]
}
pruefe "GitHub zeigt denselben Stand der Kopie" extern_gleich

echo
echo "── Überwachung ─────────────────────────────────────────────────"
alarm_konf() { local v; for v in HC_SICHERUNG HC_EXTERN HC_APP HC_ZERTIFIKAT; do sudo grep -qE "^$v=https?://" "$ALARM_KONF" || return 1; done; }
pruefe "Healthchecks.io: vier Ping-Adressen eingetragen" alarm_konf
herzschlag() { sudo journalctl -u edeka-herzschlag.service --since "-11min" -o cat --no-pager | grep -q '^Finished'; }
pruefe "Herzschlag in den letzten 10 Minuten gesendet" herzschlag
fehler_melden() { systemctl show -p OnFailure --value edeka-lager.service | grep -q edeka-hc-fehler; }
pruefe "Ausfall der App wird sofort gemeldet" fehler_melden

echo
echo "── System ──────────────────────────────────────────────────────"
firewall() { local r p; r=$(sudo iptables -S INPUT) || return 1; for p in 22 80 443; do grep -qE -- "--dport $p( |$).*-j ACCEPT" <<<"$r" || return 1; done; }
pruefe "Firewall: 22, 80 und 443 offen" firewall
pruefe "Firewall-Regeln überstehen einen Neustart" sudo grep -q -- '--dport 443' "$RULES_V4"
platte() { [ "$(df --output=pcent / | tail -1 | tr -dc 0-9)" -lt 80 ]; }
pruefe "Platte unter 80 % belegt" platte
if [ -z "${ABNAHME_OHNE_GIT:-}" ]; then
  code() {
    git -C "$REPO" fetch -q origin 2>/dev/null || return 1
    [ "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" = main ] || return 1
    [ -z "$(git -C "$REPO" status --porcelain --untracked-files=no)" ] || return 1
    [ "$(git -C "$REPO" rev-parse HEAD)" = "$(git -C "$REPO" rev-parse origin/main)" ]
  }
  pruefe "Code: main, sauber, gleich mit GitHub" code
fi
N=$(apt-get -s --with-new-pkgs upgrade 2>/dev/null | grep -c '^Inst ' || true)
[ "${N:-0}" -eq 0 ] || hinweis "$N Paket-Aktualisierungen ausstehend — siehe BETRIEB.md, Systemupdates"
[ ! -f /var/run/reboot-required ] || hinweis "Neustart erforderlich — siehe BETRIEB.md, Systemupdates"

echo
if [ "$FEHL" -eq 0 ]; then
  printf '  \033[32mAlles in Ordnung: %d von %d Prüfungen.\033[0m\n\n' "$OK" "$((OK + FEHL))"
  exit 0
fi
printf '  \033[31m%d von %d Prüfungen nicht in Ordnung — siehe ✗ oben und Edeka.lager/BETRIEB.md.\033[0m\n\n' "$FEHL" "$((OK + FEHL))"
exit 1
