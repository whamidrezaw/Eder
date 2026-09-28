#!/usr/bin/env bash
#
# apply-h3-extern.sh — Phase H, Schritt 3: eine Kopie außerhalb des Servers
#
# Bis hierher lagen alle Sicherungen auf demselben Server. Mit dem Server —
# oder dem kostenlosen Oracle-Konto — wären sie mit weg gewesen.
#
# Teil 1, Repository (alles oder nichts):
#   tools/extern-sicherung.sh   schiebt nach jeder erfolgreichen Sicherung jede
#                               noch fehlende geprüfte Sicherung verschlüsselt
#                               in ein privates GitHub-Repository
#   test/unit/extern-sicherung.test.js   mit echtem age und echter Gegenstelle
#   CI installiert age, damit dieser Test dort wirklich läuft
#   BETRIEB.md, ENTSCHEIDUNGEN.md, tools/README.md: die Kopie und der Weg zurück
#
# Teil 2, Server (interaktiv, jederzeit wiederholbar):
#   Deploy-Key nur für das Sicherungs-Repository, Prüfung "wirklich privat",
#   age-Schlüssel (eigener öffentlicher Schlüssel, oder ein neues Paar — dann
#   wird der private Schlüssel einmal gezeigt, zur Kontrolle wieder eingefügt
#   und erst danach vom Server gelöscht), /etc/edeka/extern.env,
#   edeka-extern.service mit OnSuccess= an edeka-sicherung.service, erster
#   Lauf und Nachweis der ganzen Kette.
#
# Voraussetzung: H1 ist in main. Legt den Branch phase-h3 an.
#
# Ausführen im Wurzelverzeichnis des Repos, auf dem Server:
#     bash apply-h3-extern.sh
#
set -euo pipefail

BE="Edeka.lager/backend"
SELBST="$(basename "$0")"
TEST="$BE/test/unit/extern-sicherung.test.js"
EXTERN="tools/extern-sicherung.sh"
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
die()  { printf '\n  \033[31m✗ %s\033[0m\n\n' "$1" >&2; exit 1; }
gruen() { ( cd "$BE" && node --test "$@" >/dev/null 2>&1 ); }

echo
echo "── Phase H, Schritt 3: eine Kopie außerhalb des Servers ────────"
echo

[ -f "$BE/server.js" ] || die "Bitte im Wurzelverzeichnis des Repos ausführen (cd ~/Eder)."
command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1 || die "Kein Git-Repository."
[ -f "$BE/test/unit/doku.test.js" ] || die "H1 fehlt in main — bitte zuerst  git checkout main && git pull"
# Die Dateien von Teil 1. Auf phase-h3 dürfen sie aus einem früheren Lauf
# geändert sein: bricht Teil 2 ab (etwa weil der Deploy-Key noch fehlt), wird
# das Skript einfach erneut ausgeführt.
TEIL1_DATEIEN=(Edeka.lager/BETRIEB.md Edeka.lager/ENTSCHEIDUNGEN.md tools/README.md
               "$BE/test/unit/doku.test.js" .github/workflows/ci.yml "$TEST" "$EXTERN")
BRANCH=$(git rev-parse --abbrev-ref HEAD)
SCHMUTZ=$(git status --porcelain | grep -v -- "$SELBST" | grep -vE '^\?\? apply-[a-z0-9-]+\.sh$' || true)
if [ "$BRANCH" = "phase-h3" ]; then
  for f in "${TEIL1_DATEIEN[@]}"; do SCHMUTZ=$(printf '%s\n' "$SCHMUTZ" | grep -vxE "(\?\?| M|M |MM|A ) $f" || true); done
fi
[ -z "$SCHMUTZ" ] || { printf '%s\n' "$SCHMUTZ" | sed 's/^/     /'; die "Arbeitsverzeichnis nicht sauber (siehe oben)."; }
# Reparatur: ist H3 schon in main, bleibt es auf main — nichts zu committen.
REPARATUR=0
case "$BRANCH" in
  main)
    if git ls-files --error-unmatch "$EXTERN" >/dev/null 2>&1; then REPARATUR=1
    elif git show-ref --verify --quiet refs/heads/phase-h3; then git checkout -q phase-h3
    else git checkout -q -b phase-h3; fi ;;
  phase-h3) ;;
  *) die "Du bist auf '$BRANCH'. Bitte zuerst  git checkout main && git pull" ;;
esac
if [ "$REPARATUR" = "1" ]; then ok "H3 ist schon in main — Reparaturlauf auf main"
else ok "Branch phase-h3, Arbeitsverzeichnis sauber"; fi

if ! command -v age >/dev/null || ! command -v age-keygen >/dev/null; then
  sudo apt-get install -y -qq age >/dev/null 2>&1 || die "age ließ sich nicht installieren: sudo apt install age"
fi
ok "age $(age --version)"

# ══ Teil 1: Repository — alles oder nichts ═══════════════════════════
TEIL1=0
TMP=$(mktemp -d)
zurueck() {
  rm -rf "$TMP"
  if [ "$TEIL1" != "1" ]; then
    # Teil 1 auf den Stand von HEAD — auch Reste eines früheren Laufs.
    for f in "${TEIL1_DATEIEN[@]}"; do
      if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then git checkout -q -- "$f" 2>/dev/null || true
      else rm -f "$f"; fi
    done
    printf '  \033[33m!\033[0m abgebrochen — alle Dateien wieder im Ausgangszustand\n' >&2
  fi
}
trap zurueck EXIT

echo
echo "── Teil 1: Repository ──────────────────────────────────────────"
cat > "$TMP/test.js" <<'__H3_TEST__'
'use strict';
//
// tools/extern-sicherung.sh — die Kopie außerhalb des Servers.
//
// Geprüft mit echtem age und einem echten, nackten Git-Repository als
// Gegenstelle (so wie GitHub): nur fertige, geprüfte Sicherungen gehen raus,
// nie ein Archiv im Klartext; Entschlüsseln mit dem privaten Schlüssel ergibt
// Byte für Byte das Original; ein zweiter Lauf ändert nichts; ohne gültigen
// Schlüssel erreicht nichts das Repository.
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const fs     = require('node:fs');
const os     = require('node:os');
const path   = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');

const SKRIPT = path.join(__dirname, '../../../../tools/extern-sicherung.sh');
const vorhanden = (cmd) => spawnSync('sh', ['-c', `command -v ${cmd}`]).status === 0;
const BEREIT = ['age', 'age-keygen', 'git', 'bash'].every(vorhanden);
const OHNE = BEREIT ? false : 'age fehlt — sudo apt install age';

const sha = (buf) => crypto.createHash('sha256').update(buf).digest('hex');

function umgebung(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'extern-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const ziel = path.join(dir, 'sicherungen');
  fs.mkdirSync(ziel);
  const remote = path.join(dir, 'gegenstelle.git');
  spawnSync('git', ['init', '-q', '--bare', '-b', 'main', remote]);
  const schluessel = path.join(dir, 'schluessel.txt');
  spawnSync('age-keygen', ['-o', schluessel], { stdio: 'ignore' });
  const empfaenger = spawnSync('age-keygen', ['-y', schluessel], { encoding: 'utf8' }).stdout.trim();
  return { dir, ziel, remote, schluessel, empfaenger, arbeit: path.join(dir, 'arbeit') };
}

// Eine Sicherung so, wie tools/sicherung.sh sie hinterlässt.
function sicherung(u, stempel, dbs = ['edeka_lager']) {
  const ordner = path.join(u.ziel, stempel);
  fs.mkdirSync(ordner);
  const summen = {};
  for (const db of dbs) {
    const archiv = crypto.randomBytes(2048);
    fs.writeFileSync(path.join(ordner, `${db}.archive.gz`), archiv);
    fs.writeFileSync(path.join(ordner, `${db}.inhalt`), 'products 3\nusers 2\n');
    fs.writeFileSync(path.join(ordner, `${db}.dump.log`), 'done dumping\n');
    summen[db] = sha(archiv);
  }
  return summen;
}

function lauf(u, extra = {}) {
  return spawnSync('bash', [SKRIPT], {
    encoding: 'utf8',
    env: {
      PATH: process.env.PATH, HOME: u.dir, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_NOSYSTEM: '1',
      EXTERN_REPO: u.remote, EXTERN_EMPFAENGER: u.empfaenger,
      EXTERN_ARBEIT: u.arbeit, SICHERUNG_ZIEL: u.ziel, ...extra
    }
  });
}

const git = (u, ...args) => spawnSync('git', ['--git-dir', u.remote, ...args], { encoding: 'utf8' });
const baum = (u) => git(u, 'ls-tree', '-r', '--name-only', 'main').stdout.split('\n').filter(Boolean).sort();
const stand = (u) => git(u, 'rev-parse', '-q', '--verify', 'refs/heads/main').stdout.trim();

function entschluesselt(u, pfad) {
  const blob = spawnSync('git', ['--git-dir', u.remote, 'show', `main:${pfad}`]).stdout;
  const r = spawnSync('age', ['-d', '-i', u.schluessel], { input: blob });
  assert.equal(r.status, 0, `age -d ${pfad}: ${r.stderr}`);
  return r.stdout;
}

test('geprüfte Sicherungen gehen verschlüsselt raus — unfertige nie, Klartext nie', { skip: OHNE }, (t) => {
  const u = umgebung(t);
  const a = sicherung(u, '2026-09-27_023001');
  const b = sicherung(u, '2026-09-28_023002', ['edeka_lager', 'zweite_db']);
  fs.mkdirSync(path.join(u.ziel, '2026-09-29_023003.unfertig'));
  fs.writeFileSync(path.join(u.ziel, '2026-09-29_023003.unfertig', 'edeka_lager.archive.gz'), 'halb');

  const r = lauf(u);
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual(baum(u), [
    '2026-09-27_023001/edeka_lager.archive.gz.age', '2026-09-27_023001/edeka_lager.inhalt', '2026-09-27_023001/edeka_lager.sha256',
    '2026-09-28_023002/edeka_lager.archive.gz.age', '2026-09-28_023002/edeka_lager.inhalt', '2026-09-28_023002/edeka_lager.sha256',
    '2026-09-28_023002/zweite_db.archive.gz.age', '2026-09-28_023002/zweite_db.inhalt', '2026-09-28_023002/zweite_db.sha256'
  ]);
  // Byte für Byte das Original — und die mitgelieferte Prüfsumme stimmt
  assert.equal(sha(entschluesselt(u, '2026-09-27_023001/edeka_lager.archive.gz.age')), a.edeka_lager);
  assert.equal(sha(entschluesselt(u, '2026-09-28_023002/zweite_db.archive.gz.age')), b.zweite_db);
  const summe = git(u, 'show', 'main:2026-09-28_023002/edeka_lager.sha256').stdout;
  assert.match(summe, new RegExp(`^${b.edeka_lager}\\s+\\*?edeka_lager\\.archive\\.gz`));
  // Protokolle der Probe bleiben auf dem Server
  assert.ok(!baum(u).some(f => f.endsWith('.log')));
});

test('ein zweiter Lauf ändert nichts', { skip: OHNE }, (t) => {
  const u = umgebung(t);
  sicherung(u, '2026-09-28_023002');
  assert.equal(lauf(u).status, 0);
  const vorher = stand(u);
  const r = lauf(u);
  assert.equal(r.status, 0, r.stderr);
  assert.equal(stand(u), vorher);
  assert.match(r.stdout, /nichts Neues/);
});

test('eine verpasste Nacht wird nachgeholt', { skip: OHNE }, (t) => {
  const u = umgebung(t);
  sicherung(u, '2026-09-26_023001');
  assert.equal(lauf(u).status, 0);
  sicherung(u, '2026-09-27_023001');
  sicherung(u, '2026-09-28_023001');
  const r = lauf(u);
  assert.equal(r.status, 0, r.stderr);
  const ordner = [...new Set(baum(u).map(f => f.split('/')[0]))];
  assert.deepEqual(ordner, ['2026-09-26_023001', '2026-09-27_023001', '2026-09-28_023001']);
});

test('im Stand bleiben EXTERN_BEHALTEN Sicherungen, ältere nur noch in der Geschichte', { skip: OHNE }, (t) => {
  const u = umgebung(t);
  for (const s of ['2026-09-25_023001', '2026-09-26_023001', '2026-09-27_023001']) sicherung(u, s);
  assert.equal(lauf(u, { EXTERN_BEHALTEN: '2' }).status, 0);
  const ordner = [...new Set(baum(u).map(f => f.split('/')[0]))];
  assert.deepEqual(ordner, ['2026-09-26_023001', '2026-09-27_023001']);
  const geschichte = git(u, 'log', '--format=%h', 'main', '--', '2026-09-25_023001').stdout.trim();
  assert.notEqual(geschichte, '', 'die älteste muss in der Geschichte stehen');
  // und sie wird beim nächsten Lauf nicht wieder hineingeschoben
  const vorher = stand(u);
  assert.equal(lauf(u, { EXTERN_BEHALTEN: '2' }).status, 0);
  assert.equal(stand(u), vorher);
});

test('ohne gültigen öffentlichen Schlüssel erreicht nichts das Repository', { skip: OHNE }, (t) => {
  const u = umgebung(t);
  sicherung(u, '2026-09-28_023002');
  for (const falsch of ['', 'kein-schluessel', 'AGE-SECRET-KEY-1QQQ']) {
    const r = lauf(u, { EXTERN_EMPFAENGER: falsch });
    assert.notEqual(r.status, 0, `angenommen: '${falsch}'`);
    assert.match(r.stderr, /EXTERN_EMPFAENGER/);
  }
  assert.equal(stand(u), '', 'nichts darf das Repository erreicht haben');
});

test('nie mit Gewalt ins Sicherungs-Repository', () => {
  const text = fs.readFileSync(SKRIPT, 'utf8');
  assert.doesNotMatch(text, /push[^\n]*(--force|\s-f\b|\+HEAD|\+main)/);
});
__H3_TEST__
cat > "$TMP/extern.sh" <<'__H3_SKRIPT__'
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
__H3_SKRIPT__
cat > "$TMP/doku.py" <<'__H3_DOKU__'
# Gezielte Ergänzungen der Doku für H3 — jeder Anker muss genau einmal vorkommen.
# Ist die Ergänzung schon da, wird die Datei übersprungen (erneuter Lauf).
import sys

def ergaenze(pfad, merkmal, paare):
    s = open(pfad, encoding='utf-8').read()
    if merkmal in s:
        print(f"schon  {pfad}"); return
    for alt, neu in paare:
        n = s.count(alt)
        if n != 1:
            sys.exit(f"Anker {n}× statt 1× in {pfad}: {alt[:70]!r}")
        s = s.replace(alt, neu)
    open(pfad, 'w', encoding='utf-8').write(s)
    print(f"neu    {pfad}")

B = 'Edeka.lager/BETRIEB.md'
ergaenze(B, 'edeka-extern.service', [
  ("| Datensicherung mit Wiederherstellungsprobe | täglich 02:30 (Berlin), 14 bleiben | `edeka-sicherung.timer` |\n",
   "| Datensicherung mit Wiederherstellungsprobe | täglich 02:30 (Berlin), 14 bleiben | `edeka-sicherung.timer` |\n"
   "| Verschlüsselte Kopie außer Haus | nach jeder erfolgreichen Sicherung | `edeka-extern.service` |\n"),
  ("| Sicherungsdienst | `/etc/systemd/system/edeka-sicherung.service` und `.timer`, Skript `tools/sicherung.sh` |\n",
   "| Sicherungsdienst | `/etc/systemd/system/edeka-sicherung.service` und `.timer`, Skript `tools/sicherung.sh` |\n"
   "| Kopie außer Haus | privates GitHub-Repository `<sicherungs-repo>`, Arbeitskopie `~/edeka-extern`, Skript `tools/extern-sicherung.sh` |\n"
   "| Einstellungen der Kopie | `/etc/edeka/extern.env` (Rechte 600): Repository, öffentlicher Schlüssel, Deploy-Key `~/.ssh/edeka_extern_ed25519` |\n"),
  ("### Offen: eine Kopie außerhalb des Servers\n\n"
   "Alle Sicherungen liegen auf **demselben** Server. Fällt er ganz aus, sind sie\n"
   "mit weg. Bis das geregelt ist, von Zeit zu Zeit eine Sicherung auf den eigenen\n"
   "Rechner holen (PowerShell):\n",
   "### Die Kopie außer Haus\n\n"
   "Nach jeder erfolgreichen Sicherung schiebt `tools/extern-sicherung.sh` jede\n"
   "geprüfte Sicherung, die dort noch fehlt, verschlüsselt in ein privates\n"
   "GitHub-Repository — verpasste Nächte werden nachgeholt. Verschlüsselt wird mit\n"
   "dem **öffentlichen** age-Schlüssel: entschlüsseln kann nur, wer den privaten\n"
   "hat. Dieser Server kann es nicht.\n\n"
   "```bash\n"
   "systemctl show -p Result --value edeka-extern.service\n"
   "journalctl -u edeka-extern -n 3 --no-pager\n"
   "```\n\n"
   "Erwartet: `success`, und im Protokoll `im Repository bestätigt` oder `nichts Neues`.\n\n"
   "### Wenn der Server verloren ist\n\n"
   "1. Einen neuen Server nach diesem Handbuch einrichten: App und MongoDB-Container.\n"
   "2. Das Sicherungs-Repository mit dem **eigenen** GitHub-Zugang holen:\n"
   "   `git clone git@github.com:<sicherungs-repo>.git sicherung`\n"
   "3. Die Datei mit dem privaten Schlüssel (die Zeile `AGE-SECRET-KEY-…`) kurz auf\n"
   "   den Server legen, zum Beispiel als `~/schluessel.txt`, dann entschlüsseln und\n"
   "   prüfen:\n\n"
   "   ```bash\n"
   "   cd sicherung/<Datum_Uhrzeit>\n"
   "   age -d -i ~/schluessel.txt -o edeka_lager.archive.gz edeka_lager.archive.gz.age\n"
   "   sha256sum -c edeka_lager.sha256\n"
   "   ```\n\n"
   "   Erwartet: `edeka_lager.archive.gz: OK`.\n"
   "4. Zurückspielen wie oben unter „Zurückspielen“ — mit dieser Datei.\n"
   "5. Den privaten Schlüssel wieder vom Server löschen: `shred -u ~/schluessel.txt`\n\n"
   "Zusätzlich lässt sich jederzeit von Hand eine Sicherung auf den eigenen Rechner\n"
   "holen (PowerShell):\n"),
  ("### Nach einem Kernel-Update kommt der Server nicht hoch\n",
   "### Die Kopie außer Haus ist fehlgeschlagen\n\n"
   "```bash\n"
   "journalctl -u edeka-extern -n 20 --no-pager\n"
   "```\n\n"
   "Häufige Gründe: keine Verbindung zu GitHub; der Deploy-Key wurde entfernt oder\n"
   "hat kein Schreibrecht mehr; das Repository wurde umbenannt. Danach\n"
   "`bash tools/apply-h3-extern.sh` erneut — es prüft alles und übernimmt, was\n"
   "schon stimmt. Die lokale Sicherung ist davon nicht betroffen.\n\n"
   "### Nach einem Kernel-Update kommt der Server nicht hoch\n"),
  ("- **Passwörter:** Die App verlangt mindestens 6 Zeichen. Für Admin-Konten\n"
   "  deutlich längere wählen.\n",
   "- **Passwörter:** Die App verlangt mindestens 6 Zeichen. Für Admin-Konten\n"
   "  deutlich längere wählen.\n"
   "- **Der private age-Schlüssel** (`AGE-SECRET-KEY-…`) liegt nur beim Betreiber,\n"
   "  an zwei Orten — etwa im Passwortmanager und offline auf einem USB-Stick oder\n"
   "  auf Papier. Ohne ihn ist die Kopie außer Haus wertlos, und niemand kann ihn\n"
   "  wiederherstellen.\n"
   "- **Der Deploy-Key** dieses Servers darf nur ins Sicherungs-Repository\n"
   "  schreiben. Wer den Server übernimmt, könnte dort aber auch löschen. Mit\n"
   "  GitHub Pro — für Studierende im GitHub Student Developer Pack enthalten —\n"
   "  lässt sich `main` dieses Repositorys gegen Force-Push und Löschen schützen.\n"),
])

E = 'Edeka.lager/ENTSCHEIDUNGEN.md'
ergaenze(E, '## 15. Kopie außer Haus', [
  ("---\n\n## Arbeitsweise\n",
   "## 15. Kopie außer Haus: verschlüsselt in ein privates GitHub-Repository (H3)\n\n"
   "**Anlass:** Alle Sicherungen lagen auf demselben Server. Mit dem Server — oder\n"
   "dem kostenlosen Oracle-Konto — wären sie mit weg gewesen.\n"
   "**Entscheidung:** Nach jeder erfolgreichen Sicherung schiebt\n"
   "`tools/extern-sicherung.sh` jede noch fehlende geprüfte Sicherung in ein\n"
   "privates GitHub-Repository, verschlüsselt mit age und einem öffentlichen\n"
   "Schlüssel. Der Server kann verschlüsseln, aber nichts entschlüsseln; der\n"
   "private Schlüssel liegt nur beim Betreiber. Zugang über einen Deploy-Key nur\n"
   "für dieses Repository, geschoben wird nie mit Gewalt. Verworfen: Oracle Object\n"
   "Storage (dasselbe Konto), Google Drive (Token mit weitem Zugriff), der eigene\n"
   "Rechner (nicht immer an).\n"
   "**Folgen:** Die Daten überleben den Server. Die Sicherungen enthalten\n"
   "Personendaten — Namen, Anmeldeprotokolle —, GitHub sieht davon nur\n"
   "Chiffretext. Ohne den privaten Schlüssel ist die Kopie wertlos; er muss an zwei\n"
   "Orten liegen.\n\n"
   "---\n\n## Arbeitsweise\n"),
])

T = 'tools/README.md'
ergaenze(T, '`extern-sicherung.sh`', [
  ("Entstehung — dazu zwei Hilfsskripte, die im Betrieb laufen.",
   "Entstehung — dazu drei Hilfsskripte, die im Betrieb laufen."),
  ("| `duckdns.sh` | hält `<name>.duckdns.org` auf der Adresse des Servers (`edeka-duckdns.timer`) |\n",
   "| `duckdns.sh` | hält `<name>.duckdns.org` auf der Adresse des Servers (`edeka-duckdns.timer`) |\n"
   "| `extern-sicherung.sh` | verschlüsselte Kopie jeder geprüften Sicherung ins private Sicherungs-Repository (`edeka-extern.service`, nach jeder erfolgreichen Sicherung) |\n"),
  ("| `apply-h1-doku.sh` | Betriebshandbuch, Entscheidungen, aktuelle READMEs, Doku-Test |\n",
   "| `apply-h1-doku.sh` | Betriebshandbuch, Entscheidungen, aktuelle READMEs, Doku-Test |\n"
   "| `apply-h3-extern.sh` | Kopie außer Haus: verschlüsselt in ein privates GitHub-Repository |\n"),
])

D = 'Edeka.lager/backend/test/unit/doku.test.js'
ergaenze(D, "'apply-h3-extern.sh'", [
  ("const AUSSTEHEND = new Set(['apply-h1-doku.sh']);",
   "const AUSSTEHEND = new Set(['apply-h1-doku.sh', 'apply-h3-extern.sh']);"),
])

C = '.github/workflows/ci.yml'
ergaenze(C, 'install -y -qq age', [
  ("      - run: npm ci\n",
   "      - run: npm ci\n\n"
   "      - name: age für den Test der Kopie außer Haus\n"
   "        run: sudo apt-get update -qq && sudo apt-get install -y -qq age\n"),
])
__H3_DOKU__
if cmp -s "$TMP/test.js" "$TEST"; then ok "$TEST: schon aktuell"; else cp "$TMP/test.js" "$TEST"; ok "$TEST"; fi
node --check "$TEST" >/dev/null 2>&1 || die "Syntaxfehler in $TEST"
if [ -f "$EXTERN" ] && gruen test/unit/extern-sicherung.test.js; then VORHER="grün"; else VORHER="rot"; fi
if cmp -s "$TMP/extern.sh" "$EXTERN"; then ok "$EXTERN: schon aktuell"; else cp "$TMP/extern.sh" "$EXTERN"; ok "$EXTERN"; fi
chmod 755 "$EXTERN"
bash -n "$EXTERN" || die "$EXTERN ist syntaktisch ungültig"
python3 "$TMP/doku.py" | sed 's/^/    /' || die "Doku-Anker passen nicht (siehe oben)"

gruen test/unit/extern-sicherung.test.js || { ( cd "$BE" && node --test test/unit/extern-sicherung.test.js 2>&1 | tail -40 ); die "extern-sicherung.test.js ist nicht grün"; }
if [ "$VORHER" = "rot" ]; then ok "extern-sicherung.test.js: vorher rot, jetzt grün (6 Tests)"; else ok "extern-sicherung.test.js: grün"; fi
gruen test/unit/doku.test.js || { ( cd "$BE" && node --test test/unit/doku.test.js 2>&1 | tail -30 ); die "doku.test.js ist nicht grün"; }
ok "doku.test.js: grün"

zaehle() { grep -oE '(ℹ|#) (tests|fail) [0-9]+' "$1" | sed -E 's/^(ℹ|#) //' | tr '\n' ' '; }
set +e
( cd "$BE" && npm run test:unit ) > "$TMP/unit.txt" 2>&1; U=$?
( cd "$BE" && npm run test:integration ) > "$TMP/int.txt" 2>&1; I=$?
( cd "$BE" && npm run lint ) > "$TMP/lint.txt" 2>&1; L=$?
set -e
echo "    Unit:        $(zaehle "$TMP/unit.txt")"
echo "    Integration: $(zaehle "$TMP/int.txt")"
[ "$U" -eq 0 ] || { grep -E '✖|not ok' "$TMP/unit.txt" | head -10; die "Unit-Tests nicht grün"; }
[ "$I" -eq 0 ] || { grep -E '✖|not ok|ECONNREFUSED' "$TMP/int.txt" | head -10; die "Integrationstests nicht grün (läuft MongoDB?)"; }
ok "alle Tests grün"
[ "$L" -eq 0 ] || { grep -vE '^>|^$' "$TMP/lint.txt"; die "Lint meldet etwas"; }
ok "Lint sauber"
TEIL1=1

# ══ Teil 2: Server — interaktiv, jederzeit wiederholbar ══════════════
# ── Funktionen (Teil 2) ──
# Liegt Stempel $1 in der Arbeitskopie committet — und zeigt GitHub genau diesen Stand?
auf_github() {
  git -C "$ARBEIT_EXTERN" ls-tree --name-only HEAD 2>/dev/null | grep -qx -- "$1" || return 1
  local dort
  dort=$(GIT_SSH_COMMAND="ssh -i $KEY -o IdentitiesOnly=yes -o BatchMode=yes" \
         git -C "$ARBEIT_EXTERN" ls-remote origin refs/heads/main 2>/dev/null | cut -f1)
  [ -n "$dort" ] && [ "$dort" = "$(git -C "$ARBEIT_EXTERN" rev-parse HEAD)" ]
}
juengste() { find "$ZIEL_LOKAL" -maxdepth 1 -type d -name '20[0-9][0-9]-*' ! -name '*.unfertig' -printf '%f\n' | sort | tail -1; }
# Eingaben vom Terminal; ohne Terminal von der Standardeingabe.
lies() {  # lies VARIABLE "Frage" [-s]
  local __v=""
  if { exec 3</dev/tty; } 2>/dev/null; then
    if [ "${3:-}" = "-s" ]; then read -r -s -p "$2" __v <&3; echo; else read -r -p "$2" __v <&3; fi
    exec 3<&-
  else
    printf '%s' "$2"; read -r __v || true; echo
  fi
  printf -v "$1" '%s' "$(printf '%s' "$__v" | tr -d '[:space:]')"
}
# 404 für Anonyme = privat (oder nicht vorhanden); 200 = öffentlich.
sichtbarkeit() { curl -s -o /dev/null -m 15 -w '%{http_code}' "https://github.com/$1" || echo 000; }
zugang() {  # zugang Besitzer/Name Key
  GIT_SSH_COMMAND="ssh -i $2 -o IdentitiesOnly=yes -o BatchMode=yes" \
    git ls-remote "git@github.com:$1.git" >/dev/null 2>&1
}
# Neues Schlüsselpaar: prüfen, einmal zeigen, zurück bestätigen lassen,
# erst dann den privaten Schlüssel vernichten. Setzt EMPF.
schluesselpaar() {
  local d; d=$(mktemp -d); chmod 700 "$d"
  age-keygen -o "$d/id" 2>/dev/null || { rm -rf "$d"; die "age-keygen fehlgeschlagen"; }
  EMPF=$(age-keygen -y "$d/id")
  head -c 4096 /dev/urandom > "$d/probe"
  age -r "$EMPF" -o "$d/probe.age" "$d/probe" && age -d -i "$d/id" -o "$d/zurueck" "$d/probe.age" \
    && cmp -s "$d/probe" "$d/zurueck" || { shred -u "$d/id" 2>/dev/null; rm -rf "$d"; die "Probe mit dem neuen Schlüsselpaar fehlgeschlagen"; }
  local geheim; geheim=$(grep '^AGE-SECRET-KEY-' "$d/id")
  echo
  echo "  ────────────────────────────────────────────────────────────"
  echo "  Dein PRIVATER Schlüssel — er wird nur dieses eine Mal gezeigt:"
  echo
  echo "      $geheim"
  echo
  echo "  Speichere ihn JETZT an zwei Orten: im Passwortmanager und"
  echo "  offline (USB-Stick oder Papier). Ohne ihn ist die Kopie außer"
  echo "  Haus wertlos — niemand kann ihn wiederherstellen."
  echo "  ────────────────────────────────────────────────────────────"
  local versuch eingabe
  for versuch in 1 2 3; do
    lies eingabe "  Zur Kontrolle den gespeicherten Schlüssel einfügen (unsichtbar): " -s
    if [ "$eingabe" = "$geheim" ]; then
      shred -u "$d/id" 2>/dev/null || rm -f "$d/id"; rm -rf "$d"
      ok "Schlüssel bestätigt — der private Schlüssel ist vom Server gelöscht"
      echo "    Tipp: Das Fenster nach dem Speichern schließen — der Schlüssel steht noch im Verlauf."
      return 0
    fi
    warn "stimmt nicht mit dem gezeigten Schlüssel überein (Versuch $versuch von 3)"
  done
  shred -u "$d/id" 2>/dev/null || rm -f "$d/id"; rm -rf "$d"
  die "Nicht bestätigt — nichts eingerichtet, der Schlüssel ist verworfen. Bitte erneut ausführen."
}
# ── Ende Funktionen ──

echo
echo "── Teil 2: Server ──────────────────────────────────────────────"
command -v systemctl >/dev/null && systemctl cat edeka-sicherung.service >/dev/null 2>&1 \
  || die "edeka-sicherung.service fehlt — Teil 2 gehört auf den Server. Teil 1 ist fertig und bleibt."
for c in ssh ssh-keygen curl; do command -v "$c" >/dev/null || die "$c fehlt: sudo apt install openssh-client curl"; done
NUTZER=$(id -un)
KEY="$HOME/.ssh/edeka_extern_ed25519"
KONF=/etc/edeka/extern.env
ARBEIT_EXTERN="$HOME/edeka-extern"
ZIEL_LOKAL="$HOME/edeka-sicherungen"
[ -n "$(find "$ZIEL_LOKAL" -maxdepth 1 -type d -name '20[0-9][0-9]-*' ! -name '*.unfertig' 2>/dev/null | head -1)" ] \
  || die "In $ZIEL_LOKAL liegt noch keine fertige Sicherung: sudo systemctl start edeka-sicherung.service"

ALT_REPO=""; ALT_EMPF=""
if sudo test -f "$KONF"; then
  ALT_REPO=$(sudo sed -n 's|^EXTERN_REPO=git@github.com:\(.*\)\.git$|\1|p' "$KONF")
  ALT_EMPF=$(sudo sed -n 's/^EXTERN_EMPFAENGER=//p' "$KONF")
fi

# ── Deploy-Key ──
if [ ! -f "$KEY" ]; then
  install -d -m 700 "$HOME/.ssh"
  ssh-keygen -q -t ed25519 -N "" -C "edeka-extern@$(hostname)" -f "$KEY"
  ok "Deploy-Key erzeugt: $KEY"
else
  ok "Deploy-Key vorhanden: $KEY"
fi

echo
echo "  Auf GitHub (einmalig):"
echo "   1. github.com/new — Name zum Beispiel Eder-sicherungen, **Private**,"
echo "      ohne README. Create repository."
echo "   2. Im neuen Repository: Settings → Deploy keys → Add deploy key."
echo "      Title: edeka-server. Key: die Zeile unten. Häkchen bei"
echo "      \"Allow write access\". Add key."
echo
echo "      $(cat "$KEY.pub")"
echo
R=""
for versuch in 1 2 3 4 5; do
  if [ -n "$ALT_REPO" ]; then lies R "  Repository (Besitzer/Name) [Enter = $ALT_REPO]: "; R=${R:-$ALT_REPO}
  else lies R "  Repository (Besitzer/Name, z. B. deinname/Eder-sicherungen): "; fi
  [[ "$R" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]] || { warn "Form: Besitzer/Name"; continue; }
  CODE=$(sichtbarkeit "$R")
  case "$CODE" in
    200) die "github.com/$R ist ÖFFENTLICH. Bitte auf Private stellen (Settings → Danger Zone) und erneut ausführen." ;;
    404) ;;
    *)   warn "GitHub antwortet nicht wie erwartet (HTTP $CODE) — Netz?"; continue ;;
  esac
  if zugang "$R" "$KEY"; then ok "github.com/$R: privat, und der Deploy-Key hat Zugang"; break; fi
  warn "Kein Zugang zu $R — Name richtig? Deploy-Key eingetragen? Dann Enter."
  R=""
done
[ -n "$R" ] || die "Kein Zugang zum Sicherungs-Repository. Nach dem Eintragen einfach erneut ausführen."

# ── age-Schlüssel ──
echo
EMPF=""
if [ -n "$ALT_EMPF" ]; then
  lies EINGABE "  Öffentlicher age-Schlüssel [Enter = bisheriger ${ALT_EMPF:0:12}…]: "
  EINGABE=${EINGABE:-$ALT_EMPF}
else
  echo "  Eigenen öffentlichen age-Schlüssel (age1…) einfügen, oder nur Enter:"
  lies EINGABE "  dann erzeuge ich hier ein neues Schlüsselpaar: "
fi
case "$EINGABE" in
  AGE-SECRET-KEY-*) die "Das ist der PRIVATE Schlüssel — der gehört nicht auf den Server. Bitte den öffentlichen (age1…)." ;;
  "") schluesselpaar ;;
  *) [[ "$EINGABE" =~ ^age1[02-9ac-hj-np-z]{58}$ ]] || die "Kein öffentlicher age-Schlüssel: ${EINGABE:0:20}…"
     EMPF="$EINGABE"; ok "öffentlicher Schlüssel übernommen" ;;
esac

# ── Einstellungen und Dienst ──
sudo install -d -m 755 /etc/edeka
printf '%s\n' \
  "# Von tools/apply-h3-extern.sh — Änderungen bitte dort." \
  "EXTERN_REPO=git@github.com:${R}.git" \
  "EXTERN_EMPFAENGER=${EMPF}" \
  "EXTERN_SSH_KEY=${KEY}" \
  "EXTERN_ARBEIT=${ARBEIT_EXTERN}" \
  "SICHERUNG_ZIEL=${ZIEL_LOKAL}" \
  | sudo tee "$KONF" >/dev/null
sudo chown root:root "$KONF"; sudo chmod 600 "$KONF"
ok "$KONF (Rechte 600)"

printf '%s\n' \
  "# Von tools/apply-h3-extern.sh erzeugt — Änderungen bitte dort." \
  "[Unit]" \
  "Description=EDEKA Lagerverwaltung — verschlüsselte Kopie der Sicherung außer Haus" \
  "Wants=network-online.target" \
  "After=network-online.target" \
  "" \
  "[Service]" \
  "Type=oneshot" \
  "User=${NUTZER}" \
  "EnvironmentFile=${KONF}" \
  "ExecStart=$(pwd)/${EXTERN}" \
  "NoNewPrivileges=true" \
  "PrivateTmp=true" \
  | sudo tee /etc/systemd/system/edeka-extern.service >/dev/null
sudo mkdir -p /etc/systemd/system/edeka-sicherung.service.d
printf '%s\n' \
  "# Von tools/apply-h3-extern.sh — nach jeder erfolgreichen Sicherung die Kopie außer Haus." \
  "[Unit]" \
  "OnSuccess=edeka-extern.service" \
  | sudo tee /etc/systemd/system/edeka-sicherung.service.d/20-extern.conf >/dev/null
sudo systemctl daemon-reload
systemctl show -p OnSuccess --value edeka-sicherung.service | grep -q edeka-extern.service \
  || die "OnSuccess ist nicht wirksam: systemctl cat edeka-sicherung.service"
ok "edeka-extern.service folgt jeder erfolgreichen Sicherung"

# ── Erster Lauf ──
sudo systemctl reset-failed edeka-extern.service 2>/dev/null || true
sudo systemctl start edeka-extern.service || true
if [ "$(systemctl show -p ActiveState --value edeka-extern.service)" = "failed" ] || ! auf_github "$(juengste)"; then
  journalctl -u edeka-extern -n 15 --no-pager | sed 's/^/    /'
  die "Der erste Lauf ist fehlgeschlagen (siehe oben). Schreibrecht beim Deploy-Key angehakt?"
fi
ok "erster Lauf: $(journalctl -u edeka-extern -n 1 --no-pager -o cat)"

# ── Die ganze Kette: Sicherung → Probe → Kopie ──
echo "    Nachweis der Kette: eine Sicherung jetzt, die Kopie muss von selbst folgen …"
VORHER=$(juengste)
sudo systemctl start edeka-sicherung.service || true
JUENGSTE_LOKAL=$(juengste)
[ "$(systemctl show -p ActiveState --value edeka-sicherung.service)" != "failed" ] && [ "$JUENGSTE_LOKAL" != "$VORHER" ] \
  || die "Die Sicherung selbst ist fehlgeschlagen: journalctl -u edeka-sicherung -n 30 --no-pager"
# Die Kopie startet von selbst (OnSuccess=). Geprüft wird ihre Wirkung, nicht
# der Zustand des Dienstes: ein erfolgreich beendeter Einmal-Dienst kann von
# systemd entladen werden und zeigt dann nur Standardwerte.
KETTE=0
for _ in $(seq 1 120); do
  [ "$(systemctl show -p ActiveState --value edeka-extern.service)" = "failed" ] && break
  if auf_github "$JUENGSTE_LOKAL"; then KETTE=1; break; fi
  sleep 1
done
if [ "$KETTE" != "1" ]; then
  journalctl -u edeka-extern -n 15 --no-pager | sed 's/^/    /'
  die "Die Kopie ist der Sicherung $JUENGSTE_LOKAL nicht gefolgt (siehe oben)."
fi
ANZAHL=$(find "$ARBEIT_EXTERN" -maxdepth 1 -type d -name '20[0-9][0-9]-*' | wc -l)
ok "Kette bewiesen: $JUENGSTE_LOKAL ist geprüft UND verschlüsselt auf GitHub ($ANZAHL im Repository)"

echo
echo "── Danach ──────────────────────────────────────────────────────"
echo
if [ "$REPARATUR" = "1" ]; then
  echo "  Nichts zu committen — H3 war schon in main."
  echo
  exit 0
fi
echo "    mkdir -p tools && mv $SELBST tools/"
echo "    git add .github/workflows/ci.yml Edeka.lager tools/README.md $EXTERN tools/$SELBST"
echo "    git commit -m 'Phase H Schritt 3: verschlüsselte Kopie außer Haus'"
echo "    git push -u origin phase-h3"
echo
echo "  Dann auf GitHub: Pull Request anlegen und mergen — am besten noch heute."
echo "  Der Dienst läuft aus $EXTERN; auf main gibt es die Datei erst nach dem Merge."
echo "  Danach:  git checkout main && git pull"
echo
