#!/usr/bin/env bash
#
# extern-sicherung.sh — geprüfte Sicherungen verschlüsselt außer Haus
#
# Läuft nach jeder erfolgreichen nächtlichen Sicherung: edeka-extern.service,
# ausgelöst per OnSuccess= von edeka-sicherung.service. Nimmt jede fertige
# Sicherung aus SICHERUNG_ZIEL, die im Sicherungs-Repository noch fehlt —
# verpasste Nächte werden also nachgeholt — und schiebt sie verschlüsselt
# dorthin. Fertig heißt: tools/sicherung.sh hat sie probeweise zurückgespielt
# und erst dann von <Stempel>.unfertig in <Stempel> umbenannt.
#
# Verschlüsselt wird mit age und einem ÖFFENTLICHEN Schlüssel. Dieser Server
# kann verschlüsseln, aber nichts entschlüsseln; der private Schlüssel liegt
# nur beim Betreiber (siehe Edeka.lager/BETRIEB.md).
#
# Je Sicherung und Datenbank im Repository:
#   <Stempel>/<db>.archive.gz.age   das Archiv, verschlüsselt
#   <Stempel>/<db>.inhalt           Sammlungen und Dokumentzahlen — keine Inhalte
#   <Stempel>/<db>.sha256           Prüfsumme des unverschlüsselten Archivs
#
# Einstellungen (im Betrieb aus /etc/edeka/extern.env):
#   EXTERN_REPO        Git-Adresse des privaten Sicherungs-Repositorys  (Pflicht)
#   EXTERN_EMPFAENGER  öffentlicher age-Schlüssel, age1…                (Pflicht)
#   EXTERN_SSH_KEY     Deploy-Key nur für dieses Repository (Pflicht bei git@… und ssh://)
#   EXTERN_ARBEIT      Arbeitskopie                   (~/edeka-extern)
#   SICHERUNG_ZIEL     die lokalen Sicherungen        (~/edeka-sicherungen)
#   EXTERN_BEHALTEN    so viele im aktuellen Stand    (30); ältere bleiben in der Geschichte
#
set -euo pipefail
umask 077

fehler() { echo "extern-sicherung: $*" >&2; exit 1; }

REPO="${EXTERN_REPO:-}"
EMPF="${EXTERN_EMPFAENGER:-}"
ARBEIT="${EXTERN_ARBEIT:-$HOME/edeka-extern}"
ZIEL="${SICHERUNG_ZIEL:-$HOME/edeka-sicherungen}"
BEHALTEN="${EXTERN_BEHALTEN:-30}"

[ -n "$REPO" ] || fehler "EXTERN_REPO fehlt"
# age1 + 58 Zeichen bech32. Ein privater Schlüssel (AGE-SECRET-KEY-…) wird hier
# nie angenommen — der gehört nicht auf diesen Server.
[[ "$EMPF" =~ ^age1[02-9ac-hj-np-z]{58}$ ]] || fehler "EXTERN_EMPFAENGER ist kein öffentlicher age-Schlüssel (age1…)"
[[ "$BEHALTEN" =~ ^[1-9][0-9]*$ ]] || fehler "EXTERN_BEHALTEN muss eine Zahl ab 1 sein"
command -v age >/dev/null || fehler "age fehlt: sudo apt install age"
[ -d "$ZIEL" ] || fehler "keine lokalen Sicherungen in $ZIEL"

case "$REPO" in
  git@*|ssh://*)
    KEY="${EXTERN_SSH_KEY:-}"
    [ -n "$KEY" ] && [ -r "$KEY" ] || fehler "Deploy-Key nicht lesbar: '${KEY}'"
    export GIT_SSH_COMMAND="ssh -i $KEY -o IdentitiesOnly=yes -o BatchMode=yes"
    ;;
esac
G() { git -C "$ARBEIT" -c user.name="EDEKA Sicherung" -c user.email="sicherung@localhost" "$@"; }

# ── Arbeitskopie: genau der Stand des Repositorys ─────────────────────
# Nur dieses Skript schreibt hier. Ein nicht geschobener Commit aus einem
# abgebrochenen Lauf wird verworfen — die fehlenden Sicherungen erkennt der
# nächste Schritt ohnehin wieder.
if [ ! -d "$ARBEIT/.git" ]; then
  git clone -q "$REPO" "$ARBEIT" 2>/dev/null || fehler "Klonen fehlgeschlagen: $REPO"
fi
G remote set-url origin "$REPO"
if G ls-remote --exit-code origin refs/heads/main >/dev/null 2>&1; then
  G fetch -q origin main
  G checkout -q -B main origin/main
  G reset -q --hard origin/main
fi
G clean -qfdx

# ── Was fehlt im Repository? ─────────────────────────────────────────
mapfile -t FERTIGE < <(find "$ZIEL" -maxdepth 1 -type d -name '20[0-9][0-9]-*' ! -name '*.unfertig' -printf '%f\n' | sort)
[ "${#FERTIGE[@]}" -gt 0 ] || fehler "in $ZIEL liegt keine fertige Sicherung"

NEU=()
for S in "${FERTIGE[@]}"; do
  [ -d "$ARBEIT/$S" ] && continue
  # Schon einmal hochgeladen und inzwischen aus dem Stand genommen?
  [ -n "$(G log -1 --format=%h -- "$S" 2>/dev/null || true)" ] && continue
  shopt -s nullglob; ARCHIVE=("$ZIEL/$S"/*.archive.gz); shopt -u nullglob
  [ "${#ARCHIVE[@]}" -gt 0 ] || fehler "$S enthält kein Archiv"
  rm -rf "$ARBEIT/$S.neu"; mkdir "$ARBEIT/$S.neu"
  for A in "${ARCHIVE[@]}"; do
    DB=$(basename "$A" .archive.gz)
    age -r "$EMPF" -o "$ARBEIT/$S.neu/$DB.archive.gz.age" "$A" || fehler "Verschlüsseln von $S/$DB fehlgeschlagen"
    ( cd "$ZIEL/$S" && sha256sum "$DB.archive.gz" ) > "$ARBEIT/$S.neu/$DB.sha256"
    if [ -f "$ZIEL/$S/$DB.inhalt" ]; then cp "$ZIEL/$S/$DB.inhalt" "$ARBEIT/$S.neu/"; fi
  done
  mv "$ARBEIT/$S.neu" "$ARBEIT/$S"
  NEU+=("$S")
done

if [ "${#NEU[@]}" -eq 0 ]; then
  echo "extern-sicherung: nichts Neues — ${FERTIGE[-1]} liegt schon im Repository"
  exit 0
fi

G add -A
G commit -q -m "Sicherung ${NEU[*]}"

# ── Nur die jüngsten im Stand; die Geschichte behält alle ─────────────
mapfile -t IM_STAND < <(find "$ARBEIT" -maxdepth 1 -type d -name '20[0-9][0-9]-*' -printf '%f\n' | sort)
if [ "${#IM_STAND[@]}" -gt "$BEHALTEN" ]; then
  ALT=("${IM_STAND[@]:0:$(( ${#IM_STAND[@]} - BEHALTEN ))}")
  G rm -rq -- "${ALT[@]}"
  G commit -q -m "Aus dem Stand genommen (bleibt in der Geschichte): ${ALT[*]}"
fi

# ── Schieben — nie mit Gewalt — und nachweisen ───────────────────────
if ! AUS=$(G push -q origin HEAD:refs/heads/main 2>&1); then
  printf '%s\n' "$AUS" >&2
  fehler "Schieben fehlgeschlagen — hat der Deploy-Key Schreibrecht?"
fi
DORT=$(G ls-remote origin refs/heads/main | cut -f1)
[ "$DORT" = "$(G rev-parse HEAD)" ] || fehler "das Repository zeigt nicht den eben geschobenen Stand"
echo "extern-sicherung: ${#NEU[@]} neu (${NEU[*]}) — im Repository bestätigt"
