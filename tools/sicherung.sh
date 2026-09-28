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

# ── Wächter vor jedem Löschen ────────────────────────────────────────
# Weiter unten löscht dieses Skript alte Sicherungen und abgebrochene Reste
# mit rm -rf. Vorher muss ZIEL ein eigener, echter Ordner sein: Symlinks
# aufgelöst, absolut, mindestens drei Ebenen tief, kein Systemordner, und
# falls es ihn schon gibt, ein Verzeichnis von root oder $BESITZER.
# (test/unit/sicherung-pfad.test.js)
case "$ZIEL" in /*) ;; *) fehler "ZIEL muss ein absoluter Pfad sein: '$ZIEL'" ;; esac
ZIEL=$(realpath -m -- "$ZIEL")
[ "$(printf '%s' "$ZIEL" | tr -cd '/' | wc -c)" -ge 3 ] || fehler "ZIEL liegt zu weit oben im Dateisystem: '$ZIEL'"
case "$ZIEL/" in
  /bin/*|/boot/*|/dev/*|/etc/*|/lib/*|/lib64/*|/proc/*|/run/*|/sbin/*|/sys/*|/usr/*|/var/lib/*|/var/log/*)
    fehler "ZIEL liegt in einem Systemordner: '$ZIEL'" ;;
esac
if [ -e "$ZIEL" ]; then
  [ -d "$ZIEL" ] || fehler "ZIEL ist kein Verzeichnis: '$ZIEL'"
  EIGNER=$(stat -c %U -- "$ZIEL")
  [ "$EIGNER" = root ] || [ "$EIGNER" = "$BESITZER" ] || fehler "ZIEL gehört '$EIGNER' — erwartet root oder $BESITZER: '$ZIEL'"
fi

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
