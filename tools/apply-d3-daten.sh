#!/usr/bin/env bash
#
# apply-d3-daten.sh — Phase D, Schritt 3: Datensicherung und Umzug der Daten
#
# Drei Befunde auf dem Server (27.09.2026):
#
#   · Es gab keine Datensicherung.
#   · MongoDB (Container edeka-mongo) hält ihre Daten in einem Volume OHNE
#     Namen. Ein einziges "docker rm edeka-mongo" — etwa für ein Update —
#     und der nächste Container bekäme ein neues, LEERES Volume. Am 17.09.
#     ist genau das schon einmal passiert: zwei verwaiste Volumes liegen noch.
#   · Der App-Dienst wartet beim Booten nicht auf Docker.
#
# Dieses Skript:
#   1. legt tools/sicherung.sh an: sichert jede Anwendungsdatenbank und
#      spielt die Sicherung SOFORT probeweise zurück — Dokumente und Indizes
#      jeder Sammlung werden verglichen. Erst dann gilt sie als fertig.
#   2. zieht die Daten in benannte Volumes um (edeka-mongo-daten,
#      edeka-mongo-config): App anhalten, letzte Sicherung, alten Container
#      umbenennen (NICHT löschen), neuen Container mit demselben Image
#      starten, zurückspielen, jede Sammlung vergleichen, App starten.
#      Schlägt dabei irgendetwas fehl, stellt das Skript den alten Zustand
#      selbst wieder her.
#   3. lässt die App beim Booten auf Docker warten.
#   4. richtet die tägliche Sicherung ein (02:30 Berliner Zeit, 14 Stück)
#      und führt den Dienst einmal aus, um ihn nachzuweisen.
#
# Die Formate, die ausgewertet werden, stammen aus dem Quelltext von
# mongo-tools 100.18.0 (der Version im Container), nicht aus dem Gedächtnis:
#   mongodump:    "done dumping %#q (%v %v)"   → Name in `Backticks`
#   mongorestore: "%v document(s) restored successfully. %v document(s) failed to restore."
#
# Ausführen im Wurzelverzeichnis des Repos, auf main:
#     bash apply-d3-daten.sh
#
set -euo pipefail

BE="Edeka.lager/backend"
SELBST="$(basename "$0")"
CONTAINER="edeka-mongo"
ALT="edeka-mongo-alt"
VOL_DATEN="edeka-mongo-daten"
VOL_CONFIG="edeka-mongo-config"
DIENST="edeka-lager"
REPO=$(pwd)
NUTZER=$(id -un)
ZIEL="$HOME/edeka-sicherungen"
SICHERUNG="$REPO/tools/sicherung.sh"
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
die()  { printf '\n  \033[31m✗ %s\033[0m\n\n' "$1" >&2; exit 1; }
D() { sudo docker "$@"; }
# Nur Zeilen mit "Z " zählen — was mongosh sonst ausgibt, stört so nie.
mongo_in() { D exec "$1" mongosh --quiet --eval "$2" | sed -n 's/^Z //p'; }

echo
echo "── Phase D, Schritt 3: Datensicherung und Umzug der Daten ──────"
echo

# ── 0  Voraussetzungen ───────────────────────────────────────────────
[ -f "$BE/server.js" ] && [ -d tools ] || die "Bitte im Wurzelverzeichnis des Repos ausführen (cd ~/Eder)."
for c in docker sudo systemctl curl gzip awk; do command -v "$c" >/dev/null || die "Das Programm '$c' fehlt."; done
systemctl cat "$DIENST" >/dev/null 2>&1 || die "Der Dienst $DIENST fehlt — zuerst Schritt 2 (apply-d2-dienst.sh)."

if command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
  [ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || die "Bitte auf main: git checkout main && git pull"
  SCHMUTZ=$(git status --porcelain | grep -v -- "$SELBST" | grep -v "tools/sicherung.sh" || true)
  [ -z "$SCHMUTZ" ] || { printf '%s\n' "$SCHMUTZ" | sed 's/^/     /'; die "Arbeitsverzeichnis nicht sauber (siehe oben)."; }
  ok "Branch main, Arbeitsverzeichnis sauber"
fi

[ "$(D inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" = "true" ] \
  || die "Der Container $CONTAINER läuft nicht."

# Nur einen Container neu anlegen, dessen Startparameter wir vollständig
# kennen: Standardbefehl, Port nur auf 127.0.0.1.
CMD=$(D inspect -f '{{json .Config.Cmd}}' "$CONTAINER")
[ "$CMD" = '["mongod"]' ] || die "$CONTAINER startet mit unerwarteten Parametern ($CMD) — nicht automatisch nachbaubar."
PORTS=$(D inspect -f '{{json .HostConfig.PortBindings}}' "$CONTAINER")
echo "$PORTS" | grep -q '"HostIp":"127.0.0.1","HostPort":"27017"' \
  || die "$CONTAINER ist nicht wie erwartet nur an 127.0.0.1:27017 gebunden ($PORTS)."

MOUNT=$(D inspect -f '{{range .Mounts}}{{if eq .Destination "/data/db"}}{{.Type}} {{.Name}}{{end}}{{end}}' "$CONTAINER")
if [ "$MOUNT" = "volume $VOL_DATEN" ]; then
  UMZUG=0
  ok "Daten liegen schon im benannten Volume $VOL_DATEN — kein Umzug nötig"
elif echo "$MOUNT" | grep -qE '^volume [0-9a-f]{64}$'; then
  UMZUG=1
  ok "Daten liegen im unbenannten Volume ${MOUNT#volume } — Umzug nötig"
  for v in "$VOL_DATEN" "$VOL_CONFIG"; do
    D volume inspect "$v" >/dev/null 2>&1 && die "Das Volume $v gibt es schon, benutzt wird es aber nicht. Bitte ansehen, bevor etwas überschrieben wird."
  done
  D inspect "$ALT" >/dev/null 2>&1 && die "Ein Container $ALT existiert schon — Reste eines früheren Versuchs? Bitte ansehen."
else
  die "Unerwartete Ablage der Daten: '$MOUNT'."
fi

# ── 1  tools/sicherung.sh ─────────────────────────────────────────────
echo
echo "── Sicherungsskript ────────────────────────────────────────────"
cat > "$SICHERUNG" <<'SICHERUNG_EOF'
#!/usr/bin/env bash
#
# tools/sicherung.sh — Sicherung der MongoDB im Container edeka-mongo, mit Nachweis
#
# Läuft täglich per systemd (edeka-sicherung.timer, 02:30 Berliner Zeit) und
# vor jedem Umzug der Daten. Angelegt von tools/apply-d3-daten.sh.
#
# Eine Sicherung, deren Wiederherstellung nie geprüft wurde, ist eine
# Hoffnung. Deshalb wird jede Sicherung sofort in eine eigene Datenbank
# zurückgespielt (sicherungsprobe_<name>) und je Sammlung verglichen:
# Anzahl der Dokumente wie beim Sichern, Anzahl der Indizes wie im Original.
# Danach wird die Probe gelöscht. Nur eine so geprüfte Sicherung bleibt liegen.
#
# Umgebung (alle optional):
#   CONTAINER  Container der Datenbank      (edeka-mongo)
#   ZIEL       Ablage der Sicherungen       (/home/ubuntu/edeka-sicherungen)
#   BEHALTEN   so viele bleiben liegen      (14)
#   BESITZER   Eigentümer der Dateien       (ubuntu)
#
# Zurückspielen — ÜBERSCHREIBT die Datenbank, vorher die App anhalten:
#   sudo systemctl stop edeka-lager
#   sudo docker exec -i edeka-mongo mongorestore --archive --gzip --drop \
#     < /home/ubuntu/edeka-sicherungen/<Stempel>/edeka_lager.archive.gz
#   sudo systemctl start edeka-lager
#
set -euo pipefail

CONTAINER="${CONTAINER:-edeka-mongo}"
ZIEL="${ZIEL:-/home/ubuntu/edeka-sicherungen}"
BEHALTEN="${BEHALTEN:-14}"
BESITZER="${BESITZER:-ubuntu}"
PROBE="sicherungsprobe_"

fehler() { echo "✗ $*" >&2; exit 1; }
mongo() { docker exec "$CONTAINER" mongosh --quiet --eval "$1" | sed -n 's/^Z //p'; }
# "sammlung dokumente indizes" je echter Sammlung einer Datenbank
liste() {
  mongo "const d = db.getSiblingDB('$1');
         d.getCollectionInfos({ type: 'collection' }).map(i => i.name)
          .filter(n => !n.startsWith('system.'))
          .forEach(c => print('Z ' + c + ' ' + d.getCollection(c).countDocuments({}) + ' ' + d.getCollection(c).getIndexes().length));" | sort
}

[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" = "true" ] \
  || fehler "Container $CONTAINER läuft nicht."

STEMPEL=$(date +%Y-%m-%d_%H%M%S)
ORDNER="$ZIEL/$STEMPEL"
ARBEIT="$ORDNER.unfertig"
install -d -m 700 "$ZIEL"
install -d -m 700 "$ARBEIT"

PROBEN=()
aufraeumen() {
  local p
  for p in "${PROBEN[@]}"; do mongo "db.getSiblingDB('$p').dropDatabase(); print('Z ok')" >/dev/null 2>&1 || true; done
  rm -rf "$ARBEIT"
}
trap aufraeumen EXIT

# Unfertige Reste früherer, abgebrochener Läufe
find "$ZIEL" -maxdepth 1 -name '*.unfertig' ! -path "$ARBEIT" -mmin +60 -exec rm -rf {} + 2>/dev/null || true

DBS=$(mongo "db.adminCommand({ listDatabases: 1 }).databases.forEach(d => print('Z ' + d.name))" \
      | grep -vE "^(admin|config|local)$|_test$|^${PROBE}" || true)
[ -n "$DBS" ] || fehler "Keine Anwendungsdatenbank gefunden."

GESAMT=""
for DB in $DBS; do
  # 1  Sichern
  if ! docker exec "$CONTAINER" mongodump --db="$DB" --archive --gzip \
         > "$ARBEIT/$DB.archive.gz" 2> "$ARBEIT/$DB.dump.log"; then
    sed 's/^/    /' "$ARBEIT/$DB.dump.log" >&2; fehler "mongodump für $DB fehlgeschlagen."
  fi
  gzip -t "$ARBEIT/$DB.archive.gz" || fehler "Das Archiv für $DB ist beschädigt."

  # mongodump 100.18.0 schreibt: done dumping `db.sammlung` (12 documents)
  # (%#q: Backticks; nur bei Sonderzeichen doppelte Anführungszeichen)
  grep -oE 'done dumping [`"][^`"]+[`"] \([0-9]+ documents?\)' "$ARBEIT/$DB.dump.log" \
    | sed -E 's/^done dumping [`"]([^`"]+)[`"] \(([0-9]+) documents?\)$/\1 \2/' \
    | sed "s/^${DB}\\.//" | sort > "$ARBEIT/$DB.inhalt"
  [ -s "$ARBEIT/$DB.inhalt" ] || fehler "mongodump meldete für $DB keine einzige Sammlung (siehe $DB.dump.log)."
  SOLL=$(awk '{ s += $2 } END { print s + 0 }' "$ARBEIT/$DB.inhalt")

  # 2  Probeweise zurückspielen
  P="${PROBE}${DB}"; PROBEN+=("$P")
  docker exec -i "$CONTAINER" mongorestore --archive --gzip --drop --nsFrom="${DB}.*" --nsTo="${P}.*" \
    < "$ARBEIT/$DB.archive.gz" 2> "$ARBEIT/$DB.probe.log" || true
  grep -qE "(^|[[:space:]])${SOLL} document\(s\) restored successfully\. 0 document\(s\) failed to restore\." "$ARBEIT/$DB.probe.log" \
    || { sed 's/^/    /' "$ARBEIT/$DB.probe.log" >&2; fehler "Probe für $DB: nicht alle $SOLL Dokumente zurückgespielt."; }

  # 3  Vergleichen: Dokumente wie beim Sichern, Indizes wie im Original
  liste "$DB" > "$ARBEIT/$DB.original"
  liste "$P"  > "$ARBEIT/$DB.probe"
  # FILENAME statt mitzählen: auch eine LEERE Datei (Probe schrieb nichts)
  # muss als "fehlt" auffallen, statt die nächste an ihre Stelle rücken zu lassen.
  if ! awk 'FILENAME == ARGV[1] { soll[$1] = $2; next }
            FILENAME == ARGV[2] { ist[$1] = $2; idx[$1] = $3; next }
            FILENAME == ARGV[3] { ref[$1] = $3; next }
            END { bad = 0
                  for (c in soll) {
                    if (!(c in ist))          { print "    fehlt: " c; bad = 1; continue }
                    if (ist[c] != soll[c])    { print "    " c ": " ist[c] " statt " soll[c] " Dokumente"; bad = 1 }
                    if ((c in ref) && idx[c] != ref[c]) { print "    " c ": " idx[c] " statt " ref[c] " Indizes"; bad = 1 }
                  }
                  exit bad }' "$ARBEIT/$DB.inhalt" "$ARBEIT/$DB.probe" "$ARBEIT/$DB.original"; then
    fehler "Probe für $DB weicht vom Original ab (siehe oben)."
  fi
  mongo "db.getSiblingDB('$P').dropDatabase(); print('Z ok')" >/dev/null
  GESAMT="$GESAMT $DB($(wc -l < "$ARBEIT/$DB.inhalt") Sammlungen, $SOLL Dokumente)"
done

rm -f "$ARBEIT"/*.probe "$ARBEIT"/*.original
mv "$ARBEIT" "$ORDNER"
chmod 600 "$ORDNER"/*
id "$BESITZER" >/dev/null 2>&1 && chown -R "$BESITZER": "$ZIEL"

# Nur fertige Sicherungen zählen und löschen, die ältesten zuerst.
mapfile -t FERTIGE < <(find "$ZIEL" -maxdepth 1 -type d -name '20[0-9][0-9]-*' ! -name '*.unfertig' | sort)
if [ "${#FERTIGE[@]}" -gt "$BEHALTEN" ]; then
  printf '%s\n' "${FERTIGE[@]:0:$(( ${#FERTIGE[@]} - BEHALTEN ))}" | xargs -r rm -rf
fi

echo "✓ Sicherung $STEMPEL geprüft:$GESAMT"
echo "ORDNER=$ORDNER"
SICHERUNG_EOF
chmod 755 "$SICHERUNG"
ok "tools/sicherung.sh"

sicher() {
  local aus
  if ! aus=$(sudo env ZIEL="$ZIEL" BESITZER="$NUTZER" "$SICHERUNG" 2>&1); then
    printf '%s\n' "$aus" | sed 's/^/    /' >&2
    return 1
  fi
  printf '%s\n' "$aus" | grep -v '^ORDNER=' | sed 's/^/  /' >&2
  printf '%s\n' "$aus" | sed -n 's/^ORDNER=//p'
}

echo
echo "── Erste Sicherung, mit Probe (App läuft weiter) ───────────────"
ERSTE=$(sicher) || die "Die Sicherung ist fehlgeschlagen — es wurde NICHTS umgezogen."
ok "abgelegt in $ERSTE"

gesund() {
  local i
  for i in $(seq 1 "$1"); do
    curl -fsS --max-time 2 "http://127.0.0.1:3000/api/health" 2>/dev/null | grep -q '"status":"ok"' && return 0
    sleep 1
  done
  return 1
}
bereit() {
  local i
  for i in $(seq 1 "$1"); do
    [ "$(mongo_in "$CONTAINER" "print('Z ' + db.runCommand({ ping: 1 }).ok)" 2>/dev/null || true)" = "1" ] && return 0
    sleep 1
  done
  return 1
}

# ── 2  Umzug in benannte Volumes ──────────────────────────────────────
KRITISCH=0
zurueck() {
  [ "$KRITISCH" = "1" ] || return 0
  KRITISCH=0
  printf '\n  \033[33m!\033[0m Etwas ist schiefgegangen — der alte Zustand wird wiederhergestellt …\n' >&2
  D stop "$CONTAINER" >/dev/null 2>&1 || true
  D rm "$CONTAINER" >/dev/null 2>&1 || true
  D volume rm "$VOL_DATEN" "$VOL_CONFIG" >/dev/null 2>&1 || true
  D rename "$ALT" "$CONTAINER" >/dev/null 2>&1 || true
  D update --restart=unless-stopped "$CONTAINER" >/dev/null 2>&1 || true
  D start "$CONTAINER" >/dev/null 2>&1 || true
  if bereit 60; then printf '  \033[32m✓\033[0m alter Container läuft wieder, mit seinen Daten\n' >&2
  else printf '  \033[31m✗ alter Container antwortet nicht — bitte sofort melden\033[0m\n' >&2; fi
  sudo systemctl start "$DIENST" >/dev/null 2>&1 || true
  if gesund 30; then printf '  \033[32m✓\033[0m App läuft wieder\n' >&2
  else printf '  \033[31m✗ App antwortet nicht — bitte sofort melden\033[0m\n' >&2; fi
}
trap zurueck EXIT

if [ "$UMZUG" = "1" ]; then
  echo
  echo "── Umzug in benannte Volumes (App etwa eine Minute aus) ────────"
  BILD=$(D inspect -f '{{.Image}}' "$CONTAINER")

  sudo systemctl stop "$DIENST"
  ok "App angehalten — ab jetzt schreibt niemand mehr"

  LETZTE=$(sicher) || { sudo systemctl start "$DIENST"; die "Letzte Sicherung fehlgeschlagen — App läuft wieder, NICHTS umgezogen."; }
  ok "letzte Sicherung: $LETZTE"

  VORHER="$LETZTE/.vorher"
  mkdir -p "$VORHER"
  for A in "$LETZTE"/*.archive.gz; do
    DB=$(basename "$A" .archive.gz)
    mongo_in "$CONTAINER" "const d = db.getSiblingDB('$DB');
      d.getCollectionInfos({ type: 'collection' }).map(i => i.name).filter(n => !n.startsWith('system.'))
       .forEach(c => print('Z ' + c + ' ' + d.getCollection(c).countDocuments({}) + ' ' + d.getCollection(c).getIndexes().length));" \
      | sort > "$VORHER/$DB.liste"
  done

  # Ab hier greift die Rückkehr zum alten Zustand bei jedem Fehler.
  KRITISCH=1
  D stop "$CONTAINER" >/dev/null
  D rename "$CONTAINER" "$ALT"
  D update --restart=no "$ALT" >/dev/null
  ok "alter Container heißt jetzt $ALT — angehalten, NICHT gelöscht"

  D run -d --name "$CONTAINER" --restart unless-stopped \
    -p 127.0.0.1:27017:27017 \
    -v "$VOL_DATEN":/data/db -v "$VOL_CONFIG":/data/configdb \
    "$BILD" >/dev/null
  bereit 60 || die "Der neue Container antwortet nicht."
  ok "neuer Container mit $VOL_DATEN und $VOL_CONFIG, gleiches Image (${BILD:0:19}…)"

  for A in "$LETZTE"/*.archive.gz; do
    DB=$(basename "$A" .archive.gz)
    SOLL=$(awk '{ s += $2 } END { print s + 0 }' "$LETZTE/$DB.inhalt")
    D exec -i "$CONTAINER" mongorestore --archive --gzip --drop < "$A" 2> "$VORHER/$DB.restore.log" || true
    grep -qE "(^|[[:space:]])${SOLL} document\(s\) restored successfully\. 0 document\(s\) failed to restore\." "$VORHER/$DB.restore.log" \
      || { sed 's/^/    /' "$VORHER/$DB.restore.log" >&2; die "$DB: nicht alle $SOLL Dokumente zurückgespielt."; }
    mongo_in "$CONTAINER" "const d = db.getSiblingDB('$DB');
      d.getCollectionInfos({ type: 'collection' }).map(i => i.name).filter(n => !n.startsWith('system.'))
       .forEach(c => print('Z ' + c + ' ' + d.getCollection(c).countDocuments({}) + ' ' + d.getCollection(c).getIndexes().length));" \
      | sort > "$VORHER/$DB.neu"
    if ! awk 'FILENAME == ARGV[1] { soll[$1] = $2; idx[$1] = $3; next }
              FILENAME == ARGV[2] { ist[$1] = $2; idn[$1] = $3; next }
              END { bad = 0
                    for (c in soll) {
                      if (!(c in ist))       { print "    fehlt: " c; bad = 1; continue }
                      if (ist[c] != soll[c]) { print "    " c ": " ist[c] " statt " soll[c] " Dokumente"; bad = 1 }
                      if (idn[c] != idx[c])  { print "    " c ": " idn[c] " statt " idx[c] " Indizes"; bad = 1 }
                    }
                    exit bad }' "$VORHER/$DB.liste" "$VORHER/$DB.neu"; then
      die "$DB weicht nach dem Umzug vom alten Stand ab (siehe oben)."
    fi
    ok "$DB: $(wc -l < "$VORHER/$DB.liste") Sammlungen, $SOLL Dokumente, alle Indizes — identisch"
  done

  sudo systemctl start "$DIENST"
  gesund 30 || die "Die App antwortet mit dem neuen Container nicht."
  [ "$(D inspect -f '{{range .Mounts}}{{if eq .Destination "/data/db"}}{{.Type}} {{.Name}}{{end}}{{end}}' "$CONTAINER")" = "volume $VOL_DATEN" ] \
    || die "Der neue Container benutzt nicht $VOL_DATEN."
  KRITISCH=0
  sudo rm -rf "$VORHER"
  ok "App läuft wieder — mit den Daten im benannten Volume"
fi

# ── 3  Beim Booten auf Docker warten ──────────────────────────────────
echo
echo "── Systemstart ─────────────────────────────────────────────────"
sudo mkdir -p "/etc/systemd/system/${DIENST}.service.d"
printf '%s\n' \
  "# Von tools/apply-d3-daten.sh — MongoDB läuft im Docker-Container ${CONTAINER}." \
  "# Ohne diese Zeilen konnte die App beim Booten vor der Datenbank starten." \
  "[Unit]" \
  "Wants=docker.service" \
  "After=docker.service" \
  | sudo tee "/etc/systemd/system/${DIENST}.service.d/10-docker.conf" >/dev/null
ok "die App startet beim Booten nach Docker"

# ── 4  Tägliche Sicherung ─────────────────────────────────────────────
printf '%s\n' \
  "# Von tools/apply-d3-daten.sh erzeugt — Änderungen bitte dort." \
  "[Unit]" \
  "Description=EDEKA Lagerverwaltung — Datensicherung mit Wiederherstellungsprobe" \
  "Wants=docker.service" \
  "After=docker.service" \
  "" \
  "[Service]" \
  "Type=oneshot" \
  "Environment=ZIEL=${ZIEL} BESITZER=${NUTZER} BEHALTEN=14 CONTAINER=${CONTAINER}" \
  "ExecStart=${SICHERUNG}" \
  "NoNewPrivileges=true" \
  "PrivateTmp=true" \
  | sudo tee /etc/systemd/system/edeka-sicherung.service >/dev/null
printf '%s\n' \
  "# Von tools/apply-d3-daten.sh erzeugt — Änderungen bitte dort." \
  "[Unit]" \
  "Description=EDEKA Lagerverwaltung — tägliche Datensicherung" \
  "" \
  "[Timer]" \
  "OnCalendar=*-*-* 02:30:00 Europe/Berlin" \
  "Persistent=true" \
  "" \
  "[Install]" \
  "WantedBy=timers.target" \
  | sudo tee /etc/systemd/system/edeka-sicherung.timer >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable --now edeka-sicherung.timer >/dev/null 2>&1
[ "$(systemctl is-enabled edeka-sicherung.timer 2>/dev/null)" = "enabled" ] || die "Der Timer ist nicht aktiviert."
ok "Timer: täglich 02:30 Berliner Zeit, 14 Sicherungen bleiben liegen"

# Den Dienst einmal genau so laufen lassen, wie der Timer es nachts tut.
ANZAHL_VOR=$(find "$ZIEL" -maxdepth 1 -type d -name '20[0-9][0-9]-*' ! -name '*.unfertig' | wc -l)
sudo systemctl start edeka-sicherung.service || true
ERGEBNIS=$(systemctl show -p Result --value edeka-sicherung.service 2>/dev/null || echo unbekannt)
ANZAHL_NACH=$(find "$ZIEL" -maxdepth 1 -type d -name '20[0-9][0-9]-*' ! -name '*.unfertig' | wc -l)
if [ "$ERGEBNIS" = "success" ] && [ "$ANZAHL_NACH" -gt "$ANZAHL_VOR" ]; then
  ok "der Sicherungsdienst lief einmal wie nachts — Ergebnis: success"
else
  journalctl -u edeka-sicherung.service -n 20 --no-pager 2>/dev/null | sed 's/^/    /'
  die "Der Sicherungsdienst lief nicht erfolgreich (Ergebnis: $ERGEBNIS)."
fi

echo
echo "── Danach ──────────────────────────────────────────────────────"
echo
echo "  Sicherungen:        ls -l $ZIEL"
echo "  Letzter Lauf:       journalctl -u edeka-sicherung --no-pager -n 5"
echo "  Nächster Lauf:      systemctl list-timers edeka-sicherung.timer --no-pager"
echo
if [ "$UMZUG" = "1" ]; then
  echo "  Der alte Container $ALT bleibt angehalten liegen — als Rückweg."
  echo "  Nach einer Woche ohne Auffälligkeiten entfernen:"
  echo "    sudo docker rm $ALT"
  echo
fi
echo "    mkdir -p tools && mv $SELBST tools/"
echo "    git add tools/$SELBST tools/sicherung.sh"
echo "    git commit -m 'Phase D Schritt 3: geprüfte Datensicherung, Daten in benannten Volumes'"
echo "    git push"
echo
