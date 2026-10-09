# Anbieter vorbereiten: Gmail, GMX, Yahoo

Jedes Konto wird einmalig beim Anbieter vorbereitet, **bevor** der Mailserver zum ersten Mal läuft. Danach prüft
`./setup-mailserver.sh --check`, ob die Zugangsdaten stimmen (IMAP und POP3), ohne etwas zu verändern.

> **Teststand:** Die Anbindung von Gmail ist im Betrieb erprobt. Die Anbindung von GMX und Yahoo folgt denselben
> Mechanismen und den offiziellen Servereinstellungen, wurde aber noch **nicht mit echten GMX- und Yahoo-Konten**
> durchlaufen. Probieren Sie sie zuerst mit einem Konto aus, das nicht Ihre einzige Kopie wichtiger Mails enthält,
> und prüfen Sie nach der ersten Abholung die Mails lokal, bevor Sie sich auf das Löschen beim Anbieter verlassen.

## Überblick

| | Gmail | GMX | Yahoo |
|---|---|---|---|
| Passwort für den Mailserver | **App-Passwort** (16 Buchstaben) | GMX-Passwort (bei Zwei-Faktor: Passwort für externe Programme, falls GMX eines verlangt) | **App-Passwort** |
| Freischaltung nötig | IMAP und POP in den Gmail-Einstellungen | **POP3 und IMAP in den GMX-Einstellungen** | keine (POP und IMAP stehen zur Verfügung) |
| IMAP (Import) | `imap.gmail.com:993` | `imap.gmx.net:993` (gilt auch für gmx.at und gmx.ch; `.com`-Konten: `imap.gmx.com`) | `imap.mail.yahoo.com:993` |
| POP3 (laufende Abholung) | `pop.gmail.com:995` | `pop.gmx.net:995` (`.com`: `pop.gmx.com`) | `pop.mail.yahoo.com:995` |
| SMTP (Senden) | `smtp.gmail.com:587` STARTTLS | `mail.gmx.net:587` STARTTLS (`.com`: `mail.gmx.com`) | `smtp.mail.yahoo.com:587` STARTTLS |
| Benutzername | volle Adresse | volle Adresse | volle Adresse |
| Erkannt an der Adresse | gmail.com, googlemail.com | gmx.de, .net, .at, .ch, .com, .eu, .org, .info | yahoo.* (außer yahoo.co.jp), ymail.com, rocketmail.com |

Bei anderen Domains tragen Sie den Anbieter im sechsten Feld der Kontozeile ein (`gmail`, `gmx` oder `yahoo`).

## So arbeitet der Mailserver mit dem jeweiligen Anbieter

| | Gmail | GMX und Yahoo |
|---|---|---|
| Altbestand | per IMAP: Labels werden zu Ordnern (oder nur "Alle Nachrichten"), ohne Spam und Papierkorb | per IMAP: alle Ordner **außer Posteingang, Papierkorb und Spam** |
| Posteingang | nur neue Mails per POP3 ("ab jetzt eingehende") | der **gesamte Posteingang** kommt per POP3 und wird dabei beim Anbieter gelöscht |
| Laufende Abholung | POP3, alle 5 Minuten, mit Löschen beim Anbieter | wie Gmail |
| Senden | über den SMTP-Server des Anbieters mit dem eigenen Konto | wie Gmail |
| Gmail aufräumen (Papierkorb, Gesendet) | möglich (Abschnitt "Betrieb") | **nicht vorgesehen** |

Der Posteingang von GMX und Yahoo wird absichtlich nicht per IMAP importiert. Sonst käme jede Mail ein zweites Mal
per POP3. Bei einem großen Posteingang dauert dafür die erste Abholung länger.

## Gmail

1. Google-Konto → **Sicherheit** → 2-Faktor-Anmeldung aktivieren, dann **App-Passwörter** → neues Passwort erstellen.
   Es muss ein App-Passwort sein, nicht das normale Google-Passwort.
2. Gmail → Einstellungen → **Alle Einstellungen** → **Weiterleitung und POP/IMAP**:
   - IMAP-Zugriff aktivieren (für den Import)
   - POP aktivieren für **"Nachrichten, die ab jetzt eingehen"** (für die laufende Abholung)
   - "Wenn auf Nachrichten mit POP zugegriffen wird": **"Gmail-Kopie löschen"**
3. Bei Google Workspace kann der Administrator IMAP/POP sperren.

Hinweise:
- Bei "Gmail-Kopie löschen" landen die Mails zuerst im Papierkorb, der sich nach 30 Tagen leert. Der Speicher wird also verzögert frei.
- Im Modus `ordner` fehlen archivierte Mails ohne Label. Prüfen Sie vor dem Löschen in Gmail die Suche
  `has:nouserlabels -in:inbox -in:sent -in:drafts -in:spam -in:trash`. Gibt es Treffer, setzen Sie ein Label darauf und
  starten `./setup-mailserver.sh --reimport`.

## GMX

1. Im GMX-Postfach: **Einstellungen** → **POP3 & IMAP** → **"POP3 und IMAP Zugriff erlauben"** einschalten und speichern.
2. GMX schaltet den Zugriff nach längerer Nichtnutzung aus Sicherheitsgründen wieder ab. Die Abholung alle 5 Minuten hält ihn aktiv.
   Fehlt die Freischaltung, meldet `--check` "ANMELDUNG ABGELEHNT".
3. Tragen Sie das GMX-Passwort ein. Verlangt GMX bei Ihrer Zwei-Faktor-Einstellung ein eigenes Passwort für externe Programme, verwenden Sie dieses.
4. Konten mit Endung `@gmx.com` nutzen die Server `*.gmx.com`; das Skript wählt sie automatisch.

## Yahoo

1. Yahoo-Konto → **Kontosicherheit** → **"App-Passwort generieren"**, Name z. B. "Mailserver". Das erzeugte Passwort tragen Sie ein.
   Das normale Yahoo-Passwort wird für externe Programme in der Regel abgelehnt.
2. POP3 und IMAP stehen ohne weitere Einstellung zur Verfügung.

## Zugangsdaten testen

```bash
sudo ./setup-mailserver.sh --check
```

Jedes Konto wird per IMAP und POP3 angemeldet (nur Anmeldung, es wird nichts gelesen oder verändert). Die Ausgabe nennt
bei einem Fehler die wahrscheinliche Ursache:

| Meldung | Bedeutung |
|---|---|
| ANMELDUNG ABGELEHNT | Passwort bzw. App-Passwort falsch, oder POP/IMAP beim Anbieter nicht freigeschaltet |
| Server nicht gefunden | Internetverbindung oder DNS am Server prüfen |
| Zeitüberschreitung / TLS-Fehler | Netzwerk, Firewall oder Anbieter-Störung |

Der Installationsassistent `./install.sh` bietet denselben Test für jedes Konto direkt bei der Eingabe an.

## Grenzen

- **Senden:** Ausgehende Mails laufen über den SMTP-Server des Anbieters. Empfänger sehen die Adresse des Anbieters als Absender.
  Anbieter begrenzen die Zahl der Mails pro Tag; der Mailserver ist für den privaten Gebrauch gedacht, nicht für Massenversand.
- **Nur der Posteingang per POP3:** Mails, die der Anbieter in andere Ordner einsortiert (z. B. Filter bei Yahoo oder GMX), kommen
  nur über den Import des Altbestands, nicht über die laufende Abholung.
- **Änderungen der Anbieter:** Anmeldeverfahren ändern sich (z. B. Pflicht zu OAuth statt Passwörtern). Dann muss das Projekt angepasst werden.
