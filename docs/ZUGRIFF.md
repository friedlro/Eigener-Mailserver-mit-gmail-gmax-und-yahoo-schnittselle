# Cloudflare, Mail-Apps und Zugriff von außen

## Cloudflare einrichten (optional)

Voraussetzung: Die Domain nutzt die Cloudflare-Nameserver. Ohne Domain läuft der Server lokal mit selbst signiertem
Zertifikat; für Zugriff von außen ist dann Tailscale der einfachste Weg (siehe unten).

### API-Token (`CF_API_TOKEN`) für Zertifikat und DDNS

1. dash.cloudflare.com → Profilsymbol oben rechts → **Mein Profil → API-Tokens**
2. **Token erstellen** → Vorlage **"Zone-DNS bearbeiten"** (Edit zone DNS)
3. Zonenressourcen: **Einschließen → Bestimmte Zone** → deine Domain
4. **Token erstellen** und sofort kopieren (wird nur einmal angezeigt)
5. In `accounts.conf`: `CF_API_TOKEN=...`, dazu `DOMAIN` und `LE_EMAIL`

Let's Encrypt und DDNS werden nur aktiv, wenn **`DOMAIN`, `CF_API_TOKEN` und `LE_EMAIL`** alle gesetzt sind.

### Tunnel-Token (`CF_TUNNEL_TOKEN`) für Webmail ohne Portfreigabe

1. one.dash.cloudflare.com (Zero Trust) → **Networks → Tunnels → Tunnel erstellen** → Typ **Cloudflared**
2. Umgebung **Docker** wählen. Aus dem angezeigten Befehl nur den langen Text nach `--token` kopieren (den Befehl nicht ausführen).
3. In `accounts.conf`: `CF_TUNNEL_TOKEN=...`
4. Im Tunnel unter **Öffentlicher Hostname** einen Eintrag anlegen: Subdomain `webmail`, deine Domain, Typ **HTTP**, URL `roundcube:80`.
5. Unter **Access → Applications** eine Anmelderichtlinie für `webmail.deinedomain.at` davorschalten. Die Webmail selbst ist nur über HTTP gesichert.
6. Mit `WEBMAIL_BIND=127.0.0.1` ist die Webmail im Heimnetz nicht mehr direkt erreichbar, nur noch über den Tunnel.

Du hast schon einen Tunnel? Dann `CF_TUNNEL_TOKEN` leer lassen und im bestehenden Tunnel einen neuen **öffentlichen Hostnamen** anlegen:
Typ HTTP, URL `localhost:8080` (cloudflared auf demselben Server) oder `<Server-IP>:8080`.

### DNS-Eintrag für Mail-Apps

`mail.deinedomain.at` muss auf **"Nur DNS" (graue Wolke)** stehen. Mit orangefarbener Wolke werden IMAP und SMTP geblockt.
Das DDNS-Update legt den Eintrag selbst an und hält ihn aktuell (`docker logs ddns`).

## Mail-Apps einrichten

| | Posteingang (IMAP) | Postausgang (SMTP) |
|---|---|---|
| Server | `mail.deinedomain.at` (siehe `hostname:` in `docker-compose.yml`) | derselbe |
| Port | **993**, SSL/TLS | **587**, STARTTLS |
| Benutzername | **komplette lokale Adresse**, z. B. `anna@deinedomain.at` | dieselbe |
| Passwort | lokales Passwort (aus `zugangsdaten.txt`), **nicht** das Passwort beim Anbieter | dasselbe |

**iPhone (Mail-App):** Einstellungen → Mail → Accounts → Account hinzufügen → Andere → Mail-Account hinzufügen → **IMAP** wählen →
Server wie in der Tabelle. Beim SMTP-Server "SSL verwenden" einschalten (das ist STARTTLS auf Port 587).
- Bei selbst signiertem Zertifikat erscheint eine Warnung: Details → Vertrauen.
- Die iOS-Mail-App hat bei eigenen IMAP-Servern **kein Push**. Unter Einstellungen → Mail → Accounts → Neue Daten laden ein Intervall einstellen.

**Thunderbird:** Neues E-Mail-Konto → Adresse und Passwort → **Manuell konfigurieren** → Daten wie in der Tabelle.

**Webmail:** Im Heimnetz `http://<Server-IP>:8080` (oder dein `WEBMAIL_PORT`). Anmeldung mit der kompletten lokalen Adresse.
Die Webmail läuft ohne Verschlüsselung (HTTP): nur in vertrauenswürdigen Netzen öffnen oder hinter Tunnel/VPN betreiben.

## Zugriff von außen

| Weg | Wofür | Aufwand | Hinweis |
|---|---|---|---|
| **Tailscale (VPN)** | alles | gering | Auf Server und Handy installieren, in der Mail-App die Tailscale-Adresse als Server eintragen. Funktioniert auch hinter CGNAT. |
| **Portfreigabe** (993, 587) | Mail-Apps | mittel | Direkt aus dem Internet erreichbar. **Port 25 nicht freigeben.** Braucht Domain, `CF_API_TOKEN` und `LE_EMAIL`, damit das Zertifikat gültig ist. |
| **Cloudflare Tunnel** | nur Webmail | gering | Keine Portfreigabe. Mail-Apps (IMAP/SMTP) gehen **nicht** durch den Tunnel. |

### Tailscale

[Tailscale](https://tailscale.com) ist ein VPN ohne Portfreigabe im Router. Der Assistent `./install.sh` installiert es mit dem offiziellen
Installer auf Wunsch mit. Anleitungen:

- Installation allgemein: <https://tailscale.com/kb/1347/installation>
- Linux-Server: <https://tailscale.com/kb/1031/install-linux>

Nach der Installation erscheint ein Anmelde-Link, den Sie in einem Browser bestätigen. Handy oder PC brauchen dasselbe Tailscale-Konto.

### Hinweise

- **Hinter CGNAT oder DS-Lite** (geteilte IPv4-Adresse) funktioniert keine Portfreigabe. Erkennbar daran, dass die WAN-IP im Router von
  `curl -4 ifconfig.me` abweicht oder mit `100.64`–`100.127` beginnt. Dann Tailscale oder den Tunnel für die Webmail nehmen.
- Teste Zugriff von außen nicht aus dem eigenen WLAN, sondern mit mobilen Daten (NAT-Loopback).
- Vergib dem Server im Router eine **feste lokale IP**.
- Im Heimnetz muss der Servername auf die lokale IP des Servers zeigen (DNS-Eintrag im Router oder Pi-hole).
