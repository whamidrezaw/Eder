#!/usr/bin/env bash
#
# alarm.sh — Lebenszeichen und Fehlermeldungen an Healthchecks.io
#
# Healthchecks.io schlägt Alarm, wenn ein erwartetes Lebenszeichen AUSBLEIBT —
# auch wenn dieser Server selbst tot ist — oder wenn ein Fehler gemeldet wird.
# Benachrichtigt wird von dort (E-Mail, Telegram), nicht von hier: auf diesem
# Server liegt kein Bot-Token.
#
# Aufrufe:
#   alarm.sh ok <sicherung|extern>       Lebenszeichen (OnSuccess= der Dienste)
#   alarm.sh fehlgeschlagen <einheit>    eine systemd-Einheit ist fehlgeschlagen (OnFailure=)
#   alarm.sh herzschlag                  die App über ihre ÖFFENTLICHE Adresse (alle 5 Minuten)
#   alarm.sh zertifikat                  Restlaufzeit des Zertifikats (täglich)
#   alarm.sh probe                       ein Probealarm — die Entwarnung bringt der nächste Herzschlag
#
# Einstellungen (Umgebung; von Hand aufgerufen aus ALARM_KONF, /etc/edeka/alarm.env):
#   HC_SICHERUNG, HC_EXTERN, HC_APP, HC_ZERTIFIKAT   Ping-Adressen — GEHEIM
#   APP_URL          öffentliche Adresse, zum Beispiel https://<name>.duckdns.org
#   ZERT_MIN_TAGE    ab wie vielen Resttagen gewarnt wird (14)
#
# Datenschutz: Hinaus gehen nur Stichworte und — bei den Sicherungsdiensten —
# deren letzte Protokollzeilen (Sammlungen, Zahlen). Vom Protokoll der App
# geht nichts hinaus: es kann Benutzernamen enthalten.
#
# Rückgabe: 0, wenn die Meldung angekommen ist — auch eine Fehlermeldung.
# 1, wenn sie nicht zugestellt werden konnte oder der Aufruf falsch ist.
#
set -euo pipefail

fehler() { echo "alarm: $*" >&2; exit 1; }

KONF="${ALARM_KONF:-/etc/edeka/alarm.env}"
if [ -z "${HC_APP:-}" ] && [ -r "$KONF" ] && [ "$(stat -c %U "$KONF")" = root ]; then
  set -a; . "$KONF"; set +a
fi

TMP=$(mktemp -d); chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

url_fuer() {
  case "$1" in
    sicherung)  printf '%s' "${HC_SICHERUNG:-}" ;;
    extern)     printf '%s' "${HC_EXTERN:-}" ;;
    app)        printf '%s' "${HC_APP:-}" ;;
    zertifikat) printf '%s' "${HC_ZERTIFIKAT:-}" ;;
    *) return 1 ;;
  esac
}

# melde <prüfung> <ok|fail> <text>. Immer POST — die Prüfungen nehmen nur POST
# an. Die geheime Adresse geht über die Standardeingabe an curl, nie über die
# Kommandozeile; curls eigene Meldungen werden verworfen, weil sie die Adresse
# enthalten könnten.
melde() {
  local url
  url=$(url_fuer "$1") || fehler "unbekannte Prüfung: $1"
  [ -n "$url" ] || fehler "keine Ping-Adresse für '$1' — siehe $KONF"
  [ "$2" = fail ] && url="$url/fail"
  printf '%s' "$3" | head -c 10000 > "$TMP/text"
  printf 'url = "%s"\n' "$url" \
    | curl -K - -fsS -m 10 --retry 3 --retry-delay 5 -o /dev/null --data-binary @"$TMP/text" 2>/dev/null \
    || fehler "Healthchecks.io nicht erreicht ($1, $2)"
}

jetzt() { date -Iseconds; }

BEFEHL="${1:-}"
case "$BEFEHL" in
  ok)
    [ $# -eq 2 ] || fehler "Aufruf: alarm.sh ok <sicherung|extern>"
    case "$2" in sicherung|extern) ;; *) fehler "unbekannte Prüfung: $2" ;; esac
    melde "$2" ok "OK $(jetzt)"
    ;;

  fehlgeschlagen)
    EINHEIT="${2:-}"
    case "$EINHEIT" in
      edeka-sicherung.service) P=sicherung; PROTOKOLL=1 ;;
      edeka-extern.service)    P=extern;    PROTOKOLL=1 ;;
      edeka-lager.service)     P=app;       PROTOKOLL=0 ;;
      *) fehler "unbekannte Einheit: '$EINHEIT'" ;;
    esac
    TEXT="$EINHEIT ist fehlgeschlagen ($(jetzt))."
    if [ "$PROTOKOLL" = 1 ]; then
      ZEILEN=$(journalctl -u "$EINHEIT" -n 25 --no-pager -o cat 2>/dev/null || true)
      TEXT="$TEXT"$'\n\n'"Letzte Protokollzeilen:"$'\n'"${ZEILEN:-(Protokoll nicht lesbar)}"
    else
      TEXT="$TEXT"$'\n'"Einzelheiten nur auf dem Server: journalctl -u ${EINHEIT%.service} -n 50 --no-pager"
    fi
    melde "$P" fail "$TEXT"
    ;;

  herzschlag)
    [ -n "${APP_URL:-}" ] || fehler "APP_URL fehlt — siehe $KONF"
    if CODE=$(curl -sS -m 15 -o "$TMP/antwort" -w '%{http_code}' "$APP_URL/api/health" 2>"$TMP/fehler"); then
      if [ "$CODE" = 200 ] && grep -q '"status":"ok"' "$TMP/antwort"; then
        melde app ok "HTTP 200 $(jetzt)"
      else
        melde app fail "$APP_URL/api/health antwortet mit HTTP $CODE ($(jetzt))"
      fi
    else
      melde app fail "$APP_URL nicht erreichbar ($(jetzt)): $(head -c 300 "$TMP/fehler")"
    fi
    ;;

  zertifikat)
    [ -n "${APP_URL:-}" ] || fehler "APP_URL fehlt — siehe $KONF"
    HP=${APP_URL#https://}; HP=${HP%%/*}
    HOST=${HP%%:*}; PORT=443
    case "$HP" in *:*) PORT=${HP##*:} ;; esac
    ENDE=$(timeout 20 openssl s_client -connect "$HOST:$PORT" -servername "$HOST" </dev/null 2>/dev/null \
           | openssl x509 -noout -enddate 2>/dev/null | sed 's/^notAfter=//' || true)
    if [ -z "$ENDE" ]; then
      melde zertifikat fail "Kein Zertifikat von $HOST:$PORT lesbar ($(jetzt))"
      exit 0
    fi
    TAGE=$(( ( $(date -d "$ENDE" +%s) - $(date +%s) ) / 86400 ))
    if [ "$TAGE" -ge "${ZERT_MIN_TAGE:-14}" ]; then
      melde zertifikat ok "noch $TAGE Tage (bis $ENDE)"
    else
      melde zertifikat fail "Zertifikat für $HOST läuft in $TAGE Tagen ab ($ENDE). Prüfen: sudo certbot renew --dry-run"
    fi
    ;;

  probe)
    melde app fail "PROBEALARM — kein echter Ausfall, von Hand ausgelöst ($(jetzt)). Die Entwarnung folgt mit dem nächsten Herzschlag."
    ;;

  *)
    fehler "Aufruf: alarm.sh ok|fehlgeschlagen|herzschlag|zertifikat|probe …"
    ;;
esac
