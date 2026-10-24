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
for n in blkid mkfs.ext4 mount umount mountpoint systemctl; do ln -sf "$STUBS/usbtool" "$W/bin/$n"; done
ln -sf "$STUBS/tailscale" "$W/bin/tailscale"
for n in chown chgrp apt-get systemctl; do ln -sf "$STUBS/noop" "$W/bin/$n"; done

# Kopie der Skripte ohne den sudo-Neustart und ohne die Terminalprüfung
new_instance() {
  local d="$W/$1"; mkdir -p "$d/mcp" "$d/cron" "$d/logrotate" "$d/sudoers" "$d/log"
  local f
  for f in setup-mailserver.sh install.sh uninstall.sh backup-mail.sh usb-backup.sh tailscale-setup.sh restore-mail.sh migrate-to-tailscale.sh; do
    sed -e '/exec sudo/d' -e '/-t 0 && -t 1/d' "$ROOT/$f" > "$d/$f"
  done
  cp "$ROOT/mcp/install.sh" "$d/mcp/"
  cp "$ROOT/cleanup.py" "$ROOT/usbdisks.py" "$d/"
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
GM="$D/data/config/postfix-generic.cf"
check "Absender: lokale Adresse wird auf die Anbieter-Adresse umgeschrieben (GMX, Yahoo, Gmail)" bash -c "grep -qx 'ben@home.lan ben@gmx.de' '$GM' && grep -qx 'clara@home.lan clara@yahoo.com' '$GM' && grep -qx 'anna@home.lan anna@gmail.com' '$GM'"
check "Absender: Postfix liest die Zuordnung (smtp_generic_maps)" has "$D/data/config/postfix-main.cf" "smtp_generic_maps = texthash:/tmp/docker-mailserver/postfix-generic.cf"
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

echo "message_size_limit = 1234" >> "$D/data/config/postfix-main.cf"   # eigene Einstellung des Betreibers
run "$D" bash setup-mailserver.sh -y
check "zweiter Lauf: eigene Zeilen in postfix-main.cf bleiben, Absender-Zeile genau einmal" bash -c "grep -qx 'message_size_limit = 1234' '$D/data/config/postfix-main.cf' && [[ \$(grep -c '^smtp_generic_maps' '$D/data/config/postfix-main.cf') -eq 1 ]]"
check "zweiter Lauf: Konten existieren schon" test "$(grep -c 'existiert bereits' "$D/out")" -eq 6
check "zweiter Lauf: kein erneuter Import"    test "$(grep -c 'Import bereits abgeschlossen' "$D/out")" -eq 6
check "zweiter Lauf: Exit-Code 0" test "$RC" -eq 0

N_BEFORE="$(ls "$D"/stub.mbsync.* | wc -l)"
run "$D" bash setup-mailserver.sh --update -y
check "Update: Exit-Code 0" test "$RC" -eq 0
check "Update: Mailserver wird neu gestartet (neue Relay-/Absender-Einstellungen gelten sofort)" has "$D/stub.args" "docker compose restart mailserver"
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

# ---------------------------------------------------------------- 5b. Aufräumen beim Anbieter
title "5b. Aufräumen beim Anbieter (Posteingang, Spam, Papierkorb je Anbieter)"
D="$(new_instance clean)"
for u in anna ben clara; do mkdir -p "$D/data/mail-data/home.lan/$u/cur"; echo "Message-ID: <$u@x>" > "$D/data/mail-data/home.lan/$u/cur/1"; done
cat > "$D/accounts.conf" <<'EOF'
CLEAN_INBOX=gmx,yahoo
CLEAN_SPAM=alle
CLEAN_TRASH=gmail
CLEAN_DAYS=7
anna@gmail.com|abcdabcdabcdabcd|anna
ben@gmx.at|GmxSecret99|ben
clara@yahoo.com|qrstuvwxyzabcdef|clara
dora@gmx.de|DoraSecret1|dora
EOF
run "$D" bash setup-mailserver.sh --cleanup --dry-run
check "Aufräumen: Probelauf endet mit Exit-Code 0" test "$RC" -eq 0
check "Aufräumen: Probelauf ist als solcher gekennzeichnet" has "$D/out" "PROBELAUF"
check "Aufräumen: Konto ohne lokale Mails wird übersprungen" bash -c "grep -q 'dora@gmx.de' '$D/out' && grep -A1 'dora@gmx.de' '$D/out' | grep -q 'übersprungen'"
check "Aufräumen: ein Container je Konto mit lokalen Mails" test "$(ls "$D"/stub.cleanup.* 2>/dev/null | wc -l)" -eq 3
cl() { grep -l "^CL_USER=$1" "$D"/stub.cleanup.* | head -n1; }
check "Aufräumen: Gmail nur Papierkorb und Spam" bash -c "f=\"$(cl anna@gmail.com)\"; grep -qx 'CL_TRASH=1' \"\$f\" && grep -qx 'CL_SPAM=1' \"\$f\" && grep -qx 'CL_INBOX=0' \"\$f\""
check "Aufräumen: GMX (gmx.at): Posteingang und Spam, kein Papierkorb" bash -c "f=\"$(cl ben@gmx.at)\"; grep -qx 'CL_INBOX=1' \"\$f\" && grep -qx 'CL_SPAM=1' \"\$f\" && grep -qx 'CL_TRASH=0' \"\$f\" && grep -qx 'CL_HOST=imap.gmx.net' \"\$f\""
check "Aufräumen: Yahoo: Posteingang und Spam" bash -c "f=\"$(cl clara@yahoo.com)\"; grep -qx 'CL_INBOX=1' \"\$f\" && grep -qx 'CL_HOST=imap.mail.yahoo.com' \"\$f\""
check "Aufräumen: Probelauf und Altersgrenze kommen an" bash -c "f=\"$(cl anna@gmail.com)\"; grep -qx 'CL_DRY=1' \"\$f\" && grep -qx 'CL_DAYS=7' \"\$f\""
check "Aufräumen: Passwörter stehen nie in Docker-Argumenten" bash -c "! grep -qE 'GmxSecret99|abcdabcdabcdabcd|qrstuvwxyzabcdef' '$D/stub.args'"
check "Aufräumen: Passwort kommt trotzdem im Container an" bash -c "grep -qx 'CL_PASSLEN=11' \"$(cl ben@gmx.at)\""
rm -f "$D"/stub.cleanup.*
run "$D" bash setup-mailserver.sh --cleanup
check "Aufräumen: echter Lauf ohne Probelauf" bash -c "grep -qx 'CL_DRY=0' \"$(cl clara@yahoo.com)\""
# Gmail-Posteingang erst nach abgeschlossenem Import
sed -i 's/^CLEAN_INBOX=.*/CLEAN_INBOX=gmail/' "$D/accounts.conf"
rm -f "$D"/stub.cleanup.*
run "$D" bash setup-mailserver.sh --cleanup
check "Gmail-Posteingang: ohne abgeschlossenen Import übersprungen" bash -c "grep -q 'Import nicht abgeschlossen' '$D/out' && grep -qx 'CL_INBOX=0' \"$(cl anna@gmail.com)\""
mkdir -p "$D/data/import-done"; : > "$D/data/import-done/anna@home.lan.done"
rm -f "$D"/stub.cleanup.*
run "$D" bash setup-mailserver.sh --cleanup
check "Gmail-Posteingang: nach abgeschlossenem Import freigegeben" bash -c "grep -qx 'CL_INBOX=1' \"$(cl anna@gmail.com)\""
rm -f "$D"/stub.cleanup.*
run "$D" bash setup-mailserver.sh --empty-trash
check "--empty-trash leert den Papierkorb bei allen Anbietern" bash -c "[[ \$(grep -l '^CL_TRASH=1' '$D'/stub.cleanup.* | wc -l) -eq 3 ]]"
printf '%s\n' 'anna@gmail.com|abcdabcdabcdabcd|anna' > "$D/accounts.conf"
rm -f "$D"/stub.cleanup.*
run "$D" bash setup-mailserver.sh --cleanup
check "Ohne Einstellung wird nichts aufgeräumt" bash -c "has() { grep -qF \"\$2\" \"\$1\"; }; has '$D/out' 'Nichts zu tun' && ! ls '$D'/stub.cleanup.* >/dev/null 2>&1"
printf '%s\n' 'CLEAN_TRASH=hotmail' 'anna@gmail.com|abcdabcdabcdabcd|anna' > "$D/accounts.conf"
run "$D" bash setup-mailserver.sh --cleanup
check "Unbekannter Anbieter in CLEAN_TRASH wird abgelehnt" bash -c "[[ $RC -ne 0 ]] && grep -q 'kein Anbieter' '$D/out'"
printf '%s\n' 'GMAIL_EMPTY_TRASH=1' 'GMAIL_TRASH_DAYS=30' 'anna@gmail.com|abcdabcdabcdabcd|anna' > "$D/accounts.conf"
rm -f "$D"/stub.cleanup.*
run "$D" bash setup-mailserver.sh --cleanup
check "Ältere GMAIL_EMPTY_TRASH-Einstellung funktioniert weiter" bash -c "f=\"$(cl anna@gmail.com)\"; grep -qx 'CL_TRASH=1' \"\$f\" && grep -qx 'CL_DAYS=30' \"\$f\""
check "cleanup.py ist gültiges Python" python3 -I -m py_compile "$ROOT/cleanup.py"
check "cleanup.py: Tests mit nachgebautem IMAP-Server" python3 -I "$ROOT/tests/test_cleanup.py"

# ---------------------------------------------------------------- 5c. USB-Backup
title "5c. usb-backup.sh (USB-Datenträger als Backup-Ziel)"
D="$(new_instance usb)"; mkdir -p "$D/cron" "$D/logrotate" "$D/mnt"; : > "$D/fstab"
usb() { run "$D" env USBDISKS_LSBLK_JSON="$ROOT/tests/fixtures/lsblk.json" BACKUP_MOUNT="$D/mnt/mail-backup" FSTAB="$D/fstab" BACKUP_LOG="$D/backup.log" bash usb-backup.sh "$@"; }
usb --list
check "--list zeigt die Sticks" bash -c "grep -q '/dev/sdb1' '$D/out' && grep -q '/dev/sdb2' '$D/out' && grep -q '/dev/sdc' '$D/out'"
check "--list zeigt weder Systemplatte noch interne Platte noch Boot-Stick" bash -c "! grep -qE 'nvme0n1|/dev/sda|/dev/sdd' '$D/out'"
usb --setup /dev/sda1
check "interne Platte (/dev/sda1) wird abgelehnt" bash -c "[[ $RC -ne 0 ]] && grep -q 'kein geeigneter' '$D/out'"
usb --setup /dev/sdd1
check "USB-Stick mit dem laufenden System (/dev/sdd1) wird abgelehnt" bash -c "[[ $RC -ne 0 ]] && grep -q 'kein geeigneter' '$D/out'"
usb --setup '/dev/sdb1; rm -rf /'
check "ungültiger Gerätename wird abgelehnt" bash -c "[[ $RC -ne 0 ]] && grep -q 'ungültig' '$D/out'"
usb --setup /dev/sdb2
check "NTFS-Stick ohne --format wird abgelehnt, nichts formatiert" bash -c "[[ $RC -ne 0 ]] && grep -q 'ungeeignet' '$D/out' && ! grep -q '^mkfs' '$D/stub.usb' 2>/dev/null"
usb --setup /dev/sdb1 --keep-days 5
check "vorhandenes ext4: Einrichtung ohne Formatieren" bash -c "[[ $RC -eq 0 ]] && ! grep -q '^mkfs' '$D/stub.usb'"
check "automatisch eingehängter Stick wird zuerst ausgehängt" has "$D/stub.usb" "umount /media/roland/MAILBACKUP"
check "fstab: UUID, Einhängepunkt, nofail" bash -c "grep -qE '^UUID=1111-2222-aaaa $D/mnt/mail-backup ext4 defaults,nofail,noatime 0 2 # mail-backup' '$D/fstab'"
check "Stick wird eingehängt" has "$D/stub.usb" "mount $D/mnt/mail-backup"
check "Backup-Cron mit Einhängepunkt, REQUIRE_MOUNT und Aufbewahrung" bash -c "grep -q 'REQUIRE_MOUNT=1' '$D/cron/mail-backup' && grep -q 'KEEP_DAYS=5' '$D/cron/mail-backup' && grep -qF \"'$D/mnt/mail-backup'\" '$D/cron/mail-backup'"
check "Einhängepunkt hat Rechte 700" perm "$D/mnt/mail-backup" 700
usb --setup /dev/sdc --format
check "--format legt ext4 mit Namen an" bash -c "[[ $RC -eq 0 ]] && grep -qx 'mkfs.ext4 -F -L MAILBACKUP /dev/sdc' '$D/stub.usb'"
check "fstab enthält genau einen Backup-Eintrag (der alte wird ersetzt)" test "$(grep -c '# mail-backup' "$D/fstab")" -eq 1
usb --setup /dev/sdb1 --first-run
check "--first-run startet die erste Sicherung" has "$D/out" "Erste Sicherung starten"
usb --remove
check "--remove entfernt Cron und fstab-Eintrag" bash -c "[[ ! -e '$D/cron/mail-backup' ]] && ! grep -q 'mail-backup' '$D/fstab'"
check "usbdisks.py ist gültiges Python" python3 -I -m py_compile "$ROOT/usbdisks.py"

# ---------------------------------------------------------------- 5d. Tailscale
title "5d. tailscale-setup.sh (Tailscale einrichten, Anmeldelink ausgeben)"
D="$(new_instance ts)"
echo out > "$D/ts-state"
tsrun() { run "$D" env STUB_TS_STATE="$D/ts-state" bash tailscale-setup.sh "$@"; }
tsrun --ssh --timeout 120
check "Tailscale: Anmeldelink wird ausgegeben" has "$D/out" "https://login.tailscale.com/a/abc123XYZ"
check "Tailscale: mit SSH und der gewünschten Wartezeit angemeldet" has "$D/stub.ts" "tailscale up --timeout=120s --ssh"
check "Tailscale: IP und Name am Ende der Ausgabe" bash -c "grep -qx 'Tailscale-IP: 100.64.1.2' '$D/out' && grep -qx 'Tailscale-Name: testserver.tail1234.ts.net' '$D/out'"
: > "$D/stub.ts"
tsrun --ssh
check "Tailscale: bereits angemeldet, kein erneutes 'up'" bash -c "[[ $RC -eq 0 ]] && ! grep -q 'tailscale up' '$D/stub.ts' && grep -q 'Tailscale-IP' '$D/out'"
check "Tailscale: bei bestehender Anmeldung wird SSH nachträglich eingeschaltet" has "$D/stub.ts" "tailscale set --ssh=true"
tsrun --timeout abc
check "Tailscale: ungültige Wartezeit wird abgelehnt" bash -c "[[ $RC -ne 0 ]] && grep -q 'Zahl' '$D/out'"
check "tailscale-setup.sh und mcp/install.sh: Syntax" bash -c "bash -n '$ROOT/tailscale-setup.sh' && bash -n '$ROOT/mcp/install.sh'"

# ---------------------------------------------------------------- 5e. Umstellung Cloudflare -> Tailscale
title "5e. migrate-to-tailscale.sh (Cloudflare -> Tailscale ohne Mailverlust)"
D="$(new_instance mig)"; echo out > "$D/ts-state"
cat > "$D/accounts.conf" <<'EOF'
DOMAIN=example.at
CF_API_TOKEN=AAAAAAAAAAAAAAAAAAAAAAAA
LE_EMAIL=me@example.at
CF_TUNNEL_TOKEN=BBBBBBBBBBBBBBBBBBBBBBBB
DDNS=1
WEBMAIL_BIND=0.0.0.0
anna@gmail.com|abcdabcdabcdabcd|anna
EOF
run "$D" bash setup-mailserver.sh -y
check "Ausgangslage: Cloudflare-Tunnel und DDNS stehen in der Compose-Datei" bash -c "grep -q 'cloudflared:' '$D/docker-compose.yml' && grep -q 'ddns:' '$D/docker-compose.yml' && [[ -f '$D/data/cloudflare.ini' && -f '$D/cron/mailserver-certbot' ]]"
mkdir -p "$D/data/mail-data/example.at/anna/cur"; for i in 1 2 3; do echo "mail $i" > "$D/data/mail-data/example.at/anna/cur/$i"; done
mig() { run "$D" env STUB_TS_STATE="$D/ts-state" bash migrate-to-tailscale.sh "${MIGARGS[@]}"; }
MIGARGS=(--dry-run); mig
check "Umstellung, Probelauf: nichts wird verändert" bash -c "[[ $RC -eq 0 ]] && grep -q 'Probelauf beendet' '$D/out' && grep -q '^CF_API_TOKEN=' '$D/accounts.conf' && ! ls '$D'/config-backup/vor-tailscale-* >/dev/null 2>&1 && ! grep -q 'tailscale up' '$D/stub.ts' 2>/dev/null"
check "Umstellung, Probelauf: nennt die Mail-Domain als unverändert und zählt die Mails" bash -c "grep -q 'example.at.*unverändert' '$D/out' && grep -q 'Mails (Dateien):   3' '$D/out'"
MIGARGS=(-y --no-backup); run "$D" env STUB_TS_STATE="$D/ts-state" STUB_TS_FAIL=1 bash migrate-to-tailscale.sh "${MIGARGS[@]}"
check "Tailscale schlägt fehl: Abbruch, Cloudflare und Konfiguration bleiben unverändert" bash -c "[[ $RC -ne 0 ]] && grep -q 'NICHTS' '$D/out' && grep -q '^CF_API_TOKEN=' '$D/accounts.conf' && grep -q 'cloudflared:' '$D/docker-compose.yml'"
run "$D" env STUB_TS_STATE="$D/ts-state" bash -c "bash migrate-to-tailscale.sh --no-backup </dev/null"
check "Umstellung ohne Terminal und ohne -y wird nicht ungefragt ausgeführt" bash -c "[[ $RC -ne 0 ]] && grep -q '^CF_API_TOKEN=' '$D/accounts.conf'"
mig
check "Umstellung: Exit-Code 0" test "$RC" -eq 0
check "Umstellung: Mails sind unverändert (Anzahl und Inhalt)" bash -c "[[ \$(find '$D/data/mail-data' -type f | wc -l) -eq 3 ]] && [[ \"\$(cat '$D/data/mail-data/example.at/anna/cur/2')\" == 'mail 2' ]] && grep -q 'Mails vorher: 3   nachher: 3' '$D/out'"
check "Umstellung: DOMAIN bleibt (damit bleiben Adressen und Postfach-Ordner)" has "$D/accounts.conf" "DOMAIN=example.at"
check "Umstellung: Cloudflare-Einträge sind aus accounts.conf entfernt" bash -c "! grep -qE '^(CF_API_TOKEN|LE_EMAIL|CF_TUNNEL_TOKEN|DDNS)=' '$D/accounts.conf'"
check "Umstellung: Webmail lauscht nur lokal" has "$D/accounts.conf" "WEBMAIL_BIND=127.0.0.1"
check "Umstellung: Tunnel und DDNS sind aus der Compose-Datei, Token nicht mehr in .env" bash -c "! grep -qE 'cloudflared:|ddns:' '$D/docker-compose.yml' && ! grep -q 'CF_' '$D/.env' && ! grep -qE 'AAAAAAAA|BBBBBBBB' '$D/docker-compose.yml' '$D/.env'"
check "Umstellung: Token-Datei und Zertifikats-Cron sind gelöscht" bash -c "[[ ! -e '$D/data/cloudflare.ini' && ! -e '$D/cron/mailserver-certbot' ]]"
check "Umstellung: veraltete Cloudflare-Container werden entfernt (--remove-orphans)" has "$D/stub.args" "docker compose up -d --remove-orphans"
check "Umstellung: Tailscale mit SSH angemeldet und Webmail im Tailnet freigegeben" bash -c "grep -q 'tailscale up .*--ssh' '$D/stub.ts' && grep -q 'tailscale serve --bg --https=443 http://127.0.0.1:8080' '$D/stub.ts'"
check "Umstellung: alte accounts.conf liegt gesichert (600) mit den Cloudflare-Einträgen" bash -c "f=\$(ls '$D'/accounts.conf.bak-* | head -n1); [[ \$(stat -c %a \"\$f\") == 600 ]] && grep -q '^CF_API_TOKEN=' \"\$f\""
check "Umstellung: alte Konfiguration liegt in config-backup/vor-tailscale-*" bash -c "grep -q 'cloudflared:' '$D'/config-backup/vor-tailscale-*/docker-compose.yml"
check "Umstellung: selbst signiertes Zertifikat für mail.<Domain> ist da" test -f "$D/data/certs/cert.pem"
MIGARGS=(-y --no-backup --dry-run); mig
check "Zweiter Aufruf: erkennt, dass Cloudflare schon weg ist" has "$D/out" "keine Einträge mehr in accounts.conf"
check "migrate-to-tailscale.sh: Syntax" bash -n "$ROOT/migrate-to-tailscale.sh"

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

# ---------------------------------------------------------------- 7b. Wiederherstellung
title "7b. restore-mail.sh (Backup wiederherstellen)"
if command -v rsync >/dev/null; then
  D="$(new_instance restore)"; B="$W/restore-backup"; SN="$B/daily/2026-10-01_033000"
  mkdir -p "$SN/data/mail-data/home.lan/anna/cur" "$SN/data/mail-data/home.lan/ben/cur" "$SN/data/config" "$B/monthly"
  echo "alte mail anna" > "$SN/data/mail-data/home.lan/anna/cur/1"; echo "mail ben" > "$SN/data/mail-data/home.lan/ben/cur/1"
  echo "anna@home.lan|x" > "$SN/data/config/postfix-accounts.cf"; echo "WEBMAIL_PORT=8081" > "$SN/accounts.conf"
  ln -sfn "$SN" "$B/latest"
  mkdir -p "$D/data/mail-data/home.lan/anna/cur" "$D/data/mail-data/home.lan/ben/cur"
  echo "kaputt" > "$D/data/mail-data/home.lan/anna/cur/1"; echo "nur-jetzt" > "$D/data/mail-data/home.lan/anna/cur/2"
  echo "ben aktuell" > "$D/data/mail-data/home.lan/ben/cur/1"; echo "WEBMAIL_PORT=9999" > "$D/accounts.conf"
  AN="$D/data/mail-data/home.lan/anna/cur"; BN="$D/data/mail-data/home.lan/ben/cur"
  run "$D" bash restore-mail.sh --list "$B"
  check "--list zeigt den Snapshot und markiert den neuesten" bash -c "grep -q 'daily/2026-10-01_033000' '$D/out' && grep -q 'neuester' '$D/out'"
  run "$D" bash restore-mail.sh --mailbox anna@home.lan --from "$B" --dry-run
  check "Probelauf: nichts wird verändert" bash -c "[[ $RC -eq 0 ]] && [[ \"\$(cat '$AN/1')\" == kaputt ]] && ! ls '$D'/data/vor-restore-* >/dev/null 2>&1"
  run "$D" bash -c "bash restore-mail.sh --mailbox anna@home.lan --from '$B' </dev/null"
  check "Ohne Terminal und ohne -y wird nicht ungefragt überschrieben" bash -c "[[ $RC -ne 0 ]] && grep -q -- '-y' '$D/out' && [[ \"\$(cat '$AN/1')\" == kaputt ]]"
  run "$D" bash restore-mail.sh --mailbox anna@home.lan --from "$B" -y
  check "Postfach: Datei kommt aus dem Backup zurück" bash -c "[[ $RC -eq 0 ]] && [[ \"\$(cat '$AN/1')\" == 'alte mail anna' ]]"
  check "Postfach: Datei, die nur im jetzigen Stand lag, ist weg" test ! -e "$AN/2"
  check "Postfach: anderes Postfach bleibt unberührt" bash -c "[[ \"\$(cat '$BN/1')\" == 'ben aktuell' ]]"
  check "Postfach: jetziger Stand ist gesichert (geänderte und gelöschte Datei)" bash -c "[[ \"\$(cat '$D'/data/vor-restore-*/cur/2)\" == nur-jetzt ]] && [[ \"\$(cat '$D'/data/vor-restore-*/cur/1)\" == kaputt ]]"
  check "Mailserver wird angehalten, wieder gestartet und der Index neu aufgebaut" bash -c "grep -q 'docker compose stop mailserver' '$D/stub.args' && grep -q 'docker compose up -d' '$D/stub.args' && grep -q 'doveadm force-resync -u anna@home.lan' '$D/stub.args'"
  run "$D" bash restore-mail.sh --mailbox anna@home.lan --from "$B" --snapshot ../../etc -y
  check "Ungültiger Snapshot-Name wird abgelehnt" bash -c "[[ $RC -ne 0 ]] && grep -q 'Ungültiger Snapshot' '$D/out'"
  run "$D" bash restore-mail.sh --mailbox anna@home.lan --from "$B" --snapshot daily/2020-01-01_000000 -y
  check "Unbekannter Snapshot wird abgelehnt" bash -c "[[ $RC -ne 0 ]] && grep -q 'nicht gefunden' '$D/out'"
  run "$D" bash restore-mail.sh --mailbox ../../x@home.lan --from "$B" -y
  check "Manipulierte Adresse wird abgelehnt" bash -c "[[ $RC -ne 0 ]] && grep -q 'Ungültige Adresse' '$D/out'"
  run "$D" bash restore-mail.sh --mailbox carla@home.lan --from "$B" -y
  check "Postfach, das im Snapshot fehlt, wird abgelehnt" bash -c "[[ $RC -ne 0 ]] && grep -q 'gibt es in diesem Snapshot nicht' '$D/out'"
  run "$D" bash restore-mail.sh --all --from "$W/gibt-es-nicht" -y
  check "Fehlender Backup-Ordner wird gemeldet" bash -c "[[ $RC -ne 0 ]] && grep -q 'kein Backup' '$D/out'"
  echo "kaputt2" > "$BN/1"
  run "$D" bash restore-mail.sh --all --from "$B" -y
  check "Alles: Postfächer, Konfiguration und accounts.conf kommen zurück" bash -c "[[ $RC -eq 0 ]] && [[ \"\$(cat '$BN/1')\" == 'mail ben' ]] && [[ \"\$(cat '$D/accounts.conf')\" == 'WEBMAIL_PORT=8081' ]] && [[ -f '$D/data/config/postfix-accounts.cf' ]]"
  check "Alles: accounts.conf hat Rechte 600, die alte liegt in der Sicherung" bash -c "[[ \$(stat -c %a '$D/accounts.conf') == 600 ]] && grep -rq 'WEBMAIL_PORT=9999' '$D'/data/vor-restore-*/accounts.conf"
  check "Alles: Index wird für die Konten der Konfiguration neu aufgebaut" has "$D/stub.args" "doveadm force-resync -u anna@home.lan"
  check "restore-mail.sh: Syntax" bash -n "$ROOT/restore-mail.sh"
  # --- Konfigurationssicherung (config-backup/)
  D2="$(new_instance restorecfg)"; CBD="$D2/config-backup"
  for s in 20261001_100000 20261009_210934; do mkdir -p "$CBD/$s/config" "$CBD/$s/roundcube-config"; done
  echo "alt-compose" > "$CBD/20261001_100000/docker-compose.yml"; echo "FETCHMAIL=0" > "$CBD/20261001_100000/.env"
  echo "anna@home.lan|alt" > "$CBD/20261001_100000/config/postfix-accounts.cf"; echo "alt" > "$CBD/20261001_100000/roundcube-config/custom.inc.php"
  echo "neu-compose" > "$CBD/20261009_210934/docker-compose.yml"; echo "FETCHMAIL=1" > "$CBD/20261009_210934/.env"
  echo "anna@home.lan|neu" > "$CBD/20261009_210934/config/postfix-accounts.cf"; echo "neu" > "$CBD/20261009_210934/roundcube-config/custom.inc.php"
  mkdir -p "$D2/data/config" "$D2/data/roundcube/config"
  echo "jetzt-compose" > "$D2/docker-compose.yml"; echo "FETCHMAIL=9" > "$D2/.env"
  echo "anna@home.lan|jetzt" > "$D2/data/config/postfix-accounts.cf"; echo "x" > "$D2/data/config/nur-jetzt.cf"; echo "jetzt" > "$D2/data/roundcube/config/custom.inc.php"
  run "$D2" bash restore-mail.sh --list-config
  check "--list-config zeigt beide Sicherungen mit Inhalt" bash -c "grep -q '20261001_100000' '$D2/out' && grep -q '20261009_210934' '$D2/out' && grep -q 'roundcube-config' '$D2/out'"
  run "$D2" bash restore-mail.sh --config --dry-run
  check "Konfiguration, Probelauf: nichts wird verändert" bash -c "[[ $RC -eq 0 ]] && [[ \"\$(cat '$D2/docker-compose.yml')\" == jetzt-compose ]] && [[ -e '$D2/data/config/nur-jetzt.cf' ]] && ! ls '$CBD'/vor-restore-* >/dev/null 2>&1"
  run "$D2" bash -c "bash restore-mail.sh --config </dev/null"
  check "Konfiguration: ohne Terminal und ohne -y wird nicht ungefragt überschrieben" bash -c "[[ $RC -ne 0 ]] && [[ \"\$(cat '$D2/docker-compose.yml')\" == jetzt-compose ]]"
  run "$D2" bash restore-mail.sh --config -y
  check "Konfiguration: neueste Sicherung wird wiederhergestellt" bash -c "[[ $RC -eq 0 ]] && [[ \"\$(cat '$D2/docker-compose.yml')\" == neu-compose ]] && [[ \"\$(cat '$D2/.env')\" == FETCHMAIL=1 ]] && [[ \"\$(cat '$D2/data/config/postfix-accounts.cf')\" == 'anna@home.lan|neu' ]] && [[ \"\$(cat '$D2/data/roundcube/config/custom.inc.php')\" == neu ]]"
  check "Konfiguration: Dateien, die es in der Sicherung nicht gab, sind weg" test ! -e "$D2/data/config/nur-jetzt.cf"
  check "Konfiguration: der jetzige Stand ist vorher gesichert" bash -c "[[ \"\$(cat '$CBD'/vor-restore-*/docker-compose.yml)\" == jetzt-compose ]] && ls '$CBD'/vor-restore-*/config/nur-jetzt.cf >/dev/null"
  check "Konfiguration: Container werden angehalten, gestartet und der Mailserver neu gestartet" bash -c "grep -q 'docker compose stop' '$D2/stub.args' && grep -q 'docker compose up -d' '$D2/stub.args' && grep -q 'docker compose restart mailserver' '$D2/stub.args'"
  run "$D2" bash restore-mail.sh --config 20261001_100000 -y
  check "Konfiguration: bestimmte ältere Sicherung wählbar" bash -c "[[ $RC -eq 0 ]] && [[ \"\$(cat '$D2/docker-compose.yml')\" == alt-compose ]]"
  check "Konfiguration: zwei Wiederherstellungen hintereinander sichern getrennt" test "$(ls -d "$CBD"/vor-restore-* | wc -l)" -eq 2
  run "$D2" bash restore-mail.sh --config -y
  check "Konfiguration: 'neueste' ignoriert die Sicherungen vor einer Wiederherstellung" bash -c "[[ \"\$(cat '$D2/docker-compose.yml')\" == neu-compose ]]"
  run "$D2" bash restore-mail.sh --config ../etc -y
  check "Konfiguration: ungültiger Name wird abgelehnt" bash -c "[[ $RC -ne 0 ]] && grep -q 'Ungültiger Name' '$D2/out'"
  run "$D2" bash restore-mail.sh --config 20200101_000000 -y
  check "Konfiguration: unbekannte Sicherung wird abgelehnt" bash -c "[[ $RC -ne 0 ]] && grep -q 'nicht gefunden' '$D2/out'"
else
  skip "rsync fehlt: Wiederherstellungs-Tests"
fi

# ---------------------------------------------------------------- 7c. get.sh erkennt vorhandene Installationen
title "7c. get.sh: vorhandene Installation erkennen"
G="$W/getsh"; mkdir -p "$G/opt/mailserver" "$G/home/roland/mailserver" "$G/home/anna" "$G/leer"
touch "$G/home/roland/mailserver/setup-mailserver.sh" "$G/home/roland/mailserver/accounts.conf"
detect() { ( cd "$G/leer" && env GET_SH_DETECT_ONLY=1 MAILSERVER_SEARCH="$G/opt/mailserver $G/home/*/mailserver $G/home/*" "$@" bash "$ROOT/get.sh" 2>&1 ); }
OUT="$(detect)"
check "get.sh findet die vorhandene Installation unter home/roland/mailserver" bash -c "[[ \"$OUT\" == *'Vorhandene Installation gefunden: $G/home/roland/mailserver'* ]] && [[ \"\$(tail -n1 <<<\"$OUT\")\" == '$G/home/roland/mailserver' ]]"
check "get.sh: MAILSERVER_DIR hat Vorrang" test "$(detect MAILSERVER_DIR=/srv/anderswo | tail -n1)" = "/srv/anderswo"
touch "$G/opt/mailserver/setup-mailserver.sh" "$G/opt/mailserver/docker-compose.yml"
OUT="$(detect || true)"
check "get.sh: mehrere Installationen werden gemeldet, nichts wird geraten" bash -c "[[ \"$OUT\" == *'Mehrere vorhandene Installationen'* && \"$OUT\" == *'$G/opt/mailserver'* && \"$OUT\" == *'$G/home/roland/mailserver'* ]]"
rm -rf "$G/opt/mailserver" "$G/home/roland"
check "get.sh: ohne vorhandene Installation gilt /opt/mailserver" test "$(detect | tail -n1)" = "/opt/mailserver"
mkdir -p "$G/home/anna/mail2"; touch "$G/home/anna/setup-mailserver.sh"   # Skript ohne accounts.conf/docker-compose.yml zählt nicht
check "get.sh: Ordner ohne Konfiguration zählt nicht als Installation" test "$(detect | tail -n1)" = "/opt/mailserver"
touch "$G/home/anna/accounts.conf"
check "get.sh: Installation direkt in /home/<benutzer> wird erkannt" test "$(detect | tail -n1)" = "$G/home/anna"
check "get.sh: Syntax" bash -n "$ROOT/get.sh"

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
