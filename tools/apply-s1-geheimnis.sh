#!/usr/bin/env bash
#
# apply-s1-geheimnis.sh — Sofortmaßnahme: ein veröffentlichtes Geheimnis
#
# Befund (28.09.2026): Edeka_lager_fixed.zip liegt seit dem 06.07.2026
# versioniert im ÖFFENTLICHEN Repository — und enthält
# Edeka.lager/backend/.env. Geprüft, ohne einen einzigen Wert anzuzeigen:
#
#   · JWT_SECRET — echt und stark (37 Zeichen, besteht checkJwtSecret)
#   · alles andere harmlos: MONGODB_URI lokal ohne Zugangsdaten, Telegram
#     nur Platzhalter, ADMIN_PASSWORD leer. DOMAIN ist eine Information,
#     kein Geheimnis.
#
# Die Geheimnissuche im Bericht von G1 las nur Text. Ein ZIP ist binär und
# ging darunter durch — dieses Skript schaut hinein.
#
# Wie schlimm? middleware/auth.js prüft die Signatur und lädt den Benutzer
# dann per id aus der Datenbank. Wer den Schlüssel hat, braucht zusätzlich
# eine gültige Benutzer-id: von außen schwer zu raten — aber jeder
# angemeldete Kollege kennt seine eigene, und ids stehen in Daten. Benutzt
# der Server DENSELBEN Schlüssel, gilt er als kompromittiert.
#
# Das Skript:
#   1. vergleicht den veröffentlichten Schlüssel mit dem dieses Servers —
#      nur im Speicher, ohne je einen Wert auszugeben
#   2. tauscht ihn aus, falls er gleich ist (alle melden sich einmal neu an),
#      und startet die App neu — der neue Wert steht auf keiner Kommandozeile
#   3. entfernt das ZIP aus dem Repository, ergänzt die .gitignore der Wurzel
#      und legt einen Test an, der versionierte Archive und .env-Dateien
#      künftig ablehnt
#
# Die Git-Geschichte wird NICHT umgeschrieben. Ist der Schlüssel getauscht —
# oder war er nie im Betrieb —, steht in alten Commits nur noch ein wertloser
# Wert. Das entspricht GitHubs eigener Reihenfolge: erst austauschen, dann
# (falls überhaupt) die Geschichte bereinigen.
#
# VOR D4 ausführen: D4 macht die App öffentlich erreichbar.
#
# Legt den Branch phase-s1 an; muss dafür auf main gestartet werden.
#
# Ausführen im Wurzelverzeichnis des Repos, auf dem Server:
#     bash apply-s1-geheimnis.sh
#
set -euo pipefail

BE="Edeka.lager/backend"
ZIP="Edeka_lager_fixed.zip"
ENV_LIVE="$BE/.env"
SELBST="$(basename "$0")"
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
die()  { printf '\n  \033[31m✗ %s\033[0m\n\n' "$1" >&2; exit 1; }

echo
echo "── Sofortmaßnahme: ein veröffentlichtes Geheimnis ──────────────"
echo

[ -f "$BE/server.js" ] || die "Bitte im Wurzelverzeichnis des Repos ausführen (cd ~/Eder)."
[ -f "$ENV_LIVE" ]     || die "$ENV_LIVE fehlt — dieses Skript gehört auf den Server."
[ -d "$BE/node_modules/dotenv" ] || die "dotenv fehlt in $BE/node_modules — bitte dort einmal: npm ci"
command -v python3 >/dev/null || command -v unzip >/dev/null || die "Weder python3 noch unzip vorhanden."

if command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
  SCHMUTZ=$(git status --porcelain | grep -v -- "$SELBST" | grep -vE '^\?\? (apply-[a-z0-9-]+\.sh|tools/duckdns\.sh)$' || true)
  [ -z "$SCHMUTZ" ] || { printf '%s\n' "$SCHMUTZ" | sed 's/^/     /'; die "Arbeitsverzeichnis nicht sauber (siehe oben)."; }
  BRANCH=$(git rev-parse --abbrev-ref HEAD)
  case "$BRANCH" in
    main) if git show-ref --verify --quiet refs/heads/phase-s1; then git checkout -q phase-s1; else git checkout -q -b phase-s1; fi ;;
    phase-s1) ;;
    *) die "Du bist auf '$BRANCH'. Dieser Schritt ist eigenständig: bitte zuerst  git checkout main && git pull" ;;
  esac
  ok "Branch phase-s1, Arbeitsverzeichnis sauber (wartende Schritte unberührt)"
else
  die "Kein Git-Repository — der veröffentlichte Stand wird aus der Git-Geschichte gelesen."
fi

TMP=$(mktemp -d); chmod 700 "$TMP"
T="$BE/test/unit/keine-geheimnisse.test.js"
T_DA=0; [ -f "$T" ] && T_DA=1
FERTIG=0
aufraeumen() {
  rm -rf "$TMP"
  if [ "$FERTIG" != "1" ] && [ "$T_DA" = "0" ]; then rm -f "$T"; fi
}
trap aufraeumen EXIT

# ── 1  Befund ────────────────────────────────────────────────────────
echo
echo "── Befund ──────────────────────────────────────────────────────"
QUELLE=$(git log --all --format=%H -n 1 -- "$ZIP")
JWT_GLEICH=0
if [ -z "$QUELLE" ]; then
  ok "$ZIP kommt in der Geschichte nicht vor — nichts zu vergleichen"
else
  # Letzte Fassung, in der das ZIP existierte (auch wenn es später gelöscht wurde)
  if git cat-file -e "$QUELLE:$ZIP" 2>/dev/null; then REF="$QUELLE:$ZIP"; else REF="$QUELLE^:$ZIP"; fi
  git show "$REF" > "$TMP/a.zip"
  if command -v python3 >/dev/null; then
    python3 -c "import sys, zipfile; sys.stdout.buffer.write(zipfile.ZipFile(sys.argv[1]).read('Edeka.lager/backend/.env'))" \
      "$TMP/a.zip" > "$TMP/env" 2>/dev/null || : > "$TMP/env"
  else
    unzip -p "$TMP/a.zip" 'Edeka.lager/backend/.env' > "$TMP/env" 2>/dev/null || : > "$TMP/env"
  fi
  chmod 600 "$TMP/env"
  if [ ! -s "$TMP/env" ]; then
    ok "das ZIP enthält keine Edeka.lager/backend/.env"
  else
    # Vergleich nur im Speicher. Ausgegeben wird je Schlüssel "gleich" oder
    # "verschieden" — nie ein Wert.
    ERG=$( cd "$BE" && node -e '
      const fs = require("fs"), dotenv = require("dotenv");
      const alt  = dotenv.parse(fs.readFileSync(process.argv[1]));
      const live = dotenv.parse(fs.readFileSync(".env"));
      const geheim = /SECRET|TOKEN|PASSWORD|PASSWD|KEY/;
      for (const k of Object.keys(alt)) {
        if (!alt[k] || !(k in live)) continue;
        if (!geheim.test(k) && !/:[^@/]+@/.test(alt[k])) continue;
        console.log(k + "=" + (alt[k] === live[k] ? "GLEICH" : "verschieden"));
      }' "$TMP/env" )
    rm -f "$TMP/env"
    if [ -z "$ERG" ]; then
      ok "kein Geheimnis aus dem ZIP kommt in der .env dieses Servers vor"
    fi
    while IFS='=' read -r K W; do
      [ -n "$K" ] || continue
      if [ "$W" = "GLEICH" ]; then
        warn "$K: der Server benutzt DENSELBEN Wert wie das veröffentlichte ZIP"
        [ "$K" = "JWT_SECRET" ] && JWT_GLEICH=1
      else
        ok "$K: der Server benutzt einen anderen Wert — vom ZIP nicht betroffen"
      fi
    done <<< "$ERG"
  fi
fi

# ── 2  Austausch, nur wenn nötig ─────────────────────────────────────
echo
echo "── Schlüssel ───────────────────────────────────────────────────"
if [ "$JWT_GLEICH" = "1" ]; then
  if [ ! -f "$ENV_LIVE.s1.bak" ]; then cp -p "$ENV_LIVE" "$ENV_LIVE.s1.bak"; chmod 600 "$ENV_LIVE.s1.bak"; fi
  # Erzeugen, Einsetzen und Prüfen in einem Node-Prozess: der neue Wert steht
  # auf keiner Kommandozeile und in keiner Ausgabe.
  ( cd "$BE" && node -e '
      const fs = require("fs"), crypto = require("crypto"), dotenv = require("dotenv");
      const { checkJwtSecret } = require("./lib/validate");
      const alt = dotenv.parse(fs.readFileSync(".env")).JWT_SECRET;
      const neu = crypto.randomBytes(48).toString("base64url");
      const text = fs.readFileSync(".env", "utf8");
      const zeilen = text.split("\n");
      let n = 0;
      const out = zeilen.map(z => /^\s*JWT_SECRET\s*=/.test(z) ? (n++, "JWT_SECRET=" + neu) : z);
      if (n !== 1) { console.error("JWT_SECRET steht " + n + "× in .env statt 1×"); process.exit(1); }
      fs.writeFileSync(".env", out.join("\n"), { mode: 0o600 });
      const jetzt = dotenv.parse(fs.readFileSync(".env")).JWT_SECRET;
      let fehler; try { fehler = checkJwtSecret(jetzt); } catch (e) { fehler = e.message; }
      if (fehler || jetzt === alt || jetzt !== neu) { console.error("neuer Schlüssel nicht wirksam"); process.exit(1); }
    ' ) || die "Austausch fehlgeschlagen — .env ist unverändert gesichert in $ENV_LIVE.s1.bak"
  chmod 600 "$ENV_LIVE"
  ok "JWT_SECRET ausgetauscht — neuer, zufälliger Wert (64 Zeichen), besteht checkJwtSecret"
  if systemctl is-active --quiet edeka-lager 2>/dev/null; then
    sudo systemctl restart edeka-lager
    GESUND=0
    for _ in $(seq 1 30); do
      curl -fsS --max-time 2 http://127.0.0.1:3000/api/health 2>/dev/null | grep -q '"status":"ok"' && { GESUND=1; break; }
      sleep 1
    done
    [ "$GESUND" = "1" ] || die "Die App antwortet nach dem Neustart nicht: journalctl -u edeka-lager -n 30 --no-pager"
    ok "App neu gestartet — alle alten Anmeldungen sind jetzt ungültig"
  else
    warn "Dienst edeka-lager läuft nicht — der neue Schlüssel gilt beim nächsten Start"
  fi
else
  ok "kein Austausch nötig"
fi

# ── 3  Repository: ZIP raus, Regeln rein, Test dazu ──────────────────
echo
echo "── Repository ──────────────────────────────────────────────────"
cat > "$T" <<'EOF'
'use strict';
//
// Keine Archive und keine echten .env-Dateien im Repository.
//
// Am 06.07.2026 kam ein ZIP ins öffentliche Repo, darin eine .env mit dem
// echten JWT_SECRET. Die Suche im Text fand es nicht — ein ZIP ist binär.
// Deshalb die einfachere, sichere Regel: solche Dateien werden gar nicht
// erst versioniert. .env.example bleibt erlaubt.
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const path   = require('node:path');
const { spawnSync } = require('node:child_process');

const WURZEL   = path.join(__dirname, '../../../..');
const ARCHIV   = /\.(zip|tar|tgz|gz|bz2|xz|7z|rar)$/i;
// .env, .env.local, .env.production … — aber keine Vorlagen: .env.example,
// .env.test.example und alles andere, was auf .example endet.
const UMGEBUNG = /(^|\/)\.env(\.[^/]*)?$/;
const VORLAGE  = /\.example$/;

test('keine Archive und keine .env-Dateien im Repository', (t) => {
  const r = spawnSync('git', ['ls-files'], { cwd: WURZEL, encoding: 'utf8' });
  if (r.status !== 0) { t.skip('kein Git-Repository'); return; }
  const funde = r.stdout.split('\n').filter(f => f && (ARCHIV.test(f) || (UMGEBUNG.test(f) && !VORLAGE.test(f))));
  assert.deepEqual(funde, [], 'versioniert, aber verboten:\n    ' + funde.join('\n    '));
});
EOF
node --check "$T" >/dev/null 2>&1 || die "Syntaxfehler in $T"
ROT=$( cd "$BE" && node --test test/unit/keine-geheimnisse.test.js 2>&1 | grep -cE '^# fail [1-9]' || true )

if git ls-files --error-unmatch "$ZIP" >/dev/null 2>&1; then
  git rm -q "$ZIP"
  ok "$ZIP aus dem Repository entfernt (bleibt in alten Commits — siehe unten)"
else
  ok "$ZIP ist schon aus dem Repository entfernt"
fi

if ! grep -q 'Phase S1' .gitignore 2>/dev/null; then
  printf '%s\n' '' \
    '# ── Nie wieder im Repo: Archive und echte Umgebungsdateien (Phase S1) ──' \
    '# Ein ZIP mit einer .env darin war vom 06.07. bis 28.09.2026 öffentlich.' \
    '*.zip' '*.tar' '*.tgz' '*.gz' '*.bz2' '*.xz' '*.7z' '*.rar' \
    '.env' '.env.*' '!.env.example' '!.env.*.example' >> .gitignore
  ok ".gitignore der Wurzel: Archive und .env überall ausgeschlossen, Vorlagen (*.example) erlaubt"
else
  ok ".gitignore enthält die Regeln schon"
fi
# Die echte .env und ihre Sicherungen dürfen durch die neuen Regeln nicht
# versehentlich sichtbar werden — und .env.example muss sichtbar bleiben.
git check-ignore -q "$ENV_LIVE" || die "$ENV_LIVE wäre nicht ignoriert — bitte melden"
while IFS= read -r V; do
  [ -n "$V" ] || continue
  ! git check-ignore -q --no-index "$V" || die "$V würde ignoriert — bitte melden"
done < <(git ls-files | grep -E '(^|/)\.env[^/]*\.example$')

GRUEN=$( cd "$BE" && node --test test/unit/keine-geheimnisse.test.js 2>&1 | grep -cE '^# fail 0' || true )
FERTIG=1
if [ "$ROT" = "1" ] && [ "$GRUEN" = "1" ]; then ok "Test keine-geheimnisse: vorher rot, jetzt grün"
elif [ "$GRUEN" = "1" ]; then ok "Test keine-geheimnisse: grün"
else die "Test keine-geheimnisse ist nicht grün"; fi

set +e
LINT_AUS=$( cd "$BE" && npm run lint 2>&1 ); LINT=$?
set -e
[ "$LINT" -eq 0 ] && ok "Lint sauber" || { printf '%s\n' "$LINT_AUS" | grep -vE "^>|^$"; die "Lint meldet etwas"; }

echo
echo "── Danach ──────────────────────────────────────────────────────"
echo
echo "    mkdir -p tools && mv $SELBST tools/"
echo "    git add .gitignore $T tools/$SELBST"
echo "    git commit -m 'Sofortmaßnahme S1: veröffentlichtes ZIP mit .env entfernt, Wiederholung verhindert'"
echo "    git push -u origin phase-s1"
echo
echo "  (Die Löschung des ZIP ist schon vorgemerkt — git rm hat das erledigt.)"
echo
echo "  Die Geschichte des Repos enthält das ZIP weiterhin. Ob sie bereinigt"
echo "  werden soll, ist eine eigene Entscheidung — erst nach diesem Schritt."
echo
