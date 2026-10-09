#!/usr/bin/env bash
# Installiert Tailscale (falls nötig) und legt den MCP-Server im Mailserver-Ordner ab.
# Aufruf auf dem Server:  sudo bash install.sh [MAIL_DIR]
set -euo pipefail

MAIL_DIR="${1:-$(dirname "$(cd "$(dirname "$0")" && pwd)")}"
USER_NAME="${SUDO_USER:-$(id -un)}"
HERE="$(cd "$(dirname "$0")" && pwd)"

[[ $EUID -eq 0 ]] || { echo "Bitte mit sudo ausführen." >&2; exit 1; }
[[ -d "$MAIL_DIR" ]] || { echo "Ordner $MAIL_DIR existiert nicht. Pfad als Argument angeben." >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 fehlt (apt install python3)." >&2; exit 1; }

# SKIP_TAILSCALE=1 (vom Assistenten install.sh gesetzt): Tailscale nicht anfassen
if [[ "${SKIP_TAILSCALE:-0}" != "1" ]]; then
  if ! command -v tailscale >/dev/null; then
    echo "Tailscale-Installer wird von tailscale.com geladen ..."
    curl -fsSL https://tailscale.com/install.sh | sh
  fi
  if ! tailscale status >/dev/null 2>&1; then
    echo "Tailscale-Login nötig; Link im Browser bestätigen:"
    tailscale up --ssh
  fi
fi

install -d -m 755 "$MAIL_DIR/mcp"
[[ "$HERE/server.py" -ef "$MAIL_DIR/mcp/server.py" ]] || install -m 755 "$HERE/server.py" "$MAIL_DIR/mcp/server.py"
chown -R "$USER_NAME": "$MAIL_DIR/mcp"

# Benutzer braucht Docker-Zugriff; Backup-Skript darf ohne Passwort als root laufen.
usermod -aG docker "$USER_NAME"
if [[ -x "$MAIL_DIR/backup-mail.sh" ]]; then
  echo "$USER_NAME ALL=(root) NOPASSWD: $MAIL_DIR/backup-mail.sh" > /etc/sudoers.d/mail-mcp-backup
  chmod 440 /etc/sudoers.d/mail-mcp-backup
  visudo -cf /etc/sudoers.d/mail-mcp-backup >/dev/null
fi

echo
echo "Fertig. Test (neue Anmeldung nötig wegen Docker-Gruppe):"
echo "  echo '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}' | python3 $MAIL_DIR/mcp/server.py"
if command -v tailscale >/dev/null; then tailscale status | head -n 3 || true; fi
