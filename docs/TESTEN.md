# Tests

## Automatische Tests

```bash
tests/run-tests.sh
```

Voraussetzungen: Linux, `bash`, `python3`, `rsync`, `flock`; optional `shellcheck` und `docker` (für `docker compose config`).

Die Tests brauchen **weder echte Konten noch einen laufenden Mailserver**. `docker`, `curl`, `whiptail` und ähnliche Programme werden durch
Platzhalter aus `tests/stubs/` ersetzt, die Skripte laufen in einem Wegwerf-Ordner, und ihre Systempfade (Cron-Ordner, Sperrdatei) werden
dorthin umgelenkt. Es wird nichts installiert und nichts am System verändert. **Nicht** auf einem produktiv genutzten Mailserver ausführen,
sondern auf einem Entwicklungsrechner oder in einer Test-VM.

| Bereich | Geprüft wird |
|---|---|
| Syntax | `bash -n` aller Skripte, Python-Syntax des MCP-Servers, `shellcheck` falls vorhanden |
| Installation mit Gmail, GMX, Yahoo | je Anbieter die richtigen Server für Import, Abholung und Senden; GMX.com; Anbieter per Adresse erkannt oder explizit gesetzt; Sonderzeichen in Passwörtern; Dateirechte; keine Passwörter in Befehlsargumenten; festgelegte Versionen; Gültigkeit der erzeugten `docker-compose.yml` |
| Wiederholung und Update | keine doppelten Konten, kein zweiter Import, Update importiert nichts und lässt die Abholung an |
| `--check` | Erfolg, abgelehnte Anmeldung, nicht erreichbarer Server, keine Passwörter in Argumenten |
| Fehleingaben | unbekannte Domain, Anbieter, Einstellung, ungültige Tokens, Domain, Bind-Adresse, Image-Tag, keine Konten |
| Domain und Tunnel | Let's Encrypt, DDNS und Tunnel; Token nur in `.env`; Cron mit festem Tag |
| Installationsassistent | komplette Dialogfolge mit Fehleingabe und Anbieter-Abgleich; die erzeugte `accounts.conf` versteht `setup-mailserver.sh` |
| Backup | Ablehnung von `KEEP_DAYS=0`, Ziel in der Quelle, gleiches Laufwerk, Parallellauf; Snapshots, Löschen alter Snapshots nach KEEP_DAYS, `latest`, Rechte, Cron-Zeile, logrotate |
| Aufräumen beim Anbieter | je Anbieter: Auswahl, Probelauf, Altersgrenze, Gmail-Posteingang erst nach Import, Message-ID-Abgleich, Papierkorb/Spam, Fehler und fehlende Ordner (`tests/test_cleanup.py` mit nachgebautem IMAP-Server) |
| USB-Backup | nur USB-Datenträger (nie System-/interne Platte, nie ein Stick mit laufendem System), ungültige Namen, NTFS nur nach `--format`, fstab (UUID, nofail), Aushängen, Cron mit `REQUIRE_MOUNT`, `--remove` (`tests/fixtures/lsblk.json`, Platzhalter für mount/mkfs/blkid) |
| Web-Oberfläche | Anmeldung, Passwortsperre, Eingabeprüfung, accounts.conf (Rechte, Sicherung), Protokoll mit Exit-Code, Beenden (`tests/test_webui.py`, mit Platzhalter-Setup) |
| Deinstallation | entfernt Konfiguration, Cron und Container, **lässt `data/` ohne ausdrückliche Auswahl unberührt** |

## Was die automatischen Tests nicht abdecken

- Eine echte Anmeldung bei Gmail, GMX oder Yahoo und das echte Abholen und Löschen von Mails.
- Das tatsächliche Starten von docker-mailserver und Roundcube (inklusive Anmeldung in der Webmail mit dem selbst signierten Zertifikat).
- Die Installation von Docker und Tailscale.
- `uninstall.sh` für Docker, Tailscale und das Löschen von `data/`.

Dafür gibt es den Abnahmetest auf einem frischen System.

## Abnahmetest auf einem frischen System

Verwenden Sie eine frische Test-VM (Debian 12 oder Ubuntu 24.04, 2 GB RAM, 20 GB Platte), **nicht** den laufenden Mailserver.

1. Projekt holen und `sudo ./install.sh` starten. Mit **einem Testkonto je Anbieter** durchlaufen, das Tailscale-Angebot einmal mit "Nein".
2. `docker compose ps` zeigt `mailserver` und `roundcube` als laufend. `sudo ./setup-mailserver.sh --check` meldet für alle Konten OK.
3. In der Webmail anmelden (`http://<IP>:8080`) und im Mailclient per IMAP (993) und SMTP (587) anmelden.
4. Eine Testmail an das Anbieter-Konto senden, nach spätestens 5 Minuten ist sie lokal da und beim Anbieter gelöscht (`docker logs mailserver | grep -i fetchmail`).
5. Eine Mail über den Mailserver versenden und beim Empfänger prüfen.
6. Altbestand: Prüfen, dass Ordner und Mails lokal vorhanden sind und der Posteingang von GMX/Yahoo vollständig per POP3 angekommen ist.
7. `sudo ./setup-mailserver.sh` ein zweites Mal: keine Dubletten. `--update`: Mails und Passwörter bleiben.
8. `sudo ./backup-mail.sh --install <Ziel>` und eine Wiederherstellung eines Postfachs.
9. `sudo ./uninstall.sh`: Mails bleiben, wenn nicht ausdrücklich gewählt. Anschließend `--alles` testen.

Ergebnisse bitte als Issue festhalten, damit sie in den Teststand unten einfließen.

## Teststand

| Prüfung | Stand |
|---|---|
| Automatische Tests (`tests/run-tests.sh`) | siehe Commit-Nachricht des letzten Laufs; bei Änderungen an den Skripten erneut ausführen |
| Gmail mit echtem Konto im Betrieb | erprobt mit der Vorgängerversion der Skripte |
| GMX und Yahoo mit echten Konten | **offen** |
| Frische Installation auf einem leeren System | **offen** |
| Deinstallation auf einem System mit Docker/Tailscale | **offen** |
