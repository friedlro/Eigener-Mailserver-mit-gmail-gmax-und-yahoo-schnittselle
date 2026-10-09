#!/usr/bin/env bash
# get.sh - Ein-Zeilen-Installer: lädt das Projekt von GitHub (ohne git) und startet den Assistenten.
#
# Nutzung:
#   curl -fsSL https://raw.githubusercontent.com/friedlro/Eigener-Mailserver-mit-gmail-gmax-und-yahoo-schnittselle/main/get.sh | sudo bash
#
# Einstellungen (Umgebungsvariablen, bei sudo mit "sudo env VAR=... bash"):
#   MAILSERVER_DIR    Zielordner (Standard /opt/mailserver; vorhandene accounts.conf und data/ bleiben erhalten)
#   MAILSERVER_REF    Branch, Tag oder Commit (Standard main)
#   GITHUB_TOKEN      nur für ein privates Repository (Token mit Leserecht auf "Contents")

set -euo pipefail

REPO="friedlro/Eigener-Mailserver-mit-gmail-gmax-und-yahoo-schnittselle"
REF="${MAILSERVER_REF:-main}"
DEST="${MAILSERVER_DIR:-/opt/mailserver}"

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
if [[ -r /dev/tty ]]; then
  exec bash ./install.sh </dev/tty
fi
echo "Kein Terminal gefunden. Starte den Assistenten selbst:  sudo $DEST/install.sh" >&2
