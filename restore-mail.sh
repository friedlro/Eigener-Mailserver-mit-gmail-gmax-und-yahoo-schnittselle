#!/usr/bin/env bash
# restore-mail.sh - stellt Mails und Einstellungen aus einem Backup von backup-mail.sh wieder her
#
# Nutzung:
#   sudo ./restore-mail.sh --list [ZIEL]                          Snapshots anzeigen
#   sudo ./restore-mail.sh --mailbox anna@home.lan [OPTIONEN]     ein Postfach wiederherstellen
#   sudo ./restore-mail.sh --all [OPTIONEN]                       alles: Mails, Konfiguration, Webmail-Daten, accounts.conf, .env
#
# Optionen:
#   --from ZIEL        Backup-Ordner (Standard: aus dem Cron-Job, sonst /mnt/mail-backup)
#   --snapshot NAME    daily/2026-10-09_033001, monthly/2026-10 oder nur der Name (Standard: latest = neuester)
#   --dry-run          nur anzeigen, was sich ändern würde
#   -y                 ohne Rückfrage (sonst muss WIEDERHERSTELLEN eingetippt werden)
#
# Schutz: Vor dem Überschreiben wird der aktuelle Stand in data/vor-restore-<Zeit>/ gesichert (geänderte und gelöschte Dateien),
# der Mailserver wird für die Dauer angehalten, danach gestartet und der Index neu aufgebaut (doveadm force-resync).
# Das Backup selbst wird nie verändert.

set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
BASE="$(dirname "$SELF")"
[[ $EUID -eq 0 ]] || exec sudo -E bash "$SELF" "$@"
cd "$BASE"

CRON_DIR="${CRON_DIR:-/etc/cron.d}"
die()  { echo "Fehler: $*" >&2; exit 1; }
say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

MODE=""; MAILBOX=""; FROM=""; SNAP="latest"; DRY=0; YES=0
while (( $# )); do
  case "$1" in
    --list) MODE="list" ;;
    --mailbox) MODE="mailbox"; MAILBOX="${2:-}"; shift ;;
    --all) MODE="all" ;;
    --from) FROM="${2:-}"; shift ;;
    --snapshot) SNAP="${2:-}"; shift ;;
    --dry-run) DRY=1 ;;
    -y) YES=1 ;;
    -h|--help) sed -n '2,/^$/p' "$SELF"; exit 0 ;;
    -*) die "Unbekannte Option: $1 (siehe --help)" ;;
    *) [[ "$MODE" == "list" && -z "$FROM" ]] && FROM="$1" || die "Unerwartetes Argument: $1" ;;
  esac
  shift
done
[[ -n "$MODE" ]] || die "Aktion fehlt (--list, --mailbox ADRESSE oder --all). Siehe --help."

# Backup-Ordner: Angabe, sonst aus dem Cron-Job von backup-mail.sh, sonst /mnt/mail-backup
if [[ -z "$FROM" && -f "$CRON_DIR/mail-backup" ]]; then
  FROM="$(sed -n "s/.*backup-mail\.sh' '\([^']*\)'.*/\1/p" "$CRON_DIR/mail-backup" | head -n 1)"
fi
FROM="${FROM:-/mnt/mail-backup}"
[[ "$FROM" == /* ]] || die "Der Backup-Ordner muss ein absoluter Pfad sein (ist: $FROM)."
[[ -d "$FROM/daily" ]] || die "In $FROM gibt es kein Backup (Ordner daily/ fehlt). Ist der Stick eingehängt? Mit --from ORDNER angeben."
FROM="$(readlink -f "$FROM")"

if [[ "$MODE" == "list" ]]; then
  say "Snapshots in $FROM"
  NEWEST="$(readlink -f "$FROM/latest" 2>/dev/null || true)"
  found=0
  for d in "$FROM"/daily/* "$FROM"/monthly/*; do
    [[ -d "$d" && "$d" != *.partial ]] || continue
    found=1
    printf '  %-28s %s\n' "$(basename "$(dirname "$d")")/$(basename "$d")" "$([[ "$(readlink -f "$d")" == "$NEWEST" ]] && echo '<- neuester (latest)')"
  done
  (( found )) || echo "  (keine Snapshots gefunden)"
  exit 0
fi

# ---------------------------------------------------------------- Snapshot bestimmen
if [[ "$SNAP" == "latest" ]]; then
  SRC="$(readlink -f "$FROM/latest" 2>/dev/null || true)"
  [[ -d "$SRC" ]] || die "Kein 'latest' im Backup gefunden. Snapshot mit --snapshot angeben (siehe --list)."
else
  [[ "$SNAP" =~ ^((daily|monthly)/)?[0-9]{4}-[0-9]{2}(-[0-9]{2}_[0-9]{6})?$ ]] || die "Ungültiger Snapshot-Name: $SNAP (Beispiel: daily/2026-10-09_033001)."
  if [[ "$SNAP" == */* ]]; then SRC="$FROM/$SNAP"; else SRC="$FROM/daily/$SNAP"; [[ -d "$SRC" ]] || SRC="$FROM/monthly/$SNAP"; fi
  [[ -d "$SRC" ]] || die "Snapshot nicht gefunden: $SNAP (siehe --list)."
  SRC="$(readlink -f "$SRC")"
fi
[[ "$SRC" == "$FROM"/* ]] || die "Der Snapshot liegt nicht im Backup-Ordner."
[[ "$SRC" != *.partial ]] || die "Dieser Snapshot ist unfertig (.partial) und kann nicht verwendet werden."
[[ -d "$SRC/data" ]] || die "Der Snapshot enthält keinen Ordner data/ und sieht unvollständig aus: $SRC"

command -v rsync >/dev/null || { apt-get update -qq && apt-get install -y -qq rsync; }
STAMP="$(date +%Y%m%d-%H%M%S)"
SAFE="$BASE/data/vor-restore-$STAMP"

# ---------------------------------------------------------------- Umfang
if [[ "$MODE" == "mailbox" ]]; then
  [[ "$MAILBOX" =~ ^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+$ ]] || die "Ungültige Adresse: '$MAILBOX' (Beispiel: anna@home.lan)."
  U="${MAILBOX%@*}"; D="${MAILBOX#*@}"
  [[ "$U" != *..* && "$D" != *..* && "$U" != .* && "$D" != .* ]] || die "Ungültige Adresse: $MAILBOX"
  REL="data/mail-data/$D/$U"
  [[ -d "$SRC/$REL" ]] || die "Das Postfach $MAILBOX gibt es in diesem Snapshot nicht ($REL)."
  DESC="Postfach $MAILBOX"
else
  DESC="alles (Mails, Konfiguration, Webmail-Daten, accounts.conf, .env, docker-compose.yml)"
fi

echo "Backup:   $SRC"
echo "Ziel:     $BASE"
echo "Umfang:   $DESC"
echo "Sicherung des jetzigen Stands: $SAFE"

RSYNC=(rsync -a --numeric-ids --delete --backup "--backup-dir=$SAFE")
(( ! DRY )) || RSYNC+=(--dry-run -i)

do_sync() {   # $1 = Quelle (Snapshot)  $2 = Ziel  [weitere rsync-Optionen]
  local s="$1" t="$2"; shift 2
  mkdir -p "$t"
  "${RSYNC[@]}" "$@" "$s/" "$t/"
}

if (( DRY )); then
  say "Probelauf: so würde sich der Stand ändern (es wird nichts verändert)"
  if [[ "$MODE" == "mailbox" ]]; then do_sync "$SRC/$REL" "$BASE/$REL" | head -n 200
  else do_sync "$SRC/data" "$BASE/data" --exclude 'vor-restore-*/' --exclude 'mail-logs/' | head -n 200; fi
  echo "(Ausgabe auf 200 Zeilen gekürzt)"
  exit 0
fi

if (( ! YES )); then
  [[ -t 0 ]] || die "Ohne Terminal bitte mit -y bestätigen (nach einem Probelauf mit --dry-run)."
  echo
  echo "ACHTUNG: Der jetzige Stand wird durch das Backup ersetzt. Mails, die nur im jetzigen Stand liegen, werden gelöscht"
  echo "(sie bleiben in $SAFE erhalten)."
  read -r -p "Zum Bestätigen WIEDERHERSTELLEN eintippen: " ans
  [[ "$ans" == "WIEDERHERSTELLEN" ]] || die "Abgebrochen. Es wurde nichts verändert."
fi

# ---------------------------------------------------------------- Wiederherstellen
say "Mailserver anhalten"
docker compose stop mailserver >/dev/null 2>&1 || echo "Hinweis: Der Mailserver ließ sich nicht anhalten (läuft er?)." >&2

restart() { docker compose up -d >/dev/null 2>&1 || docker compose start mailserver >/dev/null 2>&1 || true; }
trap restart EXIT   # der Mailserver wird auch bei einem Fehler wieder gestartet

mkdir -p "$SAFE"; chmod 700 "$SAFE"
if [[ "$MODE" == "mailbox" ]]; then
  say "Postfach $MAILBOX wiederherstellen"
  do_sync "$SRC/$REL" "$BASE/$REL"
else
  say "Daten, Konfiguration und Webmail wiederherstellen"
  do_sync "$SRC/data" "$BASE/data" --exclude 'vor-restore-*/' --exclude 'mail-logs/'
  for f in accounts.conf .env docker-compose.yml zugangsdaten.txt; do
    if [[ -f "$SRC/$f" ]]; then
      [[ ! -f "$BASE/$f" ]] || install -D -m 600 "$BASE/$f" "$SAFE/$f"
      install -m 600 "$SRC/$f" "$BASE/$f"
      echo "  $f"
    fi
  done
fi

say "Mailserver starten und Index neu aufbauen"
restart
trap - EXIT
ok=0
for _ in $(seq 1 40); do
  if docker exec mailserver supervisorctl status dovecot 2>/dev/null | grep -q RUNNING; then ok=1; break; fi
  sleep 3
done
(( ok )) || echo "Hinweis: Dovecot meldet sich nicht. Log ansehen: docker logs mailserver" >&2
if [[ "$MODE" == "mailbox" ]]; then
  docker exec mailserver doveadm force-resync -u "$MAILBOX" '*' || echo "Hinweis: Index für $MAILBOX nicht neu aufgebaut (docker logs mailserver)." >&2
elif [[ -f "$BASE/data/config/postfix-accounts.cf" ]]; then
  while IFS='|' read -r acct _; do
    [[ -n "$acct" ]] || continue
    docker exec mailserver doveadm force-resync -u "$acct" '*' || echo "Hinweis: Index für $acct nicht neu aufgebaut." >&2
  done < "$BASE/data/config/postfix-accounts.cf"
fi

say "Fertig"
echo "Wiederhergestellt aus: $SRC"
echo "Der Stand von vorher liegt in: $SAFE (nach der Kontrolle löschen: sudo rm -rf '$SAFE')"
