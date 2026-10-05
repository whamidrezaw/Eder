#!/usr/bin/env bash
#
# apply-h2-alarm.sh — Phase H, Schritt 2: Überwachung von außen
#
# Ein ausgefallener Server kann nicht melden, dass er ausgefallen ist.
# Healthchecks.io erwartet deshalb Lebenszeichen und schlägt Alarm, wenn eines
# ausbleibt oder ein Fehler gemeldet wird — per E-Mail und Telegram. Auf diesem
# Server liegt kein Bot-Token.
#
# Teil 1, Repository (alles oder nichts):
#   tools/alarm.sh              Lebenszeichen und Fehler an Healthchecks.io
#   test/unit/alarm.test.js     gegen nachgebaute Dienste und echte Zertifikate
#   BETRIEB.md, ENTSCHEIDUNGEN.md, tools/README.md
#
# Teil 2, Server (interaktiv, jederzeit wiederholbar):
#   vier Prüfungen per API anlegen (der API-Schlüssel wird nie gespeichert),
#   /etc/edeka/alarm.env, Herzschlag alle 5 Minuten, Zertifikat täglich,
#   Meldungen nach jeder Sicherung und Kopie, Fehler per OnFailure= — und
#   Nachweise: Herzschlag, Zertifikat, die Kette nach einer Sicherung, ein
#   Probealarm mit Entwarnung.
#
# Voraussetzung: H3 ist in main. Legt den Branch phase-h2 an.
#
# Ausführen im Wurzelverzeichnis des Repos, auf dem Server:
#     bash apply-h2-alarm.sh
#
set -euo pipefail

BE="Edeka.lager/backend"
SELBST="$(basename "$0")"
TEST="$BE/test/unit/alarm.test.js"
ALARM="tools/alarm.sh"
HC_API="${HC_API:-https://healthchecks.io/api/v3}"
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
die()  { printf '\n  \033[31m✗ %s\033[0m\n\n' "$1" >&2; exit 1; }
gruen() { ( cd "$BE" && node --test "$@" >/dev/null 2>&1 ); }

echo
echo "── Phase H, Schritt 2: Überwachung von außen ───────────────────"
echo

[ -f "$BE/server.js" ] || die "Bitte im Wurzelverzeichnis des Repos ausführen (cd ~/Eder)."
command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1 || die "Kein Git-Repository."
git ls-files --error-unmatch tools/extern-sicherung.sh >/dev/null 2>&1 || die "H3 fehlt in main — bitte zuerst  git checkout main && git pull"

# Die Dateien von Teil 1. Auf phase-h2 dürfen sie aus einem früheren Lauf
# geändert sein: bricht Teil 2 ab, wird das Skript einfach erneut ausgeführt.
TEIL1_DATEIEN=(Edeka.lager/BETRIEB.md Edeka.lager/ENTSCHEIDUNGEN.md tools/README.md
               "$BE/test/unit/doku.test.js" "$TEST" "$ALARM")
BRANCH=$(git rev-parse --abbrev-ref HEAD)
SCHMUTZ=$(git status --porcelain | grep -v -- "$SELBST" | grep -vE '^\?\? apply-[a-z0-9-]+\.sh$' || true)
if [ "$BRANCH" = "phase-h2" ]; then
  for f in "${TEIL1_DATEIEN[@]}"; do SCHMUTZ=$(printf '%s\n' "$SCHMUTZ" | grep -vxE "(\?\?| M|M |MM|A ) $f" || true); done
fi
[ -z "$SCHMUTZ" ] || { printf '%s\n' "$SCHMUTZ" | sed 's/^/     /'; die "Arbeitsverzeichnis nicht sauber (siehe oben)."; }
REPARATUR=0
case "$BRANCH" in
  main)
    if git ls-files --error-unmatch "$ALARM" >/dev/null 2>&1; then REPARATUR=1
    elif git show-ref --verify --quiet refs/heads/phase-h2; then git checkout -q phase-h2
    else git checkout -q -b phase-h2; fi ;;
  phase-h2) ;;
  *) die "Du bist auf '$BRANCH'. Bitte zuerst  git checkout main && git pull" ;;
esac
if [ "$REPARATUR" = "1" ]; then ok "H2 ist schon in main — Reparaturlauf auf main"
else ok "Branch phase-h2, Arbeitsverzeichnis sauber"; fi

# ══ Teil 1: Repository — alles oder nichts ═══════════════════════════
TEIL1=0
TMP=$(mktemp -d); chmod 700 "$TMP"
APIKEY=""
zurueck() {
  APIKEY=""; rm -rf "$TMP"
  if [ "$TEIL1" != "1" ]; then
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
cat > "$TMP/test.js" <<'__H2_TEST__'
'use strict';
//
// tools/alarm.sh — Lebenszeichen und Fehlermeldungen an Healthchecks.io.
//
// Geprüft gegen einen nachgebauten Healthchecks.io-Server, eine nachgebaute
// App und echte HTTPS-Server mit selbst ausgestellten Zertifikaten:
// jede Meldung geht per POST an die richtige Prüfung; ein Fehler geht an
// …/fail; vom Protokoll der App verlässt nichts den Server; die geheimen
// Ping-Adressen erscheinen in keiner Ausgabe.
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const fs     = require('node:fs');
const os     = require('node:os');
const path   = require('node:path');
const http   = require('node:http');
const https  = require('node:https');
const { spawn, spawnSync } = require('node:child_process');

const SKRIPT = path.join(__dirname, '../../../../tools/alarm.sh');
const vorhanden = (cmd) => spawnSync('sh', ['-c', `command -v ${cmd}`]).status === 0;
const OHNE = ['bash', 'curl', 'openssl'].every(vorhanden) ? false : 'curl oder openssl fehlt';

function lauschen(server) {
  return new Promise((ok) => { server.listen(0, '127.0.0.1', () => ok(server.address().port)); });
}

// Ein nachgebautes Healthchecks.io: merkt sich jede Anfrage.
async function hcNachbau(t) {
  const anfragen = [];
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', (c) => { body += c; });
    req.on('end', () => { anfragen.push({ method: req.method, pfad: req.url, body }); res.end('OK'); });
  });
  const port = await lauschen(server);
  t.after(() => server.close());
  const basis = `http://127.0.0.1:${port}/ping`;
  return {
    anfragen,
    env: {
      HC_SICHERUNG: `${basis}/aaaa-sicherung`, HC_EXTERN: `${basis}/bbbb-extern`,
      HC_APP: `${basis}/cccc-app`, HC_ZERTIFIKAT: `${basis}/dddd-zertifikat`
    }
  };
}

function lauf(env, ...args) {
  return new Promise((ok) => {
    const kind = spawn('bash', [SKRIPT, ...args], {
      env: { PATH: env.PATH || process.env.PATH, HOME: os.tmpdir(), ALARM_KONF: '/nicht/vorhanden', ...env }
    });
    let stdout = '', stderr = '';
    kind.stdout.on('data', (c) => { stdout += c; });
    kind.stderr.on('data', (c) => { stderr += c; });
    kind.on('close', (status) => ok({ status, stdout, stderr }));
  });
}

// Keine geheime Ping-Adresse in irgendeiner Ausgabe.
function ohneGeheimnis(r, hc) {
  for (const url of Object.values(hc.env)) {
    const geheim = url.split('/').pop();
    assert.ok(!r.stdout.includes(geheim) && !r.stderr.includes(geheim), `Ausgabe enthält ${geheim}`);
  }
}

test('ok: Lebenszeichen per POST an die richtige Prüfung', { skip: OHNE }, async (t) => {
  const hc = await hcNachbau(t);
  for (const [pruefung, pfad] of [['sicherung', '/ping/aaaa-sicherung'], ['extern', '/ping/bbbb-extern']]) {
    const r = await lauf(hc.env, 'ok', pruefung);
    assert.equal(r.status, 0, r.stderr);
    const a = hc.anfragen.at(-1);
    assert.deepEqual([a.method, a.pfad], ['POST', pfad]);
    ohneGeheimnis(r, hc);
  }
});

test('unbekannte Prüfung, unbekannte Einheit, fehlende Adresse: Abbruch ohne Meldung', { skip: OHNE }, async (t) => {
  const hc = await hcNachbau(t);
  const ohneSicherung = { ...hc.env, HC_SICHERUNG: '' };
  for (const [env, args] of [[hc.env, ['ok', 'gibt-es-nicht']],
                             [hc.env, ['fehlgeschlagen', 'fremd.service']],
                             [ohneSicherung, ['ok', 'sicherung']],
                             [hc.env, ['quatsch']]]) {
    const r = await lauf(env, ...args);
    assert.notEqual(r.status, 0, `angenommen: ${args.join(' ')}`);
    ohneGeheimnis(r, hc);
  }
  assert.equal(hc.anfragen.length, 0);
});

function mitJournal(t, zeilen) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'journal-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  fs.writeFileSync(path.join(dir, 'journalctl'), `#!/bin/sh\nprintf '%s\\n' ${zeilen.map((z) => `'${z}'`).join(' ')}\n`, { mode: 0o755 });
  return `${dir}:${process.env.PATH}`;
}

test('fehlgeschlagen: Sicherungsdienste melden ihre letzten Protokollzeilen an …/fail', { skip: OHNE }, async (t) => {
  const hc = await hcNachbau(t);
  const PATH = mitJournal(t, ['mongodump für edeka_lager fehlgeschlagen.']);
  for (const [einheit, pfad] of [['edeka-sicherung.service', '/ping/aaaa-sicherung/fail'],
                                 ['edeka-extern.service', '/ping/bbbb-extern/fail']]) {
    const r = await lauf({ ...hc.env, PATH }, 'fehlgeschlagen', einheit);
    assert.equal(r.status, 0, r.stderr);
    const a = hc.anfragen.at(-1);
    assert.deepEqual([a.method, a.pfad], ['POST', pfad]);
    assert.match(a.body, new RegExp(einheit.replace('.', '\\.')));
    assert.match(a.body, /mongodump für edeka_lager fehlgeschlagen/);
  }
});

test('fehlgeschlagen: vom Protokoll der App verlässt NICHTS den Server', { skip: OHNE }, async (t) => {
  const hc = await hcNachbau(t);
  const PATH = mitJournal(t, ['Anmeldung fehlgeschlagen für benutzer anna.schmidt']);
  const r = await lauf({ ...hc.env, PATH }, 'fehlgeschlagen', 'edeka-lager.service');
  assert.equal(r.status, 0, r.stderr);
  const a = hc.anfragen.at(-1);
  assert.deepEqual([a.method, a.pfad], ['POST', '/ping/cccc-app/fail']);
  assert.match(a.body, /edeka-lager\.service/);
  assert.match(a.body, /journalctl -u edeka-lager/);
  assert.doesNotMatch(a.body, /anna/);
});

test('herzschlag: gesund → Lebenszeichen, krank oder weg → …/fail mit Grund', { skip: OHNE }, async (t) => {
  const hc = await hcNachbau(t);
  let antwort = { code: 200, body: '{"status":"ok"}' };
  const app = http.createServer((req, res) => { res.statusCode = antwort.code; res.end(antwort.body); });
  const port = await lauschen(app);
  t.after(() => app.close());
  const env = { ...hc.env, APP_URL: `http://127.0.0.1:${port}` };

  let r = await lauf(env, 'herzschlag');
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual([hc.anfragen.at(-1).method, hc.anfragen.at(-1).pfad], ['POST', '/ping/cccc-app']);

  antwort = { code: 503, body: 'Bad Gateway' };
  r = await lauf(env, 'herzschlag');
  assert.equal(r.status, 0, r.stderr);
  assert.equal(hc.anfragen.at(-1).pfad, '/ping/cccc-app/fail');
  assert.match(hc.anfragen.at(-1).body, /HTTP 503/);

  antwort = { code: 200, body: '{"status":"kaputt"}' };
  r = await lauf(env, 'herzschlag');
  assert.equal(hc.anfragen.at(-1).pfad, '/ping/cccc-app/fail');

  r = await lauf({ ...hc.env, APP_URL: 'http://127.0.0.1:9' }, 'herzschlag');
  assert.equal(r.status, 0, r.stderr);
  assert.equal(hc.anfragen.at(-1).pfad, '/ping/cccc-app/fail');
  assert.match(hc.anfragen.at(-1).body, /nicht erreichbar/);
  ohneGeheimnis(r, hc);
});

async function httpsMitZertifikat(t, tage) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zert-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const r = spawnSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', String(tage),
    '-subj', '/CN=localhost', '-keyout', path.join(dir, 'key.pem'), '-out', path.join(dir, 'cert.pem')], { stdio: 'ignore' });
  assert.equal(r.status, 0, 'openssl req');
  const server = https.createServer({ key: fs.readFileSync(path.join(dir, 'key.pem')),
                                      cert: fs.readFileSync(path.join(dir, 'cert.pem')) }, (req, res) => res.end('ok'));
  const port = await lauschen(server);
  t.after(() => server.close());
  return `https://127.0.0.1:${port}`;
}

test('zertifikat: lange gültig → Lebenszeichen, bald abgelaufen → …/fail mit Resttagen', { skip: OHNE }, async (t) => {
  const hc = await hcNachbau(t);
  let r = await lauf({ ...hc.env, APP_URL: await httpsMitZertifikat(t, 60) }, 'zertifikat');
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual([hc.anfragen.at(-1).method, hc.anfragen.at(-1).pfad], ['POST', '/ping/dddd-zertifikat']);
  assert.match(hc.anfragen.at(-1).body, /noch (59|60) Tage/);

  r = await lauf({ ...hc.env, APP_URL: await httpsMitZertifikat(t, 5) }, 'zertifikat');
  assert.equal(r.status, 0, r.stderr);
  assert.equal(hc.anfragen.at(-1).pfad, '/ping/dddd-zertifikat/fail');
  assert.match(hc.anfragen.at(-1).body, /läuft in [45] Tagen ab/);
});

test('probe: ein Probealarm, als solcher erkennbar', { skip: OHNE }, async (t) => {
  const hc = await hcNachbau(t);
  const r = await lauf(hc.env, 'probe');
  assert.equal(r.status, 0, r.stderr);
  assert.equal(hc.anfragen.at(-1).pfad, '/ping/cccc-app/fail');
  assert.match(hc.anfragen.at(-1).body, /PROBEALARM/);
});

test('Healthchecks.io nicht erreichbar: Fehler — ohne die geheime Adresse zu zeigen', { skip: OHNE }, async () => {
  const env = { HC_SICHERUNG: 'http://127.0.0.1:9/ping/eeee-geheim' };
  const r = await lauf(env, 'ok', 'sicherung');
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, /nicht erreicht/);
  assert.ok(!r.stderr.includes('eeee-geheim') && !r.stdout.includes('eeee-geheim'));
});
__H2_TEST__
cat > "$TMP/alarm.sh" <<'__H2_SKRIPT__'
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
__H2_SKRIPT__
cat > "$TMP/doku.py" <<'__H2_DOKU__'
# Gezielte Ergänzungen der Doku für H2 — jeder Anker genau einmal.
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

ergaenze('Edeka.lager/BETRIEB.md', '## Überwachung und Alarme', [
  ("| Verschlüsselte Kopie außer Haus | nach jeder erfolgreichen Sicherung | `edeka-extern.service` |\n",
   "| Verschlüsselte Kopie außer Haus | nach jeder erfolgreichen Sicherung | `edeka-extern.service` |\n"
   "| Lebenszeichen der App über die öffentliche Adresse | alle 5 Minuten | `edeka-herzschlag.timer` |\n"
   "| Restlaufzeit des Zertifikats | täglich 09:00 (Berlin) | `edeka-zertifikat.timer` |\n"),
  ("| Einstellungen der Kopie | `/etc/edeka/extern.env` (Rechte 600): Repository, öffentlicher Schlüssel, Deploy-Key `~/.ssh/edeka_extern_ed25519` |\n",
   "| Einstellungen der Kopie | `/etc/edeka/extern.env` (Rechte 600): Repository, öffentlicher Schlüssel, Deploy-Key `~/.ssh/edeka_extern_ed25519` |\n"
   "| Überwachung | Healthchecks.io, vier Prüfungen; Ping-Adressen in `/etc/edeka/alarm.env` (Rechte 640, root:ubuntu); Skript `tools/alarm.sh` |\n"),
  ("## Protokolle\n",
   "## Überwachung und Alarme\n\n"
   "Healthchecks.io erwartet vier Lebenszeichen von diesem Server. Bleibt eines aus\n"
   "— auch weil der Server ganz ausgefallen ist — oder meldet der Server einen\n"
   "Fehler, schickt Healthchecks.io eine Nachricht: per E-Mail und, wenn dort\n"
   "eingerichtet, per Telegram. Auf diesem Server liegt dafür kein Bot-Token.\n\n"
   "| Prüfung | erwartet | bei Alarm zuerst |\n"
   "|---|---|---|\n"
   "| `edeka-sicherung` | täglich nach 02:30 (Berlin), spätestens 1 Stunde später | „Die Sicherung ist fehlgeschlagen“ |\n"
   "| `edeka-extern` | nach jeder Sicherung, spätestens 2 Stunden später | „Die Kopie außer Haus ist fehlgeschlagen“ |\n"
   "| `edeka-app` | alle 5 Minuten über die **öffentliche** Adresse, spätestens 10 Minuten später | „Die App antwortet nicht“ |\n"
   "| `edeka-zertifikat` | täglich 09:00, mindestens 14 Tage Restlaufzeit | `sudo certbot renew --dry-run` |\n\n"
   "Die Meldungen der Sicherungsdienste enthalten ihre letzten Protokollzeilen.\n"
   "Vom Protokoll der App verlässt nichts den Server — die Meldung nennt nur den\n"
   "Befehl, mit dem man auf dem Server nachsieht.\n\n"
   "Probealarm — kommt die Nachricht an?\n\n"
   "```bash\n"
   "bash ~/Eder/tools/alarm.sh probe\n"
   "```\n\n"
   "Die Entwarnung folgt mit dem nächsten Herzschlag, spätestens nach 5 Minuten —\n"
   "sofort mit `sudo systemctl start edeka-herzschlag.service`.\n\n"
   "## Protokolle\n"),
  ("  lässt sich `main` dieses Repositorys gegen Force-Push und Löschen schützen.\n",
   "  lässt sich `main` dieses Repositorys gegen Force-Push und Löschen schützen.\n"
   "- **Die Ping-Adressen** in `/etc/edeka/alarm.env` sind Geheimnisse: Wer sie\n"
   "  kennt, kann falsche Entwarnungen schicken. Sie kommen nie ins Repository. Die\n"
   "  Prüfungen nehmen nur POST an — ein bloß aufgerufener Link zählt nicht.\n"),
])

ergaenze('Edeka.lager/ENTSCHEIDUNGEN.md', '## 16. Überwachung von außen', [
  ("---\n\n## Arbeitsweise\n",
   "## 16. Überwachung von außen: Healthchecks.io als Totmannschalter (H2)\n\n"
   "**Anlass:** Ein ausgefallener Server kann nicht melden, dass er ausgefallen\n"
   "ist. Bis hierher hätte niemand eine gescheiterte Sicherung, eine stehende App\n"
   "oder ein ablaufendes Zertifikat bemerkt.\n"
   "**Entscheidung:** Der Server schickt Lebenszeichen an Healthchecks.io: nach\n"
   "jeder Sicherung, nach jeder Kopie außer Haus, alle 5 Minuten über die\n"
   "öffentliche Adresse — das prüft nginx, Zertifikat, DNS und App zugleich — und\n"
   "täglich die Restlaufzeit des Zertifikats. Fehler meldet er sofort an `/fail`.\n"
   "Benachrichtigt wird von Healthchecks.io per E-Mail und Telegram; auf dem\n"
   "Server liegt kein Bot-Token. Die Prüfungen nehmen nur POST an, und vom\n"
   "Protokoll der App geht nichts hinaus. Verworfen: ein Telegram-Bot auf dem\n"
   "Server (kann den eigenen Ausfall nicht melden, ein weiteres Geheimnis), E-Mail\n"
   "vom Server (SMTP-Zugang als Geheimnis), ntfy (öffentliche Themen).\n"
   "**Folgen:** Stille fällt spätestens nach 15 Minuten auf. Fällt Healthchecks.io\n"
   "selbst aus, bleiben Alarme aus — für einen einzelnen Laden hingenommen.\n\n"
   "---\n\n## Arbeitsweise\n"),
])

ergaenze('tools/README.md', '`alarm.sh`', [
  ("Entstehung — dazu drei Hilfsskripte, die im Betrieb laufen.",
   "Entstehung — dazu vier Hilfsskripte, die im Betrieb laufen."),
  ("| `extern-sicherung.sh` | verschlüsselte Kopie jeder geprüften Sicherung ins private Sicherungs-Repository (`edeka-extern.service`, nach jeder erfolgreichen Sicherung) |\n",
   "| `extern-sicherung.sh` | verschlüsselte Kopie jeder geprüften Sicherung ins private Sicherungs-Repository (`edeka-extern.service`, nach jeder erfolgreichen Sicherung) |\n"
   "| `alarm.sh` | Lebenszeichen und Fehlermeldungen an Healthchecks.io (Herzschlag, Zertifikat, nach Sicherung und Kopie) |\n"),
  ("| `apply-h3-extern.sh` | Kopie außer Haus: verschlüsselt in ein privates GitHub-Repository |\n",
   "| `apply-h3-extern.sh` | Kopie außer Haus: verschlüsselt in ein privates GitHub-Repository |\n"
   "| `apply-h2-alarm.sh` | Überwachung von außen: Healthchecks.io als Totmannschalter |\n"),
])

ergaenze('Edeka.lager/backend/test/unit/doku.test.js', "'apply-h2-alarm.sh'", [
  ("const AUSSTEHEND = new Set(['apply-h1-doku.sh', 'apply-h3-extern.sh']);",
   "const AUSSTEHEND = new Set(['apply-h1-doku.sh', 'apply-h3-extern.sh', 'apply-h2-alarm.sh']);"),
])
__H2_DOKU__
if cmp -s "$TMP/test.js" "$TEST"; then ok "$TEST: schon aktuell"; else cp "$TMP/test.js" "$TEST"; ok "$TEST"; fi
node --check "$TEST" >/dev/null 2>&1 || die "Syntaxfehler in $TEST"
if [ -f "$ALARM" ] && gruen test/unit/alarm.test.js; then VORHER="grün"; else VORHER="rot"; fi
if cmp -s "$TMP/alarm.sh" "$ALARM"; then ok "$ALARM: schon aktuell"; else cp "$TMP/alarm.sh" "$ALARM"; ok "$ALARM"; fi
chmod 755 "$ALARM"
bash -n "$ALARM" || die "$ALARM ist syntaktisch ungültig"
python3 "$TMP/doku.py" | sed 's/^/    /' || die "Doku-Anker passen nicht (siehe oben)"

gruen test/unit/alarm.test.js || { ( cd "$BE" && node --test test/unit/alarm.test.js 2>&1 | tail -40 ); die "alarm.test.js ist nicht grün"; }
if [ "$VORHER" = "rot" ]; then ok "alarm.test.js: vorher rot, jetzt grün (8 Tests)"; else ok "alarm.test.js: grün"; fi
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
# api METHODE PFAD [JSON] — Antwort in $TMP/api.json, gibt den HTTP-Code aus.
# Der Schlüssel geht über die Standardeingabe an curl, nie auf die Kommandozeile.
api() {
  local args=(-K - -sS -m 20 -o "$TMP/api.json" -w '%{http_code}' -X "$1")
  if [ -n "${3:-}" ]; then args+=(-H 'Content-Type: application/json' --data-binary "$3"); fi
  printf 'header = "X-Api-Key: %s"\nurl = "%s%s"\n' "$APIKEY" "$HC_API" "$2" | curl "${args[@]}" 2>/dev/null || echo 000
}
# anlegen VARIABLE SLUG NAME BESCHREIBUNG ZUSATZ-JSON — legt an oder aktualisiert
# (unique: slug), nur POST, alle vorhandenen Benachrichtigungswege.
anlegen() {
  local json code url
  json=$(python3 -c '
import json, sys
d = {"slug": sys.argv[1], "name": sys.argv[2], "desc": sys.argv[3], "methods": "POST",
     "channels": "*", "unique": ["slug"]}
d.update(json.loads(sys.argv[4]))
print(json.dumps(d))' "$2" "$3" "$4" "$5")
  code=$(api POST /checks/ "$json")
  case "$code" in
    200|201) ;;
    403) die "Healthchecks.io lehnt ab: Grenze der Prüfungen erreicht oder falscher Schlüssel (HTTP 403)." ;;
    *)   die "Anlegen von $2 fehlgeschlagen (HTTP $code)." ;;
  esac
  url=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("ping_url", ""))' "$TMP/api.json")
  [[ "$url" =~ ^https?://[^[:space:]]+$ ]] || die "Healthchecks.io lieferte für $2 keine Ping-Adresse — read-only-Schlüssel?"
  printf -v "$1" '%s' "$url"
}
# zustand SLUG — Status der Prüfung laut Healthchecks.io (up, down, new …)
zustand() {
  [ "$(api GET "/checks/?slug=$1")" = 200 ] || { echo "?"; return; }
  python3 -c 'import json, sys; c = json.load(open(sys.argv[1]))["checks"]; print(c[0]["status"] if c else "?")' "$TMP/api.json"
}
warte_auf_zustand() {  # SLUG ZUSTAND SEKUNDEN
  local i
  for i in $(seq 1 "$3"); do [ "$(zustand "$1")" = "$2" ] && return 0; sleep 1; done
  return 1
}
# ── Ende Funktionen ──

echo
echo "── Teil 2: Server ──────────────────────────────────────────────"
command -v systemctl >/dev/null && systemctl cat edeka-sicherung.service edeka-extern.service edeka-lager.service >/dev/null 2>&1 \
  || die "Die Dienste von D2, D3 und H3 fehlen — Teil 2 gehört auf den Server. Teil 1 ist fertig und bleibt."
for c in curl openssl python3; do command -v "$c" >/dev/null || die "$c fehlt: sudo apt install $c"; done
NUTZER=$(id -un); GRUPPE=$(id -gn)
KONF=/etc/edeka/alarm.env
sudo test -f /etc/edeka/duckdns.env || die "/etc/edeka/duckdns.env fehlt — ist D4 eingerichtet?"
DOMAIN=$(sudo sed -n 's/^DUCKDNS_DOMAIN=//p' /etc/edeka/duckdns.env)
[[ "$DOMAIN" =~ ^[a-z0-9-]+$ ]] || die "Kein DuckDNS-Name in /etc/edeka/duckdns.env"
APP_URL="https://${DOMAIN}.duckdns.org"
curl -fsS -m 15 "$APP_URL/api/health" 2>/dev/null | grep -q '"status":"ok"' \
  || die "Die App ist über $APP_URL nicht erreichbar — zuerst das beheben."
ok "App über die öffentliche Adresse erreichbar"
if id -nG | tr ' ' '\n' | grep -qxE 'adm|systemd-journal'; then ok "Protokolle lesbar (Gruppe adm) — Fehlermeldungen enthalten die letzten Zeilen"
else warn "$NUTZER ist nicht in der Gruppe adm — Fehlermeldungen kommen ohne Protokollzeilen"; fi

VORHANDEN=0
if sudo test -f "$KONF"; then
  VORHANDEN=1
  for v in HC_SICHERUNG HC_EXTERN HC_APP HC_ZERTIFIKAT; do sudo grep -qE "^$v=https?://" "$KONF" || VORHANDEN=0; done
fi

echo
if [ "$VORHANDEN" = "1" ]; then
  lies APIKEY "  API-Schlüssel (read-write) — oder Enter, um die bestehenden Prüfungen zu behalten: " -s
else
  echo "  Healthchecks.io → dein Projekt → Settings → API Access → API key erstellen"
  echo "  (read-write, NICHT read-only). Er wird nur jetzt benutzt und nie gespeichert."
  lies APIKEY "  API-Schlüssel einfügen (unsichtbar): " -s
  [ -n "$APIKEY" ] || die "Ohne API-Schlüssel lassen sich die Prüfungen nicht anlegen."
fi

if [ -n "$APIKEY" ]; then
  CODE=000
  for versuch in 1 2 3; do
    CODE=$(api GET /channels/)
    [ "$CODE" = 200 ] && break
    warn "Healthchecks.io lehnt den Schlüssel ab (HTTP $CODE) — read-write, nicht read-only?"
    [ "$versuch" = 3 ] || lies APIKEY "  API-Schlüssel noch einmal (unsichtbar): " -s
  done
  [ "$CODE" = 200 ] || die "Kein gültiger read-write-Schlüssel."
  ok "API-Schlüssel gültig"

  # channels "*" weist nur Benachrichtigungswege zu, die es SCHON gibt.
  for versuch in 1 2 3 4; do
    ARTEN=$(python3 -c 'import json, sys; print(" ".join(sorted({c["kind"] for c in json.load(open(sys.argv[1]))["channels"]})))' "$TMP/api.json")
    [ -n "$ARTEN" ] || die "In Healthchecks.io ist kein Benachrichtigungsweg eingerichtet (Integrations)."
    case " $ARTEN " in *" telegram "*) ok "Benachrichtigungswege: $ARTEN"; break ;; esac
    warn "Telegram fehlt unter den Benachrichtigungswegen (vorhanden: $ARTEN)."
    echo "    Healthchecks.io → Integrations → Telegram → Add Integration, im Telegram-Chat bestätigen."
    lies W "  Danach Enter — oder 'ohne', um nur mit $ARTEN weiterzumachen: "
    if [ "$W" = "ohne" ]; then ok "weiter mit: $ARTEN"; break; fi
    CODE=$(api GET /channels/); [ "$CODE" = 200 ] || die "Healthchecks.io antwortet nicht (HTTP $CODE)."
  done

  anlegen U_SICHERUNG edeka-sicherung "EDEKA Sicherung" "tools/sicherung.sh — täglich 02:30, mit Wiederherstellungsprobe" \
    '{"schedule": "*-*-* 02:30:00", "tz": "Europe/Berlin", "grace": 3600}'
  anlegen U_EXTERN edeka-extern "EDEKA Kopie außer Haus" "tools/extern-sicherung.sh — nach jeder erfolgreichen Sicherung" \
    '{"schedule": "*-*-* 02:30:00", "tz": "Europe/Berlin", "grace": 7200}'
  anlegen U_APP edeka-app "EDEKA App erreichbar" "öffentliche Adresse /api/health — alle 5 Minuten" \
    '{"timeout": 300, "grace": 600}'
  anlegen U_ZERT edeka-zertifikat "EDEKA Zertifikat" "mindestens 14 Tage Restlaufzeit — täglich 09:00" \
    '{"schedule": "*-*-* 09:00:00", "tz": "Europe/Berlin", "grace": 3600}'
  ok "vier Prüfungen in Healthchecks.io: nur POST, alle Benachrichtigungswege"

  sudo install -d -m 755 /etc/edeka
  printf '%s\n' \
    "# Von tools/apply-h2-alarm.sh — GEHEIM: nie ins Repository." \
    "HC_SICHERUNG=${U_SICHERUNG}" "HC_EXTERN=${U_EXTERN}" "HC_APP=${U_APP}" "HC_ZERTIFIKAT=${U_ZERT}" \
    "APP_URL=${APP_URL}" "ZERT_MIN_TAGE=14" \
    | sudo tee "$KONF" >/dev/null
else
  ok "bestehende Prüfungen bleiben"
  sudo sed -i "s|^APP_URL=.*|APP_URL=${APP_URL}|" "$KONF"
fi
sudo chown root:"$GRUPPE" "$KONF"; sudo chmod 640 "$KONF"
ok "$KONF (Rechte 640, root:$GRUPPE)"

# ── Dienste, Timer, Anbindung an die bestehenden Dienste ──
einheit() {  # einheit DATEI  — Inhalt von der Standardeingabe
  { echo "# Von tools/apply-h2-alarm.sh erzeugt — Änderungen bitte dort."; cat; } | sudo tee "/etc/systemd/system/$1" >/dev/null
}
DIENST_KOPF="Type=oneshot
User=${NUTZER}
EnvironmentFile=${KONF}
NoNewPrivileges=true
PrivateTmp=true"
printf '[Unit]\nDescription=EDEKA Lagerverwaltung — Lebenszeichen %%i an Healthchecks.io\n\n[Service]\n%s\nExecStart=%s/%s ok %%i\n' \
  "$DIENST_KOPF" "$(pwd)" "$ALARM" | einheit edeka-hc-ok@.service
printf '[Unit]\nDescription=EDEKA Lagerverwaltung — Fehler von %%i an Healthchecks.io\n\n[Service]\n%s\nExecStart=%s/%s fehlgeschlagen %%i\n' \
  "$DIENST_KOPF" "$(pwd)" "$ALARM" | einheit edeka-hc-fehler@.service
printf '[Unit]\nDescription=EDEKA Lagerverwaltung — Herzschlag über die öffentliche Adresse\nWants=network-online.target\nAfter=network-online.target\n\n[Service]\n%s\nExecStart=%s/%s herzschlag\n' \
  "$DIENST_KOPF" "$(pwd)" "$ALARM" | einheit edeka-herzschlag.service
printf '[Unit]\nDescription=EDEKA Lagerverwaltung — Herzschlag alle 5 Minuten\n\n[Timer]\nOnBootSec=2min\nOnUnitActiveSec=5min\nAccuracySec=30s\n\n[Install]\nWantedBy=timers.target\n' \
  | einheit edeka-herzschlag.timer
printf '[Unit]\nDescription=EDEKA Lagerverwaltung — Restlaufzeit des Zertifikats\nWants=network-online.target\nAfter=network-online.target\n\n[Service]\n%s\nExecStart=%s/%s zertifikat\n' \
  "$DIENST_KOPF" "$(pwd)" "$ALARM" | einheit edeka-zertifikat.service
printf '[Unit]\nDescription=EDEKA Lagerverwaltung — Zertifikat täglich prüfen\n\n[Timer]\nOnCalendar=*-*-* 09:00:00 Europe/Berlin\nPersistent=true\n\n[Install]\nWantedBy=timers.target\n' \
  | einheit edeka-zertifikat.timer
for d in edeka-sicherung:sicherung edeka-extern:extern; do
  sudo mkdir -p "/etc/systemd/system/${d%%:*}.service.d"
  printf '[Unit]\nOnSuccess=edeka-hc-ok@%s.service\nOnFailure=edeka-hc-fehler@%%n.service\n' "${d##*:}" \
    | { echo "# Von tools/apply-h2-alarm.sh — Lebenszeichen und Fehler an Healthchecks.io."; cat; } \
    | sudo tee "/etc/systemd/system/${d%%:*}.service.d/30-alarm.conf" >/dev/null
done
sudo mkdir -p /etc/systemd/system/edeka-lager.service.d
printf '# Von tools/apply-h2-alarm.sh — gibt systemd die App auf, meldet Healthchecks.io das sofort.\n[Unit]\nOnFailure=edeka-hc-fehler@%%n.service\n' \
  | sudo tee /etc/systemd/system/edeka-lager.service.d/30-alarm.conf >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable --now edeka-herzschlag.timer edeka-zertifikat.timer >/dev/null 2>&1
S_OK=$(systemctl show -p OnSuccess --value edeka-sicherung.service)
[[ "$S_OK" == *edeka-extern.service* && "$S_OK" == *edeka-hc-ok@sicherung.service* ]] || die "OnSuccess der Sicherung unvollständig: $S_OK"
systemctl show -p OnFailure --value edeka-sicherung.service | grep -q 'edeka-hc-fehler@edeka-sicherung.service' || die "OnFailure der Sicherung fehlt"
systemctl show -p OnSuccess --value edeka-extern.service | grep -q 'edeka-hc-ok@extern.service' || die "OnSuccess der Kopie fehlt"
systemctl show -p OnFailure --value edeka-lager.service | grep -q 'edeka-hc-fehler@edeka-lager.service' || die "OnFailure der App fehlt"
[ "$(systemctl is-enabled edeka-herzschlag.timer)" = enabled ] && [ "$(systemctl is-enabled edeka-zertifikat.timer)" = enabled ] || die "Timer nicht aktiviert"
ok "Herzschlag alle 5 Minuten, Zertifikat täglich, Meldungen nach Sicherung und Kopie, Fehler per OnFailure"

# ── Nachweise ──
echo
echo "── Nachweise ───────────────────────────────────────────────────"
lauf() {  # lauf EINHEIT — startet sie und verlangt Erfolg
  sudo systemctl reset-failed "$1" 2>/dev/null || true
  sudo systemctl start "$1" || true
  if [ "$(systemctl show -p ActiveState --value "$1")" = failed ]; then
    sudo journalctl -u "$1" -n 15 --no-pager | sed 's/^/    /'; die "$1 ist fehlgeschlagen (siehe oben)."
  fi
}
lauf edeka-herzschlag.service
if [ -n "$APIKEY" ]; then warte_auf_zustand edeka-app up 30 || die "Healthchecks.io zeigt edeka-app nicht als up."; fi
ok "Herzschlag angekommen"
lauf edeka-zertifikat.service
if [ -n "$APIKEY" ]; then warte_auf_zustand edeka-zertifikat up 30 || die "Healthchecks.io zeigt edeka-zertifikat nicht als up."; fi
BIS=$(timeout 20 openssl s_client -connect "${DOMAIN}.duckdns.org:443" -servername "${DOMAIN}.duckdns.org" </dev/null 2>/dev/null \
      | openssl x509 -noout -enddate 2>/dev/null | sed 's/^notAfter=//' || true)
ok "Zertifikat geprüft — gültig bis ${BIS:-?}"

echo "    Die Kette: eine Sicherung jetzt — beide Lebenszeichen müssen von selbst folgen …"
SEIT=$(date +%s)
sudo systemctl start edeka-sicherung.service || true
[ "$(systemctl show -p ActiveState --value edeka-sicherung.service)" != failed ] || die "Die Sicherung selbst ist fehlgeschlagen: journalctl -u edeka-sicherung -n 30 --no-pager"
KETTE=0
for _ in $(seq 1 180); do
  if sudo journalctl -u edeka-hc-ok@sicherung.service --since "@$SEIT" -o cat --no-pager 2>/dev/null | grep -q '^Finished' \
     && sudo journalctl -u edeka-hc-ok@extern.service --since "@$SEIT" -o cat --no-pager 2>/dev/null | grep -q '^Finished'; then
    KETTE=1; break
  fi
  sleep 1
done
[ "$KETTE" = 1 ] || { sudo journalctl -u 'edeka-hc-ok@*' -u edeka-extern --since "@$SEIT" -n 20 --no-pager | sed 's/^/    /'; die "Die Lebenszeichen sind der Sicherung nicht gefolgt (siehe oben)."; }
if [ -n "$APIKEY" ]; then
  warte_auf_zustand edeka-sicherung up 30 && warte_auf_zustand edeka-extern up 30 || die "Healthchecks.io zeigt Sicherung oder Kopie nicht als up."
fi
ok "Kette bewiesen: Sicherung → Kopie außer Haus → beide Lebenszeichen bei Healthchecks.io"

echo
lies W "  Probealarm senden — kommt die Nachricht an? [J/n] "
case "$W" in n|N|nein) warn "kein Probealarm — später: bash $ALARM probe" ;;
  *)
    bash "$ALARM" probe || die "Probealarm nicht zugestellt."
    if [ -n "$APIKEY" ]; then warte_auf_zustand edeka-app down 30 && ok "Healthchecks.io hat den Probealarm registriert"; fi
    echo "    Die Nachricht sollte in Telegram (und per E-Mail) ankommen — das kann eine Minute dauern."
    lies W "  Angekommen? [j/n] "
    case "$W" in
      j|J|ja) ok "Probealarm angekommen" ;;
      *) warn "Nicht angekommen: in Healthchecks.io unter Integrations prüfen, ob Telegram aktiv ist, und bei der Prüfung edeka-app unter Notifications. E-Mail: auch im Spam-Ordner nachsehen." ;;
    esac
    lauf edeka-herzschlag.service
    if [ -n "$APIKEY" ]; then warte_auf_zustand edeka-app up 30 || warn "edeka-app ist noch nicht wieder up"; fi
    ok "Entwarnung gesendet — auch sie kommt als Nachricht"
    ;;
esac
APIKEY=""

if [ "$REPARATUR" = "1" ]; then
  echo
  echo "  Nichts zu committen — H2 war schon in main."
  echo
  exit 0
fi
echo
echo "── Danach ──────────────────────────────────────────────────────"
echo
echo "    mkdir -p tools && mv $SELBST tools/"
echo "    git add Edeka.lager tools/README.md $ALARM tools/$SELBST"
echo "    git commit -m 'Phase H Schritt 2: Überwachung von außen mit Healthchecks.io'"
echo "    git push -u origin phase-h2"
echo
echo "  Dann auf GitHub: Pull Request anlegen und SOFORT mergen, erst danach:"
echo "      git checkout main && git pull"
echo "  Der Herzschlag läuft alle 5 Minuten aus $ALARM. Wer vor dem Merge auf main"
echo "  wechselt, nimmt ihm die Datei weg — nach 15 Minuten meldet Healthchecks.io"
echo "  die App dann (fälschlich) als ausgefallen."
echo
