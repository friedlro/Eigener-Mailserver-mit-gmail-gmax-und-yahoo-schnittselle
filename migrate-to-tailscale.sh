#!/usr/bin/env bash
# migrate-to-tailscale.sh - stellt den Fernzugriff von Cloudflare (Domain, Let's Encrypt, DDNS, Tunnel) auf Tailscale um,
# ohne dass Mails verloren gehen.
#
# Nutzung:
#   sudo ./migrate-to-tailscale.sh --dry-run      ansehen, was sich ändern würde (ändert nichts)
#   sudo ./migrate-to-tailscale.sh                umstellen (mit Rückfrage)
#   Optionen: -y (ohne Rückfrage)  --no-ssh (Tailscale SSH nicht einschalten)  --no-serve (Webmail nicht per "tailscale serve" freigeben)
#             --no-backup (kein Backup vor der Umstellung)
#
# Was passiert, in dieser Reihenfolge:
#   1. Prüfung und Zählung der Mails (die Mails selbst werden NIE angefasst: data/mail-data bleibt unverändert).
#   2. Sicherung: accounts.conf.bak-<Zeit>, config-backup/vor-tailscale-<Zeit>, und das Backup-Skript läuft einmal, wenn es eingerichtet ist.
#   3. Tailscale einrichten (Anmeldelink im Terminal bestätigen). Schlägt das fehl, bleibt ALLES unverändert (Cloudflare läuft weiter).
#   4. Aus accounts.conf verschwinden CF_API_TOKEN, LE_EMAIL, CF_TUNNEL_TOKEN und DDNS. DOMAIN BLEIBT: Sie bestimmt die lokalen
#      Adressen (name@domain) und die Postfach-Ordner, sonst wären die Mails unter anderem Namen nicht mehr zu finden.
#   5. setup-mailserver.sh --update: neue Konfiguration, selbst signiertes Zertifikat, Cloudflare-Container (cloudflared, ddns) und
#      Token-Datei werden entfernt.
#   6. Webmail per "tailscale serve" nur im Tailnet über HTTPS (Webmail lauscht danach nur noch auf 127.0.0.1).
#   7. Kontrolle: Mails gezählt, Container laufen.
# Rückgängig: sudo ./restore-mail.sh --config vor-tailscale-<Zeit> (Konfiguration) und accounts.conf.bak-<Zeit> zurückkopieren.

set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
BASE="$(dirname "$SELF")"
[[ $EUID -eq 0 ]] || exec sudo -E bash "$SELF" "$@"
cd "$BASE"

CRON_DIR="${CRON_DIR:-/etc/cron.d}"
die() { echo "Fehler: $*" >&2; exit 1; }
say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

DRY=0; YES=0; SSH=1; SERVE=1; BACKUP=1
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    -y) YES=1 ;;
    --no-ssh) SSH=0 ;;
    --no-serve) SERVE=0 ;;
    --no-backup) BACKUP=0 ;;
    -h|--help) sed -n '2,/^$/p' "$SELF"; exit 0 ;;
    *) die "Unbekannte Option: $a (siehe --help)" ;;
  esac
done

CONF="$BASE/accounts.conf"
[[ -f "$CONF" ]] || die "accounts.conf fehlt in $BASE. Läuft hier eine Installation? (Ordner prüfen)"
[[ -f "$BASE/docker-compose.yml" ]] || die "docker-compose.yml fehlt in $BASE. Die Umstellung gilt für eine vorhandene Installation."
[[ -f "$BASE/setup-mailserver.sh" && -f "$BASE/tailscale-setup.sh" ]] || die "setup-mailserver.sh oder tailscale-setup.sh fehlt (Dateien mit get.sh aktualisieren)."

conf_val() { sed -n -E "s/^[[:space:]]*$1=(.*)$/\\1/p" "$CONF" | tail -n 1; }
CF_LINES='^[[:space:]]*(CF_API_TOKEN|LE_EMAIL|CF_TUNNEL_TOKEN|DDNS)='
HAS_CF=0; grep -qE "$CF_LINES" "$CONF" && HAS_CF=1
DOMAIN="$(conf_val DOMAIN)"
PORT="$(conf_val WEBMAIL_PORT)"; PORT="${PORT:-8080}"
[[ "$PORT" =~ ^[0-9]{1,5}$ ]] || die "WEBMAIL_PORT in accounts.conf ist ungültig: $PORT"

count_mails() { find "$BASE/data/mail-data" -type f \( -path '*/cur/*' -o -path '*/new/*' \) 2>/dev/null | wc -l; }
BEFORE="$(count_mails)"

echo "Ordner:            $BASE"
echo "Mail-Domain:       ${DOMAIN:-(keine, lokale Adressen @home.lan)}  -> bleibt unverändert"
echo "Mails (Dateien):   $BEFORE  -> data/mail-data wird nicht angefasst"
if (( HAS_CF )); then
  echo "Cloudflare-Einträge in accounts.conf, die entfernt werden:"
  grep -E "$CF_LINES" "$CONF" | sed -E 's/^([[:space:]]*[A-Z_]+)=.*/  \1=…/'
else
  echo "Cloudflare:        keine Einträge mehr in accounts.conf (nur Tailscale wird eingerichtet)"
fi
for c in cloudflared ddns; do
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$c"; then echo "Container, der entfernt wird: $c"; fi
done
[[ ! -f data/cloudflare.ini ]] || echo "Datei, die gelöscht wird:   data/cloudflare.ini (Cloudflare-Token)"
[[ ! -f "$CRON_DIR/mailserver-certbot" ]] || echo "Cron-Job, der entfernt wird: mailserver-certbot (Zertifikatserneuerung)"
echo "Webmail:           künftig nur im Tailnet: https://<name>.ts.net (über 'tailscale serve'), Port $PORT nur lokal"
echo "Zertifikat:        selbst signiert für mail.${DOMAIN:-home.lan} (Mailclients zeigen einmal eine Warnung)"

BACKUP_DEST=""
if [[ -f "$CRON_DIR/mail-backup" ]]; then
  BACKUP_DEST="$(sed -n "s/.*backup-mail\.sh' '\([^']*\)'.*/\1/p" "$CRON_DIR/mail-backup" | head -n 1)"
fi
if (( BACKUP )); then
  if [[ -n "$BACKUP_DEST" ]]; then echo "Backup vorher:     ja (backup-mail.sh nach $BACKUP_DEST)"
  else echo "Backup vorher:     NEIN (keins eingerichtet; die Mails bleiben trotzdem unverändert)"; fi
fi

if (( DRY )); then
  echo
  echo "Probelauf beendet: es wurde nichts verändert."
  exit 0
fi

if (( ! YES )); then
  [[ -t 0 ]] || die "Ohne Terminal bitte mit -y bestätigen (nach einem Probelauf mit --dry-run)."
  echo
  read -r -p "Zum Bestätigen UMSTELLEN eintippen: " ans
  [[ "$ans" == "UMSTELLEN" ]] || die "Abgebrochen. Es wurde nichts verändert."
fi

STAMP="$(date +%Y%m%d-%H%M%S)"

# ---------------------------------------------------------------- 2. Sicherung
say "Sicherung anlegen"
cp -p "$CONF" "$CONF.bak-$STAMP"; chmod 600 "$CONF.bak-$STAMP"
CBK="$BASE/config-backup/vor-tailscale-$STAMP"
mkdir -p "$CBK"
cp -a docker-compose.yml .env "$CBK/" 2>/dev/null || true
[[ ! -d data/config ]] || cp -a data/config "$CBK/config"
[[ ! -d data/roundcube/config ]] || cp -a data/roundcube/config "$CBK/roundcube-config"
chmod -R go-rwx "$BASE/config-backup"
echo "  accounts.conf.bak-$STAMP und config-backup/vor-tailscale-$STAMP"
if (( BACKUP )) && [[ -n "$BACKUP_DEST" && -f "$BASE/backup-mail.sh" ]]; then
  say "Backup der Mails vor der Umstellung (kann dauern)"
  if grep -q 'REQUIRE_MOUNT=1' "$CRON_DIR/mail-backup"; then export REQUIRE_MOUNT=1; fi
  bash "$BASE/backup-mail.sh" "$BACKUP_DEST" || die "Das Backup ist fehlgeschlagen. Die Umstellung wurde NICHT begonnen (nichts verändert)."
elif (( BACKUP )); then
  echo "Hinweis: Es ist kein Backup eingerichtet. Die Mails bleiben unverändert; ein Backup empfiehlt sich trotzdem (./usb-backup.sh --setup ...)." >&2
fi

# ---------------------------------------------------------------- 3. Tailscale
say "Tailscale einrichten (Anmeldelink im Browser bestätigen)"
TSOUT="$(mktemp)"; trap 'rm -f "$TSOUT"' EXIT
TS_ARGS=(--timeout 300); (( ! SSH )) || TS_ARGS+=(--ssh)
tsrc=0
bash "$BASE/tailscale-setup.sh" "${TS_ARGS[@]}" 2>&1 | tee "$TSOUT" || tsrc=${PIPESTATUS[0]}
if (( tsrc != 0 )) || ! grep -q '^Tailscale-IP: ' "$TSOUT"; then
  die "Tailscale ist nicht eingerichtet. Es wurde NICHTS an Cloudflare oder der Konfiguration verändert (alles läuft wie vorher)."
fi
TS_IP="$(sed -n 's/^Tailscale-IP: //p' "$TSOUT" | head -n 1)"
TS_NAME="$(sed -n 's/^Tailscale-Name: //p' "$TSOUT" | head -n 1)"

# ---------------------------------------------------------------- 6. Webmail im Tailnet (vor dem Umbau, damit es nie unerreichbar ist)
SERVE_OK=0
if (( SERVE )); then
  say "Webmail im Tailnet freigeben (tailscale serve)"
  if tailscale serve --bg --https=443 "http://127.0.0.1:$PORT"; then SERVE_OK=1
  else echo "Hinweis: 'tailscale serve' hat nicht geklappt (HTTPS im Tailnet aktivieren: https://tailscale.com/kb/1153/enabling-https). Webmail bleibt unter Port $PORT erreichbar." >&2; fi
fi

# ---------------------------------------------------------------- 4. accounts.conf umstellen
say "accounts.conf umstellen (DOMAIN bleibt)"
sed -E -i "/$CF_LINES/d" "$CONF"
if (( SERVE_OK )); then
  if grep -qE '^[[:space:]]*WEBMAIL_BIND=' "$CONF"; then sed -E -i 's/^[[:space:]]*WEBMAIL_BIND=.*/WEBMAIL_BIND=127.0.0.1/' "$CONF"
  else echo "WEBMAIL_BIND=127.0.0.1" >> "$CONF"; fi
fi
chmod 600 "$CONF"

# ---------------------------------------------------------------- 5. Neu konfigurieren
say "Konfiguration neu schreiben (setup-mailserver.sh --update)"
bash "$BASE/setup-mailserver.sh" --update -y

# ---------------------------------------------------------------- 7. Kontrolle
say "Kontrolle"
AFTER="$(count_mails)"
echo "  Mails vorher: $BEFORE   nachher: $AFTER"
if (( AFTER < BEFORE )); then
  echo "WARNUNG: Es sind weniger Mail-Dateien als vorher! Nichts weiter ändern und zurückholen mit: sudo ./restore-mail.sh --all" >&2
fi
for c in mailserver roundcube; do
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$c"; then echo "  $c läuft"; else echo "  WARNUNG: $c läuft nicht (docker logs $c)" >&2; fi
done
for c in cloudflared ddns; do
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$c"; then echo "  WARNUNG: $c existiert noch (entfernen: docker rm -f $c)" >&2; fi
done

say "Fertig"
echo "Server im Tailnet:  $TS_IP${TS_NAME:+  ($TS_NAME)}"
(( ! SERVE_OK )) || echo "Webmail:            https://${TS_NAME:-<Tailscale-Name>}"
echo "Mailclient (Thunderbird, Handy; Gerät muss im selben Tailnet sein):"
echo "  IMAP  ${TS_NAME:-$TS_IP}  Port 993 (SSL/TLS)    SMTP  ${TS_NAME:-$TS_IP}  Port 587 (STARTTLS)    Benutzername = komplette lokale Adresse"
echo "  Das Zertifikat ist selbst signiert: einmal als Ausnahme bestätigen."
echo
echo "Noch von Hand bei Cloudflare (nicht automatisierbar):"
echo "  - DNS-Einträge für mail.${DOMAIN:-deinedomain.at} und ggf. den Webmail-Hostnamen löschen"
echo "  - Tunnel löschen (Zero Trust > Networks > Tunnels) und den API-Token widerrufen (Mein Profil > API-Tokens)"
echo "  - Router: Portfreigaben für 993 und 587 entfernen"
echo "Rückgängig: sudo ./restore-mail.sh --config vor-tailscale-$STAMP  und  cp -p accounts.conf.bak-$STAMP accounts.conf"
