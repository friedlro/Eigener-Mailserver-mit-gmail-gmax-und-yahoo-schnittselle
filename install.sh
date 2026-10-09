#!/usr/bin/env bash
# install.sh - Installationsassistent mit Menüoberfläche (whiptail)
#
# Fragt alle relevanten Daten ab, schreibt accounts.conf und startet danach
# setup-mailserver.sh. Optional werden Tailscale, das Backup und der
# MCP-Server gleich mit eingerichtet.
#
# Nutzung:
#   sudo ./install.sh                Assistent starten
#   sudo ./install.sh --config-only  nur accounts.conf erzeugen, nichts installieren
#   sudo ./install.sh -h             Hilfe
#
# Deinstallation: ./uninstall.sh

set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
BASE="$(dirname "$SELF")"
[[ $EUID -eq 0 ]] || exec sudo -E bash "$SELF" "$@"
cd "$BASE"

TITLE="Mailserver-Installation"
CONF="$BASE/accounts.conf"
TS_GUIDE="https://tailscale.com/kb/1347/installation"
TS_LINUX="https://tailscale.com/kb/1031/install-linux"
CONFIG_ONLY=0

for arg in "$@"; do
  case "$arg" in
    --config-only) CONFIG_ONLY=1 ;;
    -h|--help) sed -n '2,/^$/p' "$SELF"; exit 0 ;;
    *) echo "Unbekannte Option: $arg (siehe --help)" >&2; exit 1 ;;
  esac
done

[[ -f "$BASE/setup-mailserver.sh" ]] || { echo "setup-mailserver.sh fehlt im Ordner $BASE." >&2; exit 1; }
[[ -t 0 && -t 1 ]] || { echo "Der Assistent braucht ein Terminal (interaktive Sitzung)." >&2; exit 1; }

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mHinweis: %s\033[0m\n' "$*" >&2; }

# ---------------------------------------------------------------- whiptail sicherstellen
if ! command -v whiptail >/dev/null; then
  command -v apt-get >/dev/null || { echo "whiptail fehlt und apt-get ist nicht vorhanden. Bitte whiptail installieren." >&2; exit 1; }
  say "whiptail wird installiert"
  apt-get update -qq && apt-get install -y -qq whiptail
fi
export NEWT_COLORS='root=,blue'

# ---------------------------------------------------------------- Dialog-Helfer
wt() { whiptail --title "$TITLE" "$@"; }

# Höhe der Box aus dem Text schätzen (Zeilen plus Umbrüche), begrenzt auf die Terminalhöhe
box_h() {
  local t="$1" n=0 l max
  while IFS= read -r l; do n=$(( n + 1 + ${#l} / 68 )); done <<<"$t"
  max=$(( $(tput lines 2>/dev/null || echo 24) - 2 ))
  n=$(( n + 7 )); (( n > max )) && n=$max
  echo "$n"
}
cancel() { clear; echo "Abgebrochen. Es wurde nichts installiert."; exit 1; }
# Doppelt angeführter String mit \\ und \" (für curl-Konfiguration)
dq()     { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '"%s"' "$s"; }
msg()    { wt --msgbox "$1" "$(box_h "$1")" 76; }
yesno()  { wt --yesno "$1" "$(box_h "$1")" 76; }                  # Standard: Ja
yesno_n(){ wt --defaultno --yesno "$1" "$(box_h "$1")" 76; }      # Standard: Nein
input()  { local r; r=$(wt --inputbox "$2" "$(box_h "$2")" 76 "${3:-}" 3>&1 1>&2 2>&3) || cancel; printf -v "$1" '%s' "$r"; }
secret() { local r; r=$(wt --passwordbox "$2" "$(box_h "$2")" 76 "" 3>&1 1>&2 2>&3) || cancel; printf -v "$1" '%s' "$r"; }

# Wiederholt die Eingabe, bis das Muster passt (leere Eingabe nur, wenn $5 = opt)
input_re() {   # var  text  default  regex  [opt]  [fehlertext]
  local v
  while :; do
    input v "$2" "$3"
    v="$(sed -E 's/^[[:space:]]+|[[:space:]]+$//g' <<<"$v")"
    if [[ -z "$v" && "${5:-}" == "opt" ]]; then break; fi
    [[ "$v" =~ $4 ]] && break
    msg "${6:-Ungültige Eingabe. Bitte erneut versuchen.}"
  done
  printf -v "$1" '%s' "$v"
}
secret_re() {  # var  text  regex  [opt]  [fehlertext]
  local v
  while :; do
    secret v "$2"
    if [[ -z "$v" && "${4:-}" == "opt" ]]; then break; fi
    [[ "$v" =~ $3 ]] && break
    msg "${5:-Ungültige Eingabe. Bitte erneut versuchen.}"
  done
  printf -v "$1" '%s' "$v"
}

[[ $(tput lines 2>/dev/null || echo 24) -ge 20 ]] || warn "Das Terminal ist sehr klein. Bitte das Fenster vergrößern, sonst werden Dialoge abgeschnitten."

# ---------------------------------------------------------------- Willkommen
msg "Dieser Assistent richtet einen lokalen Mailserver ein, der Mails von Gmail, GMX und Yahoo abholt, lokal speichert und beim Anbieter löscht.

Ablauf:
 1. Tailscale (optional)
 2. Konten (Anbieter frei wählbar) und Einstellungen eingeben
 3. Zusammenfassung prüfen
 4. Installation starten

Mit Abbrechen (ESC) beenden Sie den Assistenten jederzeit. Bis zur Bestätigung in Schritt 3 wird nichts verändert.

Vorher sollten Sie bei jedem Konto den Zugriff per POP/IMAP freigeschaltet und, wo nötig, ein App-Passwort erstellt haben. Der Assistent zeigt Ihnen bei jedem Anbieter, was zu tun ist (siehe auch README, Abschnitt 6)."

# ---------------------------------------------------------------- 1. Tailscale
INSTALL_TS=0; TS_SSH=0
if command -v tailscale >/dev/null; then
  msg "Tailscale ist bereits installiert. Der Schritt wird übersprungen."
else
  if yesno "Soll Tailscale installiert werden?

Tailscale ist ein VPN, über das Sie von unterwegs sicher auf den Mailserver zugreifen (ohne Portfreigabe im Router). Es ist optional und kann später nachgerüstet werden.

Anleitung:
  $TS_GUIDE
  $TS_LINUX

Nach der Installation erscheint ein Anmelde-Link, den Sie in einem Browser bestätigen müssen."; then
    INSTALL_TS=1
    yesno_n "Tailscale SSH aktivieren?

Damit können Sie sich über Tailscale ohne SSH-Schlüssel am Server anmelden. Empfohlen, wenn Sie den Server aus der Ferne verwalten." && TS_SSH=1 || true
  fi
fi

# ---------------------------------------------------------------- vorhandene Konfiguration
USE_EXISTING=0
if [[ -f "$CONF" ]]; then
  if yesno "Es gibt bereits eine accounts.conf in diesem Ordner.

Ja   = vorhandene Konfiguration verwenden (keine Eingaben nötig)
Nein = neu eingeben (die alte Datei wird als Sicherung abgelegt)"; then
    USE_EXISTING=1
  fi
fi

ACCOUNT_LINES=(); FIRST_GMAIL=""; ANY_GMAIL=0; PROVIDERS_USED=""
IMPORT_MODE="ordner"; WEBMAIL_PORT="8080"; WEBMAIL_BIND="0.0.0.0"; DOMAIN=""; CF_API_TOKEN=""; LE_EMAIL=""; CF_TUNNEL_TOKEN=""; DDNS="1"
CLEAN_TRASH=0; CLEAN_TRASH_DAYS=0; CLEAN_SPAM=0; CLEAN_SENT=0; CLEAN_SENT_DAYS=0
DO_BACKUP=0; BACKUP_DEST=""; DO_MCP=0
TZ_VAL="$(cat /etc/timezone 2>/dev/null || timedatectl show -p Timezone --value 2>/dev/null || echo Europe/Vienna)"

if (( ! USE_EXISTING )); then
  # -------------------------------------------------------------- 2. Konten
  msg "Konten

Jetzt tragen Sie die Konten ein, die abgeholt werden sollen. Pro Konto wählen Sie den Anbieter (Gmail, GMX oder Yahoo) und geben ein:
 - die Adresse
 - das Passwort für externe Programme (Gmail und Yahoo: App-Passwort)
 - optional: lokalen Namen, lokales Passwort und Speicherlimit"

  while :; do
    PV="$(wt --menu "Anbieter dieses Kontos:" 14 76 3 \
      gmail "Gmail / Google Mail" \
      gmx   "GMX (gmx.de, gmx.net, gmx.at, gmx.ch, gmx.com)" \
      yahoo "Yahoo (yahoo.com, yahoo.de, ymail.com ...)" 3>&1 1>&2 2>&3)" || cancel
    case "$PV" in
      gmail) PV_DOMS='^(gmail|googlemail)\.com$'; PV_NAME="Gmail"; PV_EX="anna@gmail.com"
             PV_HINT="Vorbereitung bei Google (einmalig):
 1. 2-Faktor-Anmeldung aktivieren und ein App-Passwort erstellen (Google-Konto > Sicherheit > App-Passwörter).
 2. Gmail > Einstellungen > Weiterleitung und POP/IMAP: IMAP aktivieren; POP für 'Nachrichten, die ab jetzt eingehen'; bei POP-Zugriff 'Gmail-Kopie löschen'." ;;
      gmx)   PV_DOMS='^gmx\.(de|net|at|ch|com|eu|org|info)$'; PV_NAME="GMX"; PV_EX="anna@gmx.de"
             PV_HINT="Vorbereitung bei GMX (einmalig):
 1. Im GMX-Postfach: Einstellungen > POP3 & IMAP > 'POP3 und IMAP Zugriff erlauben' einschalten und speichern.
 2. GMX schaltet den Zugriff nach längerer Nichtnutzung wieder ab; die Abholung alle 5 Minuten hält ihn aktiv.
 3. Verwenden Sie das GMX-Passwort (bei aktiver Zwei-Faktor-Anmeldung ein Passwort für externe Programme, falls GMX es anbietet)." ;;
      yahoo) PV_DOMS='^(yahoo\.[a-z.]+|ymail\.com|rocketmail\.com)$'; PV_NAME="Yahoo"; PV_EX="anna@yahoo.com"
             PV_HINT="Vorbereitung bei Yahoo (einmalig):
 1. Yahoo-Konto > Kontosicherheit > 'App-Passwort generieren' (Name z. B. 'Mailserver').
 2. Dieses App-Passwort hier eintragen, NICHT das normale Yahoo-Passwort.
 3. POP und IMAP sind bei Yahoo standardmäßig nutzbar." ;;
    esac
    msg "$PV_HINT"
    input_re GM "$PV_NAME-Adresse (z. B. $PV_EX):" "" '^[^@|[:space:]]+@[^@|[:space:]]+\.[^@|[:space:]]+$' "" \
      "Das ist keine gültige E-Mail-Adresse."
    GM_DOM="${GM#*@}"; GM_DOM="${GM_DOM,,}"
    if [[ ! "$GM_DOM" =~ $PV_DOMS ]]; then
      yesno_n "Die Adresse $GM sieht nicht nach $PV_NAME aus.

Trotzdem als $PV_NAME-Konto verwenden?" || continue
    fi
    if [[ "$PV" == "gmail" ]]; then
      secret_re GP "Google-App-Passwort für $GM

16 Buchstaben, Leerzeichen sind egal." '^[A-Za-z]{4}[[:space:]]?[A-Za-z]{4}[[:space:]]?[A-Za-z]{4}[[:space:]]?[A-Za-z]{4}$' "" \
        "Ein App-Passwort besteht aus genau 16 Buchstaben (in Viererblöcken). Haben Sie das normale Google-Passwort eingegeben?"
    else
      secret_re GP "Passwort für $GM ($PV_NAME)

$( [[ "$PV" == yahoo ]] && echo "Das Yahoo-App-Passwort." || echo "Das GMX-Passwort für externe Programme." )" '^[^|]{6,}$' "" \
        "Mindestens 6 Zeichen und kein Senkrechtstrich (|)."
    fi
    GP="${GP// /}"
    if yesno "Anmeldung für $GM jetzt testen (IMAP-Verbindung zu $PV_NAME)?

Empfohlen: Es wird nur geprüft, ob die Zugangsdaten stimmen. Es wird nichts verändert."; then
      if command -v curl >/dev/null || { apt-get update -qq && apt-get install -y -qq curl; }; then
        case "$PV" in gmail) IMH=imap.gmail.com ;; yahoo) IMH=imap.mail.yahoo.com ;; gmx) [[ "$GM_DOM" == gmx.com ]] && IMH=imap.gmx.com || IMH=imap.gmx.net ;; esac
        RC=0; printf 'user = %s\n' "$(dq "$GM:$GP")" | curl -sS -K - --max-time 40 --url "imaps://$IMH/" -o /dev/null 2>/dev/null || RC=$?
        case "$RC" in
          0)  msg "Anmeldung bei $PV_NAME erfolgreich." ;;
          67) yesno_n "Anmeldung abgelehnt: Passwort falsch, oder POP/IMAP ist beim Anbieter noch nicht aktiviert.

Trotzdem mit diesen Daten weitermachen?" || continue ;;
          *)  yesno_n "Der Test war nicht möglich (curl-Code $RC; Internetverbindung?).

Trotzdem mit diesen Daten weitermachen?" || continue ;;
        esac
      fi
    fi
    input_re LN "Lokaler Benutzername für $GM

Leer lassen = Teil vor dem @. Es entsteht <name>@<Domain>." "" '^[A-Za-z0-9._@-]+$' opt \
      "Erlaubt sind Buchstaben, Ziffern und . _ @ -"
    secret_re LP "Lokales Passwort für das Postfach von $GM (Mail-App, Webmail).

Leer lassen = wird erzeugt und in zugangsdaten.txt gespeichert. Mindestens 8 Zeichen, kein Senkrechtstrich (|)." '^[^|]{8,}$' opt \
      "Mindestens 8 Zeichen und kein Senkrechtstrich (|)."
    input_re LQ "Speicherlimit für das Postfach (z. B. 10G oder 500M).

Leer lassen = unbegrenzt." "" '^[0-9]+[MG]$' opt "Format: Zahl plus M oder G, z. B. 10G."
    ACCOUNT_LINES+=("$GM|$GP|$LN|$LP|$LQ|$PV")
    [[ -n "$FIRST_GMAIL" ]] || FIRST_GMAIL="$GM"
    [[ "$PV" != gmail ]] || ANY_GMAIL=1
    [[ " $PROVIDERS_USED " == *" $PV_NAME "* ]] || PROVIDERS_USED+="$PV_NAME "
    yesno_n "Konto $GM ($PV_NAME) hinzugefügt. Insgesamt: ${#ACCOUNT_LINES[@]}.

Weiteres Konto eintragen?" || break
  done
  unset GP LP

  # -------------------------------------------------------------- Einstellungen
  if (( ANY_GMAIL )); then
    IMPORT_MODE="$(wt --menu "Wie soll der Altbestand aus Gmail importiert werden?
(GMX und Yahoo: alle Ordner außer Papierkorb und Spam, der Posteingang kommt per POP3.)" 16 76 2 \
      ordner "Gmail-Labels werden zu Ordnern (ohne Spam, Papierkorb, Alle Nachrichten)" \
      alles  "Nur 'Alle Nachrichten': vollständig, aber ohne Ordnerstruktur" 3>&1 1>&2 2>&3)" || cancel
  fi

  input_re TZ_VAL "Zeitzone:" "$TZ_VAL" '^([A-Za-z_]+/[A-Za-z_+-]+(/[A-Za-z_+-]+)?|UTC)$' "" \
    "Format: Region/Stadt, z. B. Europe/Vienna."
  input_re WEBMAIL_PORT "Port für die Webmail (Roundcube) im Heimnetz:" "8080" '^[0-9]{2,5}$' "" "Bitte eine Portnummer eingeben."
  (( WEBMAIL_PORT >= 1 && WEBMAIL_PORT <= 65535 )) || { msg "Ungültiger Port, es wird 8080 verwendet."; WEBMAIL_PORT=8080; }
  WEBMAIL_BIND="$(wt --menu "Wer soll die Webmail (Roundcube) erreichen?

Die Webmail läuft ohne Verschlüsselung (HTTP)." 16 76 2 \
    0.0.0.0   "Alle Geräte im Heimnetz (Standard)" \
    127.0.0.1 "Nur dieser Server (z. B. mit Cloudflare Tunnel oder Tailscale Serve)" 3>&1 1>&2 2>&3)" || cancel

  if yesno_n "Eigene Domain bei Cloudflare für den Zugriff von außen verwenden?

Nein = lokaler Betrieb mit selbst signiertem Zertifikat (Zugriff von außen am besten über Tailscale).
Ja   = gültiges Zertifikat, DDNS und optional Webmail über einen Cloudflare Tunnel (siehe README, Abschnitt 7)."; then
    input_re DOMAIN "Domain (ohne 'mail.' davor, z. B. deinedomain.at):" "" '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$' "" \
      "Bitte nur den Domainnamen eintragen, z. B. deinedomain.at."
    [[ "$DOMAIN" != mail.* ]] || { msg "Hinweis: Der Server heißt dann mail.$DOMAIN. Meinten Sie '${DOMAIN#mail.}'?"; }
    secret_re CF_API_TOKEN "Cloudflare-API-Token (Vorlage 'Zone-DNS bearbeiten') für Zertifikat und DDNS.

Leer lassen = selbst signiertes Zertifikat." '^[A-Za-z0-9_=+/.-]{20,}$' opt "Das sieht nicht wie ein API-Token aus (zu kurz oder ungültige Zeichen)."
    if [[ -n "$CF_API_TOKEN" ]]; then
      input_re LE_EMAIL "Ihre E-Mail-Adresse für Let's-Encrypt-Hinweise:" "$FIRST_GMAIL" '^[^@|[:space:]]+@[^@|[:space:]]+$' "" "Bitte eine gültige E-Mail-Adresse eingeben."
      yesno "DDNS aktivieren? (mail.$DOMAIN wird automatisch auf Ihre aktuelle öffentliche IP gesetzt)" || DDNS=0
    fi
    secret_re CF_TUNNEL_TOKEN "Cloudflare-Tunnel-Token für die Webmail ohne Portfreigabe.

Leer lassen, wenn Sie keinen Tunnel nutzen oder schon einen haben." '^[A-Za-z0-9_=+/.-]{20,}$' opt "Das sieht nicht wie ein Tunnel-Token aus."
  fi

  if (( ANY_GMAIL )) && yesno_n "Gmail automatisch aufräumen?

ACHTUNG: Das löscht bei Google ENDGÜLTIG (Papierkorb, optional Spam und Gesendet). Aktivieren Sie es erst, wenn Import und Backup nachweislich laufen. Sie können es später in accounts.conf einschalten. Gilt nur für Gmail-Konten."; then
    CLEAN_TRASH=1
    input_re CLEAN_TRASH_DAYS "Papierkorb: nur Mails löschen, die älter sind als wie viele Tage? (0 = alle)" "30" '^[0-9]+$' "" "Bitte eine Zahl eingeben."
    yesno_n "Auch den Spam-Ordner leeren?" && CLEAN_SPAM=1 || true
    if yesno_n "Auch den Ordner 'Gesendet' bei Gmail in den Papierkorb verschieben?

(Gesendete Mails bleiben lokal erhalten.)"; then
      CLEAN_SENT=1
      input_re CLEAN_SENT_DAYS "Gesendet: nur Mails verschieben, die älter sind als wie viele Tage? (0 = alle)" "30" '^[0-9]+$' "" "Bitte eine Zahl eingeben."
    fi
  fi
fi

# ---------------------------------------------------------------- optionale Zusätze
if (( ! CONFIG_ONLY )); then
  if yesno "Tägliches Backup einrichten (03:30 Uhr)?

Das Ziel muss ein anderes Laufwerk, NAS oder ein anderer Rechner sein."; then
    DO_BACKUP=1
    input_re BACKUP_DEST "Backup-Ziel (Ordner auf einem anderen Laufwerk):" "/mnt/backup/mail" '^/[^[:space:]]+$' "" \
      "Bitte einen absoluten Pfad ohne Leerzeichen eingeben."
  fi
  yesno_n "MCP-Server installieren?

Damit kann ein KI-Assistent wie Claude den Mailserver prüfen und verwalten (siehe README, Kapitel MCP-Server). Optional." && DO_MCP=1 || true
fi

# ---------------------------------------------------------------- 3. Zusammenfassung
SUM="Bitte prüfen:

Tailscale:        $( (( INSTALL_TS )) && echo "wird installiert$( (( TS_SSH )) && echo ' (mit Tailscale SSH)')" || { command -v tailscale >/dev/null && echo "bereits vorhanden" || echo "nein"; } )
"
if (( USE_EXISTING )); then
  SUM+="Konfiguration:    vorhandene accounts.conf
"
else
  SUM+="Konten:           ${#ACCOUNT_LINES[@]} (${PROVIDERS_USED% })
Import (Gmail):   $( (( ANY_GMAIL )) && echo "$IMPORT_MODE" || echo "-" )
Zeitzone:         $TZ_VAL
Webmail:          Port $WEBMAIL_PORT, erreichbar für $( [[ "$WEBMAIL_BIND" == 127.0.0.1 ]] && echo "diesen Server" || echo "das Heimnetz" )
Domain:           ${DOMAIN:-keine (lokal, selbst signiert)}
Zertifikat/DDNS:  $( [[ -n "$DOMAIN" && -n "$CF_API_TOKEN" ]] && echo "Let's Encrypt, DDNS=$DDNS" || echo "selbst signiert" )
Cloudflare Tunnel: $( [[ -n "$CF_TUNNEL_TOKEN" ]] && echo ja || echo nein )
Gmail aufräumen:  $( (( CLEAN_TRASH || CLEAN_SENT )) && echo "JA (löscht bei Google endgültig)" || echo nein )
"
fi
if (( ! CONFIG_ONLY )); then
  SUM+="Backup:           $( (( DO_BACKUP )) && echo "täglich nach $BACKUP_DEST" || echo nein )
MCP-Server:       $( (( DO_MCP )) && echo ja || echo nein )

Danach startet die Installation. Der Import großer Postfächer kann Stunden dauern."
else
  SUM+="
Es wird nur accounts.conf geschrieben (--config-only)."
fi
wt --yes-button "Starten" --no-button "Abbrechen" --yesno "$SUM" "$(box_h "$SUM")" 76 || cancel
clear

# ---------------------------------------------------------------- accounts.conf schreiben
if (( ! USE_EXISTING )); then
  say "accounts.conf wird geschrieben"
  if [[ -f "$CONF" ]]; then
    BK="$CONF.bak-$(date +%Y%m%d-%H%M%S)"
    cp -p "$CONF" "$BK"; chmod 600 "$BK"
    echo "Alte Konfiguration gesichert: $BK"
  fi
  umask 077
  {
    echo "# Erzeugt von install.sh am $(date '+%Y-%m-%d %H:%M')"
    echo "# Enthält Passwörter im Klartext. Nicht weitergeben."
    echo
    (( ANY_GMAIL )) && echo "IMPORT_MODE=$IMPORT_MODE"
    echo "TIMEZONE=$TZ_VAL"
    echo "WEBMAIL_PORT=$WEBMAIL_PORT"
    echo "WEBMAIL_BIND=$WEBMAIL_BIND"
    if [[ -n "$DOMAIN" ]]; then
      echo "DOMAIN=$DOMAIN"
      [[ -z "$CF_API_TOKEN" ]] || { echo "CF_API_TOKEN=$CF_API_TOKEN"; echo "LE_EMAIL=$LE_EMAIL"; echo "DDNS=$DDNS"; }
      [[ -z "$CF_TUNNEL_TOKEN" ]] || echo "CF_TUNNEL_TOKEN=$CF_TUNNEL_TOKEN"
    fi
    if (( CLEAN_TRASH )); then
      echo "GMAIL_EMPTY_TRASH=1"; echo "GMAIL_TRASH_DAYS=$CLEAN_TRASH_DAYS"; echo "GMAIL_EMPTY_SPAM=$CLEAN_SPAM"
    fi
    if (( CLEAN_SENT )); then
      echo "GMAIL_EMPTY_SENT=1"; echo "GMAIL_SENT_DAYS=$CLEAN_SENT_DAYS"
    fi
    echo
    echo "# Konten: adresse | passwort | lokaler-name | lokales-passwort | quota | anbieter"
    printf '%s\n' "${ACCOUNT_LINES[@]}"
  } > "$CONF"
  chmod 600 "$CONF"
  echo "Gespeichert: $CONF (nur für root lesbar)"
fi
unset CF_API_TOKEN CF_TUNNEL_TOKEN ACCOUNT_LINES

if (( CONFIG_ONLY )); then
  say "Fertig. Installation später mit: sudo ./setup-mailserver.sh"
  exit 0
fi

# ---------------------------------------------------------------- Tailscale installieren
if (( INSTALL_TS )); then
  say "Tailscale wird installiert"
  echo "Anleitung: $TS_GUIDE"
  if ! command -v curl >/dev/null; then apt-get update -qq && apt-get install -y -qq curl; fi
  if curl -fsSL https://tailscale.com/install.sh | sh; then
    echo
    echo "Melden Sie sich jetzt an: Öffnen Sie den folgenden Link in einem Browser (Zeitlimit 5 Minuten)."
    TS_ARGS=(up --timeout=300s)
    (( TS_SSH )) && TS_ARGS+=(--ssh)
    tailscale "${TS_ARGS[@]}" || warn "Tailscale-Anmeldung nicht abgeschlossen. Später nachholen mit: sudo tailscale up"
  else
    warn "Tailscale konnte nicht installiert werden. Die Mailserver-Installation läuft trotzdem weiter. Anleitung: $TS_LINUX"
  fi
fi

# ---------------------------------------------------------------- Mailserver installieren
say "Mailserver wird installiert (setup-mailserver.sh)"
bash "$BASE/setup-mailserver.sh" -y

# ---------------------------------------------------------------- Zusätze
if (( DO_BACKUP )); then
  say "Backup wird eingerichtet"
  bash "$BASE/backup-mail.sh" --install "$BACKUP_DEST" \
    || warn "Backup konnte nicht eingerichtet werden (Ziel auf anderem Laufwerk?). Später: ./backup-mail.sh --install <Ziel>"
fi
if (( DO_MCP )); then
  say "MCP-Server wird installiert"
  SKIP_TAILSCALE=1 bash "$BASE/mcp/install.sh" "$BASE" || warn "MCP-Installation fehlgeschlagen."
fi

# ---------------------------------------------------------------- Abschluss
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
say "Installation abgeschlossen"
echo "  Webmail im Heimnetz:  http://${IP:-<Server-IP>}:$WEBMAIL_PORT"
echo "  Zugangsdaten:         $BASE/zugangsdaten.txt  (nur für root lesbar, nach dem Notieren löschen)"
echo "  Status:               docker compose ps"
echo "  Hilfe:                README.md und docs/"
echo "  Deinstallation:       sudo ./uninstall.sh"
