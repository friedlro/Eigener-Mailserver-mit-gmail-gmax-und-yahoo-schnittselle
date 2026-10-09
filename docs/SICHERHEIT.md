# Sicherheit

## Was das Projekt absichert

| Maßnahme | Wirkung |
|---|---|
| **Geheimnisse nur in `.env` und `accounts.conf`** | API- und Tunnel-Token stehen nicht mehr in `docker-compose.yml`. `.env` hat Rechte 640 (Gruppe `docker`), `accounts.conf`, `fetchmail.cf`, `postfix-sasl-password.cf`, `zugangsdaten.txt`, `cloudflare.ini` und der private Zertifikatsschlüssel 600. |
| **Feste Image-Versionen** | Kein `:latest`. Eine Aktualisierung ändert das Verhalten nicht unbemerkt, sie erfolgt bewusst mit `--update`. |
| **Passwörter nie in Befehlszeilen** | Lokale Passwörter gehen per stdin an `setup email add`, Anbieter-Passwörter per Konfiguration auf stdin an `curl`. Sie stehen nicht in der Prozessliste des Hosts. |
| **Maskierung von Sonderzeichen** | Anführungszeichen und Backslashes in Passwörtern werden für `fetchmail` und `mbsync` korrekt maskiert. |
| **Zertifikatsprüfung bei der Abholung** | `fetchmail` prüft das Zertifikat des Anbieters (`sslcertck`). |
| **Webmail prüft das Zertifikat** | Bei selbst signiertem Zertifikat vertraut Roundcube genau diesem Zertifikat; die Prüfung ist nicht abgeschaltet. |
| **Webmail nur lokal möglich** | `WEBMAIL_BIND=127.0.0.1` macht Roundcube nur auf dem Server selbst erreichbar (z. B. hinter Cloudflare Tunnel). |
| **Log-Begrenzung** | Docker-Logs sind je Container auf 3 × 10 MB begrenzt, die Backup-Logs werden rotiert. |
| **Backup** | Sperre gegen Parallelläufe, Fehlermeldung bei jedem Abbruch, Ziel nur für root, Prüfung von Aufbewahrung, Ziel und Laufwerk. |
| **Deinstallation** | Mails und Backups löscht `uninstall.sh` nur nach ausdrücklicher Auswahl und Eingabe von `LOESCHEN`. |
| **Fail2ban** | Im Mailserver aktiv. |
| **`.gitignore`** | Hält `accounts.conf`, `.env`, `zugangsdaten.txt`, `data/` und Sicherungen aus dem Repository. |

## Was bleibt (bewusst oder technisch bedingt)

- **Passwörter im Klartext:** Für die Abholung bei Gmail, GMX und Yahoo muss der Server die Anbieter-Passwörter lesen können. Sie liegen in
  `accounts.conf`, `data/config/fetchmail.cf` und `data/config/postfix-sasl-password.cf` (nur für root lesbar) und in jedem Backup.
  Schützen Sie den Server und die Backups (Festplattenverschlüsselung, verschlüsselte Cloud-Kopien). Nutzen Sie, wo es geht, App-Passwörter:
  Sie lassen sich beim Anbieter einzeln widerrufen.
- **Webmail ohne TLS:** Roundcube spricht im Heimnetz HTTP. Öffnen Sie es nur in vertrauenswürdigen Netzen oder hinter Tunnel/VPN.
- **Docker-Zugriff ist Root-Zugriff:** Wer in der Gruppe `docker` ist (auch der Benutzer des MCP-Servers), kann den Server übernehmen.
- **Installer per Skript:** Docker und Tailscale werden mit den offiziellen Installationsskripten (`get.docker.com`, `tailscale.com/install.sh`)
  geladen und ausgeführt. Wer das nicht möchte, installiert beides vorher selbst.
- **Nach dem Löschen beim Anbieter** existieren die Mails nur noch auf dem Server. Das Backup ist dann die einzige Absicherung.
- **Port 25** nie freigeben. Nur 993 und 587, oder besser: Tailscale.

## Wenn ein Passwort oder Token bekannt wurde

1. Beim Anbieter das App-Passwort **widerrufen** und ein neues erstellen (Gmail/Yahoo) bzw. das GMX-Passwort ändern.
2. In `accounts.conf` eintragen und `./setup-mailserver.sh --update` starten.
3. Cloudflare-Token im Dashboard löschen und neu erstellen.

## Meldung von Sicherheitsproblemen

Bitte nicht öffentlich als Issue, sondern direkt an den Autor.
