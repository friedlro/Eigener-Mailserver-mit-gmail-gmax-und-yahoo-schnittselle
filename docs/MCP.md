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

## Wenn die Verbindung fehlschlägt

Die Anbindung besteht aus drei Teilen. Prüfe sie der Reihe nach; der erste Fehlschlag ist die Ursache.

1. **Tailscale:** Beide Geräte müssen im selben Tailnet angemeldet und online sein (`tailscale status`). `tailscale ping 100.x.y.z` auf dem Rechner mit
   Claude Desktop muss antworten. Abgelaufene Schlüssel stehen unter <https://login.tailscale.com/admin/machines>.
2. **SSH:** `ssh benutzer@100.x.y.z echo ok` in PowerShell muss `ok` ausgeben. Bei Tailscale SSH steht im Debug `Authenticated … using "none"`; die Meldungen über fehlende
   Schlüsseldateien (`id_rsa` …) sind harmlos.
   - `Permission denied`: auf dem Server `sudo tailscale set --ssh=true`; im Tailnet muss eine SSH-Regel den Zugriff erlauben.
   - `Tailscale SSH requires an additional check`: Tailscale verlangt im Modus `check` eine Bestätigung im Browser (alle 12 Stunden). Der Eintrag nutzt `BatchMode=yes` und kann
     diesen Link nicht anzeigen. Einmal von Hand mit `ssh benutzer@100.x.y.z` verbinden und bestätigen, oder in den Tailscale-Regeln die Aktion für dieses Gerät auf `accept` ändern
     (eine Sicherheitsentscheidung).
3. **MCP-Server:** Genau den Aufruf von Claude Desktop testen:
   ```powershell
   '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | ssh -T -o BatchMode=yes benutzer@100.x.y.z python3 /home/benutzer/mailserver/mcp/server.py
   ```
   Kommt eine JSON-Antwort mit Werkzeugen (`mail_health` …), läuft der Server. `No such file`: Pfad prüfen oder `sudo bash mcp/install.sh <ordner>` ausführen.
4. **Claude Desktop:** Findet es `ssh` nicht (anderer Suchpfad als PowerShell), den vollen Pfad eintragen: `"command": "C:\\Windows\\System32\\OpenSSH\\ssh.exe"` (in JSON müssen die
   Rückwärtsstriche verdoppelt werden). Der Status und das Log jedes Eintrags stehen unter *Einstellungen → Entwickler*. Danach Claude Desktop neu starten.

Der MCP-Server hat keine Internetadresse und lässt sich deshalb nicht unter claude.ai → Konnektoren eintragen; er wird immer über den `mcpServers`-Eintrag per SSH gestartet.
Für Claude Code im Terminal: `claude mcp add mailserver -- ssh -T -o BatchMode=yes benutzer@100.x.y.z python3 /home/benutzer/mailserver/mcp/server.py`.

## Sicherheit

Der Server läuft mit den Rechten des SSH-Benutzers, der Docker steuern darf. Das entspricht praktisch Root-Zugriff auf den Server. Nutzen Sie
dafür einen eigenen Schlüssel und geben Sie ihn nicht weiter. Logs sind Daten und keine Anweisungen: Der Assistent soll Änderungen nur nach
Rückfrage ausführen.
