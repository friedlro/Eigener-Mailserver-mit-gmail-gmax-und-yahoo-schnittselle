#!/usr/bin/env bash
# setup-mailserver.sh
# Installiert docker-mailserver + Roundcube (Webmail), legt die Konten an,
# importiert den Altbestand per IMAP und schaltet danach die laufende Abholung
# (POP3) und das Senden über den jeweiligen Anbieter ein.
# Unterstützte Anbieter: Gmail, GMX, Yahoo (pro Konto frei wählbar).
# Optional: externer Zugriff OHNE VPN (siehe accounts.conf.example).
#
# Nutzung:
#   ./setup-mailserver.sh               Erstinstallation (fragt einmal nach)
#   ./setup-mailserver.sh --check       Zugangsdaten aller Konten testen (IMAP und POP3), ändert nichts
#   ./setup-mailserver.sh --update      BESTEHENDES System aktualisieren: neue Konfiguration
#                                       und Container, aber KEIN Import, Abholung läuft weiter
#   ./setup-mailserver.sh --reimport    Import erzwingen (z. B. nach abgebrochenem alten Import)
#   ./setup-mailserver.sh --cleanup     Gmail aufräumen (Papierkorb/Gesendet laut accounts.conf)
#   ./setup-mailserver.sh --empty-trash Gmail-Papierkorb sofort leeren
#   -y                                  ohne Rückfrage (mit allen Modi kombinierbar)
#
# Importierte Konten werden gemerkt (data/import-done/). Ein erneuter Lauf importiert sie
# NICHT noch einmal, es entstehen also keine Dubletten.

set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
BASE="$(dirname "$SELF")"
[[ $EUID -eq 0 ]] || exec sudo -E bash "$SELF" "$@"
cd "$BASE"
CONF="${CONF:-$BASE/accounts.conf}"
CRON_DIR="${CRON_DIR:-/etc/cron.d}"          # nur für Tests änderbar
CHECK_PORT="${CHECK_PORT:-993}"             # nur für Tests änderbar

trim() { sed -E 's/^[[:space:]]+|[[:space:]]+$//g' <<<"$1"; }
say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mHinweis: %s\033[0m\n' "$*" >&2; }
die()  { printf '\n\033[31mFehler: %s\033[0m\n' "$*" >&2; exit 1; }
# Doppelt angeführter String mit \\ und \" (für fetchmail, mbsync und curl)
dq()   { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '"%s"' "$s"; }

# ---------------------------------------------------------------- Optionen
ASSUME_YES=0; MODE="install"; REIMPORT=0
for arg in "$@"; do
  case "$arg" in
    -y) ASSUME_YES=1 ;;
    --check) MODE="check" ;;
    --update) MODE="update" ;;
    --reimport) REIMPORT=1 ;;
    --cleanup) MODE="cleanup" ;;
    --empty-trash) MODE="empty-trash" ;;
    -h|--help) sed -n '2,/^$/p' "$SELF"; exit 0 ;;
    *) die "Unbekannte Option: $arg  (siehe --help)" ;;
  esac
done

# ---------------------------------------------------------------- Festgelegte Versionen
# Die Images sind auf getestete Versionen festgelegt (kein ":latest"). Eine neue Version des
# Projekts bringt neue Versionen mit; abweichende Tags lassen sich in accounts.conf setzen.
DMS_TAG="16.0.1"; ROUNDCUBE_TAG="1.7.4-apache"; DDNS_TAG="1.17.1"
CLOUDFLARED_TAG="2026.10.0"; CERTBOT_TAG="v5.8.0"

# ---------------------------------------------------------------- Anbieter
# Pro Konto wählbar: gmail, gmx, yahoo. Ohne Angabe wird der Anbieter aus der Adresse erkannt.
declare -A PROV_NAME=([gmail]="Gmail" [gmx]="GMX" [yahoo]="Yahoo")

detect_provider() {   # $1 = Adresse
  local d="${1#*@}"; d="${d,,}"
  case "$d" in
    gmail.com|googlemail.com) echo gmail ;;
    gmx.de|gmx.net|gmx.at|gmx.ch|gmx.com|gmx.eu|gmx.org|gmx.info) echo gmx ;;
    yahoo.co.jp) echo "" ;;
    yahoo.*|ymail.com|rocketmail.com) echo yahoo ;;
    *) echo "" ;;
  esac
}

prov_host() {   # $1 = imap|pop|smtp   $2 = Anbieter   $3 = Adresse
  local d="${3#*@}" t="net"
  d="${d,,}"
  case "$2" in
    gmail) case "$1" in imap) echo imap.gmail.com ;; pop) echo pop.gmail.com ;; smtp) echo smtp.gmail.com ;; esac ;;
    gmx)   [[ "$d" == "gmx.com" ]] && t="com"
           case "$1" in imap) echo "imap.gmx.$t" ;; pop) echo "pop.gmx.$t" ;; smtp) echo "mail.gmx.$t" ;; esac ;;
    yahoo) case "$1" in imap) echo imap.mail.yahoo.com ;; pop) echo pop.mail.yahoo.com ;; smtp) echo smtp.mail.yahoo.com ;; esac ;;
  esac
}

# Ordner, die beim Import ausgelassen werden (der Posteingang kommt bei GMX und Yahoo per POP3,
# damit nichts doppelt ankommt; Papierkorb und Spam sollen nicht importiert werden)
import_patterns() {   # $1 = Anbieter
  case "$1" in
    gmail)
      if [[ "$IMPORT_MODE" == "alles" ]]; then
        echo '"[Gmail]/Alle Nachrichten" "[Gmail]/All Mail"'
      else
        echo '* !"[Gmail]/Alle Nachrichten" !"[Gmail]/All Mail" !"[Gmail]/Spam" !"[Gmail]/Papierkorb" !"[Gmail]/Trash" !"[Gmail]/Wichtig" !"[Gmail]/Important"'
      fi ;;
    gmx)   echo '* !INBOX !Spam !Papierkorb !Trash' ;;
    yahoo) echo '* !INBOX !Bulk !"Bulk Mail" !Spam !Trash' ;;
  esac
}

# ---------------------------------------------------------------- Konfiguration lesen
[[ -f "$CONF" ]] || die "accounts.conf fehlt. Vorlage: accounts.conf.example kopieren und ausfüllen (oder ./install.sh)."
chmod 600 "$CONF"

DOMAIN=""; CF_API_TOKEN=""; CF_TUNNEL_TOKEN=""; LE_EMAIL=""
WEBMAIL_PORT="8080"; WEBMAIL_BIND="0.0.0.0"; DDNS="1"; IMPORT_MODE="ordner"
GMAIL_EMPTY_TRASH="0"; GMAIL_TRASH_DAYS="0"; GMAIL_EMPTY_SPAM="0"
GMAIL_EMPTY_SENT="0"; GMAIL_SENT_DAYS="0"
TZ_VAL="$(cat /etc/timezone 2>/dev/null || echo Europe/Vienna)"
ENTRIES=()

while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%$'\r'}"
  [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue
  if [[ "$line" =~ ^[[:space:]]*([A-Z_0-9]+)[[:space:]]*=(.*)$ ]]; then
    key="${BASH_REMATCH[1]}"; val="$(trim "${BASH_REMATCH[2]}")"
    val="${val%\"}"; val="${val#\"}"
    case "$key" in
      DOMAIN) DOMAIN="$val" ;;
      CF_API_TOKEN) CF_API_TOKEN="$val" ;;
      CF_TUNNEL_TOKEN) CF_TUNNEL_TOKEN="$val" ;;
      LE_EMAIL) LE_EMAIL="$val" ;;
      WEBMAIL_PORT) WEBMAIL_PORT="$val" ;;
      WEBMAIL_BIND) WEBMAIL_BIND="$val" ;;
      DDNS) DDNS="$val" ;;
      IMPORT_MODE) IMPORT_MODE="$val" ;;
      GMAIL_EMPTY_TRASH) GMAIL_EMPTY_TRASH="$val" ;;
      GMAIL_TRASH_DAYS) GMAIL_TRASH_DAYS="$val" ;;
      GMAIL_EMPTY_SPAM) GMAIL_EMPTY_SPAM="$val" ;;
      GMAIL_EMPTY_SENT) GMAIL_EMPTY_SENT="$val" ;;
      GMAIL_SENT_DAYS) GMAIL_SENT_DAYS="$val" ;;
      TIMEZONE) TZ_VAL="$val" ;;
      DMS_TAG) DMS_TAG="$val" ;;
      ROUNDCUBE_TAG) ROUNDCUBE_TAG="$val" ;;
      DDNS_TAG) DDNS_TAG="$val" ;;
      CLOUDFLARED_TAG) CLOUDFLARED_TAG="$val" ;;
      CERTBOT_TAG) CERTBOT_TAG="$val" ;;
      *) die "Unbekannte Einstellung in accounts.conf: $key" ;;
    esac
  else
    ENTRIES+=("$line")
  fi
done < "$CONF"

[[ ${#ENTRIES[@]} -gt 0 ]] || die "Keine Konten in accounts.conf eingetragen."
[[ "$IMPORT_MODE" == "all" || "$IMPORT_MODE" == "alle" ]] && IMPORT_MODE="alles"
[[ "$IMPORT_MODE" == "ordner" || "$IMPORT_MODE" == "alles" ]] || die "IMPORT_MODE muss 'ordner' oder 'alles' sein (ist: $IMPORT_MODE)."
[[ "$GMAIL_TRASH_DAYS" =~ ^[0-9]+$ ]] || die "GMAIL_TRASH_DAYS muss eine Zahl sein (0 = sofort)."
[[ "$GMAIL_SENT_DAYS" =~ ^[0-9]+$ ]] || die "GMAIL_SENT_DAYS muss eine Zahl sein (0 = alle)."
[[ "$WEBMAIL_PORT" =~ ^[0-9]{1,5}$ ]] || die "WEBMAIL_PORT muss eine Portnummer sein (ist: $WEBMAIL_PORT)."
[[ "$WEBMAIL_BIND" =~ ^[0-9.]+$ ]] || die "WEBMAIL_BIND muss eine IPv4-Adresse sein, z. B. 0.0.0.0 oder 127.0.0.1 (ist: $WEBMAIL_BIND)."
[[ "$DDNS" == "0" || "$DDNS" == "1" ]] || die "DDNS muss 0 oder 1 sein (ist: $DDNS)."
for v in CF_API_TOKEN CF_TUNNEL_TOKEN; do   # landen in .env: keine Sonderzeichen zulassen
  [[ "${!v}" =~ ^[A-Za-z0-9_=+/.-]*$ ]] || die "$v enthält ungültige Zeichen (erlaubt: Buchstaben, Ziffern und _ = + / . -)."
done
for v in DMS_TAG ROUNDCUBE_TAG DDNS_TAG CLOUDFLARED_TAG CERTBOT_TAG; do
  [[ "${!v}" =~ ^[A-Za-z0-9._-]+$ ]] || die "$v ist kein gültiger Image-Tag."
done
[[ -z "$DOMAIN" || "$DOMAIN" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || die "DOMAIN ist ungültig (ist: $DOMAIN). Nur den Domainnamen eintragen, z. B. deinedomain.at."

if [[ -n "$DOMAIN" ]]; then MAILDOM="$DOMAIN"; FQDN="mail.$DOMAIN"; else MAILDOM="home.lan"; FQDN="mail.home.lan"; fi
USE_LE=0
[[ -n "$DOMAIN" && -n "$CF_API_TOKEN" && -n "$LE_EMAIL" ]] && USE_LE=1

# Konten in Arrays zerlegen: adresse|passwort|lokaler-name|lokales-passwort|quota|anbieter
G_MAIL=(); G_PASS=(); G_PROV=(); L_ADDR=(); L_PASS=(); L_QUOTA=()
for e in "${ENTRIES[@]}"; do
  IFS='|' read -r a b c d f g <<<"$e"
  a="$(trim "${a:-}")"; b="$(trim "${b:-}")"; c="$(trim "${c:-}")"; d="$(trim "${d:-}")"; f="$(trim "${f:-}")"; g="$(trim "${g:-}")"
  [[ "$a" == *@* && -n "$b" ]] || die "Ungültige Kontozeile: $a  (Format: adresse|passwort|lokalname|lokales-passwort|quota|anbieter)"
  g="${g,,}"
  if [[ -z "$g" ]]; then
    g="$(detect_provider "$a")"
    [[ -n "$g" ]] || die "Anbieter von $a nicht erkannt. Als sechstes Feld gmail, gmx oder yahoo eintragen."
  fi
  [[ -n "${PROV_NAME[$g]:-}" ]] || die "Unbekannter Anbieter '$g' bei $a (erlaubt: gmail, gmx, yahoo)."
  c="${c:-${a%@*}}"
  [[ "$c" == *@* ]] || c="$c@$MAILDOM"
  [[ "$c" =~ ^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+$ ]] || die "Ungültiger lokaler Name: $c"
  # App-Passwörter (Gmail, Yahoo) werden oft mit Leerzeichen angezeigt; ein GMX-Passwort bleibt unverändert
  [[ "$g" == "gmx" ]] || b="${b// /}"
  G_MAIL+=("$a"); G_PASS+=("$b"); G_PROV+=("$g"); L_ADDR+=("$c"); L_PASS+=("$d"); L_QUOTA+=("$f")
done

# ---------------------------------------------------------------- Zugangsdaten testen
# curl liest Benutzer und Passwort aus der Konfiguration auf stdin, damit sie nicht in der Prozessliste stehen.
curl_login() {   # $1 = URL  $2 = Benutzer  $3 = Passwort  -> Exit-Code von curl
  local rc=0
  printf 'user = %s\n' "$(dq "$2:$3")" | curl -sS -K - --max-time 40 --url "$1" -o /dev/null 2>/dev/null || rc=$?
  return "$rc"
}
login_hint() {
  case "$1" in
    0)  echo "OK" ;;
    67) echo "ANMELDUNG ABGELEHNT (Passwort bzw. App-Passwort falsch, oder POP/IMAP beim Anbieter nicht aktiviert)" ;;
    6)  echo "Server nicht gefunden (Internetverbindung/DNS prüfen)" ;;
    28) echo "Zeitüberschreitung" ;;
    35|60) echo "TLS-Fehler" ;;
    *)  echo "Fehler (curl-Code $1)" ;;
  esac
}
check_accounts() {
  command -v curl >/dev/null || { apt-get update -qq && apt-get install -y -qq curl; }
  local i rc bad=0
  for i in "${!G_MAIL[@]}"; do
    echo "${G_MAIL[$i]} (${PROV_NAME[${G_PROV[$i]}]}):"
    rc=0; curl_login "imaps://$(prov_host imap "${G_PROV[$i]}" "${G_MAIL[$i]}")/" "${G_MAIL[$i]}" "${G_PASS[$i]}" || rc=$?
    printf '  IMAP (%s): %s\n' "$(prov_host imap "${G_PROV[$i]}" "${G_MAIL[$i]}")" "$(login_hint "$rc")"; ((rc == 0)) || bad=1
    rc=0; curl_login "pop3s://$(prov_host pop "${G_PROV[$i]}" "${G_MAIL[$i]}")/" "${G_MAIL[$i]}" "${G_PASS[$i]}" || rc=$?
    printf '  POP3 (%s): %s\n' "$(prov_host pop "${G_PROV[$i]}" "${G_MAIL[$i]}")" "$(login_hint "$rc")"; ((rc == 0)) || bad=1
  done
  return "$bad"
}
if [[ "$MODE" == "check" ]]; then
  say "Zugangsdaten testen (${#G_MAIL[@]} Konten)"
  if check_accounts; then echo; echo "Alle Anmeldungen funktionieren."; exit 0; fi
  echo; die "Mindestens eine Anmeldung ist fehlgeschlagen (siehe oben). Hinweise zu den Anbietern: README, Abschnitt 6."
fi

# ---------------------------------------------------------------- Import-Status und Gmail aufräumen
MARK="$BASE/data/import-done"

# Wurde für dieses Konto schon importiert?
#   done    = Import abgeschlossen (Vermerk dieses Skripts)
#   resume  = Import wurde begonnen, aber nicht abgeschlossen (mit diesem Skript)
#   legacy  = Statusdateien von mbsync vorhanden (Import mit einer älteren Skriptversion)
#   fresh   = noch nie importiert
import_state() {   # $1 = lokale Adresse, $2 = Postfach-Ordner
  if   [[ -f "$MARK/$1.done" ]];    then echo "done"
  elif [[ -f "$MARK/$1.started" ]]; then echo resume
  elif [[ -n "$(find "$2" -type f \( -name .mbsyncstate -o -name .uidvalidity \) -print -quit 2>/dev/null)" ]]; then echo legacy
  else echo fresh; fi
}

# Löscht bei Gmail ENDGÜLTIG (nicht rückgängig zu machen):
#   - den Papierkorb (und optional Spam)                                 [$1 = 1]
#   - den Ordner "Gesendet": erst in den Papierkorb verschieben          [$2 = 1]
# Gilt nur für Gmail-Konten. GMX und Yahoo werden nicht aufgeräumt: Die Abholung per POP3 löscht
# neue Mails dort ohnehin, und ihre Ordnernamen sind nicht einheitlich genug für ein sicheres Löschen.
# Schutz: Ein Konto wird übersprungen, solange lokal noch keine Mails liegen. "Gesendet" wird
# zusätzlich nur bereinigt, wenn der Import des Kontos abgeschlossen ist.
gmail_cleanup() {   # $1 = Papierkorb leeren (1/0), $2 = Gesendet bereinigen (1/0)
  command -v docker >/dev/null || die "Docker fehlt."
  local i A U D T S do_trash do_sent
  for i in "${!L_ADDR[@]}"; do
    [[ "${G_PROV[$i]}" == "gmail" ]] || continue
    A="${L_ADDR[$i]}"; U="${A%@*}"; D="${A#*@}"; T="$BASE/data/mail-data/$D/$U"
    do_trash="$1"; do_sent="$2"
    if [[ -z "$(find "$T" -type f \( -path '*/cur/*' -o -path '*/new/*' \) -print -quit 2>/dev/null)" ]]; then
      echo "  ${G_MAIL[$i]}: übersprungen (lokal noch keine Mails, erst Import prüfen)"
      continue
    fi
    if [[ "$do_sent" == "1" ]]; then
      S="$(import_state "$A" "$T")"
      if [[ "$S" != "done" && "$S" != "legacy" ]]; then
        echo "  ${G_MAIL[$i]}: 'Gesendet' übersprungen (Import nicht abgeschlossen)"
        do_sent=0
      fi
    fi
    [[ "$do_trash" == "1" || "$do_sent" == "1" ]] || continue
    echo "  ${G_MAIL[$i]}:"
    GM_USER="${G_MAIL[$i]}" GM_PASS="${G_PASS[$i]}" GM_DAYS="$GMAIL_TRASH_DAYS" GM_SPAM="$GMAIL_EMPTY_SPAM" \
    GM_TRASH="$do_trash" GM_SENT="$do_sent" GM_SENT_DAYS="$GMAIL_SENT_DAYS" \
    docker run --rm -i -e GM_USER -e GM_PASS -e GM_DAYS -e GM_SPAM -e GM_TRASH -e GM_SENT -e GM_SENT_DAYS \
      python:3-alpine python -I - <<'PY' || echo "  Fehlgeschlagen für ${G_MAIL[$i]} (App-Passwort und IMAP prüfen)"
import imaplib, os, re, datetime

user, pw = os.environ["GM_USER"], os.environ["GM_PASS"]

def num(key):
    return int(os.environ.get(key, "0") or 0)

trash_days, sent_days = num("GM_DAYS"), num("GM_SENT_DAYS")
do_trash = os.environ.get("GM_TRASH") == "1"
do_sent = os.environ.get("GM_SENT") == "1"
do_spam = os.environ.get("GM_SPAM") == "1"

M = imaplib.IMAP4_SSL("imap.gmail.com")
M.login(user, pw)

# Sonderordner über die IMAP-Kennzeichen finden (unabhängig von der Sprache)
box = {}
for raw in M.list()[1]:
    line = raw.decode("utf-8", "replace")
    m = re.match(r'\((?P<flags>[^)]*)\)\s+"(?P<sep>[^"]*)"\s+(?P<name>.+)$', line)
    if not m:
        continue
    flags, name = m.group("flags"), m.group("name").strip().strip('"')
    for key in ("Trash", "Sent", "Junk"):
        if "\\" + key in flags:
            box[key] = name

def find(days):
    if days > 0:
        d = (datetime.date.today() - datetime.timedelta(days=days)).strftime("%d-%b-%Y")
        return M.search(None, "BEFORE", d)[1][0].split()
    return M.search(None, "ALL")[1][0].split()

def chunks(ids, n=500):
    for i in range(0, len(ids), n):
        yield b",".join(ids[i:i + n])

# 1) Gesendet -> Papierkorb (die Kopie, die Gmail beim Senden über den Relay ablegt)
if do_sent:
    if "Sent" not in box or "Trash" not in box:
        print("    Gesendet- oder Papierkorb-Ordner nicht gefunden, übersprungen")
    elif M.select('"%s"' % box["Sent"])[0] != "OK":
        print("    %s: nicht lesbar" % box["Sent"])
    else:
        moved = 0
        for ch in chunks(find(sent_days)):
            if M.copy(ch, '"%s"' % box["Trash"])[0] != "OK":
                print("    Verschieben in den Papierkorb fehlgeschlagen, Abbruch")
                break
            M.store(ch, "+FLAGS", "\\Deleted")
            moved += ch.count(b",") + 1
        if moved:
            M.expunge()
        M.close()
        print("    %s: %d Nachrichten in den Papierkorb verschoben" % (box["Sent"], moved))

# 2) Papierkorb (und optional Spam) endgültig leeren
if do_trash:
    targets = []
    if "Trash" in box:
        targets.append(box["Trash"])
    else:
        print("    kein Papierkorb-Ordner gefunden")
    if do_spam and "Junk" in box:
        targets.append(box["Junk"])
    for name in targets:
        if M.select('"%s"' % name)[0] != "OK":
            print("    %s: nicht lesbar" % name)
            continue
        ids = find(trash_days)
        for ch in chunks(ids):
            M.store(ch, "+FLAGS", "\\Deleted")
        if ids:
            M.expunge()
        print("    %s: %d Nachrichten endgültig gelöscht" % (name, len(ids)))
        M.close()

M.logout()
PY
  done
}

# Nur Gmail aufräumen, nichts installieren
#   --cleanup      = nach den Einstellungen in accounts.conf (das nutzt der tägliche Cron-Job)
#   --empty-trash  = Papierkorb jetzt leeren, unabhängig von GMAIL_EMPTY_TRASH
if [[ "$MODE" == "cleanup" || "$MODE" == "empty-trash" ]]; then
  say "Gmail aufräumen ($(date '+%F %T'))"
  if [[ "$MODE" == "empty-trash" ]]; then CT=1; else CT="$GMAIL_EMPTY_TRASH"; fi
  if [[ "$CT" != "1" && "$GMAIL_EMPTY_SENT" != "1" ]]; then
    echo "  Nichts zu tun (GMAIL_EMPTY_TRASH und GMAIL_EMPTY_SENT sind aus)."
  else
    gmail_cleanup "$CT" "$GMAIL_EMPTY_SENT"
  fi
  exit 0
fi

# ---------------------------------------------------------------- Rückfrage
PROV_LIST="$(printf '%s\n' "${G_PROV[@]}" | sort -u | tr '\n' ' ')"
if ((! ASSUME_YES)); then
  if [[ "$MODE" == "update" ]]; then
    cat <<EOF

UPDATE einer bestehenden Installation:
  - Es wird KEIN Import durchgeführt, die Abholung (POP3) bleibt eingeschaltet.
  - Bestehende Konten und Passwörter bleiben unverändert, Mails werden nicht angefasst.
  - Neu geschrieben werden: docker-compose.yml, .env, Relay-/Abholungs-Einstellungen, Roundcube-Konfiguration.
    Eine Kopie des bisherigen Stands wird vorher in config-backup/ abgelegt.
  - Container und Images werden aktualisiert (kurze Unterbrechung von ein bis zwei Minuten).
  - Empfehlung: vorher ein Backup (./backup-mail.sh).

Konten: ${#L_ADDR[@]}   Anbieter: $PROV_LIST  Maildomain: $MAILDOM
EOF
    read -r -p "Update jetzt durchführen? [j/N] " ans
  else
    cat <<EOF

Bevor es losgeht (einmalig pro Konto, im Browser; Einzelheiten: README, Abschnitt 6):
  Gmail:  2-Faktor aktivieren, App-Passwort erstellen. Einstellungen > Weiterleitung und POP/IMAP:
          POP "ab jetzt eingehende Nachrichten" und "Gmail-Kopie löschen" (sonst Doppelmails).
  GMX:    Einstellungen > POP3 & IMAP > "POP3 und IMAP Zugriff erlauben" einschalten.
  Yahoo:  Kontosicherheit > "App-Passwort generieren" und dieses Passwort verwenden.

Konten: ${#L_ADDR[@]}   Anbieter: $PROV_LIST  Maildomain: $MAILDOM
Importmodus (nur Gmail): $IMPORT_MODE
Externer Zugriff: $( ((USE_LE)) && echo "Domain + Let's Encrypt" || echo "nur lokal (self-signed)" )$( [[ -n "$CF_TUNNEL_TOKEN" ]] && echo " + Cloudflare Tunnel (Webmail)" )
Tipp: Zugangsdaten vorab prüfen mit ./setup-mailserver.sh --check
Läuft hier schon ein System? Dann Abbrechen und stattdessen: ./setup-mailserver.sh --update
EOF
    read -r -p "Alles erledigt, jetzt installieren? [j/N] " ans
  fi
  [[ "$ans" =~ ^[jJyY]$ ]] || exit 0
fi

# ---------------------------------------------------------------- Voraussetzungen
say "Voraussetzungen prüfen"
for t in curl openssl; do
  command -v "$t" >/dev/null || { apt-get update -qq && apt-get install -y -qq "$t"; }
done
command -v docker >/dev/null || curl -fsSL https://get.docker.com | sh
docker compose version >/dev/null 2>&1 || die "'docker compose' fehlt. Bitte Docker mit Compose-Plugin installieren."

# Kopie der bisherigen Konfiguration, bevor Dateien neu geschrieben werden
CB=""
if [[ -f docker-compose.yml || -d data/config ]]; then
  CB="$BASE/config-backup/$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$CB"
  cp -a docker-compose.yml .env "$CB/" 2>/dev/null || true
  [[ -d data/config ]] && cp -a data/config "$CB/config" || true
  [[ -d data/roundcube/config ]] && cp -a data/roundcube/config "$CB/roundcube-config" || true
  chmod -R go-rwx "$BASE/config-backup"
  echo "  Bisherige Konfiguration gesichert in: $CB"
fi

mkdir -p data/mail-data data/mail-state data/mail-logs data/config data/certs data/certbot data/roundcube/db data/roundcube/config "$MARK"

# ---------------------------------------------------------------- Zertifikat
if ((USE_LE)); then
  say "Let's-Encrypt-Zertifikat für $FQDN holen (DNS-Challenge über Cloudflare)"
  ( umask 077; printf 'dns_cloudflare_api_token = %s\n' "$CF_API_TOKEN" > data/cloudflare.ini )
  if [[ ! -d "data/certbot/live/$FQDN" ]]; then
    docker run --rm \
      -v "$BASE/data/certbot:/etc/letsencrypt" \
      -v "$BASE/data/cloudflare.ini:/cloudflare.ini:ro" \
      "certbot/dns-cloudflare:$CERTBOT_TAG" certonly --dns-cloudflare --dns-cloudflare-credentials /cloudflare.ini \
      -d "$FQDN" -m "$LE_EMAIL" --agree-tos --no-eff-email --non-interactive
  fi
  # Der Mailserver bemerkt erneuerte Zertifikate selbst und lädt sie neu.
  cat > "$CRON_DIR/mailserver-certbot" <<EOF
17 3 * * 1 root docker run --rm -v '$BASE/data/certbot:/etc/letsencrypt' -v '$BASE/data/cloudflare.ini:/cloudflare.ini:ro' certbot/dns-cloudflare:$CERTBOT_TAG renew --quiet
EOF
  SSL_ENV="      - SSL_TYPE=letsencrypt"
  SSL_VOL="      - ./data/certbot:/etc/letsencrypt:ro"
else
  say "Self-signed Zertifikat erzeugen"
  if [[ ! -f data/certs/cert.pem ]]; then
    openssl req -x509 -nodes -newkey rsa:4096 -days 3650 \
      -keyout data/certs/key.pem -out data/certs/cert.pem \
      -subj "/CN=$FQDN" -addext "subjectAltName=DNS:$FQDN" 2>/dev/null
  fi
  chmod 600 data/certs/key.pem
  SSL_ENV=$'      - SSL_TYPE=manual\n      - SSL_CERT_PATH=/certs/cert.pem\n      - SSL_KEY_PATH=/certs/key.pem'
  SSL_VOL="      - ./data/certs:/certs:ro"
fi

# ---------------------------------------------------------------- Roundcube-Konfiguration
# Bei selbst signiertem Zertifikat vertraut Roundcube genau diesem Zertifikat (keine abgeschaltete Prüfung).
{
  echo "<?php"
  echo "\$config['smtp_user'] = '%u';"
  echo "\$config['smtp_pass'] = '%p';"
  if ((! USE_LE)); then
    echo "\$config['imap_conn_options'] = ['ssl' => ['verify_peer' => true, 'verify_peer_name' => true, 'cafile' => '/certs/cert.pem']];"
    echo "\$config['smtp_conn_options'] = ['ssl' => ['verify_peer' => true, 'verify_peer_name' => true, 'cafile' => '/certs/cert.pem']];"
  fi
} > data/roundcube/config/custom.inc.php

# ---------------------------------------------------------------- .env (Versionen, Geheimnisse, Abholung)
# Die Geheimnisse stehen nur hier (Rechte 640, Gruppe docker), nicht in docker-compose.yml.
write_env() {   # $1 = FETCHMAIL (0|1)
  ( umask 027
    {
      echo "FETCHMAIL=$1"
      echo "DMS_TAG=$DMS_TAG"
      echo "ROUNDCUBE_TAG=$ROUNDCUBE_TAG"
      echo "DDNS_TAG=$DDNS_TAG"
      echo "CLOUDFLARED_TAG=$CLOUDFLARED_TAG"
      [[ -z "$CF_TUNNEL_TOKEN" ]] || echo "CF_TUNNEL_TOKEN=$CF_TUNNEL_TOKEN"
      [[ -z "$CF_API_TOKEN" ]]    || echo "CF_API_TOKEN=$CF_API_TOKEN"
    } > .env )
  if getent group docker >/dev/null; then chgrp docker .env; fi
  chmod 640 .env
}

# ---------------------------------------------------------------- docker-compose.yml
say "docker-compose.yml schreiben"
cat > docker-compose.yml <<EOF
# Erzeugt von setup-mailserver.sh. Nicht von Hand ändern: Änderungen gehen beim nächsten Lauf verloren.
# Versionen und Geheimnisse stehen in .env.
x-logging: &logging
  driver: json-file
  options:
    max-size: "10m"
    max-file: "3"

services:
  mailserver:
    image: ghcr.io/docker-mailserver/docker-mailserver:\${DMS_TAG}
    container_name: mailserver
    hostname: $FQDN
    ports:
      - "993:993"
      - "587:587"
    volumes:
      - ./data/mail-data:/var/mail
      - ./data/mail-state:/var/mail-state
      - ./data/mail-logs:/var/log/mail
      - ./data/config:/tmp/docker-mailserver
      - /etc/localtime:/etc/localtime:ro
$SSL_VOL
    environment:
      - TZ=$TZ_VAL
      - ENABLE_FETCHMAIL=\${FETCHMAIL:-0}
      - FETCHMAIL_POLL=5
      - ENABLE_POP3=0
      - ENABLE_CLAMAV=0
      - ENABLE_SPAMASSASSIN=0
      - ENABLE_FAIL2BAN=1
      - ENABLE_QUOTAS=1
$SSL_ENV
    cap_add:
      - NET_ADMIN
    networks:
      default:
        aliases:
          - $FQDN
    logging: *logging
    restart: always

  roundcube:
    image: roundcube/roundcubemail:\${ROUNDCUBE_TAG}
    container_name: roundcube
    depends_on:
      - mailserver
    volumes:
      - ./data/roundcube/db:/var/roundcube/db
      - ./data/roundcube/config:/var/roundcube/config
$( ((USE_LE)) || echo "      - ./data/certs/cert.pem:/certs/cert.pem:ro" )
    environment:
      - ROUNDCUBEMAIL_DB_TYPE=sqlite
      - ROUNDCUBEMAIL_DEFAULT_HOST=ssl://$FQDN
      - ROUNDCUBEMAIL_DEFAULT_PORT=993
      - ROUNDCUBEMAIL_SMTP_SERVER=tls://$FQDN
      - ROUNDCUBEMAIL_SMTP_PORT=587
    ports:
      - "$WEBMAIL_BIND:$WEBMAIL_PORT:80"
    security_opt:
      - no-new-privileges:true
    logging: *logging
    restart: always
EOF

if [[ -n "$CF_TUNNEL_TOKEN" ]]; then
cat >> docker-compose.yml <<EOF

  cloudflared:
    image: cloudflare/cloudflared:\${CLOUDFLARED_TAG}
    container_name: cloudflared
    command: tunnel --no-autoupdate run
    environment:
      - TUNNEL_TOKEN=\${CF_TUNNEL_TOKEN}
    security_opt:
      - no-new-privileges:true
    logging: *logging
    restart: always
EOF
fi

if ((USE_LE)) && [[ "$DDNS" == "1" ]]; then
cat >> docker-compose.yml <<EOF

  ddns:
    image: favonia/cloudflare-ddns:\${DDNS_TAG}
    container_name: ddns
    network_mode: host
    cap_drop: [all]
    read_only: true
    security_opt: [no-new-privileges:true]
    environment:
      - CLOUDFLARE_API_TOKEN=\${CF_API_TOKEN}
      - DOMAINS=$FQDN
      - PROXIED=false
      - IP6_PROVIDER=none
    logging: *logging
    restart: always
EOF
fi
if getent group docker >/dev/null; then chgrp docker docker-compose.yml; fi
chmod 640 docker-compose.yml

# ---------------------------------------------------------------- Konten anlegen
DMS_IMAGE="ghcr.io/docker-mailserver/docker-mailserver:$DMS_TAG"
docker pull -q "$DMS_IMAGE" >/dev/null
dms_setup() { docker run --rm -v "$BASE/data/config:/tmp/docker-mailserver" "$DMS_IMAGE" setup "$@"; }
# Passwort über stdin statt als Befehlsargument (steht sonst kurz in der Prozessliste des Hosts)
dms_add_account() {   # $1 = Adresse  $2 = Passwort
  printf '%s\n' "$2" | docker run --rm -i -v "$BASE/data/config:/tmp/docker-mailserver" "$DMS_IMAGE" \
    sh -c 'IFS= read -r p; exec setup email add "$0" "$p"' "$1"
}

say "Konten anlegen"
touch data/config/postfix-accounts.cf
CRED="$BASE/zugangsdaten.txt"; ( umask 077; touch "$CRED" ); chmod 600 "$CRED"
: > data/config/postfix-relaymap.cf
( umask 077; : > data/config/postfix-sasl-password.cf )

for i in "${!L_ADDR[@]}"; do
  A="${L_ADDR[$i]}"
  if awk -F'|' -v a="$A" '$1 == a { f = 1 } END { exit !f }' data/config/postfix-accounts.cf; then
    echo "  $A existiert bereits"
  else
    P="${L_PASS[$i]:-$(openssl rand -hex 8)}"
    dms_add_account "$A" "$P" >/dev/null
    [[ -n "${L_QUOTA[$i]}" ]] && dms_setup quota set "$A" "${L_QUOTA[$i]}" >/dev/null
    printf '%s  %s\n' "$A" "$P" >> "$CRED"
    echo "  $A angelegt"
  fi
  echo "$A [$(prov_host smtp "${G_PROV[$i]}" "${G_MAIL[$i]}")]:587" >> data/config/postfix-relaymap.cf
  echo "$A ${G_MAIL[$i]}:${G_PASS[$i]}" >> data/config/postfix-sasl-password.cf
done
chmod 600 data/config/postfix-sasl-password.cf

# ---------------------------------------------------------------- Start
say "Container starten"
if [[ "$MODE" == "update" ]]; then
  # Update: Abholung bleibt, wie sie ist (nur einschalten, falls keine .env vorhanden war)
  FETCH_NOW="$(sed -n 's/^FETCHMAIL=//p' "$CB/.env" 2>/dev/null | head -n1)"
  write_env "${FETCH_NOW:-1}"
else
  # Erstinstallation: Abholung während des Imports aus, sonst entstehen Dubletten
  write_env 0
fi
docker compose pull -q
docker compose up -d

wait_dovecot() {
  local _
  for _ in $(seq 1 60); do
    if docker exec mailserver supervisorctl status dovecot 2>/dev/null | grep -q RUNNING \
       && (exec 3<>"/dev/tcp/127.0.0.1/$CHECK_PORT") 2>/dev/null; then
      return 0
    fi
    sleep 3
  done
  die "Mailserver startet nicht. Log ansehen: docker logs mailserver"
}
wait_dovecot

# ---------------------------------------------------------------- Import per IMAP
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FAILED=()

for i in "${!L_ADDR[@]}"; do
  A="${L_ADDR[$i]}"; U="${A%@*}"; D="${A#*@}"
  PV="${G_PROV[$i]}"; PN="${PROV_NAME[$PV]}"
  TARGET="$BASE/data/mail-data/$D/$U"
  STATE="$(import_state "$A" "$TARGET")"

  # Bestehende Systeme: nie importieren. Schon importierte Konten: nicht noch einmal (keine Dubletten).
  if [[ "$MODE" == "update" ]]; then
    case "$STATE" in
      legacy) touch "$MARK/$A.done"; echo "  $A: Import war schon erfolgt, wird nicht wiederholt" ;;
      resume) echo "  $A: ACHTUNG, Import war nicht abgeschlossen. Mit './setup-mailserver.sh' (ohne --update) fortsetzen." ;;
      *)      echo "  $A: Import übersprungen (Update-Modus)" ;;
    esac
    continue
  fi
  if ((! REIMPORT)); then
    case "$STATE" in
      done)   echo "  $A: Import bereits abgeschlossen, übersprungen (erneut mit --reimport)"; continue ;;
      legacy) echo "  $A: Import war schon erfolgt (ältere Version), übersprungen (erneut mit --reimport)"
              touch "$MARK/$A.done"; continue ;;
    esac
  fi

  say "Import ${G_MAIL[$i]} ($PN) -> $A (kann bei großen Postfächern Stunden dauern)"
  mkdir -p "$TARGET"
  touch "$MARK/$A.started"
  CFG="$TMP/mbsyncrc.$i"
  # Sync PullNew: holt nur NEUE Nachrichten vom Anbieter. Es wird nichts hochgeladen,
  # nichts gelöscht und es werden keine Markierungen verändert (keine Dubletten, kein Verlust).
  ( umask 077
    cat > "$CFG" <<EOF
IMAPAccount remote
Host $(prov_host imap "$PV" "${G_MAIL[$i]}")
User $(dq "${G_MAIL[$i]}")
Pass $(dq "${G_PASS[$i]}")
TLSType IMAPS
CertificateFile /etc/ssl/certs/ca-certificates.crt
Timeout 120

IMAPStore remote-remote
Account remote

MaildirStore local
Inbox /srv/mail/
SubFolders Maildir++

Channel remote
Far :remote-remote:
Near :local:
Patterns $(import_patterns "$PV")
Create Near
Sync PullNew
Expunge None
SyncState *
EOF
  )
  if docker run --rm -v "$CFG":/root/.mbsyncrc:ro -v "$TARGET":/srv/mail alpine \
       sh -c "apk add --no-cache isync ca-certificates >/dev/null && mbsync -a"; then
    echo "  Import ok"
    touch "$MARK/$A.done"
  else
    echo "  Import für ${G_MAIL[$i]} fehlgeschlagen (Passwort und IMAP-Zugriff beim Anbieter prüfen)."
    FAILED+=("${G_MAIL[$i]}")
  fi
  chown -R 5000:5000 "$BASE/data/mail-data/$D"
done

# ---------------------------------------------------------------- Laufende Abholung einschalten
say "Laufende Abholung (POP3) einschalten"
( umask 077; : > data/config/fetchmail.cf )
for i in "${!L_ADDR[@]}"; do
  cat >> data/config/fetchmail.cf <<EOF
poll '$(prov_host pop "${G_PROV[$i]}" "${G_MAIL[$i]}")' proto POP3 port 995
  user $(dq "${G_MAIL[$i]}")
  pass $(dq "${G_PASS[$i]}")
  is '${L_ADDR[$i]}' here
  ssl
  sslcertck
  nokeep

EOF
done
chmod 600 data/config/fetchmail.cf
write_env 1
docker compose up -d
wait_dovecot
for A in "${L_ADDR[@]}"; do
  docker exec mailserver doveadm force-resync -u "$A" '*' || warn "Index für $A konnte nicht neu aufgebaut werden (docker logs mailserver)."
done

# ---------------------------------------------------------------- Täglicher Gmail-Aufräum-Job
if [[ "$GMAIL_EMPTY_TRASH" == "1" || "$GMAIL_EMPTY_SENT" == "1" ]]; then
  say "Täglicher Job: Gmail aufräumen (04:45 Uhr)"
  echo "45 4 * * * root '$SELF' --cleanup >> /var/log/mail-gmail-cleanup.log 2>&1" > "$CRON_DIR/mailserver-gmail-cleanup"
else
  rm -f "$CRON_DIR/mailserver-gmail-cleanup"
fi
rm -f "$CRON_DIR/mailserver-gmail-trash"   # Vorgänger-Version

# ---------------------------------------------------------------- Fertig
say "Fertig"
if [[ "$MODE" == "update" ]]; then
  echo "Update abgeschlossen. Es wurde nichts importiert, Mails und Passwörter blieben unverändert."
  [[ -n "$CB" ]] && echo "Bisherige Konfiguration: $CB"
  exit 0
fi
cat <<EOF

Zugangsdaten der lokalen Konten: $CRED   (nur für root lesbar; nach dem Notieren löschen)
  Anzeigen mit:  sudo cat $CRED

Mailclient (Thunderbird, Handy):
  IMAP  $FQDN  Port 993 (SSL/TLS)
  SMTP  $FQDN  Port 587 (STARTTLS)
  Benutzername = komplette lokale Adresse
Webmail im Heimnetz:  http://<server-ip>:$WEBMAIL_PORT
EOF

if ((USE_LE)); then
cat <<EOF

Externer Zugriff für Mailclients ohne VPN:
  - Im Router NUR Port 993 und 587 auf diesen Server weiterleiten (Port 25 NICHT).
  - $FQDN zeigt per DDNS automatisch auf deine IP (Cloudflare-Eintrag auf "Nur DNS", graue Wolke).
  - Fail2ban ist aktiv.
EOF
fi

if [[ -n "$CF_TUNNEL_TOKEN" ]]; then
cat <<EOF

Webmail von außen über Cloudflare Tunnel (ohne Portfreigabe):
  Cloudflare Zero Trust > Networks > Tunnels > dein Tunnel > Public Hostname:
  z. B. webmail.${DOMAIN:-deinedomain.at}  ->  Typ HTTP, URL: roundcube:80
  Empfehlung: dort zusätzlich eine Cloudflare-Access-Richtlinie davorschalten.
EOF
fi

if [[ " ${G_PROV[*]} " == *" gmail "* && "$IMPORT_MODE" == "ordner" ]]; then
cat <<EOF

ACHTUNG vor dem Löschen bei Google (gilt für Gmail-Konten):
  Im Modus "ordner" werden Mails nicht importiert, die in Gmail archiviert sind und kein Label haben.
  Prüfe in Gmail die Suche:  has:nouserlabels -in:inbox -in:sent -in:drafts -in:spam -in:trash
  Gibt es Treffer: in Gmail ein Label (z. B. "Archiv") darauf setzen und ./setup-mailserver.sh --reimport
  starten, dann kommen sie als Ordner dazu. IMPORT_MODE=alles holt ALLES noch einmal und erzeugt bei einem
  schon importierten Konto Dubletten.
EOF
fi

if [[ " ${G_PROV[*]} " == *" gmx "* || " ${G_PROV[*]} " == *" yahoo "* ]]; then
cat <<EOF

Hinweis zu GMX und Yahoo:
  Der Posteingang dieser Konten kommt komplett über die laufende POP3-Abholung (alle 5 Minuten) und wird
  dabei beim Anbieter gelöscht. Bei einem großen Posteingang dauert die erste Abholung entsprechend länger.
  Prüfe nach einigen Minuten:  docker logs --tail 50 mailserver | grep -i fetchmail
EOF
fi

if ((${#FAILED[@]})); then
  printf '\nImport fehlgeschlagen für: %s\n' "${FAILED[*]}"
fi
echo
echo "Backup nicht vergessen: $BASE/data/mail-data"
