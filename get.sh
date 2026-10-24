#!/usr/bin/env bash
# get.sh - Ein-Zeilen-Installer: lädt das Projekt von GitHub (ohne git) und startet den Assistenten.
#
# Nutzung:
#   curl -fsSL https://raw.githubusercontent.com/friedlro/Eigener-Mailserver-mit-gmail-gmax-und-yahoo-schnittselle/main/get.sh | sudo bash
#   ... | sudo bash -s -- --web     Installation im Browser statt im Terminalmenü (Adresse und Passwort erscheinen im Terminal)
#
# Einstellungen (Umgebungsvariablen, bei sudo mit "sudo env VAR=... bash"):
#   MAILSERVER_DIR    Zielordner. Ohne Angabe wird eine vorhandene Installation gesucht (/opt/mailserver, /srv/mailserver,
#                     /root/mailserver, /home/*/mailserver, /home/*, aktueller Ordner); gibt es keine, wird /opt/mailserver
#                     angelegt. Vorhandene accounts.conf und data/ bleiben erhalten.
#   MAILSERVER_REF    Branch, Tag oder Commit (Standard main)
#   GITHUB_TOKEN      nur für ein privates Repository (Token mit Leserecht auf "Contents")

set -euo pipefail

REPO="friedlro/Eigener-Mailserver-mit-gmail-gmax-und-yahoo-schnittselle"
REF="${MAILSERVER_REF:-main}"

# Eine vorhandene Installation erkennen: Ordner mit setup-mailserver.sh und accounts.conf oder docker-compose.yml
find_install() {
  local pat c r seen=" "
  FOUND=()
  shopt -s nullglob
  # shellcheck disable=SC2206
  local pats=(${MAILSERVER_SEARCH:-/opt/mailserver /srv/mailserver /root/mailserver /home/*/mailserver /home/* "$PWD"})
  for pat in "${pats[@]}"; do
    for c in $pat; do
      [[ -d "$c" && -f "$c/setup-mailserver.sh" && ( -f "$c/accounts.conf" || -f "$c/docker-compose.yml" ) ]] || continue
      r="$(readlink -f "$c")"
      [[ "$seen" == *" $r "* ]] && continue
      seen+="$r "; FOUND+=("$r")
    done
  done
  shopt -u nullglob
}

if [[ -n "${MAILSERVER_DIR:-}" ]]; then
  DEST="$MAILSERVER_DIR"
else
  find_install
  case ${#FOUND[@]} in
    0) DEST="/opt/mailserver" ;;
    1) DEST="${FOUND[0]}"; echo "Vorhandene Installation gefunden: $DEST (anderer Ordner: MAILSERVER_DIR=... angeben)" ;;
    *) echo "Fehler: Mehrere vorhandene Installationen gefunden:" >&2
       printf '  %s\n' "${FOUND[@]}" >&2
       echo "Bitte den gewünschten Ordner angeben, z. B.:  ... | sudo env MAILSERVER_DIR=${FOUND[0]} bash" >&2
       exit 1 ;;
  esac
fi
[[ "${GET_SH_DETECT_ONLY:-0}" != "1" ]] || { echo "$DEST"; exit 0; }   # nur für Tests

[[ $EUID -eq 0 ]] || { echo "Bitte mit sudo starten (siehe Kopf von get.sh)." >&2; exit 1; }
for t in curl tar; do
  command -v "$t" >/dev/null || { apt-get update -qq && apt-get install -y -qq "$t"; }
done
[[ "$REF" =~ ^[A-Za-z0-9._/-]+$ ]] || { echo "Ungültiger Wert für MAILSERVER_REF." >&2; exit 1; }

TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
echo "==> Lade $REPO ($REF) nach $DEST"
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  printf 'header = "Authorization: Bearer %s"\n' "$GITHUB_TOKEN" |
    curl -fsSL -K - -H "Accept: application/vnd.github+json" -o "$TMP" "https://api.github.com/repos/$REPO/tarball/$REF"
else
  curl -fsSL -o "$TMP" "https://codeload.github.com/$REPO/tar.gz/$REF" ||
    { echo "Download fehlgeschlagen. Ist das Repository privat? Dann GITHUB_TOKEN setzen." >&2; exit 1; }
fi

mkdir -p "$DEST"
tar -xzf "$TMP" -C "$DEST" --strip-components=1
chmod +x "$DEST"/*.sh

cd "$DEST"
if [[ "${1:-}" == "--web" || "${MAILSERVER_WEB:-0}" == "1" ]]; then
  command -v python3 >/dev/null || { apt-get update -qq && apt-get install -y -qq python3; }
  exec python3 ./webui.py </dev/null
fi
if [[ -r /dev/tty ]]; then
  exec bash ./install.sh </dev/tty
fi
echo "Kein Terminal gefunden. Starte den Assistenten selbst:  sudo $DEST/install.sh" >&2
