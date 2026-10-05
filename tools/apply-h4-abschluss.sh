#!/usr/bin/env bash
#
# apply-h4-abschluss.sh — Phase H, Schritt 4: Aufräumen, Systemupdates, Endabnahme
#
# Teil 1, Repository (alles oder nichts):
#   tools/abnahme.sh             läuft alles? Eine Prüfung über den ganzen Betrieb
#   test/unit/abnahme.test.js    gegen einen nachgebauten Server: grün, und je ein
#                                Defekt macht genau seine Zeile rot
#   BETRIEB.md, ENTSCHEIDUNGEN.md (Nr. 17: bei Ubuntu 24.04 bleiben), tools/README.md
#
# Teil 2, Server:
#   1. Abnahme vorher — aufgeräumt wird nur auf einem ganz grünen System
#   2. Aufräumen: erst die Liste, dann EINE Rückfrage (Vorgabe: nein). Nur was
#      eindeutig zu EDEKA gehört; ein Volume nur, wenn es MongoDB-Daten enthält
#      und an keinem Container hängt; cloudflared nicht, wenn es läuft
#   3. Systemupdates, ohne automatische Neustarts von Diensten
#   4. Abnahme nachher
# Neu gestartet wird erst nach dem Merge — siehe "Danach".
#
# Voraussetzung: H2 ist in main. Legt den Branch phase-h4 an.
#
#     bash apply-h4-abschluss.sh
#
set -euo pipefail

BE="Edeka.lager/backend"
SELBST="$(basename "$0")"
TEST="$BE/test/unit/abnahme.test.js"
ABNAHME="tools/abnahme.sh"
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
die()  { printf '\n  \033[31m✗ %s\033[0m\n\n' "$1" >&2; exit 1; }
gruen() { ( cd "$BE" && node --test "$@" >/dev/null 2>&1 ); }

echo
echo "── Phase H, Schritt 4: Aufräumen, Systemupdates, Endabnahme ────"
echo

[ -f "$BE/server.js" ] || die "Bitte im Wurzelverzeichnis des Repos ausführen (cd ~/Eder)."
command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1 || die "Kein Git-Repository."
git ls-files --error-unmatch tools/alarm.sh >/dev/null 2>&1 || die "H2 fehlt in main — erst H2 abschließen und mergen, dann  git checkout main && git pull"

TEIL1_DATEIEN=(Edeka.lager/BETRIEB.md Edeka.lager/ENTSCHEIDUNGEN.md tools/README.md
               "$BE/test/unit/doku.test.js" "$TEST" "$ABNAHME")
BRANCH=$(git rev-parse --abbrev-ref HEAD)
SCHMUTZ=$(git status --porcelain | grep -v -- "$SELBST" | grep -vE '^\?\? apply-[a-z0-9-]+\.sh$' || true)
if [ "$BRANCH" = "phase-h4" ]; then
  for f in "${TEIL1_DATEIEN[@]}"; do SCHMUTZ=$(printf '%s\n' "$SCHMUTZ" | grep -vxE "(\?\?| M|M |MM|A ) $f" || true); done
fi
[ -z "$SCHMUTZ" ] || { printf '%s\n' "$SCHMUTZ" | sed 's/^/     /'; die "Arbeitsverzeichnis nicht sauber (siehe oben)."; }
REPARATUR=0
case "$BRANCH" in
  main)
    if git ls-files --error-unmatch "$ABNAHME" >/dev/null 2>&1; then REPARATUR=1
    elif git show-ref --verify --quiet refs/heads/phase-h4; then git checkout -q phase-h4
    else git checkout -q -b phase-h4; fi ;;
  phase-h4) ;;
  *) die "Du bist auf '$BRANCH'. Bitte zuerst  git checkout main && git pull" ;;
esac
if [ "$REPARATUR" = "1" ]; then ok "H4 ist schon in main — Lauf auf main"
else ok "Branch phase-h4, Arbeitsverzeichnis sauber"; fi

# ══ Teil 1: Repository — alles oder nichts ═══════════════════════════
TEIL1=0
TMP=$(mktemp -d); chmod 700 "$TMP"
zurueck() {
  rm -rf "$TMP"
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
cat > "$TMP/test.js" <<'__H4_TEST__'
'use strict';
//
// tools/abnahme.sh — die Prüfung über den ganzen Betrieb.
//
// Eine Abnahme, die sich nicht irren kann, ist wertlos. Geprüft gegen einen
// nachgebauten Server (systemctl, docker, curl, openssl, ss, iptables,
// journalctl als Attrappen, git echt): erst alles grün, dann je ein Defekt —
// und jeder Defekt muss genau seine eigene Zeile rot machen.
//
const test   = require('node:test');
const assert = require('node:assert/strict');
const fs     = require('node:fs');
const os     = require('node:os');
const path   = require('node:path');
const { spawnSync } = require('node:child_process');

const SKRIPT = path.join(__dirname, '../../../../tools/abnahme.sh');
const OHNE = spawnSync('sh', ['-c', 'command -v bash && command -v git']).status === 0 ? false : 'bash oder git fehlt';

// Attrappen: kleine Node-Skripte, gesteuert über Umgebungsvariablen.
const ATTRAPPEN = {
  sudo: `#!/bin/sh\nexec "$@"\n`,
  systemctl: `#!/usr/bin/env node
const a = process.argv.slice(2);
if (a[0] === 'is-active') process.exit((process.env.STUB_INAKTIV || '').split(',').includes(a[2]) ? 3 : 0);
if (a[0] === 'show') { console.log('edeka-hc-fehler@edeka-lager.service.service'); process.exit(0); }
process.exit(1);`,
  curl: `#!/usr/bin/env node
const a = process.argv.slice(2), url = a.filter(x => /^https?:/.test(x)).pop() || '';
const oeffentlich = url.startsWith('https://');
if (oeffentlich && process.env.STUB_OEFFENTLICH_AUS) { process.stderr.write('curl: (28) timeout'); process.exit(28); }
if (a.includes('-w')) { process.stdout.write('301 https://test.duckdns.org/'); process.exit(0); }
if (a.some(x => /^-[a-zA-Z]*I/.test(x))) {
  const skript = process.env.STUB_SKRIPT_SRC || "'self'";
  process.stdout.write('HTTP/2 200\\r\\ncontent-security-policy: default-src \\'self\\';script-src ' + skript +
    ";script-src-attr 'none';style-src 'self' 'unsafe-inline'\\r\\n\\r\\n");
  process.exit(0);
}
process.stdout.write('{"status":"ok","uptime":1}');`,
  openssl: `#!/usr/bin/env node
const a = process.argv.slice(2);
if (a[0] === 's_client') { console.log('-----BEGIN CERTIFICATE-----'); process.exit(0); }
const ende = new Date(Date.now() + Number(process.env.STUB_ZERT_TAGE || 60) * 86400e3 + 3600e3);
console.log('notAfter=' + ende.toUTCString());`,
  docker: `#!/usr/bin/env node
const f = process.argv.slice(2).join(' ');
console.log(f.includes('State.Running') ? 'true' : 'edeka-mongo-daten edeka-mongo-config');`,
  ss: `#!/usr/bin/env node
const app = process.env.STUB_APP_OFFEN ? '0.0.0.0:3000' : '127.0.0.1:3000';
for (const l of ['0.0.0.0:22', '0.0.0.0:80', '[::]:443', app, '127.0.0.1:27017'])
  console.log('LISTEN 0 511 ' + l + ' 0.0.0.0:*');`,
  journalctl: `#!/usr/bin/env node
if (!process.env.STUB_KEIN_HERZ) console.log('Finished edeka-herzschlag.service - Herzschlag.');`,
  iptables: `#!/usr/bin/env node
for (const p of [22, 80, 443]) console.log('-A INPUT -p tcp -m tcp --dport ' + p + ' -j ACCEPT');
console.log('-A INPUT -j REJECT --reject-with icmp-host-prohibited');`,
  df: `#!/bin/sh\nprintf 'Use%%\\n 30%%\\n'\n`,
  'apt-get': `#!/bin/sh\nexit 0\n`
};

const git = (cwd, ...args) => {
  const r = spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@t', ...args], { cwd, encoding: 'utf8' });
  assert.equal(r.status, 0, `git ${args.join(' ')}: ${r.stderr}`);
  return r.stdout.trim();
};

function server(t) {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), 'abnahme-'));
  t.after(() => fs.rmSync(d, { recursive: true, force: true }));
  const bin = path.join(d, 'bin'); fs.mkdirSync(bin);
  for (const [name, inhalt] of Object.entries(ATTRAPPEN)) fs.writeFileSync(path.join(bin, name), inhalt, { mode: 0o755 });

  const konf = (name, text) => { const p = path.join(d, name); fs.writeFileSync(p, text); return p; };
  // Code-Repository: main, sauber, gleich mit origin
  const repo = path.join(d, 'repo'), repoOrigin = path.join(d, 'repo.git');
  git(d, 'init', '-q', '--bare', '-b', 'main', repoOrigin);
  git(d, 'init', '-q', '-b', 'main', repo);
  fs.writeFileSync(path.join(repo, 'datei'), 'x');
  git(repo, 'add', '.'); git(repo, 'commit', '-qm', 'eins');
  git(repo, 'remote', 'add', 'origin', repoOrigin); git(repo, 'push', '-q', 'origin', 'main');
  // Sicherungen und ihre Kopie außer Haus
  const ziel = path.join(d, 'sicherungen'); fs.mkdirSync(path.join(ziel, '2026-10-05_023001'), { recursive: true });
  const extern = path.join(d, 'extern'), externOrigin = path.join(d, 'extern.git');
  git(d, 'init', '-q', '--bare', '-b', 'main', externOrigin);
  git(d, 'init', '-q', '-b', 'main', extern);
  fs.mkdirSync(path.join(extern, '2026-10-05_023001'));
  fs.writeFileSync(path.join(extern, '2026-10-05_023001', 'edeka_lager.archive.gz.age'), 'chiffre');
  git(extern, 'add', '.'); git(extern, 'commit', '-qm', 'Sicherung');
  git(extern, 'remote', 'add', 'origin', externOrigin); git(extern, 'push', '-q', 'origin', 'main');

  return {
    ziel,
    env: {
      PATH: `${bin}:${process.env.PATH}`, HOME: d,
      ABNAHME_REPO: repo, SICHERUNG_ZIEL: ziel, EXTERN_ARBEIT: extern,
      DUCKDNS_KONF: konf('duckdns.env', 'DUCKDNS_DOMAIN=test\nDUCKDNS_TOKEN=geheim\n'),
      EXTERN_KONF: konf('extern.env', 'EXTERN_SSH_KEY=/dev/null\n'),
      ALARM_KONF: konf('alarm.env', ['SICHERUNG', 'EXTERN', 'APP', 'ZERTIFIKAT'].map(n => `HC_${n}=https://hc-ping.com/${n}`).join('\n') + '\n'),
      RULES_V4: konf('rules.v4', '-A INPUT -p tcp -m tcp --dport 443 -j ACCEPT\n')
    }
  };
}

function abnahme(s, extra = {}) {
  const r = spawnSync('bash', [SKRIPT], { encoding: 'utf8', env: { ...s.env, ...extra } });
  const rein = r.stdout.replace(/\x1b\[[0-9;]*m/g, '');
  return { status: r.status, aus: rein, rot: rein.split('\n').filter(z => /^\s*✗ /.test(z)).map(z => z.replace(/^\s*✗\s*/, '')) };
}

test('alles in Ordnung: kein ✗, Rückgabe 0 — auch mit unsafe-inline nur bei den Stilen', { skip: OHNE }, (t) => {
  const r = abnahme(server(t));
  assert.deepEqual(r.rot, [], r.aus);
  assert.equal(r.status, 0);
  assert.match(r.aus, /Alles in Ordnung: (\d+) von \1 Prüfungen/);
  assert.match(r.aus, /Zertifikat: noch 60 Tage/);
});

const DEFEKTE = [
  // Ist HTTPS von außen nicht erreichbar, lässt sich auch die CSP nicht lesen: zwei Zeilen.
  ['öffentliche Adresse unerreichbar (z. B. Security List zu)', { STUB_OEFFENTLICH_AUS: '1' }, [/^öffentlich: /, /^CSP: /]],
  ['Inline-Skripte wieder erlaubt', { STUB_SKRIPT_SRC: "'self' 'unsafe-inline'" }, [/^CSP: /]],
  ['App lauscht auf allen Adressen', { STUB_APP_OFFEN: '1' }, [/^App \(3000\) und MongoDB/]],
  ['Zertifikat läuft in 5 Tagen ab', { STUB_ZERT_TAGE: '5' }, [/^Zertifikat: 5 Tage/]],
  ['Herzschlag-Timer gestoppt', { STUB_INAKTIV: 'edeka-herzschlag.timer' }, [/^edeka-herzschlag\.timer aktiv/]],
  ['kein Herzschlag in den letzten 10 Minuten', { STUB_KEIN_HERZ: '1' }, [/^Herzschlag in den letzten/]]
];
for (const [name, env, zeilen] of DEFEKTE) {
  test(`Defekt: ${name} — genau diese Zeilen rot`, { skip: OHNE }, (t) => {
    const r = abnahme(server(t), env);
    assert.equal(r.status, 1, r.aus);
    assert.equal(r.rot.length, zeilen.length, `erwartet ${zeilen.length} ✗, bekommen:\n${r.rot.join('\n')}`);
    zeilen.forEach((z, i) => assert.match(r.rot[i], z));
  });
}

test('Defekt: Sicherung älter als 26 Stunden — genau diese Zeile rot', { skip: OHNE }, (t) => {
  const s = server(t);
  const alt = (Date.now() - 30 * 3600e3) / 1000;
  fs.utimesSync(path.join(s.ziel, '2026-10-05_023001'), alt, alt);
  const r = abnahme(s);
  assert.equal(r.status, 1);
  assert.deepEqual(r.rot.map(z => z.split(' (')[0]), ['keine geprüfte Sicherung der letzten 26 Stunden']);
});

test('Defekt: die jüngste Sicherung fehlt in der Kopie außer Haus — genau diese Zeile rot', { skip: OHNE }, (t) => {
  const s = server(t);
  fs.mkdirSync(path.join(s.ziel, '2026-10-06_023001'));
  const r = abnahme(s);
  assert.equal(r.status, 1);
  assert.equal(r.rot.length, 1, r.rot.join('\n'));
  assert.match(r.rot[0], /^Kopie außer Haus enthält 2026-10-06_023001/);
});
__H4_TEST__
cat > "$TMP/abnahme.sh" <<'__H4_SKRIPT__'
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
__H4_SKRIPT__
cat > "$TMP/doku.py" <<'__H4_DOKU__'
# Gezielte Ergänzungen der Doku für H4 — jeder Anker genau einmal.
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
s = open(B, encoding='utf-8').read()
if 'tools/abnahme.sh' not in s:
    i = s.find('## Aufräumen (fällig ab 04.10.2026)')
    if i < 0 or '\n## ' in s[i + 3:]:
        sys.exit("Aufräumen ist nicht der letzte Abschnitt von BETRIEB.md — Anker passt nicht")
    s = s[:i] + (
        "## Aufräumen\n\n"
        "Einmalig mit `bash tools/apply-h4-abschluss.sh`: der Rückweg vom Umzug der\n"
        "Daten (`edeka-mongo-alt` und seine Volumes), zwei verwaiste Volumes mit alten\n"
        "MongoDB-Daten, alte Kopien der `.env`, liegengebliebene `*.bak`, `cloudflared`\n"
        "und die gemergten Branches auf GitHub. Gelöscht wird nur, was eindeutig zu\n"
        "diesem Projekt gehört, nur auf einem System, dessen Abnahme ganz grün ist, und\n"
        "erst nach Rückfrage. Nie blind `docker volume prune`: Volumes ohne Container\n"
        "können anderen Projekten auf diesem Server gehören.\n")
    open(B, 'w', encoding='utf-8').write(s)
ergaenze(B, 'Eine Prüfung über alles', [
  ("## Läuft alles?\n\n",
   "## Läuft alles?\n\n"
   "Eine Prüfung über alles — sie liest nur und ändert nichts:\n\n"
   "```bash\n"
   "bash ~/Eder/tools/abnahme.sh\n"
   "```\n\n"
   "Jede Zeile ✓ oder ✗; die Summe am Ende sagt, ob alles stimmt. Nach einem\n"
   "Neustart zwei Minuten warten, dann kommt der erste Herzschlag. Einzeln:\n\n"),
  ("Danach „Läuft alles?“ prüfen.\n",
   "Danach „Läuft alles?“ prüfen.\n\n"
   "Ein Wechsel auf eine neue Ubuntu-Version (`do-release-upgrade`, etwa 26.04)\n"
   "gehört **nicht** dazu — siehe `ENTSCHEIDUNGEN.md`, Nr. 17.\n"),
])

ergaenze('Edeka.lager/ENTSCHEIDUNGEN.md', '## 17. Bei Ubuntu 24.04 LTS bleiben', [
  ("---\n\n## Arbeitsweise\n",
   "## 17. Bei Ubuntu 24.04 LTS bleiben (H4)\n\n"
   "**Anlass:** Der Server meldet eine neue Ubuntu-Version (26.04).\n"
   "**Entscheidung:** Kein Wechsel im laufenden Betrieb. 24.04 LTS bekommt\n"
   "Sicherheitsupdates bis 2029, und die werden eingespielt. Ein Versionswechsel\n"
   "ändert Node, nginx und viele Bibliotheken auf einmal — er kommt nur geplant:\n"
   "mit frischer Sicherung, zuerst an einer Kopie erprobt, mit `abnahme.sh` danach.\n"
   "**Folgen:** Eine ruhige Grundlage für den Laden; der Wechsel ist eine eigene\n"
   "Aufgabe, spätestens 2029.\n\n"
   "---\n\n## Arbeitsweise\n"),
])

ergaenze('tools/README.md', '`abnahme.sh`', [
  ("Entstehung — dazu vier Hilfsskripte, die im Betrieb laufen.",
   "Entstehung — dazu die Hilfsskripte für den Betrieb."),
  ("| `alarm.sh` | Lebenszeichen und Fehlermeldungen an Healthchecks.io (Herzschlag, Zertifikat, nach Sicherung und Kopie) |\n",
   "| `alarm.sh` | Lebenszeichen und Fehlermeldungen an Healthchecks.io (Herzschlag, Zertifikat, nach Sicherung und Kopie) |\n"
   "| `abnahme.sh` | läuft alles? Eine Prüfung über den ganzen Betrieb — liest nur, jede Zeile ✓ oder ✗ |\n"),
  ("| `apply-h2-alarm.sh` | Überwachung von außen: Healthchecks.io als Totmannschalter |\n",
   "| `apply-h2-alarm.sh` | Überwachung von außen: Healthchecks.io als Totmannschalter |\n"
   "| `apply-h4-abschluss.sh` | Aufräumen, Systemupdates, Endabnahme |\n"),
])

ergaenze('Edeka.lager/backend/test/unit/doku.test.js', "'apply-h4-abschluss.sh'", [
  ("const AUSSTEHEND = new Set(['apply-h1-doku.sh', 'apply-h3-extern.sh', 'apply-h2-alarm.sh']);",
   "const AUSSTEHEND = new Set(['apply-h1-doku.sh', 'apply-h3-extern.sh', 'apply-h2-alarm.sh', 'apply-h4-abschluss.sh']);"),
])
__H4_DOKU__
if cmp -s "$TMP/test.js" "$TEST"; then ok "$TEST: schon aktuell"; else cp "$TMP/test.js" "$TEST"; ok "$TEST"; fi
node --check "$TEST" >/dev/null 2>&1 || die "Syntaxfehler in $TEST"
if [ -f "$ABNAHME" ] && gruen test/unit/abnahme.test.js; then VORHER="grün"; else VORHER="rot"; fi
if cmp -s "$TMP/abnahme.sh" "$ABNAHME"; then ok "$ABNAHME: schon aktuell"; else cp "$TMP/abnahme.sh" "$ABNAHME"; ok "$ABNAHME"; fi
chmod 755 "$ABNAHME"
bash -n "$ABNAHME" || die "$ABNAHME ist syntaktisch ungültig"
python3 "$TMP/doku.py" | sed 's/^/    /' || die "Doku-Anker passen nicht (siehe oben)"

gruen test/unit/abnahme.test.js || { ( cd "$BE" && node --test test/unit/abnahme.test.js 2>&1 | tail -40 ); die "abnahme.test.js ist nicht grün"; }
if [ "$VORHER" = "rot" ]; then ok "abnahme.test.js: vorher rot, jetzt grün (9 Tests)"; else ok "abnahme.test.js: grün"; fi
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

# ══ Teil 2: Server ═══════════════════════════════════════════════════
lies() {  # lies VARIABLE "Frage"
  local __v=""
  if { exec 3</dev/tty; } 2>/dev/null; then read -r -p "$2" __v <&3; exec 3<&-
  else printf '%s' "$2"; read -r __v || true; echo; fi
  printf -v "$1" '%s' "$(printf '%s' "$__v" | tr -d '[:space:]')"
}

echo
echo "── Teil 2: Server ──────────────────────────────────────────────"
command -v systemctl >/dev/null && systemctl cat edeka-lager.service edeka-herzschlag.timer >/dev/null 2>&1 \
  || die "Die Dienste fehlen — Teil 2 gehört auf den Server, nach H2. Teil 1 ist fertig und bleibt."

echo
echo "── 1  Abnahme vorher ───────────────────────────────────────────"
if ! ABNAHME_OHNE_GIT=1 bash "$ABNAHME"; then
  die "Die Abnahme ist nicht ganz grün — aufgeräumt wird nur auf einem gesunden System. Erst die ✗ beheben, dann erneut ausführen."
fi

echo "── 2  Aufräumen ────────────────────────────────────────────────"
PLAN=()
# Inhalt eines Volumes, ohne Netz und nur lesend: mongo, leer oder anderes.
inhalt() {
  local liste
  liste=$(sudo docker run --rm --network none -v "$1":/v:ro --entrypoint ls mongo:7 -A /v 2>/dev/null) || { echo anderes; return; }
  if [ -z "$liste" ]; then echo leer
  elif grep -q '^WiredTiger' <<<"$liste"; then echo mongo
  else echo anderes; fi
}
unbenutzt()   { [ -z "$(sudo docker ps -aq --filter "volume=$1")" ]; }
ALT_DA=0; VOLUMES=()
if sudo docker inspect edeka-mongo-alt >/dev/null 2>&1; then
  [ "$(sudo docker inspect -f '{{.State.Running}}' edeka-mongo-alt)" = false ] || die "edeka-mongo-alt läuft — so war das nicht vorgesehen. Bitte melden."
  ALT_DA=1; PLAN+=("Container edeka-mongo-alt — der Rückweg vom Umzug der Daten am 27.09.")
  for v in $(sudo docker inspect -f '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}} {{end}}{{end}}' edeka-mongo-alt); do
    [[ "$v" =~ ^[0-9a-f]{64}$ ]] && VOLUMES+=("$v")
  done
fi
for v in $(sudo docker volume ls -qf dangling=true); do
  case "$v" in 2e82c5be*|025be0cf*) VOLUMES+=("$v") ;; esac
done
VOL_OK=()
for v in "${VOLUMES[@]}"; do
  if [ "$ALT_DA" = 1 ] || unbenutzt "$v"; then
    case "$(inhalt "$v")" in
      mongo) VOL_OK+=("$v"); PLAN+=("Volume ${v:0:12}… — alte MongoDB-Daten (WiredTiger)") ;;
      leer)  VOL_OK+=("$v"); PLAN+=("Volume ${v:0:12}… — leer") ;;
      *)     warn "Volume ${v:0:12}… enthält etwas anderes als MongoDB-Daten — bleibt" ;;
    esac
  fi
done
ENV_BAK=()
for f in "$BE/.env.d2.bak" "$BE/.env.s1.bak"; do [ -f "$f" ] && ENV_BAK+=("$f") && PLAN+=("$f — alte Kopie der .env mit Geheimnissen (wird überschrieben, dann gelöscht)"); done
mapfile -t BAKS < <(git ls-files --others --ignored --exclude-standard --directory | grep -E '\.bak$' | grep -vE '\.env\.(d2|s1)\.bak$' || true)
[ "${#BAKS[@]}" -eq 0 ] || PLAN+=("${#BAKS[@]} liegengebliebene *.bak im Repository")
CF=""
if command -v cloudflared >/dev/null; then
  if pgrep -x cloudflared >/dev/null || systemctl list-unit-files 'cloudflared*' --no-legend 2>/dev/null | grep -q .; then
    warn "cloudflared läuft oder hat einen Dienst — bleibt (gehört womöglich zu einem anderen Projekt)"
  else CF=1; PLAN+=("cloudflared — der Übergangstunnel, seit D4 unnötig"); fi
fi
git fetch -q origin --prune
ZWEIGE=()
while read -r b; do
  case "$b" in origin/main|origin|origin/HEAD) continue ;; origin/*) ;; *) continue ;; esac
  git merge-base --is-ancestor "$b" origin/main && ZWEIGE+=("${b#origin/}")
done < <(git for-each-ref --format='%(refname:short)' refs/remotes/origin/)
[ "${#ZWEIGE[@]}" -eq 0 ] || PLAN+=("auf GitHub ${#ZWEIGE[@]} Branches, die vollständig in main stehen: ${ZWEIGE[*]}")

if [ "${#PLAN[@]}" -eq 0 ]; then
  ok "nichts aufzuräumen"
else
  echo "  Entfernt würde:"
  for p in "${PLAN[@]}"; do echo "    · $p"; done
  lies W "  Alles oben Aufgeführte entfernen? [j/N] "
  case "$W" in
    j|J|ja)
      if [ "$ALT_DA" = 1 ]; then sudo docker rm edeka-mongo-alt >/dev/null && ok "edeka-mongo-alt entfernt"; fi
      for v in "${VOL_OK[@]}"; do
        if unbenutzt "$v"; then sudo docker volume rm "$v" >/dev/null && ok "Volume ${v:0:12}… entfernt"
        else warn "Volume ${v:0:12}… hängt an einem Container — bleibt"; fi
      done
      for f in "${ENV_BAK[@]}"; do shred -u "$f" && ok "$f überschrieben und gelöscht"; done
      for f in "${BAKS[@]}"; do rm -f -- "$f"; done
      [ "${#BAKS[@]}" -eq 0 ] || ok "${#BAKS[@]} *.bak entfernt"
      if [ -n "$CF" ]; then
        if dpkg -s cloudflared >/dev/null 2>&1; then sudo apt-get remove -y -qq cloudflared >/dev/null
        else sudo rm -f "$(command -v cloudflared)"; fi
        ok "cloudflared entfernt"
      fi
      if [ "${#ZWEIGE[@]}" -gt 0 ]; then
        if git push -q origin --delete "${ZWEIGE[@]}" 2>/dev/null; then ok "${#ZWEIGE[@]} gemergte Branches auf GitHub gelöscht"
        else warn "Branches auf GitHub nicht (alle) gelöscht — von Hand: git push origin --delete <name>"; fi
      fi
      ;;
    *) warn "nichts entfernt" ;;
  esac
fi

echo
echo "── 3  Systemupdates ────────────────────────────────────────────"
sudo apt-get update -qq
N=$(apt-get -s --with-new-pkgs upgrade 2>/dev/null | grep -c '^Inst ' || true)
if [ "${N:-0}" -gt 0 ]; then
  # Bestehende Konfigurationsdateien behalten; Dienste NICHT automatisch neu
  # starten (Docker neu zu starten träfe auch andere Projekte) — der Neustart
  # des Servers kommt nach dem Merge.
  sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get -y -qq --with-new-pkgs \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade >/dev/null
  ok "$N Pakete aktualisiert"
else
  ok "System ist aktuell"
fi
NEUSTART=0; [ -f /var/run/reboot-required ] && NEUSTART=1

echo
echo "── 4  Abnahme nachher ──────────────────────────────────────────"
if ! ABNAHME_OHNE_GIT=1 bash "$ABNAHME"; then
  echo "    Ein Paket kann seinen Dienst selbst neu gestartet haben — zweiter Versuch in 30 Sekunden …"
  sleep 30
  ABNAHME_OHNE_GIT=1 bash "$ABNAHME" || die "Nach den Updates ist die Abnahme nicht grün — siehe ✗ oben."
fi

if [ "$REPARATUR" = "1" ]; then
  [ "$NEUSTART" = 1 ] && echo "  Ein Neustart ist fällig:  sudo reboot  — danach  bash ~/Eder/tools/abnahme.sh"
  echo
  exit 0
fi
echo "── Danach ──────────────────────────────────────────────────────"
echo
echo "    mkdir -p tools && mv $SELBST tools/"
echo "    git add Edeka.lager tools/README.md $ABNAHME tools/$SELBST"
echo "    git commit -m 'Phase H Schritt 4: Aufräumen, Systemupdates, Endabnahme'"
echo "    git push -u origin phase-h4"
echo
echo "  Dann auf GitHub: Pull Request anlegen und mergen, danach:"
echo "      git checkout main && git pull"
echo "      sudo reboot"
echo "  Nach drei Minuten wieder anmelden und die Endabnahme — jetzt mit Git:"
echo "      bash ~/Eder/tools/abnahme.sh"
echo
