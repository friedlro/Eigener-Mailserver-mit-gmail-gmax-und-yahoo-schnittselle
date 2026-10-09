#!/usr/bin/env bash
# tests/run-tests.sh - automatische Tests der Skripte
#
# Die Tests brauchen weder echte Mail-Konten noch einen laufenden Mailserver:
# docker, curl, whiptail usw. werden durch Platzhalter aus tests/stubs ersetzt, die Skripte laufen in
# einem Wegwerf-Ordner, und ihre Systempfade (Cron-Ordner usw.) werden dorthin umgelenkt.
# Es wird nichts installiert und nichts am System verändert.
#
# Nutzung:  tests/run-tests.sh          (unter Linux, als normaler Benutzer; bash, python3, rsync, flock nötig)
# Optional: shellcheck und docker (für "docker compose config") werden verwendet, wenn vorhanden.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STUBS="$ROOT/tests/stubs"
W="$(mktemp -d)"
PIDS=()
PASS=0; FAIL=0; SKIP=0
REAL_DOCKER="$(command -v docker || true)"
TESTPORT=19993

cleanup() {
  local p
  for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null; done
  rm -r -- "$W"
}
trap cleanup EXIT

ok()   { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FEHLER %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf '  übersprungen: %s\n' "$1"; }
title() { printf '\n== %s\n' "$1"; }
check() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }
has()   { grep -qF -- "$2" "$1" 2>/dev/null; }
hasnt() { ! grep -qF -- "$2" "$1" 2>/dev/null; }
perm()  { [[ "$(stat -c %a "$1" 2>/dev/null)" == "$2" ]]; }

# ---------------------------------------------------------------- Aufbau
chmod +x "$STUBS"/* 2>/dev/null || true
mkdir -p "$W/bin"
for n in docker curl whiptail; do ln -sf "$STUBS/$n" "$W/bin/$n"; done
for n in chown chgrp apt-get tailscale systemctl; do ln -sf "$STUBS/noop" "$W/bin/$n"; done

# Kopie der Skripte ohne den sudo-Neustart und ohne die Terminalprüfung
new_instance() {
  local d="$W/$1"; mkdir -p "$d/mcp" "$d/cron" "$d/logrotate" "$d/sudoers" "$d/log"
  local f
  for f in setup-mailserver.sh install.sh uninstall.sh backup-mail.sh; do
    sed -e '/exec sudo/d' -e '/-t 0 && -t 1/d' "$ROOT/$f" > "$d/$f"
  done
  cp "$ROOT/mcp/install.sh" "$d/mcp/"
  echo "$d"
}

# Skript in der Instanz ausführen; Ausgabe landet in $d/out, Exit-Code in $RC
run() {
  local d="$1"; shift
  RC=0
  ( cd "$d" && env PATH="$W/bin:$PATH" TERM=xterm STUB_LOG="$d/stub" CRON_DIR="$d/cron" LOGROTATE_DIR="$d/logrotate" \
      SUDOERS_DIR="$d/sudoers" LOG_DIR="$d/log" LOCK_FILE="$d/lock" CHECK_PORT="$TESTPORT" WT_ANSWERS="$d/answers" \
      "$@" ) > "$d/out" 2>&1 || RC=$?
}

compose_ok() {   # docker compose config prüft die erzeugte Datei auf Gültigkeit
  [[ -n "$REAL_DOCKER" ]] || return 2
  ( cd "$1" && "$REAL_DOCKER" compose --env-file .env -f docker-compose.yml config -q )
}

# Ein Port, auf dem der Test den "Mailserver" lauschen lässt (setup-mailserver.sh wartet darauf)
python3 -c "
import socket, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', $TESTPORT)); s.listen(50); time.sleep(600)" &
PIDS+=("$!")
sleep 1

# ---------------------------------------------------------------- 1. Syntax
title "1. Syntax und shellcheck"
for f in setup-mailserver.sh install.sh uninstall.sh backup-mail.sh mcp/install.sh tests/run-tests.sh; do
  check "bash -n $f" bash -n "$ROOT/$f"
done
check "mcp/server.py ist gültiges Python" python3 -c "import ast,sys; ast.parse(open('$ROOT/mcp/server.py', encoding='utf-8').read())"
if command -v shellcheck >/dev/null; then
  check "shellcheck (Warnungen und Fehler)" shellcheck -S warning "$ROOT"/setup-mailserver.sh "$ROOT"/install.sh "$ROOT"/uninstall.sh "$ROOT"/backup-mail.sh "$ROOT"/mcp/install.sh
else
  skip "shellcheck ist nicht installiert"
fi

# ---------------------------------------------------------------- 2. Installation mit allen Anbietern
title "2. setup-mailserver.sh: Gmail, GMX und Yahoo (Installation, Wiederholung, Update)"
D="$(new_instance multi)"
cat > "$D/accounts.conf" <<'EOF'
TIMEZONE=Europe/Vienna
WEBMAIL_PORT=9090
WEBMAIL_BIND=127.0.0.1
IMPORT_MODE=ordner
anna@gmail.com|abcd efgh ijkl mnop|anna
ben@gmx.de|GmxPass"with\back$dollar'q|ben||10G
clara@yahoo.com|qrstuvwxyzabcdef|clara|LocalPass99
dirk@gmx.com|pw12345|dirk
erik@googlemail.com|abcdabcdabcdabcd|erik||5G
fritz@mydomain.at|pwfritz1|fritz|||gmx
EOF
run "$D" bash setup-mailserver.sh -y
check "Installation endet mit Exit-Code 0" test "$RC" -eq 0
FM="$D/data/config/fetchmail.cf"
check "fetchmail: 6 Konten"                     test "$(grep -c '^poll ' "$FM")" -eq 6
check "fetchmail: Zertifikatsprüfung bei allen" test "$(grep -c 'sslcertck' "$FM")" -eq 6
check "fetchmail: Gmail-Server"      has "$FM" "poll 'pop.gmail.com'"
check "fetchmail: GMX-Server"        has "$FM" "poll 'pop.gmx.net'"
check "fetchmail: GMX.com-Server"    has "$FM" "poll 'pop.gmx.com'"
check "fetchmail: Yahoo-Server"      has "$FM" "poll 'pop.mail.yahoo.com'"
check "fetchmail: Anbieter explizit (eigene Domain, gmx)" has "$FM" "user \"fritz@mydomain.at\""
check "fetchmail: Sonderzeichen im Passwort werden maskiert" has "$FM" "pass \"GmxPass\\\"with\\\\back\$dollar'q\""
check "fetchmail.cf hat Rechte 600" perm "$FM" 600
RM="$D/data/config/postfix-relaymap.cf"; SP="$D/data/config/postfix-sasl-password.cf"
check "Relay Gmail"  has "$RM" "anna@home.lan [smtp.gmail.com]:587"
check "Relay GMX"    has "$RM" "ben@home.lan [mail.gmx.net]:587"
check "Relay Yahoo"  has "$RM" "clara@home.lan [smtp.mail.yahoo.com]:587"
check "Relay GMX.com" has "$RM" "dirk@home.lan [mail.gmx.com]:587"
check "SASL-Daten pro Konto" has "$SP" "ben@home.lan ben@gmx.de:GmxPass\"with\\back\$dollar'q"
check "SASL-Datei hat Rechte 600" perm "$SP" 600
check "6 lokale Konten angelegt" test "$(grep -c '@home.lan|' "$D/data/config/postfix-accounts.cf")" -eq 6
check "zugangsdaten.txt hat Rechte 600" perm "$D/zugangsdaten.txt" 600
check "vorgegebenes lokales Passwort wird übernommen" has "$D/zugangsdaten.txt" "clara@home.lan  LocalPass99"
check "Passwörter stehen nie in Docker-Argumenten" bash -c "! grep -qE 'LocalPass99|abcdefghijklmnop|GmxPass|qrstuvwxyzabcdef|pwfritz1' '$D/stub.args'"
check "Import für alle 6 Konten gestartet" test "$(ls "$D"/stub.mbsync.* 2>/dev/null | wc -l)" -eq 6
MB="$(grep -lF 'Host imap.gmx.net' "$D"/stub.mbsync.* 2>/dev/null | xargs grep -lF 'GmxPass' 2>/dev/null | head -n1)"
check "mbsync GMX: Server und Ordnerauswahl" bash -c "grep -qF 'Patterns * !INBOX !Spam !Papierkorb !Trash' '$MB'"
check "mbsync GMX: Passwort maskiert" has "$MB" "Pass \"GmxPass\\\"with\\\\back\$dollar'q\""
check "mbsync Gmail: Ordnermodus" bash -c "grep -lF 'Host imap.gmail.com' '$D'/stub.mbsync.* | xargs grep -qF '!\"[Gmail]/Spam\"'"
check "mbsync Yahoo: Server"      bash -c "grep -qF 'Host imap.mail.yahoo.com' '$D'/stub.mbsync.*"
check "mbsync GMX.com: Server"    bash -c "grep -qF 'Host imap.gmx.com' '$D'/stub.mbsync.*"
check "Import-Vermerke für alle Konten" test "$(ls "$D"/data/import-done/*.done 2>/dev/null | wc -l)" -eq 6
check ".env: festgelegte Versionen" bash -c "grep -q '^DMS_TAG=16.0.1' '$D/.env' && grep -q '^ROUNDCUBE_TAG=1.7.4-apache' '$D/.env'"
check ".env: Abholung eingeschaltet" has "$D/.env" "FETCHMAIL=1"
check ".env hat Rechte 640" perm "$D/.env" 640
CO="$D/docker-compose.yml"
check "Compose: kein :latest"        hasnt "$CO" ":latest"
check "Compose: Webmail nur lokal"   has "$CO" "127.0.0.1:9090:80"
check "Compose: Versionen aus .env"  has "$CO" 'docker-mailserver:${DMS_TAG}'
check "Compose: Log-Begrenzung"      has "$CO" "max-size"
check "Compose: Roundcube vertraut dem eigenen Zertifikat" has "$D/data/roundcube/config/custom.inc.php" "'cafile' => '/certs/cert.pem'"
check "Roundcube: Zertifikatsprüfung bleibt an" hasnt "$D/data/roundcube/config/custom.inc.php" "'verify_peer' => false"
if [[ -n "$REAL_DOCKER" ]]; then check "docker compose config: Datei ist gültig" compose_ok "$D"; else skip "docker nicht vorhanden (compose config)"; fi
check "private Schlüsseldatei hat Rechte 600" perm "$D/data/certs/key.pem" 600

run "$D" bash setup-mailserver.sh -y
check "zweiter Lauf: Konten existieren schon" test "$(grep -c 'existiert bereits' "$D/out")" -eq 6
check "zweiter Lauf: kein erneuter Import"    test "$(grep -c 'Import bereits abgeschlossen' "$D/out")" -eq 6
check "zweiter Lauf: Exit-Code 0" test "$RC" -eq 0

N_BEFORE="$(ls "$D"/stub.mbsync.* | wc -l)"
run "$D" bash setup-mailserver.sh --update -y
check "Update: Exit-Code 0" test "$RC" -eq 0
check "Update: kein Import"  test "$(ls "$D"/stub.mbsync.* | wc -l)" -eq "$N_BEFORE"
check "Update: Abholung bleibt an" has "$D/.env" "FETCHMAIL=1"

D="$(new_instance spaces)"
cat > "$D/accounts.conf" <<'EOF'
gina@gmx.at|mit leer zeichen|gina
anna@gmail.com|abcd efgh ijkl mnop|anna
EOF
run "$D" bash setup-mailserver.sh -y
check "GMX-Passwort mit Leerzeichen bleibt unverändert" has "$D/data/config/fetchmail.cf" 'pass "mit leer zeichen"'
check "Gmail-App-Passwort wird von Leerzeichen befreit" has "$D/data/config/fetchmail.cf" 'pass "abcdefghijklmnop"'

D="$(new_instance gmxat)"
printf '%s\n' 'gina@gmx.at|GinaPw123|gina' > "$D/accounts.conf"
run "$D" bash setup-mailserver.sh -y
check "gmx.at: Installation endet mit Exit-Code 0" test "$RC" -eq 0
check "gmx.at: wird als GMX abgeholt (pop.gmx.net)" has "$D/data/config/fetchmail.cf" "poll 'pop.gmx.net'"
check "gmx.at: Relay über mail.gmx.net" has "$D/data/config/postfix-relaymap.cf" "gina@home.lan [mail.gmx.net]:587"
check "gmx.at: Import über imap.gmx.net" bash -c "grep -qF 'Host imap.gmx.net' '$D'/stub.mbsync.*"
printf '%s\n' 'gina@gmx.at|GinaPw123' > "$D/accounts.conf"
run "$D" bash setup-mailserver.sh --check
check "gmx.at: --check prüft IMAP und POP3 bei GMX" bash -c "grep -qF 'imaps://imap.gmx.net/' '$D/stub.curl' && grep -qF 'pop3s://pop.gmx.net/' '$D/stub.curl'"

# ---------------------------------------------------------------- 3. Zugangsdaten prüfen
title "3. setup-mailserver.sh --check"
D="$(new_instance check)"
printf '%s\n' 'ok@gmail.com|pw1234567' 'bad@gmx.de|pw1234567' 'down@yahoo.com|pw1234567' > "$D/accounts.conf"
run "$D" bash setup-mailserver.sh --check
check "ein Fehler macht den Exit-Code ungleich 0" test "$RC" -ne 0
check "Hinweis: Anmeldung abgelehnt"  has "$D/out" "ANMELDUNG ABGELEHNT"
check "Hinweis: Server nicht gefunden" has "$D/out" "Server nicht gefunden"
check "GMX wird per IMAP und POP3 geprüft" bash -c "grep -qF 'imaps://imap.gmx.net/' '$D/stub.curl' && grep -qF 'pop3s://pop.gmx.net/' '$D/stub.curl'"
check "Yahoo wird geprüft" has "$D/stub.curl" "pop3s://pop.mail.yahoo.com/"
check "Passwörter stehen nicht in den curl-Argumenten" hasnt "$D/stub.curl" "pw1234567"
printf '%s\n' 'ok@gmail.com|pw1234567' 'ok2@gmx.net|pw1234567' > "$D/accounts.conf"
run "$D" bash setup-mailserver.sh --check
check "alles in Ordnung: Exit-Code 0" test "$RC" -eq 0

# ---------------------------------------------------------------- 4. Fehleingaben
title "4. Ungültige Konfiguration wird abgelehnt"
D="$(new_instance errors)"
expect_error() {   # Name  Konfigurationszeilen...  (letztes Argument: erwarteter Text)
  local name="$1" want="${*: -1}"; local lines=("${@:2:$#-2}")
  printf '%s\n' "${lines[@]}" > "$D/accounts.conf"
  run "$D" bash setup-mailserver.sh --check
  if [[ "$RC" -ne 0 ]] && has "$D/out" "$want"; then ok "$name"; else bad "$name (Exit $RC, erwartet: $want)"; fi
}
expect_error "unbekannte Domain ohne Anbieter"  'x@example.org|pw1234567' "nicht erkannt"
expect_error "unbekannter Anbieter"             'x@gmail.com|pw1234567||||foo' "Unbekannter Anbieter"
expect_error "Token mit Leerzeichen"            'CF_API_TOKEN=abc def' 'x@gmail.com|pw1234567' "ungültige Zeichen"
expect_error "WEBMAIL_BIND ist keine Adresse"   'WEBMAIL_BIND=abc' 'x@gmail.com|pw1234567' "WEBMAIL_BIND"
expect_error "Domain mit Pfad"                  'DOMAIN=example.at/x' 'x@gmail.com|pw1234567' "DOMAIN ist ungültig"
expect_error "unbekannte Einstellung"           'FOO=1' 'x@gmail.com|pw1234567' "Unbekannte Einstellung"
expect_error "Image-Tag mit Sonderzeichen"      'DMS_TAG=latest;rm' 'x@gmail.com|pw1234567' "kein gültiger Image-Tag"
expect_error "keine Konten"                     'TIMEZONE=Europe/Vienna' "Keine Konten"

# ---------------------------------------------------------------- 5. Domain, Tunnel und Geheimnisse
title "5. setup-mailserver.sh mit Domain, Let's Encrypt, DDNS und Tunnel"
D="$(new_instance domain)"
cat > "$D/accounts.conf" <<'EOF'
DOMAIN=example.at
CF_API_TOKEN=AAAAAAAAAAAAAAAAAAAAAAAA
LE_EMAIL=me@example.at
CF_TUNNEL_TOKEN=BBBBBBBBBBBBBBBBBBBBBBBB
DDNS=1
GMAIL_EMPTY_TRASH=1
GMAIL_TRASH_DAYS=30
anna@gmail.com|abcd efgh ijkl mnop|anna
EOF
run "$D" bash setup-mailserver.sh -y
check "Installation mit Domain: Exit-Code 0" test "$RC" -eq 0
CO="$D/docker-compose.yml"
check "Compose: Server heißt mail.example.at" has "$CO" "hostname: mail.example.at"
check "Compose: Tunnel und DDNS enthalten" bash -c "grep -q 'cloudflared:' '$CO' && grep -q 'ddns:' '$CO'"
check "Compose: Token nur als Variable"    has "$CO" 'TUNNEL_TOKEN=${CF_TUNNEL_TOKEN}'
check "Compose enthält keine Token-Werte"  bash -c "! grep -qE 'AAAAAAAA|BBBBBBBB' '$CO'"
check ".env enthält die Token"             bash -c "grep -q '^CF_API_TOKEN=AAAA' '$D/.env' && grep -q '^CF_TUNNEL_TOKEN=BBBB' '$D/.env'"
check "cloudflare.ini hat Rechte 600"      perm "$D/data/cloudflare.ini" 600
check "Cron: Zertifikat mit festem Tag"    has "$D/cron/mailserver-certbot" "certbot/dns-cloudflare:v5.8.0"
check "Cron: Gmail-Aufräumen angelegt"     has "$D/cron/mailserver-gmail-cleanup" "--cleanup"
check "Compose: Let's-Encrypt-Zertifikate eingebunden" has "$CO" "./data/certbot:/etc/letsencrypt:ro"
check "Compose: kein selbst signiertes Zertifikat im Webmail" hasnt "$CO" "/certs/cert.pem"
if [[ -n "$REAL_DOCKER" ]]; then check "docker compose config: Datei ist gültig" compose_ok "$D"; else skip "docker nicht vorhanden (compose config)"; fi

# ---------------------------------------------------------------- 6. Installationsassistent
title "6. install.sh (Menüoberfläche) und Zusammenspiel mit setup-mailserver.sh"
D="$(new_instance wizard)"
cat > "$D/answers" <<'EOF'
gmail
anna@gmail.com
abcd efgh ijkl mnop
N



Y
gmx
ben@example.org
N
gmx
ben@gmx.de
GmxPw123
N
ben
Secret1234
10G
Y
yahoo
clara@yahoo.com
qrstuvwxyzabcdef
N



N
alles
Europe/Vienna
8080
127.0.0.1
N
Y
30
N
Y
14
Y
EOF
run "$D" bash install.sh --config-only
check "Assistent endet mit Exit-Code 0" test "$RC" -eq 0
check "Assistent hat alle Antworten verbraucht" test ! -s "$D/answers"
C="$D/accounts.conf"
check "accounts.conf: Gmail-Zeile mit Anbieter"  has "$C" "anna@gmail.com|abcdefghijklmnop||||gmail"
check "accounts.conf: GMX-Zeile mit allen Feldern" has "$C" "ben@gmx.de|GmxPw123|ben|Secret1234|10G|gmx"
check "accounts.conf: Yahoo-Zeile"               has "$C" "clara@yahoo.com|qrstuvwxyzabcdef||||yahoo"
check "accounts.conf: Webmail nur lokal"         has "$C" "WEBMAIL_BIND=127.0.0.1"
check "accounts.conf: Aufräum-Einstellungen"     bash -c "grep -q '^GMAIL_EMPTY_TRASH=1' '$C' && grep -q '^GMAIL_TRASH_DAYS=30' '$C' && grep -q '^GMAIL_EMPTY_SENT=1' '$C' && grep -q '^GMAIL_SENT_DAYS=14' '$C'"
check "accounts.conf: Import-Modus"              has "$C" "IMPORT_MODE=alles"
check "accounts.conf hat Rechte 600" perm "$C" 600
check "Falsche Domain wurde nachgefragt (Anbieter-Abgleich)" has "$D/answers.log" "sieht nicht nach GMX aus"
run "$D" bash setup-mailserver.sh --check
check "setup-mailserver.sh versteht die erzeugte Datei (--check)" test "$RC" -eq 0
check "alle drei Anbieter werden geprüft" test "$(grep -c '^  IMAP' "$D/out")" -eq 3

# ---------------------------------------------------------------- 7. Backup
title "7. backup-mail.sh"
if ! command -v rsync >/dev/null || ! command -v flock >/dev/null; then
  skip "rsync oder flock fehlt: Backup-Tests"
else
  D="$(new_instance backup)"
  mkdir -p "$D/data/mail-data/home.lan/anna/cur"; echo "Mail 1" > "$D/data/mail-data/home.lan/anna/cur/1"
  B="$W/backup-dest"
  run "$D" env KEEP_DAYS=0 bash backup-mail.sh "$B"
  check "KEEP_DAYS=0 wird abgelehnt"            bash -c "[[ $RC -ne 0 ]] && grep -q 'KEEP_DAYS' '$D/out'"
  run "$D" env ALLOW_SAME_DISK=1 bash backup-mail.sh "$D/bk"
  check "Ziel innerhalb der Quelle wird abgelehnt" bash -c "[[ $RC -ne 0 ]] && grep -q 'innerhalb' '$D/out'"
  run "$D" bash backup-mail.sh "$B"
  check "gleiches Dateisystem wird abgelehnt"   bash -c "[[ $RC -ne 0 ]] && grep -q 'Dateisystem' '$D/out'"
  run "$D" env ALLOW_SAME_DISK=1 KEEP_MONTHLY=1 bash backup-mail.sh "$B"
  check "Sicherung läuft durch" test "$RC" -eq 0
  check "Snapshot enthält die Mail" test -f "$B/latest/data/mail-data/home.lan/anna/cur/1"
  check "Ziel hat Rechte 700" perm "$B" 700
  check "Monatssnapshot angelegt" test "$(ls "$B/monthly" | wc -l)" -eq 1
  mkdir -p "$B/daily/2020-01-01_000000" "$B/daily/$(date -d '-8 days' +%Y-%m-%d_%H%M%S)" "$B/daily/$(date -d '-6 days' +%Y-%m-%d_%H%M%S)"
  sleep 1; run "$D" env ALLOW_SAME_DISK=1 bash backup-mail.sh "$B"
  check "Aufbewahrung: Sicherung von 2020 wird gelöscht"      test ! -e "$B/daily/2020-01-01_000000"
  check "Aufbewahrung: Sicherung von vor 8 Tagen wird gelöscht" test "$(find "$B/daily" -maxdepth 1 -name "$(date -d '-8 days' +%Y-%m-%d)*" | wc -l)" -eq 0
  check "Aufbewahrung: Sicherung von vor 6 Tagen bleibt"      test "$(find "$B/daily" -maxdepth 1 -name "$(date -d '-6 days' +%Y-%m-%d)*" | wc -l)" -eq 1
  check "Aufbewahrung: neueste Sicherung bleibt"              test -d "$(readlink -f "$B/latest")"
  B2="$W/bk-default"; mkdir -p "$B2"
  run "$D" env ALLOW_SAME_DISK=1 bash backup-mail.sh "$B2"
  check "Standard (ohne Monatssnapshots): Sicherung läuft durch" bash -c "[[ $RC -eq 0 ]] && [[ ! -e '$B2/monthly' || -z \"\$(ls -A '$B2/monthly')\" ]]"
  check "latest zeigt auf den neuesten Snapshot" test "$(readlink -f "$B/latest")" = "$(ls -d "$B"/daily/* | sort | tail -n1)"
  ( exec 9>"$D/lock"; flock -n 9; sleep 4 ) &
  PIDS+=("$!"); sleep 1
  run "$D" env ALLOW_SAME_DISK=1 bash backup-mail.sh "$B"
  check "gleichzeitiger zweiter Lauf wird abgelehnt" bash -c "[[ $RC -ne 0 ]] && grep -q 'bereits eine Sicherung' '$D/out'"
  mkdir -p "$D/cron" "$D/logrotate"
  run "$D" env KEEP_DAYS=7 bash backup-mail.sh --install "$B"
  check "--install: Cron-Zeile mit Aufbewahrung und Pfad" bash -c "grep -q 'KEEP_DAYS=7' '$D/cron/mail-backup' && grep -qF \"'$B'\" '$D/cron/mail-backup'"
  check "--install: logrotate-Regel angelegt" test -f "$D/logrotate/mail-backup"
  run "$D" env HC_URL=http://unsicher bash backup-mail.sh --install "$B"
  check "--install: ungültige HC_URL wird abgelehnt" test "$RC" -ne 0
fi

# ---------------------------------------------------------------- 8. Deinstallation
title "8. uninstall.sh -y (ohne Mail-Daten)"
D="$(new_instance uninstall)"
mkdir -p "$D/data/mail-data/home.lan/anna/cur" "$D/config-backup/x" "$D/cron" "$D/logrotate" "$D/sudoers" "$D/log"
echo "Mail 1" > "$D/data/mail-data/home.lan/anna/cur/1"
for f in accounts.conf docker-compose.yml .env zugangsdaten.txt; do echo x > "$D/$f"; done
for f in "$D/cron/mailserver-certbot" "$D/cron/mail-backup" "$D/logrotate/mail-backup" "$D/sudoers/mail-mcp-backup" "$D/log/mail-backup.log"; do echo x > "$f"; done
run "$D" bash uninstall.sh -y
check "Exit-Code 0" test "$RC" -eq 0
check "Cron-Dateien und Logs entfernt" bash -c "[[ ! -e '$D/cron/mailserver-certbot' && ! -e '$D/cron/mail-backup' && ! -e '$D/logrotate/mail-backup' && ! -e '$D/log/mail-backup.log' ]]"
check "sudo-Regel entfernt" test ! -e "$D/sudoers/mail-mcp-backup"
check "Konfiguration und Passwörter entfernt" bash -c "[[ ! -e '$D/accounts.conf' && ! -e '$D/.env' && ! -e '$D/zugangsdaten.txt' && ! -e '$D/docker-compose.yml' && ! -d '$D/config-backup' ]]"
check "MAILS BLEIBEN ERHALTEN (data/ wird ohne --alles nie gelöscht)" test -f "$D/data/mail-data/home.lan/anna/cur/1"
check "Skripte bleiben bestehen" test -f "$D/setup-mailserver.sh"
check "Container wurden entfernt (compose down)" has "$D/stub.args" "compose down"
run "$D" bash uninstall.sh --hilfe
check "unbekannte Option wird abgelehnt" test "$RC" -ne 0

# ---------------------------------------------------------------- 9. Web-Oberfläche
title "9. webui.py (Installation im Browser)"
check "webui.py ist gültiges Python" python3 -I -m py_compile "$ROOT/webui.py"
if command -v python3 >/dev/null; then
  while IFS= read -r line; do echo "$line"; case "$line" in *FEHLER*) FAIL=$((FAIL + 1)) ;; *"  ok  "*) PASS=$((PASS + 1)) ;; esac; done < <(python3 -I "$ROOT/tests/test_webui.py" 2>&1)
fi

# ---------------------------------------------------------------- Ergebnis
printf '\n== Ergebnis: %d bestanden, %d fehlgeschlagen, %d übersprungen\n' "$PASS" "$FAIL" "$SKIP"
[[ "$FAIL" -eq 0 ]]
