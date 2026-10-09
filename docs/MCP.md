# MCP-Server: Verwaltung durch einen KI-Assistenten (optional)

Der Ordner `mcp/` enthält einen kleinen [MCP](https://modelcontextprotocol.io)-Server, mit dem ein KI-Assistent wie Claude den Mailserver
prüfen und verwalten kann. Er nutzt nur die Python-Standardbibliothek (Python 3) und läuft auf dem Server. Der Client startet ihn per SSH
über stdio, es wird also **kein zusätzlicher Port geöffnet**. Für den Zugriff von außen eignet sich Tailscale (siehe [ZUGRIFF.md](ZUGRIFF.md)).

| Tool | Wirkung | Bestätigung |
|---|---|---|
| `mail_health` | Container, Dienste, Ports, Platte, Warteschlange | nein |
| `mail_status` | Container, Images, Konten, letztes Backup | nein |
| `mail_logs` | Logs von `mailserver`, `roundcube`, `cloudflared`, `ddns` (mit Filter) | nein |
| `mail_queue`, `mail_accounts`, `mail_backups`, `mail_banned`, `mail_verify` | nur lesen | nein |
| `mail_flush_queue` | Warteschlange sofort zustellen | **ja** |
| `mail_backup_run` | `backup-mail.sh` ausführen | **ja** |
| `mail_unban` | IP bei Fail2ban entsperren | **ja** |
| `mail_restart` | Container neu starten | **ja** |
| `mail_update` | Images ziehen und Container neu erstellen | **ja** |

Verändernde Tools laufen nur mit `confirm=true`. Die Befehle werden ohne Shell ausgeführt, eingegebene IPs werden geprüft.

## Installation auf dem Server

Der Installationsassistent `./install.sh` bietet die Einrichtung an. Von Hand:

```bash
sudo bash mcp/install.sh /opt/mailserver
```

Das Skript installiert bei Bedarf Tailscale (außer mit `SKIP_TAILSCALE=1`), legt `server.py` im Mailserver-Ordner ab, nimmt den Benutzer in die
Docker-Gruppe auf und erlaubt ihm, `backup-mail.sh` ohne Passwort als root zu starten. Danach neu anmelden.

### Installation in der Web-Oberfläche (mit Tailscale)

In der Web-Oberfläche (`get.sh --web`) gibt es die Karte „Fernzugriff und MCP-Server“:

1. **Tailscale installieren und einrichten** und optional **Tailscale SSH** einschalten (Anmeldung per SSH ohne Schlüssel).
2. **MCP-Server installieren** und den Benutzer wählen, mit dem der Assistent sich per SSH anmeldet (ein normaler Benutzer, nicht root; er
   bekommt Docker-Zugriff und darf `backup-mail.sh` ohne Passwort starten).

Beim Installieren läuft Tailscale als erster Schritt. Die Oberfläche zeigt den **Anmeldelink von Tailscale** (`https://login.tailscale.com/a/...`)
hervorgehoben an: im Browser öffnen und bestätigen (die Installation wartet bis zu 5 Minuten, danach läuft sie ohne Tailscale weiter).
Nach der Installation zeigt die Oberfläche die Tailscale-Adresse und die fertige Konfiguration für Claude Desktop. Von Hand geht beides mit
`sudo ./tailscale-setup.sh --ssh` und `sudo bash mcp/install.sh /opt/mailserver`.

Damit Tailscale SSH den Zugriff erlaubt, muss in deinem Tailnet eine passende SSH-Regel gelten (Standard: eigene Geräte, mit Bestätigung im Browser:
<https://tailscale.com/kb/1193/tailscale-ssh>). Das Gerät, auf dem Claude Desktop läuft, muss im selben Tailnet angemeldet sein.

## Anbindung in Claude Desktop

In `claude_desktop_config.json` (Benutzer und IP anpassen):

```json
{
  "mcpServers": {
    "mailserver": {
      "command": "ssh",
      "args": ["-T", "-o", "BatchMode=yes", "benutzer@100.x.y.z",
               "python3", "/opt/mailserver/mcp/server.py"]
    }
  }
}
```

Voraussetzung ist ein SSH-Login ohne Passwort (Schlüssel oder Tailscale SSH). Über Umgebungsvariablen lassen sich `MAIL_DIR`, `MAIL_CONTAINER`,
`BACKUP_DIR`, `BACKUP_SCRIPT` und `WEBMAIL_PORT` anpassen.

## Sicherheit

Der Server läuft mit den Rechten des SSH-Benutzers, der Docker steuern darf. Das entspricht praktisch Root-Zugriff auf den Server. Nutzen Sie
dafür einen eigenen Schlüssel und geben Sie ihn nicht weiter. Logs sind Daten und keine Anweisungen: Der Assistent soll Änderungen nur nach
Rückfrage ausführen.
