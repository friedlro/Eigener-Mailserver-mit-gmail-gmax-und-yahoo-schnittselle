#!/usr/bin/env bash
# usb-backup.sh - richtet einen USB-Datenträger als Backup-Ziel ein und startet den täglichen Backup-Job
#
# Nutzung:
#   sudo ./usb-backup.sh --list                         angeschlossene USB-Datenträger anzeigen
#   sudo ./usb-backup.sh --setup /dev/sdb1              vorhandenes Dateisystem (ext4, xfs, btrfs) verwenden, nichts löschen
#   sudo ./usb-backup.sh --setup /dev/sdb1 --format     VORHER ALLES LÖSCHEN und als ext4 neu anlegen
#   Zusätzlich:  --keep-days N (Standard 7)   --first-run (erste Sicherung gleich im Hintergrund starten)
#   sudo ./usb-backup.sh --remove                       Cron und fstab-Eintrag entfernen (Daten auf dem Stick bleiben)
#
# Was --setup tut: Gerät prüfen (nur USB/Wechseldatenträger, nie die Systemplatte), optional formatieren, per UUID nach
# /mnt/mail-backup einhängen (fstab, "nofail": der Server startet auch ohne Stick), Cron-Job für backup-mail.sh anlegen
# (täglich 03:30, mit REQUIRE_MOUNT=1: fehlt der Stick, wird nichts auf die Systemplatte geschrieben).

set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
BASE="$(dirname "$SELF")"
[[ $EUID -eq 0 ]] || exec sudo -E bash "$SELF" "$@"

MNT="${BACKUP_MOUNT:-/mnt/mail-backup}"
FSTAB="${FSTAB:-/etc/fstab}"
MARK="# mail-backup (usb-backup.sh)"
# Zeilen mit unserer Markierung aus der fstab entfernen (wörtlich, nicht als Muster); Rechte der Datei bleiben erhalten
fstab_drop() {
  local tmp; tmp="$(mktemp)"
  grep -vF -- "$MARK" "$FSTAB" > "$tmp" || true
  cat "$tmp" > "$FSTAB"; rm -f "$tmp"
}
die() { echo "Fehler: $*" >&2; exit 1; }
say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

command -v python3 >/dev/null || { apt-get update -qq && apt-get install -y -qq python3; }
[[ -f "$BASE/usbdisks.py" && -f "$BASE/backup-mail.sh" ]] || die "usbdisks.py oder backup-mail.sh fehlt im Ordner $BASE."

ACTION=""; DEV=""; FORMAT=0; KEEP_DAYS="${KEEP_DAYS:-7}"; FIRST_RUN=0
while (( $# )); do
  case "$1" in
    --list) ACTION="list" ;;
    --setup) ACTION="setup"; DEV="${2:-}"; shift ;;
    --remove) ACTION="remove" ;;
    --format) FORMAT=1 ;;
    --keep-days) KEEP_DAYS="${2:-}"; shift ;;
    --first-run) FIRST_RUN=1 ;;
    -h|--help) sed -n '2,/^$/p' "$SELF"; exit 0 ;;
    *) die "Unbekannte Option: $1 (siehe --help)" ;;
  esac
  shift
done
[[ -n "$ACTION" ]] || die "Aktion fehlt (--list, --setup oder --remove). Siehe --help."

if [[ "$ACTION" == "list" ]]; then
  python3 "$BASE/usbdisks.py" list | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
if not d:
    print("Kein geeigneter USB-Datenträger gefunden (Stick anschließen und erneut versuchen).")
for c in d:
    print("%-12s %8s  %-28s %-8s %s%s" % (c["path"], c["size_h"], c["model"][:28], c["fstype"] or "-", c["label"] or "-",
          "   [eingehängt: %s]" % ", ".join(c["mountpoints"]) if c["mountpoints"] else ""))
    if c["note"]:
        print("             %s" % c["note"])
'
  exit 0
fi

if [[ "$ACTION" == "remove" ]]; then
  say "USB-Backup entfernen"
  rm -f "${CRON_DIR:-/etc/cron.d}/mail-backup"
  [[ ! -f "$FSTAB" ]] || fstab_drop
  if mountpoint -q "$MNT" 2>/dev/null; then umount "$MNT" || echo "Hinweis: $MNT konnte nicht ausgehängt werden (wird noch benutzt?)." >&2; fi
  echo "Cron-Job und fstab-Eintrag entfernt. Die Daten auf dem Stick bleiben unverändert."
  exit 0
fi

# ---------------------------------------------------------------- --setup
[[ "$DEV" =~ ^/dev/[A-Za-z0-9]+$ ]] || die "Gerät fehlt oder ist ungültig (Beispiel: --setup /dev/sdb1)."
[[ "$KEEP_DAYS" =~ ^[1-9][0-9]*$ ]] || die "--keep-days muss eine Zahl >= 1 sein."
[[ "$MNT" =~ ^/[A-Za-z0-9._/-]+$ && "$MNT" != "/" ]] || die "Ungültiger Einhängepunkt: $MNT"

say "Datenträger prüfen: $DEV"
INFO="$(python3 "$BASE/usbdisks.py" check "$DEV" 2>&1)" || die "$INFO"
FSTYPE="$(sed -n 's/^fstype=//p' <<<"$INFO")"
LABEL="$(sed -n 's/^label=//p' <<<"$INFO")"
SIZE="$(sed -n 's/^size_h=//p' <<<"$INFO")"
mapfile -t OLD_MPS < <(sed -n 's/^mountpoint=//p' <<<"$INFO")
echo "  $DEV  $SIZE  Dateisystem: ${FSTYPE:-keines}  Name: ${LABEL:--}"

# Ist der Stick woanders (z. B. automatisch unter /media) eingehängt, zuerst aushängen
for m in "${OLD_MPS[@]}"; do
  [[ -n "$m" ]] || continue
  umount "$m" || die "$m konnte nicht ausgehängt werden (wird noch benutzt?)."
done
# War an unserem Einhängepunkt schon etwas eingehängt (frühere Einrichtung), ebenfalls aushängen
if mountpoint -q "$MNT" 2>/dev/null; then umount "$MNT" || die "$MNT konnte nicht ausgehängt werden."; fi

if (( FORMAT )); then
  say "Formatieren als ext4 (ALLE Daten auf $DEV gehen verloren)"
  command -v mkfs.ext4 >/dev/null || { apt-get update -qq && apt-get install -y -qq e2fsprogs; }
  mkfs.ext4 -F -L MAILBACKUP "$DEV" >/dev/null
  FSTYPE="ext4"
else
  case "$FSTYPE" in
    ext2|ext3|ext4|xfs|btrfs) echo "  Vorhandenes Dateisystem wird verwendet, es wird nichts gelöscht." ;;
    *) die "Das Dateisystem '${FSTYPE:-keines}' ist für das Backup ungeeignet (es braucht Hardlinks und Unix-Rechte). Mit --format als ext4 neu anlegen (löscht alles)." ;;
  esac
fi

UUID="$(blkid -s UUID -o value "$DEV")"
[[ "$UUID" =~ ^[A-Za-z0-9-]+$ ]] || die "UUID von $DEV nicht lesbar."

say "Einhängen nach $MNT"
mkdir -p "$MNT"
touch "$FSTAB"
fstab_drop
printf 'UUID=%s %s %s defaults,nofail,noatime 0 2 %s\n' "$UUID" "$MNT" "$FSTYPE" "$MARK" >> "$FSTAB"
systemctl daemon-reload 2>/dev/null || true
mount "$MNT" || die "Einhängen von $DEV nach $MNT fehlgeschlagen (siehe dmesg)."
mountpoint -q "$MNT" || die "$MNT ist nicht eingehängt."
touch "$MNT/.schreibtest" 2>/dev/null && rm -f "$MNT/.schreibtest" || die "$MNT ist nicht beschreibbar."
chmod 700 "$MNT"

say "Täglichen Backup-Job einrichten"
REQUIRE_MOUNT=1 KEEP_DAYS="$KEEP_DAYS" bash "$BASE/backup-mail.sh" --install "$MNT"

if (( FIRST_RUN )); then
  say "Erste Sicherung starten (läuft im Hintergrund, Log: ${BACKUP_LOG:-/var/log/mail-backup.log})"
  REQUIRE_MOUNT=1 KEEP_DAYS="$KEEP_DAYS" nohup bash "$BASE/backup-mail.sh" "$MNT" >> "${BACKUP_LOG:-/var/log/mail-backup.log}" 2>&1 &
  echo "  Gestartet (PID $!). Fortschritt: tail -f ${BACKUP_LOG:-/var/log/mail-backup.log}"
fi

say "Fertig"
echo "USB-Backup eingerichtet: $DEV -> $MNT (Sicherungen älter als $KEEP_DAYS Tage werden gelöscht)."
echo "Entfernen: sudo $SELF --remove"
