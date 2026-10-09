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

## Backup

`backup-mail.sh` legt tägliche Snapshots des gesamten Ordners an (Mails, Konfiguration, Webmail-Daten, `accounts.conf`). Unveränderte
Dateien werden per Hardlink nicht doppelt gespeichert.

```bash
# Einrichten: täglich um 03:30 per Cron (Log: /var/log/mail-backup.log, wöchentlich rotiert)
sudo ./backup-mail.sh --install /mnt/backup/mail

# Sofort einmal ausführen (zum Testen)
sudo ./backup-mail.sh /mnt/backup/mail
```

| Punkt | Wert |
|---|---|
| Aufbewahrung | 14 Tages- und 6 Monats-Snapshots (`KEEP_DAILY`, `KEEP_MONTHLY`, mindestens 1) |
| Struktur | `daily/<Datum>/`, `monthly/<Jahr-Monat>/`, `latest` zeigt auf den neuesten Stand |
| Schutz | bricht ab, wenn das Ziel auf demselben Laufwerk wie die Mails oder innerhalb des Mailserver-Ordners liegt |
| Laufwerk eingehängt? | `REQUIRE_MOUNT=1` bricht ab, wenn das Ziel kein eigener Mountpunkt ist |
| Gleichzeitige Läufe | werden per Sperre verhindert |
| Rechte | Ziel nur für root (700) |
| Monitoring | `HC_URL=https://hc-ping.com/xxxx` meldet Start, Erfolg und jeden Fehler an Healthchecks.io |

Die Variablen werden mit `--install` in die Cron-Zeile übernommen, z. B.
`sudo KEEP_DAILY=30 REQUIRE_MOUNT=1 HC_URL=https://hc-ping.com/xxxx ./backup-mail.sh --install /mnt/backup/mail`.

**Wiederherstellen** (Beispiel: ein Postfach):

```bash
docker compose stop mailserver
rsync -a /mnt/backup/mail/daily/<Datum>/data/mail-data/deinedomain.at/anna/ \
         data/mail-data/deinedomain.at/anna/
docker compose start mailserver
docker exec mailserver doveadm force-resync -u anna@deinedomain.at '*'
```

Besitzer und Rechte stellt `rsync` selbst wieder her.

**Empfehlungen:**
- Das Ziel muss ein **anderes Laufwerk, NAS oder ein anderer Rechner** sein. Eine zweite Kopie außer Haus schützt vor Diebstahl und Brand.
- Das Backup enthält Klartext-Mails und die **Anbieter-Passwörter**. Kopien in die Cloud nur **verschlüsselt** (z. B. mit restic oder borg).
- Die Webmail-Datenbank (SQLite mit Einstellungen und Adressbuch, keine Mails) wird im laufenden Betrieb kopiert; sie kann in seltenen Fällen
  inkonsistent sein. Die Mails selbst sind davon nicht betroffen.
- **Läuft der Server in einer Proxmox-VM oder einem LXC:** zusätzlich ein Proxmox-Backup.
- **Teste die Wiederherstellung einmal**, bevor du beim Anbieter etwas löschst.

## Gmail aufräumen (nur Gmail-Konten)

**Neue Mails:** werden bei der Abholung automatisch beim Anbieter gelöscht.

**Altbestand:** Der Import löscht nichts beim Anbieter. Vorgehen nach der Kontrolle:
1. Stichproben im Mailprogramm prüfen
2. Backup durchführen
3. In Gmail suchen mit `older_than:1d`, alles markieren, löschen, Papierkorb leeren

**Automatisch durch das Skript (optional):** Sobald `GMAIL_EMPTY_TRASH=1` oder `GMAIL_EMPTY_SENT=1` in `accounts.conf` steht, richtet
`setup-mailserver.sh` einen täglichen Cron-Job ein (04:45 Uhr, Log: `/var/log/mail-gmail-cleanup.log`). Er löscht bei Gmail
**endgültig** und findet Papierkorb, Spam und Gesendet über die IMAP-Kennzeichen, also unabhängig von der Sprache.

```
GMAIL_EMPTY_TRASH=1
GMAIL_TRASH_DAYS=30
GMAIL_EMPTY_SENT=1
GMAIL_SENT_DAYS=30
```

Schutz: Ein Konto wird übersprungen, solange lokal noch keine Mails liegen. "Gesendet" wird zusätzlich nur bereinigt, wenn der Import
des Kontos abgeschlossen ist. Von Hand: `./setup-mailserver.sh --cleanup` oder `--empty-trash`. Für GMX und Yahoo gibt es dieses
Aufräumen nicht.

## Fehlersuche

| Problem | Ursache und Lösung |
|---|---|
| `Ungültige Kontozeile` / `Anbieter ... nicht erkannt` | Format `adresse\|passwort\|lokalname\|lokales-passwort\|quota\|anbieter`. Bei fremden Domains den Anbieter (gmail, gmx, yahoo) im sechsten Feld eintragen. Kein `\|` in Passwörtern. |
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
