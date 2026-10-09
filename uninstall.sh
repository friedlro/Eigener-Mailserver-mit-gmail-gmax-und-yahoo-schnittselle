#!/usr/bin/env bash
# uninstall.sh - entfernt den Mailserver und alles, was install.sh / setup-mailserver.sh angelegt haben
#
# Nutzung:
#   sudo ./uninstall.sh                      Auswahlmenü (Mail-Daten, Docker und Tailscale sind NICHT vorgewählt)
#   sudo ./uninstall.sh --alles              Menü mit allem vorgewählt, inklusive Mail-Daten
#   sudo ./uninstall.sh --alles -y           ALLES ohne Rückfrage entfernen, auch alle Mails (nicht rückgängig zu machen)
#   sudo ./uninstall.sh -y                   ohne Rückfrage, aber OHNE Mail-Daten, Backups, Docker und Tailscale
#   sudo ./uninstall.sh -h                   Hilfe
#
# Bei Google (Gmail) wird nichts verändert. Der Ordner mit den Skripten selbst bleibt bestehen
# und kann danach von Hand gelöscht werden.

set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
BASE="$(dirname "$SELF")"
[[ $EUID -eq 0 ]] || exec sudo -E bash "$SELF" "$@"

TITLE="Mailserver deinstallieren"
ALL=0; YES=0
for arg in "$@"; do
  case "$arg" in
    --alles) ALL=1 ;;
    -y) YES=1 ;;
    -h|--help) sed -n '2,/^$/p' "$SELF"; exit 0 ;;
    *) echo "Unbekannte Option: $arg (siehe --help)" >&2; exit 1 ;;
  esac
done

[[ -f "$BASE/setup-mailserver.sh" ]] || { echo "Dieses Skript muss im Mailserver-Ordner liegen (setup-mailserver.sh fehlt)." >&2; exit 1; }
[[ -n "$BASE" && "$BASE" != "/" ]] || { echo "Ungültiger Ordner." >&2; exit 1; }

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mHinweis: %s\033[0m\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

CONTAINERS=(mailserver roundcube ddns cloudflared)
IMAGES=(ghcr.io/docker-mailserver/docker-mailserver roundcube/roundcubemail cloudflare/cloudflared favonia/cloudflare-ddns certbot/dns-cloudflare)
# Systempfade; nur für Tests änderbar
CRON_DIR="${CRON_DIR:-/etc/cron.d}"; LOGROTATE_DIR="${LOGROTATE_DIR:-/etc/logrotate.d}"
SUDOERS_DIR="${SUDOERS_DIR:-/etc/sudoers.d}"; LOG_DIR="${LOG_DIR:-/var/log}"
CRON_FILES=("$CRON_DIR/mailserver-certbot" "$CRON_DIR/mailserver-gmail-cleanup" "$CRON_DIR/mailserver-gmail-trash" "$CRON_DIR/mail-backup" "$LOGROTATE_DIR/mail-backup")
LOG_FILES=("$LOG_DIR/mail-backup.log" "$LOG_DIR/mail-gmail-cleanup.log")
CONF_FILES=(accounts.conf docker-compose.yml docker-compose.yml.vor-update .env zugangsdaten.txt config-backup)

# ---------------------------------------------------------------- Bestandsaufnahme
BACKUP_DEST=""
if [[ -f "$CRON_DIR/mail-backup" ]]; then
  BACKUP_DEST="$(sed -n "s/.* '\([^']*\)' >> .*/\1/p" "$CRON_DIR/mail-backup" | head -n1)"
  [[ "$BACKUP_DEST" == /* && "$BACKUP_DEST" != "/" && ( -d "$BACKUP_DEST/daily" || -L "$BACKUP_DEST/latest" ) ]] || BACKUP_DEST=""
fi
OTHER_CONTAINERS=0
if have docker; then
  while IFS= read -r n; do
    [[ -z "$n" ]] && continue
    [[ " ${CONTAINERS[*]} " == *" $n "* ]] || OTHER_CONTAINERS=$((OTHER_CONTAINERS + 1))
  done < <(docker ps -a --format '{{.Names}}' 2>/dev/null || true)
fi
VIA_TAILSCALE=0
SSH_FROM="${SSH_CONNECTION:-}"; SSH_FROM="${SSH_FROM%% *}"
if [[ "$SSH_FROM" == 100.* ]]; then VIA_TAILSCALE=1; fi

# ---------------------------------------------------------------- Auswahl
SEL=()
if (( YES )); then
  SEL=(containers cron images mcp config)
  if (( ALL )); then
    SEL+=(data docker tailscale)
    if [[ -n "$BACKUP_DEST" ]]; then SEL+=(backups); fi
  fi
else
  have whiptail || { echo "whiptail fehlt. Alternativ: sudo ./uninstall.sh -y" >&2; exit 1; }
  [[ -t 0 && -t 1 ]] || { echo "Dieses Skript braucht ein Terminal (oder die Option -y)." >&2; exit 1; }
  st() { (( ALL )) && echo ON || echo "$1"; }
  ITEMS=(
    containers "Container stoppen und entfernen (Mailserver, Webmail, DDNS, Tunnel)" ON
    cron       "Cron-Jobs und Logdateien (Zertifikat, Gmail-Aufräumen, Backup)" ON
    images     "Docker-Images dieses Projekts" ON
    mcp        "MCP-Server und sudo-Regel" ON
    config     "Konfiguration und Passwörter (accounts.conf, docker-compose.yml, zugangsdaten.txt ...)" ON
    data       "ALLE MAILS und Daten (data/) - NICHT rückgängig zu machen" "$(st OFF)"
  )
  [[ -z "$BACKUP_DEST" ]] || ITEMS+=(backups "Backup-Snapshots in $BACKUP_DEST" "$(st OFF)")
  ITEMS+=(
    docker     "Docker komplett entfernen$( ((OTHER_CONTAINERS)) && echo " (ACHTUNG: $OTHER_CONTAINERS andere Container vorhanden)")" "$(st OFF)"
    tailscale  "Tailscale entfernen$( ((VIA_TAILSCALE)) && echo " (ACHTUNG: diese Sitzung läuft über Tailscale)")" "$(st OFF)"
  )
  OUT="$(whiptail --title "$TITLE" --separate-output --checklist \
    "Was soll entfernt werden? (Leertaste = auswählen, Enter = weiter)\nBei Google (Gmail) wird nichts verändert." \
    "$(( ${#ITEMS[@]} / 3 + 9 ))" 100 "$(( ${#ITEMS[@]} / 3 ))" "${ITEMS[@]}" 3>&1 1>&2 2>&3)" || { clear; echo "Abgebrochen. Es wurde nichts entfernt."; exit 1; }
  mapfile -t SEL <<<"$OUT"
fi
sel() { [[ " ${SEL[*]:-} " == *" $1 "* ]]; }

(( ${#SEL[@]} )) && [[ -n "${SEL[0]}" ]] || { echo "Nichts ausgewählt."; exit 0; }

# ---------------------------------------------------------------- Bestätigungen
if ! (( YES )); then
  if sel data || sel backups; then
    TXT="Sie haben ausgewählt, Mails und/oder Backups ENDGÜLTIG zu löschen.\nNach dem Löschen bei Google existieren Ihre Mails sonst nur noch hier.\n\nZur Bestätigung LOESCHEN eingeben:"
    C="$(whiptail --title "$TITLE" --inputbox "$TXT" 12 70 "" 3>&1 1>&2 2>&3)" || { clear; echo "Abgebrochen."; exit 1; }
    [[ "$C" == "LOESCHEN" ]] || { clear; echo "Falsche Eingabe. Abgebrochen, es wurde nichts entfernt."; exit 1; }
  fi
  if sel tailscale && (( VIA_TAILSCALE )); then
    whiptail --title "$TITLE" --yesno "Diese SSH-Sitzung läuft über Tailscale und bricht beim Entfernen ab.\nDie Deinstallation läuft trotzdem zu Ende.\n\nTrotzdem fortfahren?" 11 70 || { clear; echo "Abgebrochen."; exit 1; }
  fi
  whiptail --title "$TITLE" --yes-button "Entfernen" --no-button "Abbrechen" --yesno "Ausgewählt: ${SEL[*]}\n\nJetzt entfernen?" 10 70 || { clear; echo "Abgebrochen. Es wurde nichts entfernt."; exit 1; }
  clear
fi

# ---------------------------------------------------------------- Ausführung
rm_path() {   # nur Pfade innerhalb von $BASE
  local p="$BASE/$1"
  [[ -e "$p" || -L "$p" ]] || return 0
  rm -rf -- "$p" && echo "  entfernt: $p"
}

if sel containers; then
  say "Container stoppen und entfernen"
  if have docker; then
    if [[ -f "$BASE/docker-compose.yml" ]]; then
      (cd "$BASE" && docker compose down --remove-orphans) || warn "docker compose down fehlgeschlagen, Container werden einzeln entfernt."
    fi
    for c in "${CONTAINERS[@]}"; do
      docker rm -f "$c" >/dev/null 2>&1 && echo "  entfernt: Container $c" || true
    done
  else
    echo "  Docker nicht vorhanden, übersprungen."
  fi
fi

if sel cron; then
  say "Cron-Jobs und Logdateien entfernen"
  for f in "${CRON_FILES[@]}" "${LOG_FILES[@]}"; do
    if [[ -e "$f" ]]; then rm -f -- "$f"; echo "  entfernt: $f"; fi
  done
fi

if sel images; then
  say "Docker-Images entfernen"
  if have docker; then
    for img in "${IMAGES[@]}"; do
      ids="$(docker images -q "$img" 2>/dev/null | sort -u || true)"
      # shellcheck disable=SC2086
      [[ -z "$ids" ]] || { docker rmi -f $ids >/dev/null 2>&1 && echo "  entfernt: $img" || warn "Image $img wird noch benutzt."; }
    done
  fi
fi

if sel mcp; then
  say "MCP-Server entfernen"
  if [[ -e "$SUDOERS_DIR/mail-mcp-backup" ]]; then rm -f -- "$SUDOERS_DIR/mail-mcp-backup"; echo "  entfernt: sudo-Regel für das Backup"; fi
  echo "  Hinweis: Die Dateien in mcp/ gehören zum Projektordner und bleiben bestehen."
  echo "  Den Eintrag 'mcpServers' in claude_desktop_config.json entfernen Sie am PC."
fi

if sel config; then
  say "Konfiguration und Passwörter entfernen"
  for f in "${CONF_FILES[@]}"; do rm_path "$f"; done
  for f in "$BASE"/accounts.conf.bak-*; do
    if [[ -e "$f" ]]; then rm -f -- "$f"; echo "  entfernt: $f"; fi
  done
fi

if sel data; then
  say "Mails und Daten entfernen (data/)"
  rm_path data
fi

if sel backups && [[ -n "$BACKUP_DEST" ]]; then
  say "Backup-Snapshots entfernen ($BACKUP_DEST)"
  rm -rf -- "$BACKUP_DEST/daily" "$BACKUP_DEST/monthly" "$BACKUP_DEST/latest" && echo "  entfernt: Snapshots in $BACKUP_DEST"
fi

if sel docker; then
  say "Docker entfernen"
  PKGS="$(dpkg -l 2>/dev/null | awk '/^ii/ && $2 ~ /^(docker-ce|docker-ce-cli|docker-ce-rootless-extras|docker-buildx-plugin|docker-compose-plugin|containerd\.io|docker\.io|docker-compose)$/ {print $2}' | tr '\n' ' ')"
  # shellcheck disable=SC2086
  [[ -z "$PKGS" ]] || apt-get purge -y $PKGS
  apt-get autoremove -y >/dev/null 2>&1 || true
  rm -rf /var/lib/docker /var/lib/containerd /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc /etc/apt/keyrings/docker.gpg
  echo "  Docker entfernt."
fi

if sel tailscale; then
  say "Tailscale entfernen"
  if have tailscale; then
    tailscale logout >/dev/null 2>&1 || true
    systemctl disable --now tailscaled >/dev/null 2>&1 || true
    apt-get purge -y tailscale tailscale-archive-keyring >/dev/null 2>&1 || true
    rm -f /etc/apt/sources.list.d/tailscale.list /usr/share/keyrings/tailscale-archive-keyring.gpg
    echo "  Tailscale entfernt."
    echo "  Der Eintrag bleibt in der Admin-Konsole, bis Sie ihn dort löschen: https://login.tailscale.com/admin/machines"
  else
    echo "  Tailscale nicht vorhanden."
  fi
fi

say "Deinstallation abgeschlossen"
echo "  Bei Google (Gmail) wurde nichts verändert."
echo "  Der Ordner $BASE mit den Skripten bleibt bestehen. Zum Entfernen: sudo rm -rf '$BASE'"
sel data || echo "  Ihre Mails liegen weiterhin in $BASE/data/mail-data."
