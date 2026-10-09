#!/usr/bin/env bash
# tailscale-setup.sh - installiert Tailscale (falls nötig), meldet den Server an und gibt IP und Namen aus
#
# Nutzung:
#   sudo ./tailscale-setup.sh [--ssh] [--timeout 300]
#
#   --ssh        Tailscale SSH einschalten (Anmeldung per SSH ohne Schlüssel; nötig für die MCP-Anbindung ohne Schlüsselverwaltung)
#   --timeout N  so viele Sekunden auf die Bestätigung des Anmeldelinks warten (Standard 300)
#
# Ist der Server noch nicht angemeldet, gibt Tailscale einen Link aus ("To authenticate, visit: https://login.tailscale.com/a/...").
# Den Link im Browser öffnen und bestätigen. Die Web-Oberfläche (webui.py) zeigt ihn hervorgehoben an.
# Am Ende stehen "Tailscale-IP: ..." und "Tailscale-Name: ..." in der Ausgabe.

set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
[[ $EUID -eq 0 ]] || exec sudo -E bash "$SELF" "$@"

SSH=0; TIMEOUT=300
while (( $# )); do
  case "$1" in
    --ssh) SSH=1 ;;
    --timeout) TIMEOUT="${2:-}"; shift ;;
    -h|--help) sed -n '2,/^$/p' "$SELF"; exit 0 ;;
    *) echo "Fehler: Unbekannte Option: $1 (siehe --help)" >&2; exit 1 ;;
  esac
  shift
done
[[ "$TIMEOUT" =~ ^[1-9][0-9]{0,3}$ ]] || { echo "Fehler: --timeout muss eine Zahl von 1 bis 9999 sein." >&2; exit 1; }

echo "==> Tailscale einrichten"
if ! command -v tailscale >/dev/null; then
  echo "Tailscale wird von tailscale.com installiert ..."
  command -v curl >/dev/null || { apt-get update -qq && apt-get install -y -qq curl; }
  curl -fsSL https://tailscale.com/install.sh | sh || { echo "Fehler: Tailscale konnte nicht installiert werden. Anleitung: https://tailscale.com/kb/1031/install-linux" >&2; exit 1; }
fi

if tailscale status >/dev/null 2>&1; then
  echo "Dieser Server ist bereits bei Tailscale angemeldet."
  (( ! SSH )) || tailscale set --ssh=true || echo "Hinweis: Tailscale SSH konnte nicht eingeschaltet werden." >&2
else
  echo "Anmeldung nötig: Den folgenden Link im Browser öffnen und bestätigen (Wartezeit bis zu ${TIMEOUT} Sekunden)."
  ARGS=(up "--timeout=${TIMEOUT}s")
  (( ! SSH )) || ARGS+=(--ssh)
  tailscale "${ARGS[@]}" 2>&1 || { echo "Fehler: Die Tailscale-Anmeldung wurde nicht abgeschlossen. Später nachholen mit: sudo tailscale up --ssh" >&2; exit 1; }
fi

IP="$(tailscale ip -4 2>/dev/null | head -n 1 || true)"
NAME="$(tailscale status --json 2>/dev/null | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("Self",{}).get("DNSName","").rstrip("."))' 2>/dev/null || true)"
[[ -n "$IP" ]] || { echo "Fehler: Keine Tailscale-Adresse gefunden (tailscale status prüfen)." >&2; exit 1; }
echo "Tailscale-IP: $IP"
[[ -z "$NAME" ]] || echo "Tailscale-Name: $NAME"
echo "Fertig. Dieser Server ist im Tailnet unter $IP erreichbar."
