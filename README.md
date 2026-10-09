# Eigener Mailserver mit Gmail-, GMX- und Yahoo-Anbindung

Ein selbst gehosteter Mailserver für den Heimserver. Er holt die Mails von **Gmail-, GMX- und Yahoo-Konten** ab, speichert sie lokal
und löscht sie beim Anbieter, damit dort kein Speicher mehr belegt wird. Jeder Nutzer hat ein eigenes Postfach mit eigenem Passwort und
optionalem Speicherlimit. Zugriff per Mail-App, Thunderbird oder Webmail, auch von außen.

Die Konten sind frei mischbar: Ein Server kann gleichzeitig Gmail-, GMX- und Yahoo-Konten abholen. Der Anbieter wird bei der Installation
pro Konto ausgewählt.

> **Teststand:** Die Skripte haben automatische Tests (`tests/run-tests.sh`). Die Anbindung von Gmail ist im Betrieb erprobt. GMX und Yahoo
> sind nach den offiziellen Servereinstellungen umgesetzt, aber noch **nicht mit echten Konten** durchlaufen, und eine Installation auf einem
> frischen System steht noch aus. Einzelheiten: [docs/TESTEN.md](docs/TESTEN.md). Machen Sie vor dem Löschen beim Anbieter ein Backup und
> prüfen Sie die Mails lokal.

## Inhalt

1. [Funktionsweise](#funktionsweise)
2. [Schnellstart](#schnellstart)
3. [Dateien](#dateien)
4. [Voraussetzungen](#voraussetzungen)
5. [Installation](#installation)
6. [Einstellungen in accounts.conf](#einstellungen-in-accountsconf)
7. [Anbieter vorbereiten](#anbieter-vorbereiten)
8. [Mail-Apps und Zugriff von außen](#mail-apps-und-zugriff-von-außen)
9. [Betrieb, Backup und Fehlersuche](#betrieb-backup-und-fehlersuche)
10. [Sicherheit](#sicherheit)
11. [Deinstallation](#deinstallation)
12. [MCP-Server (optional)](#mcp-server-optional)
13. [Tests](#tests)
14. [Lizenz](#lizenz)

---

## Funktionsweise

```
  Gmail / GMX / Yahoo ──(einmalig: IMAP-Import des Altbestands)──┐
          │                                                      ▼
          └──(laufend: POP3-Abruf alle 5 Min.)──►  docker-mailserver  ◄──── Mail-App (IMAP 993)
                                                    (Postfix + Dovecot)  ◄──── Roundcube (Webmail)
                                                          │
                                                          └── Senden (SMTP 587) ──► SMTP-Server des Anbieters ──► Empfänger
```

| Baustein | Aufgabe |
|---|---|
| **docker-mailserver** | Postfix (Mail-Transport) und Dovecot (IMAP) in einem Container. Speichert die Mails pro Nutzer als Maildir in `data/mail-data`. |
| **IMAP-Import (mbsync)** | Läuft einmal bei der Installation. Holt den Altbestand inklusive Ordnerstruktur. Löscht beim Anbieter **nichts**. |
| **Laufende Abholung (fetchmail, POP3)** | Holt neue Mails alle 5 Minuten und löscht sie beim Anbieter (`nokeep`). Bei GMX und Yahoo kommt so der gesamte Posteingang. |
| **Senden über den Anbieter** | Ausgehende Mails gehen über den SMTP-Server des jeweiligen Anbieters mit den Zugangsdaten des Nutzers. Empfänger sehen die Adresse des Anbieters als Absender. |
| **Roundcube** | Webmail im Browser, Port `WEBMAIL_PORT` (Standard 8080). |
| **Let's Encrypt (optional)** | Gültiges Zertifikat per Cloudflare-DNS-Challenge. Ohne Domain wird ein selbst signiertes Zertifikat erzeugt. |
| **DDNS (optional)** | Hält `mail.deinedomain.at` per Cloudflare-API auf der aktuellen öffentlichen IP. |
| **Cloudflare Tunnel (optional)** | Macht Roundcube ohne Portfreigabe im Internet erreichbar. |
| **Fail2ban** | Sperrt IPs nach mehreren fehlgeschlagenen Anmeldungen. |

Unterschiede der Anbieter und was beim Import passiert: [docs/ANBIETER.md](docs/ANBIETER.md).

---

## Schnellstart

Ohne git und ohne manuellen Download (ein Befehl, lädt das Projekt nach `/opt/mailserver` und startet den Assistenten):

```bash
curl -fsSL https://raw.githubusercontent.com/friedlro/Eigener-Mailserver-mit-gmail-gmax-und-yahoo-schnittselle/main/get.sh | sudo bash
```

Solange das Repository privat ist, geht das nur mit einem GitHub-Token. Das Token legst du selbst an unter
<https://github.com/settings/personal-access-tokens/new>: Repository-Zugriff *Only select repositories* (nur dieses Repository),
Berechtigung *Contents: Read-only*, kurze Laufzeit. Nach der Installation unter
<https://github.com/settings/personal-access-tokens> widerrufen. Das Token nie in Chats oder Dateien ablegen:

```bash
read -rs -p "Token: " GITHUB_TOKEN; echo
```

Danach:

```bash
curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" https://raw.githubusercontent.com/friedlro/Eigener-Mailserver-mit-gmail-gmax-und-yahoo-schnittselle/main/get.sh | sudo env GITHUB_TOKEN="$GITHUB_TOKEN" bash
unset GITHUB_TOKEN
```

**Im Browser statt im Terminalmenü** (wenn der Assistent hängt oder die Konsole keine Menüs darstellt, z. B. Webkonsolen und Handy-SSH):

```bash
curl -fsSL https://raw.githubusercontent.com/friedlro/Eigener-Mailserver-mit-gmail-gmax-und-yahoo-schnittselle/main/get.sh | sudo bash -s -- --web
```

Im Terminal erscheinen eine Adresse (`http://<server-ip>:8099`) und ein Einmal-Passwort. Im Browser trägst du die Konten ein
(Anbieter wird an der Adresse erkannt, auch gmx.at), prüfst die Zugangsdaten und startest die Installation. Das Protokoll läuft live mit.
Die Seite ist **nicht verschlüsselt** (HTTP): nur im Heimnetz oder über Tailscale benutzen. Sicherer ist ein SSH-Tunnel: Starte mit
`... | sudo env WEBUI_BIND=127.0.0.1 bash -s -- --web`, öffne auf deinem Rechner `ssh -L 8099:localhost:8099 user@server` und im Browser
`http://localhost:8099`. Nach 5 falschen Passwörtern beendet sich der Server, nach der Installation auch von selbst.
Später erneut starten: `sudo python3 /opt/mailserver/webui.py`.

Alternativ mit git:

```bash
sudo apt-get install -y git
sudo git clone https://github.com/friedlro/Eigener-Mailserver-mit-gmail-gmax-und-yahoo-schnittselle.git /opt/mailserver
cd /opt/mailserver
sudo ./install.sh
```

Der Assistent führt durch alles: Anbieter und Zugangsdaten je Konto (mit Anmeldetest), Einstellungen, optional Tailscale, Backup und MCP.
Danach installiert er den Mailserver. Vorher in jedem Konto POP/IMAP freischalten und, wo nötig, ein App-Passwort erstellen
(Abschnitt [Anbieter vorbereiten](#anbieter-vorbereiten)).

---

## Dateien

| Datei | Zweck |
|---|---|
| `install.sh` | **Installationsassistent** mit Menüoberfläche: fragt alle Daten ab, schreibt `accounts.conf` und startet die Installation. |
| `uninstall.sh` | **Deinstallation** mit Auswahlmenü (Abschnitt [Deinstallation](#deinstallation)). |
| `setup-mailserver.sh` | Installiert und konfiguriert alles, importiert die Mails. Wird vom Assistenten aufgerufen, geht aber auch allein. |
| `accounts.conf.example` | Vorlage. Kopieren nach `accounts.conf` und ausfüllen. |
| `accounts.conf` | **Deine Einstellungen und Passwörter.** Nicht weitergeben, nicht ins Repository. |
| `backup-mail.sh` | Tägliche Sicherung mit Snapshots. |
| `mcp/` | Optionaler MCP-Server zur Verwaltung durch einen KI-Assistenten. |
| `tests/` | Automatische Tests. |
| `docs/` | Ausführliche Dokumentation. |

Vom Skript erzeugt:

| Datei / Ordner | Inhalt |
|---|---|
| `docker-compose.yml`, `.env` | Container-Definition; `.env` enthält die Image-Versionen, Token und den Schalter für die Abholung. |
| `zugangsdaten.txt` | Lokale Adressen und Passwörter, die das Skript neu angelegt hat. |
| `data/mail-data/` | **Alle Mails.** Das ist das, was gesichert werden muss. |
| `data/config/` | Konten, Relay-Einstellungen, `fetchmail.cf` (enthält Anbieter-Passwörter). |
| `data/certbot/`, `data/certs/` | Zertifikate. |
| `data/roundcube/` | Datenbank und Konfiguration der Webmail. |

---

## Voraussetzungen

- Linux-Server (Debian oder Ubuntu) mit `sudo` und Internetzugang
- Docker mit Compose-Plugin (wird bei Bedarf installiert)
- Konten bei Gmail, GMX und/oder Yahoo mit Zugriff per POP3/IMAP (Abschnitt [Anbieter vorbereiten](#anbieter-vorbereiten))
- Für Zugriff von außen ohne VPN zusätzlich eine **Domain bei Cloudflare**; einfacher ist Tailscale
- Speicherplatz: mindestens so viel wie die Postfächer beim Anbieter belegen, dazu ein zweites Laufwerk für Backups

---

## Installation

### Mit dem Assistenten (empfohlen)

```bash
sudo ./install.sh
```

Der Assistent läuft im Terminal (Menüoberfläche mit `whiptail`, wird bei Bedarf nachinstalliert) und fragt der Reihe nach:

1. **Tailscale installieren?** Optional, mit Verweis auf die Anleitung (unten). Auf Wunsch mit Tailscale SSH.
2. **Konten:** je Konto den **Anbieter** (Gmail, GMX, Yahoo), die Adresse, das Passwort (App-Passwort bei Gmail und Yahoo), lokalen Namen,
   lokales Passwort und Speicherlimit. Zu jedem Anbieter zeigt der Assistent, was vorher dort einzustellen ist, und bietet einen **Anmeldetest**
   an. Passt die Adresse nicht zum gewählten Anbieter, fragt er nach.
3. **Einstellungen:** Import-Modus (Gmail), Zeitzone, Webmail-Port und -Erreichbarkeit, optional Domain mit Cloudflare-Token und das automatische
   Aufräumen bei Gmail.
4. **Zusätze:** tägliches Backup und MCP-Server.
5. **Zusammenfassung.** Erst nach Ihrer Bestätigung wird etwas verändert: Der Assistent schreibt `accounts.conf` (Rechte 600, eine vorhandene Datei
   wird vorher gesichert), installiert bei Bedarf Tailscale und startet danach `setup-mailserver.sh`.

`sudo ./install.sh --config-only` erzeugt nur die `accounts.conf`. Bei großen Postfächern kann der Import **Stunden** dauern. Bricht er ab oder
drosselt der Anbieter, startest du `./setup-mailserver.sh` einfach noch einmal.

### Tailscale (optional)

[Tailscale](https://tailscale.com) ist ein VPN, über das du von unterwegs ohne Portfreigabe auf den Server zugreifst. Der Assistent installiert es
mit dem offiziellen Installer und zeigt danach einen Anmelde-Link, den du im Browser bestätigst. Anleitungen:

- Installation allgemein: <https://tailscale.com/kb/1347/installation>
- Linux-Server: <https://tailscale.com/kb/1031/install-linux>

### Von Hand

```bash
cp accounts.conf.example accounts.conf
nano accounts.conf                      # Konten und Einstellungen eintragen
chmod +x *.sh
sudo ./setup-mailserver.sh --check      # Zugangsdaten prüfen
sudo ./setup-mailserver.sh              # installieren (fragt einmal nach, mit -y ohne Rückfrage)
sudo cat zugangsdaten.txt               # lokale Zugangsdaten ansehen
sudo ./backup-mail.sh --install /mnt/backup/mail
```

### Modi von setup-mailserver.sh

| Aufruf | Wirkung |
|---|---|
| `./setup-mailserver.sh` | Erstinstallation (fragt einmal nach). |
| `./setup-mailserver.sh --check` | Zugangsdaten aller Konten testen (IMAP und POP3). Ändert nichts. |
| `./setup-mailserver.sh --update` | Bestehendes System aktualisieren: neue Konfiguration und Container, **kein** Import, die Abholung läuft weiter. Die bisherige Konfiguration wird vorher gesichert. |
| `./setup-mailserver.sh --reimport` | Import erzwingen, z. B. nach einem abgebrochenen alten Import. |
| `./setup-mailserver.sh --cleanup` | Gmail aufräumen nach den Einstellungen in `accounts.conf`. |
| `./setup-mailserver.sh --empty-trash` | Gmail-Papierkorb sofort leeren. |
| `-y` | Ohne Rückfrage, mit jedem Modus kombinierbar. |

Bereits importierte Konten merkt sich das Skript in `data/import-done/`. Ein erneuter Lauf importiert sie nicht noch einmal, es entstehen keine Dubletten.

---

## Einstellungen in accounts.conf

### Konten (Pflicht)

Eine Zeile pro Konto:

```
adresse | passwort | lokaler-name | lokales-passwort | quota | anbieter
```

| Feld | Pflicht | Bedeutung |
|---|---|---|
| adresse | ja | Adresse beim Anbieter, z. B. `anna@gmail.com`, `ben@gmx.de`, `clara@yahoo.com` |
| passwort | ja | Gmail und Yahoo: App-Passwort (Leerzeichen sind egal). GMX: GMX-Passwort. |
| lokaler-name | nein | leer = Teil vor dem `@`. Ohne `@` wird `@<DOMAIN>` angehängt. |
| lokales-passwort | nein | leer = wird erzeugt und in `zugangsdaten.txt` gespeichert |
| quota | nein | leer = unbegrenzt, sonst z. B. `10G` |
| anbieter | nein | `gmail`, `gmx` oder `yahoo`. Leer = wird aus der Adresse erkannt. |

Beispiel:
```
anna@gmail.com|abcd efgh ijkl mnop|anna
ben@gmx.de|MeinGmxPasswort|ben||10G
clara@yahoo.com|qrst uvwx yzab cdef|clara
me@meinedomain.at|passwort|me|||gmx
```

Passwörter dürfen keinen Senkrechtstrich (`|`) enthalten. Alle anderen Sonderzeichen sind erlaubt.

### Optionale Einstellungen

Eine Einstellung pro Zeile, `NAME=Wert`, **keine Leerzeichen vor dem Namen oder um das `=`**.

| Einstellung | Standard | Bedeutung |
|---|---|---|
| `IMPORT_MODE` | `ordner` | Nur Gmail. `ordner`: Labels werden zu Ordnern (ohne Spam, Papierkorb, Alle Nachrichten). `alles`: nur "Alle Nachrichten", vollständig, aber ohne Ordnerstruktur. |
| `DOMAIN` | leer | Hauptname deiner Domain, z. B. `deinedomain.at`. Der Server heißt dann `mail.<DOMAIN>`. **Nicht** `mail.deinedomain.at` eintragen. |
| `CF_API_TOKEN` | leer | Cloudflare-Token für Zertifikat und DDNS ([docs/ZUGRIFF.md](docs/ZUGRIFF.md)). |
| `LE_EMAIL` | leer | Deine E-Mail-Adresse für Let's-Encrypt-Hinweise. |
| `CF_TUNNEL_TOKEN` | leer | Tunnel-Token für Webmail ohne Portfreigabe. |
| `DDNS` | `1` | `0` schaltet die automatische IP-Aktualisierung ab. |
| `WEBMAIL_PORT` | `8080` | Port, auf dem Roundcube erreichbar ist. |
| `WEBMAIL_BIND` | `0.0.0.0` | `0.0.0.0` = Heimnetz, `127.0.0.1` = nur der Server selbst (z. B. hinter Tunnel). |
| `TIMEZONE` | Systemzeit | z. B. `Europe/Vienna` |
| `GMAIL_EMPTY_TRASH`, `GMAIL_TRASH_DAYS`, `GMAIL_EMPTY_SPAM`, `GMAIL_EMPTY_SENT`, `GMAIL_SENT_DAYS` | aus | Gmail automatisch aufräumen, nur Gmail ([docs/BETRIEB.md](docs/BETRIEB.md)). |
| `DMS_TAG`, `ROUNDCUBE_TAG`, `DDNS_TAG`, `CLOUDFLARED_TAG`, `CERTBOT_TAG` | getestete Versionen | Andere Image-Versionen erzwingen (Fortgeschrittene). |

Let's Encrypt und DDNS werden nur aktiv, wenn **`DOMAIN`, `CF_API_TOKEN` und `LE_EMAIL`** alle gesetzt sind. Sonst läuft der Server lokal mit
selbst signiertem Zertifikat.

---

## Anbieter vorbereiten

Einmalig pro Konto, **vor** dem ersten Start. Die vollständige Anleitung mit allen Servern, Unterschieden und Grenzen steht in
[docs/ANBIETER.md](docs/ANBIETER.md). Kurzfassung:

| Anbieter | Passwort | Vorbereitung |
|---|---|---|
| **Gmail** | App-Passwort | 2-Faktor aktivieren, App-Passwort erstellen. Einstellungen → Weiterleitung und POP/IMAP: IMAP aktivieren, POP für "Nachrichten, die ab jetzt eingehen", "Gmail-Kopie löschen". |
| **GMX** | GMX-Passwort | Einstellungen → POP3 & IMAP → "POP3 und IMAP Zugriff erlauben". |
| **Yahoo** | App-Passwort | Kontosicherheit → "App-Passwort generieren". |

Danach: `sudo ./setup-mailserver.sh --check` prüft alle Anmeldungen.

---

## Mail-Apps und Zugriff von außen

| | Posteingang (IMAP) | Postausgang (SMTP) |
|---|---|---|
| Server | `mail.deinedomain.at` (siehe `hostname:` in `docker-compose.yml`) | derselbe |
| Port | **993**, SSL/TLS | **587**, STARTTLS |
| Benutzername | **komplette lokale Adresse**, z. B. `anna@deinedomain.at` | dieselbe |
| Passwort | lokales Passwort (aus `zugangsdaten.txt`), **nicht** das Passwort beim Anbieter | dasselbe |

Webmail im Heimnetz: `http://<Server-IP>:8080`. Zugriff von außen am besten über **Tailscale**; alternativ Portfreigabe (nur 993 und 587, **nie 25**) oder
Cloudflare Tunnel für die Webmail. Einrichtung von iPhone und Thunderbird, Cloudflare und alle Hinweise: [docs/ZUGRIFF.md](docs/ZUGRIFF.md).

---

## Betrieb, Backup und Fehlersuche

Befehle für Konten, Passwörter, Logs, Warteschlange und Fail2ban, die Aktualisierung, das Backup mit Wiederherstellung, das Gmail-Aufräumen und eine
Fehlersuche-Tabelle: [docs/BETRIEB.md](docs/BETRIEB.md).

```bash
docker compose ps                         # Status
sudo ./setup-mailserver.sh --check        # Zugangsdaten bei den Anbietern testen
sudo ./backup-mail.sh --install /mnt/backup/mail   # tägliches Backup 03:30 Uhr
sudo ./setup-mailserver.sh --update       # nach einer neuen Projektversion
```

---

## Sicherheit

Das Projekt setzt unter anderem feste Image-Versionen, Geheimnisse nur in `.env` mit eingeschränkten Rechten, Passwörter nie in Befehlszeilen,
Zertifikatsprüfung bei der Abholung und in der Webmail, Log-Begrenzung und ein geschütztes Backup um. Was bleibt (Klartext-Passwörter für die
Abholung, Webmail ohne TLS, Docker-Zugriff = Root): [docs/SICHERHEIT.md](docs/SICHERHEIT.md).

Kurz:
- `accounts.conf`, `data/config/fetchmail.cf`, `data/config/postfix-sasl-password.cf` und die Backups enthalten **Passwörter im Klartext**. Rechte restriktiv halten, nicht weitergeben.
- Nur Port **993 und 587** freigeben, **nie 25**. Webmail nur hinter Cloudflare Access oder VPN öffentlich machen.
- Nach dem Löschen beim Anbieter existieren die Mails **nur noch bei dir**. Das Backup ist dann die einzige Absicherung. Testen Sie die Wiederherstellung einmal.

---

## Deinstallation

```bash
sudo ./uninstall.sh
```

Das Skript zeigt ein Auswahlmenü. Vorgewählt sind die Teile, die sich gefahrlos neu aufbauen lassen:

| Auswahl | Entfernt | Vorgewählt |
|---|---|---|
| Container | `mailserver`, `roundcube`, `ddns`, `cloudflared` (per `docker compose down`) | ja |
| Cron-Jobs und Logs | Zertifikat, Gmail-Aufräumen, Backup, `/var/log/mail-*.log`, logrotate-Regel | ja |
| Docker-Images | die Images dieses Projekts | ja |
| MCP-Server | sudo-Regel für das Backup | ja |
| Konfiguration | `accounts.conf` (und Sicherungen), `docker-compose.yml`, `.env`, `zugangsdaten.txt`, `config-backup/` | ja |
| **Mails und Daten** | `data/` mit **allen Mails**, Zertifikaten und Webmail-Daten | **nein** |
| **Backup-Snapshots** | `daily/`, `monthly/`, `latest` im Backup-Ziel | **nein** |
| Docker | Pakete, `/var/lib/docker` (das Menü warnt, wenn andere Container laufen) | nein |
| Tailscale | Abmelden, Dienst und Pakete entfernen | nein |

Das Löschen von Mails und Backups verlangt zusätzlich die Eingabe von `LOESCHEN`. Bei den Anbietern wird nichts verändert. Der Projektordner bleibt bestehen.

| Aufruf | Wirkung |
|---|---|
| `sudo ./uninstall.sh --alles` | Menü mit **allem** vorgewählt, auch Mails, Docker und Tailscale. |
| `sudo ./uninstall.sh -y` | Ohne Rückfrage, aber ohne Mail-Daten, Backups, Docker und Tailscale. |
| `sudo ./uninstall.sh --alles -y` | **Alles** ohne Rückfrage, auch alle Mails. Nicht rückgängig zu machen. |

Läuft die SSH-Sitzung über Tailscale, bricht sie beim Entfernen von Tailscale ab. Der Eintrag bleibt in der
[Tailscale-Verwaltung](https://login.tailscale.com/admin/machines), bis du ihn dort löschst.

---

## MCP-Server (optional)

Mit dem MCP-Server in `mcp/` kann ein KI-Assistent wie Claude den Mailserver prüfen (Zustand, Logs, Warteschlange, Backups) und nach Rückfrage
verwalten. Er läuft per SSH über stdio, ohne zusätzlichen Port. Installation, Tools und Sicherheitshinweise: [docs/MCP.md](docs/MCP.md).

---

## Tests

```bash
tests/run-tests.sh
```

Die Tests laufen ohne echte Konten und ohne Mailserver (mit Platzhaltern für `docker`, `curl` und `whiptail`) und verändern das System nicht.
Nicht auf einem produktiven Server ausführen. Umfang, Abnahmetest auf einem frischen System und Teststand: [docs/TESTEN.md](docs/TESTEN.md).

---

## Lizenz

[MIT](LICENSE) © 2026 Roland Friedl. Die Software wird ohne Gewähr bereitgestellt. Prüfe vor dem Löschen beim Anbieter, dass Import und Backup funktionieren.
