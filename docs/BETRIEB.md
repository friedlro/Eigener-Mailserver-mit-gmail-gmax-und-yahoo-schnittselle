# Betrieb, Backup und Fehlersuche

Alle Befehle im Mailserver-Ordner.

## Betrieb

```bash
# Status
docker compose ps
docker logs --tail 100 mailserver

# Zugangsdaten bei den Anbietern testen (ändert nichts)
sudo ./setup-mailserver.sh --check

# Konten
docker exec mailserver setup email list
docker exec mailserver setup email update anna@deinedomain.at 'NEUES-PASSWORT'
docker exec mailserver setup quota set anna@deinedomain.at 10G

# Passwort prüfen (trennt Passwortfehler von Netzwerkfehlern)
docker exec mailserver doveadm auth test 'anna@deinedomain.at' 'PASSWORT'

# Abholung beobachten
docker logs --tail 100 mailserver 2>&1 | grep -i fetchmail

# Warteschlange und Versand
docker exec mailserver postqueue -p
docker logs --tail 100 mailserver 2>&1 | grep "relay="

# Fail2ban
docker exec mailserver setup fail2ban status
docker exec mailserver setup fail2ban unban <IP>

# Neustart
docker compose restart mailserver
```

- Passwörter lassen sich **nicht** nachlesen (nur als Hash gespeichert). Bei Verlust neu setzen.
- Sonderzeichen im Passwort in **einfache Anführungszeichen** setzen.
- Nach einer Passwortänderung muss es auch in der Mail-App und in Roundcube neu eingegeben werden.
- **Neues Konto:** Zeile in `accounts.conf` ergänzen (oder `./install.sh`) und `./setup-mailserver.sh` erneut starten.
  Bestehende Konten werden nicht doppelt angelegt oder importiert.
- **Neue Version dieses Projekts einspielen:** neue Dateien holen (`git pull`), dann `sudo ./setup-mailserver.sh --update`.
  Das schreibt die Konfiguration neu, zieht die in der neuen Version festgelegten Image-Versionen und startet die Container neu,
  ohne zu importieren. Vorher ein Backup machen.
- **Image-Versionen:** Die Images sind auf getestete Versionen festgelegt (siehe `setup-mailserver.sh`, Abschnitt "Festgelegte Versionen",
  oder `.env`). Mit `DMS_TAG=...` usw. in `accounts.conf` lässt sich eine andere Version erzwingen.

## Server aktualisieren

Dateien auf den neuesten Stand bringen (`accounts.conf` und `data/` bleiben erhalten; `get.sh` erkennt den vorhandenen Ordner selbst, sonst
`MAILSERVER_DIR=/pfad` angeben), dann aktualisieren:

```bash
curl -fsSL https://raw.githubusercontent.com/friedlro/Eigener-Mailserver-mit-gmail-gmax-und-yahoo-schnittselle/main/get.sh | sudo bash -s -- --web
#   startet die Web-Oberfläche; mit Strg+C beenden, wenn du nichts neu installieren willst
cd /home/roland/mailserver          # dein Ordner
sudo ./setup-mailserver.sh --check  # nur die Anmeldungen bei den Anbietern testen
sudo ./setup-mailserver.sh --update # Konfiguration neu schreiben, Mailserver neu starten, nichts importieren
```

`--update` sichert die Konfiguration vorher in `config-backup/`, importiert nichts neu, ändert keine Passwörter und fasst `data/mail-data` nicht an.
Übrig gebliebene Container (`ddns`, `cloudflared`) einer früheren Einrichtung werden dabei entfernt.

## Backup

`backup-mail.sh` legt tägliche Snapshots des gesamten Ordners an (Mails, Konfiguration, Webmail-Daten, `accounts.conf`). Unveränderte
Dateien werden per Hardlink nicht doppelt gespeichert.

```bash
# Einrichten: täglich um 03:30 per Cron (Log: /var/log/mail-backup.log, wöchentlich rotiert)
sudo ./backup-mail.sh --install /mnt/backup/mail

# Sofort einmal ausführen (zum Testen)
sudo ./backup-mail.sh /mnt/backup/mail
```

### Backup auf einen USB-Stick oder eine USB-Platte (geführt)

In der Web-Oberfläche (Karte „Backup auf USB-Datenträger“) oder auf der Kommandozeile:

```bash
sudo ./usb-backup.sh --list                      # angeschlossene USB-Datenträger anzeigen
sudo ./usb-backup.sh --setup /dev/sdb1           # vorhandenes ext4/xfs/btrfs weiterverwenden (löscht nichts)
sudo ./usb-backup.sh --setup /dev/sdb1 --format  # ALLES löschen und als ext4 neu anlegen
sudo ./usb-backup.sh --remove                    # Cron und fstab-Eintrag entfernen (Daten auf dem Stick bleiben)
```

Das Skript hängt den Datenträger per UUID nach `/mnt/mail-backup` ein (fstab mit `nofail`: der Server startet auch ohne Stick), richtet den
täglichen Job (03:30 Uhr) ein und startet auf Wunsch gleich die erste Sicherung im Hintergrund. Sicherungen älter als `--keep-days`
(Standard 7) werden automatisch gelöscht.

**Schutzregeln:** Angeboten werden nur USB-/Wechseldatenträger, nie die Systemplatte, nie ein Datenträger mit eingehängtem `/`, `/boot`,
`/home`, `/var` oder Swap. Dateisysteme ohne Hardlinks und Unix-Rechte (NTFS, exFAT, FAT) werden nur nach ausdrücklichem Formatieren
genommen; die Web-Oberfläche verlangt dafür, den Gerätenamen zur Bestätigung einzutippen. Der Job läuft mit `REQUIRE_MOUNT=1`: Fehlt
der Stick, wird nichts auf die Systemplatte geschrieben, und das Backup meldet einen Fehler. Stick ziehen: erst `sudo umount /mnt/mail-backup`.

| Punkt | Wert |
|---|---|
| Aufbewahrung | Sicherungen älter als 7 Tage werden bei jedem Lauf automatisch gelöscht (`KEEP_DAYS`, mindestens 1). Der neueste Snapshot bleibt immer. Monatssnapshots nur mit `KEEP_MONTHLY=n` (Standard 0). |
| Struktur | `daily/<Datum>/`, `monthly/<Jahr-Monat>/`, `latest` zeigt auf den neuesten Stand |
| Schutz | bricht ab, wenn das Ziel auf demselben Laufwerk wie die Mails oder innerhalb des Mailserver-Ordners liegt |
| Laufwerk eingehängt? | `REQUIRE_MOUNT=1` bricht ab, wenn das Ziel kein eigener Mountpunkt ist |
| Gleichzeitige Läufe | werden per Sperre verhindert |
| Rechte | Ziel nur für root (700) |
| Monitoring | `HC_URL=https://hc-ping.com/xxxx` meldet Start, Erfolg und jeden Fehler an Healthchecks.io |

Die Variablen werden mit `--install` in die Cron-Zeile übernommen, z. B.
`sudo KEEP_DAYS=30 REQUIRE_MOUNT=1 HC_URL=https://hc-ping.com/xxxx ./backup-mail.sh --install /mnt/backup/mail`.

### Wiederherstellen

Mit `restore-mail.sh` (der Backup-Ordner wird aus dem Cron-Job erkannt, sonst `--from /mnt/mail-backup`):

```bash
sudo ./restore-mail.sh --list                                 # Snapshots anzeigen
sudo ./restore-mail.sh --mailbox anna@home.lan --dry-run      # ansehen, was sich ändern würde (ändert nichts)
sudo ./restore-mail.sh --mailbox anna@home.lan                # ein Postfach aus dem neuesten Snapshot
sudo ./restore-mail.sh --mailbox anna@home.lan --snapshot daily/2026-10-01_033000
sudo ./restore-mail.sh --all                                  # alles: Mails, Konfiguration, Webmail, accounts.conf, .env
```

Ohne `-y` musst du `WIEDERHERSTELLEN` eintippen. Das Skript hält den Mailserver für die Dauer an, startet ihn danach wieder und baut den Index
neu auf (`doveadm force-resync`). **Der jetzige Stand wird vorher gesichert** in `data/vor-restore-<Zeit>/` (geänderte und gelöschte Dateien,
bei `--all` auch die alte `accounts.conf`); nach der Kontrolle löschen. Das Backup selbst wird nie verändert. Mails, die nur im jetzigen Stand
liegen, werden beim Wiederherstellen entfernt, bleiben aber in dieser Sicherung erhalten.

**Nur die Konfiguration** (nicht die Mails) kommt aus `config-backup/`. Die legt `setup-mailserver.sh` bei jeder Aktualisierung (`--update`)
automatisch an: `docker-compose.yml`, `.env`, `data/config` (Konten, Relay, fetchmail, Zertifikate ...) und die Roundcube-Konfiguration.

```bash
sudo ./restore-mail.sh --list-config                       # Sicherungen anzeigen
sudo ./restore-mail.sh --config --dry-run                  # ansehen, was sich ändern würde (ändert nichts)
sudo ./restore-mail.sh --config                            # neueste Sicherung wiederherstellen
sudo ./restore-mail.sh --config 20261009_210934            # eine bestimmte
sudo ./restore-mail.sh --config vor-restore-20261024-153000   # die letzte Wiederherstellung rückgängig machen
```

Vorher wird der jetzige Stand in `config-backup/vor-restore-<Zeit>/` gesichert, damit sich jede Wiederherstellung rückgängig machen lässt. Danach
werden die Container neu gestartet. **Achtung:** Konten, die nach der Sicherung angelegt wurden, fehlen dann in `data/config/postfix-accounts.cf`
(ihre Mails bleiben unter `data/mail-data` erhalten); neu anlegen mit `./setup-mailserver.sh --update`. Ein einzelnes Backup der
`accounts.conf` (`accounts.conf.bak-*`) kopierst du von Hand zurück: `sudo cp -p accounts.conf.bak-<Zeit> accounts.conf`.

**Frischer Server (alles ist weg):** Dateien neu laden (`get.sh`), den Backup-Stick einhängen (`sudo ./usb-backup.sh --setup /dev/sdb1`, das Dateisystem
bleibt erhalten), dann `sudo ./restore-mail.sh --all` und `sudo ./setup-mailserver.sh --update`.

Von Hand geht es auch (ein Postfach):

```bash
docker compose stop mailserver
rsync -a /mnt/backup/mail/daily/<Datum>/data/mail-data/deinedomain.at/anna/ data/mail-data/deinedomain.at/anna/
docker compose start mailserver
docker exec mailserver doveadm force-resync -u anna@deinedomain.at '*'
```

**Empfehlungen:**
- Das Ziel muss ein **anderes Laufwerk, NAS oder ein anderer Rechner** sein. Eine zweite Kopie außer Haus schützt vor Diebstahl und Brand.
- Das Backup enthält Klartext-Mails und die **Anbieter-Passwörter**. Kopien in die Cloud nur **verschlüsselt** (z. B. mit restic oder borg).
- Die Webmail-Datenbank (SQLite mit Einstellungen und Adressbuch, keine Mails) wird im laufenden Betrieb kopiert; sie kann in seltenen Fällen
  inkonsistent sein. Die Mails selbst sind davon nicht betroffen.
- **Läuft der Server in einer Proxmox-VM oder einem LXC:** zusätzlich ein Proxmox-Backup.
- **Teste die Wiederherstellung einmal**, bevor du beim Anbieter etwas löschst.

## Mails beim Anbieter löschen (Gmail, GMX, Yahoo)

**Neue Mails:** werden bei der Abholung (POP3) automatisch beim Anbieter gelöscht.

**Altbestand:** Der Import löscht nichts beim Anbieter. Vorgehen nach der Kontrolle:
1. Stichproben im Mailprogramm prüfen
2. Backup durchführen
3. Aufräumen aktivieren (unten) oder von Hand beim Anbieter löschen

**Automatisch durch das Skript (optional, je Anbieter wählbar):** In der Web-Oberfläche (Karte „Mails beim Anbieter löschen“) oder in
`accounts.conf` wählst du je Anbieter, ob Posteingang, Spam und Papierkorb geleert werden. Das richtet einen täglichen Cron-Job ein
(04:45 Uhr, Log: `/var/log/mail-gmail-cleanup.log`). Gelöscht wird **endgültig** beim Anbieter.

```
CLEAN_INBOX=gmx,yahoo
CLEAN_SPAM=alle
CLEAN_TRASH=alle
CLEAN_DAYS=7
GMAIL_EMPTY_SENT=1
GMAIL_SENT_DAYS=30
```

**Schutzregeln:**
- **Posteingang:** gelöscht wird nur, was lokal nachweislich gespeichert ist. Das Skript vergleicht die Message-ID jeder Mail mit dem lokalen
  Mailordner. Mails ohne Message-ID oder ohne lokale Kopie bleiben beim Anbieter. Bei Gmail gehen die Mails zuerst in den Papierkorb
  (sonst würde IMAP nur das Label entfernen) und werden dort mit `CLEAN_TRASH` endgültig gelöscht.
- **Spam und Papierkorb** werden nie importiert und deshalb ohne Abgleich geleert.
- Ein Konto wird übersprungen, solange lokal noch keine Mails liegen. Der Gmail-Posteingang und „Gesendet“ werden erst nach
  abgeschlossenem Import bereinigt.
- Ordner werden über die IMAP-Kennzeichen (Trash, Junk) und, wenn der Anbieter keine liefert, über Namen gefunden (Papierkorb, Spam, Bulk Mail …).
  Wird ein Ordner nicht gefunden, bleibt er unberührt und das Skript meldet es.

**Vorher ansehen, was gelöscht würde (ändert nichts):** `sudo ./setup-mailserver.sh --cleanup --dry-run`.
Von Hand sofort: `./setup-mailserver.sh --cleanup` (nach der Konfiguration) oder `--empty-trash` (Papierkorb bei allen Anbietern).

## Zur Seite gelegte Mails zurückholen

Wurde `DOMAIN` einmal falsch gesetzt, können Mails in einem zweiten Postfach landen (`data/mail-data/<falsche-domain>/<name>`). Lege diese Ordner zur Seite, statt sie zu löschen:

```bash
sudo mkdir -p data/alt-mailboxen
sudo mv data/mail-data/<falsche-domain> data/alt-mailboxen/
sudo ./setup-mailserver.sh --update
```

Dann übernimmt `merge_mailboxes.py` nur die Mails, die im richtigen Postfach noch fehlen (Abgleich über die Message-ID, ohne Doppelte):

```bash
sudo python3 merge_mailboxes.py            # Probelauf: zeigt nur die Zahlen
sudo python3 merge_mailboxes.py --apply    # kopiert und baut den Dovecot-Index neu auf
```

Die Quelle wird nie verändert. Das Zielkonto muss existieren. Mit `--user NAME` lässt sich ein einzelnes Postfach wählen, mit `--domain` die Ziel-Domain (Standard: `DOMAIN` aus `accounts.conf`).

## Fehlersuche

| Problem | Ursache und Lösung |
|---|---|
| `Ungültige Kontozeile` / `Anbieter ... nicht erkannt` | Format `adresse\|passwort\|lokalname\|lokales-passwort\|quota\|anbieter`. Bei fremden Domains den Anbieter (gmail, gmx, yahoo) im sechsten Feld eintragen. Kein `\|` in Passwörtern. |
| Senden scheitert mit `550 Sender address is not allowed` (GMX) | Der Anbieter erlaubt als Absender nur die eigene Adresse. Seit dieser Version schreibt der Server beim Senden die lokale Adresse (`name@home.lan`) auf die Adresse beim Anbieter um (`postfix-generic.cf`, `smtp_generic_maps`). Dateien aktualisieren (Installationsbefehl erneut ausführen, `accounts.conf` bleibt) und `sudo ./setup-mailserver.sh --update` starten; das startet den Mailserver neu. |
| Webmail: beim Anmelden „Verbindung zum Server fehlgeschlagen" | Roundcube prüft das Zertifikat des Mailservers streng. Passt dessen Name nicht zum Servernamen (`hostname:` in `docker-compose.yml`), lehnt es die Verbindung ab. Typisch nach einer Änderung von `DOMAIN` oder bei einem Zertifikat aus einer früheren Einrichtung. Prüfen: `grep hostname: docker-compose.yml` und `sudo openssl x509 -in data/certs/cert.pem -noout -subject -ext subjectAltName`. Seit dieser Version erneuert `setup-mailserver.sh` ein selbst signiertes Zertifikat mit falschem Namen selbst (das alte liegt in `data/certs-alt/`): `sudo ./setup-mailserver.sh --update`. Mit Let's Encrypt: `data/certbot/live/` muss den Servernamen enthalten. Test aus Roundcube: `docker exec roundcube php -r '$c=stream_context_create(["ssl"=>["cafile"=>"/certs/cert.pem","verify_peer"=>true,"verify_peer_name"=>true]]);$s=@stream_socket_client("ssl://SERVERNAME:993",$e,$m,10,STREAM_CLIENT_CONNECT,$c);echo $s?"OK\n":"FEHLER: $m\n";'` (SERVERNAME = der Name aus `hostname:`) |
| Webmail öffnet sich von einem anderen Rechner nicht | Mit `WEBMAIL_BIND=127.0.0.1` lauscht es nur auf dem Server. Zugriff über `tailscale serve` (`https://<name>.ts.net`), einen SSH-Tunnel (`ssh -L 8080:127.0.0.1:8080 benutzer@server`, dann `http://localhost:8080`) oder `WEBMAIL_BIND=0.0.0.0` und `--update`. Siehe [ZUGRIFF.md](ZUGRIFF.md). |
| Server heißt `mail.mail.deinedomain.at` (doppeltes `mail.`) | Das ist nur der Name des Servers (und seines Zertifikats). **Ändere `DOMAIN` deswegen nicht nachträglich:** `DOMAIN` bestimmt die lokale Adresse (`name@DOMAIN`) und den Ordner der Mails (`data/mail-data/<DOMAIN>/<name>/`). Nach einer Änderung wären bereits importierte Mails unter den neuen Adressen nicht zu finden. `setup-mailserver.sh` bricht in diesem Fall ab und nennt die betroffenen Postfächer. Ob und wo Mails liegen: `for d in data/mail-data/*/*; do echo "$(find "$d" -type f \( -path '*/cur/*' -o -path '*/new/*' \) \| wc -l)  $d"; done`. |
| `ANMELDUNG ABGELEHNT` bei `--check` | Gmail/Yahoo: App-Passwort statt normalem Passwort. GMX: POP3/IMAP in den Einstellungen freischalten. Beim Anbieter ggf. Zwei-Faktor prüfen. |
| Import schlägt fehl | Die Meldung direkt über "Import fehlgeschlagen" lesen. Zuerst `--check`. `bandwidth limits` oder `too many connections`: der Anbieter drosselt, später erneut starten. |
| Es kommen keine neuen Mails | `docker logs --tail 100 mailserver 2>&1 \| grep -i fetchmail`. Bei GMX: Freischaltung abgelaufen? `--check`. Bei Gmail: POP auf "ab jetzt" und "Kopie löschen"? |
| `zugangsdaten.txt` ist leer | Die Konten existierten schon. Passwörter neu setzen (`setup email update`). |
| Roundcube startet nicht | `docker logs roundcube`. Bei `unable to open database file`: `sudo chown -R 33:33 data/roundcube/db && docker compose restart roundcube`. Bei belegtem Port einen anderen `WEBMAIL_PORT` setzen. |
| Webmail-Login schlägt fehl (selbst signiert) | Roundcube vertraut `data/certs/cert.pem`. Hat sich der Servername geändert (neue `DOMAIN`), das Zertifikat löschen und `./setup-mailserver.sh --update` starten. |
| Login schlägt fehl | `doveadm auth test` (siehe oben). Benutzername muss die **komplette Adresse** sein. Fail2ban prüfen und die IP entsperren. |
| Verbindung nicht möglich | Schrittweise: `docker compose ps`, `ss -tlnp \| grep -E ':(993\|587)'`, `openssl s_client -connect localhost:993 -brief </dev/null`, dann Firewall (`ufw allow 993/tcp`, `587/tcp`), DNS (`dig +short mail.deinedomain.at`), Portfreigabe, CGNAT. Orange Wolke in Cloudflare blockiert IMAP. |
| Senden funktioniert nicht | `docker exec mailserver postqueue -p` und `docker logs mailserver \| grep -E "postfix/(smtp\|submission)"`. `SASL authentication failed`: Passwort in `data/config/postfix-sasl-password.cf` prüfen. Kein Logeintrag: Client erreicht den Server nicht, Port 587 mit STARTTLS und volle Adresse als Benutzername. |
| Zertifikatswarnung in der App | Bei selbst signiertem Zertifikat normal. Mit Domain und Let's Encrypt verschwindet sie. Der Servername in der App muss exakt dem `hostname:` entsprechen. |
| Doppelte Mails | Gmail: POP stand auf "alle Nachrichten" statt "ab jetzt". GMX/Yahoo: Posteingang wurde zusätzlich per IMAP importiert (nur bei einer älteren Skriptversion). |
| `docker compose` meldet fehlende Variablen | Die Datei `.env` fehlt oder ist nicht lesbar (Rechte 640, Gruppe docker). `./setup-mailserver.sh --update` schreibt sie neu. |
