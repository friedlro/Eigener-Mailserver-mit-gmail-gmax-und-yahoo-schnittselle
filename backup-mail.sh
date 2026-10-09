#!/usr/bin/env bash
# backup-mail.sh - tägliche Sicherung des Mailservers (Snapshots mit Hardlinks)
#
# Sichert den ganzen Mailserver-Ordner (Mails, Konfiguration, Webmail-Daten,
# docker-compose.yml, accounts.conf) und spart Platz: unveränderte Dateien
# werden zwischen den Snapshots nicht doppelt gespeichert.
#
# Nutzung:
#   ./backup-mail.sh /pfad/zum/backupziel             einmalige Sicherung
#   ./backup-mail.sh --install /pfad/zum/backupziel   täglich um 03:30 per Cron einrichten
#
# Das Ziel sollte eine ANDERE Platte, ein NAS oder ein anderer Rechner (Mount) sein.
# Aufbewahrung: Sicherungen, die älter als KEEP_DAYS Tage sind (Standard 7), werden bei jedem Lauf automatisch gelöscht.
# Der neueste Snapshot bleibt immer erhalten. Monatssnapshots gibt es nur mit KEEP_MONTHLY > 0 (Standard 0 = keine).
# Optional:
#   HC_URL=https://hc-ping.com/xxxx   meldet Start, Erfolg und Fehler an Healthchecks.io
#   REQUIRE_MOUNT=1                   bricht ab, wenn das Ziel kein eigener Mountpunkt ist
#   ALLOW_SAME_DISK=1                 erlaubt ein Ziel auf demselben Dateisystem (nur zum Testen)
# Die Variablen werden mit --install in die Cron-Zeile übernommen.
#
# Das Backup enthält Klartext-Mails und Passwörter: Ziel nur für root lesbar (700),
# Kopien in die Cloud nur verschlüsselt.
#
# Wiederherstellen (Beispiel, ein Postfach; vorher "docker compose stop mailserver"):
#   rsync -a ZIEL/daily/<datum>/data/mail-data/home.lan/anna/ data/mail-data/home.lan/anna/
#   docker compose start mailserver
#   docker exec mailserver doveadm force-resync -u anna@home.lan '*'
# Besitzer und Rechte stellt rsync (--numeric-ids) selbst wieder her.

set -euo pipefail

KEEP_DAYS="${KEEP_DAYS:-7}"
KEEP_MONTHLY="${KEEP_MONTHLY:-0}"
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
SRC="$(dirname "$SELF")"
CRON_DIR="${CRON_DIR:-/etc/cron.d}"            # die drei Pfade sind nur für Tests änderbar
LOGROTATE_DIR="${LOGROTATE_DIR:-/etc/logrotate.d}"
LOCK_FILE="${LOCK_FILE:-/var/lock/mail-backup.lock}"

fail() {   # Fehler melden (Healthchecks) und beenden
  trap - EXIT
  echo "Fehler: $*" >&2
  if [[ -n "${HC_URL:-}" ]]; then curl -fsS -m 10 -o /dev/null "$HC_URL/fail" || true; fi
  exit 1
}
die() { fail "$@"; }

[[ $EUID -eq 0 ]] || exec sudo -E bash "$SELF" "$@"

# Eingaben prüfen: 0 Tage würde jede Sicherung sofort wieder löschen
[[ "$KEEP_DAYS" =~ ^[1-9][0-9]*$ ]]    || die "KEEP_DAYS muss eine Zahl >= 1 sein (ist: $KEEP_DAYS)."
[[ "$KEEP_MONTHLY" =~ ^[0-9]+$ ]]      || die "KEEP_MONTHLY muss eine Zahl >= 0 sein (ist: $KEEP_MONTHLY)."

if [[ "${1:-}" == "--install" ]]; then
  DEST="${2:-}"; [[ -n "$DEST" ]] || die "Zielordner fehlt. Beispiel: $0 --install /mnt/backup/mail"
  DEST="$(readlink -f "$DEST")"
  [[ "$DEST" == /* && "$DEST" != "/" ]] || die "Ungültiges Ziel: $DEST"
  [[ "$DEST" =~ ^[A-Za-z0-9._/@+-]+$ ]] || die "Das Ziel enthält Sonderzeichen oder Leerzeichen, die in einer Cron-Zeile nicht sicher sind: $DEST"
  ENV_PART="KEEP_DAYS=$KEEP_DAYS KEEP_MONTHLY=$KEEP_MONTHLY"
  [[ "${REQUIRE_MOUNT:-0}" != "1" ]] || ENV_PART+=" REQUIRE_MOUNT=1"
  if [[ -n "${HC_URL:-}" ]]; then
    [[ "$HC_URL" =~ ^https://[A-Za-z0-9._/-]+$ ]] || die "HC_URL hat ein ungültiges Format."
    ENV_PART+=" HC_URL=$HC_URL"
  fi
  echo "30 3 * * * root $ENV_PART '$SELF' '$DEST' >> /var/log/mail-backup.log 2>&1" > "$CRON_DIR/mail-backup"
  # Das Log wächst sonst unbegrenzt
  cat > "$LOGROTATE_DIR/mail-backup" <<'EOF'
/var/log/mail-backup.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
}
EOF
  echo "Cron eingerichtet: täglich 03:30 -> $DEST (Log: /var/log/mail-backup.log, Rotation: wöchentlich)"
  exit 0
fi

DEST="${1:-}"; [[ -n "$DEST" ]] || die "Zielordner fehlt. Beispiel: $0 /mnt/backup/mail"
[[ "$DEST" == /* ]] || die "Bitte einen absoluten Pfad angeben."

# Nur ein Lauf gleichzeitig (Cron und manueller Start würden sich sonst in die Quere kommen)
exec 9>"$LOCK_FILE"
flock -n 9 || die "Es läuft bereits eine Sicherung."

# Fehlt das Laufwerk, würde sonst in den leeren Mountpunkt auf der Systemplatte gesichert
if [[ "${REQUIRE_MOUNT:-0}" == "1" ]]; then
  mountpoint -q "$DEST" || die "$DEST ist kein eingehängtes Laufwerk (REQUIRE_MOUNT=1)."
fi
mkdir -p "$DEST/daily" "$DEST/monthly"
chmod 700 "$DEST"
DEST="$(readlink -f "$DEST")"

# Ziel innerhalb der Quelle würde das Backup rekursiv in sich selbst sichern
case "$DEST/" in
  "$SRC"/*) die "Das Ziel $DEST liegt innerhalb von $SRC. Ein Ziel außerhalb des Mailserver-Ordners wählen." ;;
esac

# Schutz vor Scheinsicherheit: Ziel darf nicht auf derselben Platte wie die Mails liegen
if [[ "$(stat -c %d "$SRC")" == "$(stat -c %d "$DEST")" && "${ALLOW_SAME_DISK:-0}" != "1" ]]; then
  die "Ziel liegt auf demselben Dateisystem wie die Mails. Anderes Laufwerk wählen (oder ALLOW_SAME_DISK=1)."
fi

# Jeder unerwartete Abbruch wird gemeldet (sonst bliebe der Fehler stumm)
trap 'rc=$?; [[ $rc -eq 0 ]] || fail "Sicherung abgebrochen (Zeile $LINENO, Code $rc)"' EXIT

[[ -z "${HC_URL:-}" ]] || curl -fsS -m 10 -o /dev/null "$HC_URL/start" || true

NAME="$(date +%Y-%m-%d_%H%M%S)"
PREV="$(readlink -f "$DEST/latest" 2>/dev/null || true)"
LINK=(); [[ -d "$PREV" ]] && LINK=(--link-dest="$PREV")

echo "[$(date '+%F %T')] Sicherung startet: $SRC -> $DEST/daily/$NAME"

# Mails kommen laufend an: Maildir ist dafür ausgelegt, rsync-Code 24 (Datei verschwunden) ist ok
rc=0
rsync -aH --delete --numeric-ids \
  --exclude 'data/mail-logs/' \
  "${LINK[@]}" "$SRC/" "$DEST/daily/$NAME.partial/" || rc=$?
[[ $rc -eq 0 || $rc -eq 24 ]] || die "rsync fehlgeschlagen (Code $rc)"

mv "$DEST/daily/$NAME.partial" "$DEST/daily/$NAME"
ln -sfn "$DEST/daily/$NAME" "$DEST/latest"

# Monatssnapshot (Hardlink-Kopie, braucht kaum zusätzlichen Platz); fehlt er, wird er beim nächsten Erfolg nachgeholt
MONTH="$(date +%Y-%m)"
[[ "$KEEP_MONTHLY" -eq 0 || -d "$DEST/monthly/$MONTH" ]] || cp -al "$DEST/daily/$NAME" "$DEST/monthly/$MONTH"

# Alte Snapshots löschen (älter als KEEP_DAYS Tage; der neueste bleibt immer), unfertige Reste ebenfalls
rm -rf "$DEST"/daily/*.partial
CUTOFF="$(date -d "-$KEEP_DAYS days" +%Y-%m-%d_%H%M%S)"
NEWEST="$(ls -1d "$DEST"/daily/* 2>/dev/null | sort | tail -n 1 || true)"
for d in "$DEST"/daily/*; do
  [[ -d "$d" && "$d" != "$NEWEST" && "${d##*/}" < "$CUTOFF" ]] || continue
  echo "Lösche alte Sicherung: ${d##*/}"
  rm -rf "$d"
done
if [[ "$KEEP_MONTHLY" -eq 0 ]]; then
  rm -rf "$DEST"/monthly/*
else
  ls -1d "$DEST"/monthly/* 2>/dev/null | sort | head -n -"$KEEP_MONTHLY" | xargs -r rm -rf
fi

trap - EXIT
echo "[$(date '+%F %T')] Fertig."
[[ -z "${HC_URL:-}" ]] || curl -fsS -m 10 -o /dev/null "$HC_URL" || true
