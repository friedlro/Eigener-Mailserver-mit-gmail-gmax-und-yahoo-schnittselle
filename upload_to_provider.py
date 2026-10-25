#!/usr/bin/env python3
"""upload_to_provider.py - legt Mails aus dem lokalen Postfach beim Anbieter (Gmail, GMX, Yahoo) per IMAP ab.

Wird von setup-mailserver.sh --upload in einem python:3-alpine-Container gestartet (nur Standardbibliothek).
Es werden Mails HINZUGEFÜGT, nie gelöscht oder verändert (weder lokal noch beim Anbieter). Regeln:

  * Mails landen unter einem eigenen Label/Ordner (Standard "Vom-Server/<Ordnername>"), NICHT im Posteingang.
    Sonst würde die laufende POP3-Abholung sie sofort wieder abholen.
  * Was beim Anbieter schon vorhanden ist (gleiche Message-ID), wird übersprungen. Bei Gmail zählt dafür das ganze Konto
    ("Alle Nachrichten"), bei den anderen Anbietern der Zielordner. Ein erneuter Aufruf lädt deshalb nichts doppelt hoch.
  * Mails ohne Message-ID bekommen beim Hochladen eine aus der Prüfsumme ihres Inhalts (sonst wären sie beim nächsten Lauf
    nicht wiederzuerkennen); dafür wird eine Kopfzeile ergänzt, sonst bleibt die Mail unverändert.
  * Flags (gelesen, beantwortet, markiert) und das Originaldatum (Kopfzeile Date) bleiben erhalten.
  * Papierkorb, Spam und Entwürfe werden nicht hochgeladen (UP_SKIP).
  * UP_DRY=1: nur zählen, nichts hochladen.   UP_LIMIT=N: nach N hochgeladenen Mails aufhören (Tageslimits der Anbieter).

Eingaben (Umgebungsvariablen): UP_PROV, UP_USER, UP_PASS, UP_HOST, UP_MAILDIR, UP_LABEL, UP_SKIP, UP_DRY, UP_LIMIT.
"""
import datetime
import email.utils
import hashlib
import imaplib
import os
import re
import sys

HOSTS = {"gmail": "imap.gmail.com", "gmx": "imap.gmx.net", "yahoo": "imap.mail.yahoo.com"}
MID_RE = re.compile(rb"(?im)^message-id:\s*(<[^>\s]+>)")
LIST_RE = re.compile(r'\((?P<flags>[^)]*)\)\s+(?:"(?P<sep>[^"]*)"|NIL)\s+(?P<name>.+)$')
MAX_SIZE = 25 * 1024 * 1024
FLAG_MAP = {"S": "\\Seen", "R": "\\Answered", "F": "\\Flagged"}


def chunks(items, n=300):
    items = list(items)
    for i in range(0, len(items), n):
        yield b",".join(items[i:i + n])


def key_of(data):
    """Message-ID (klein). Mails ohne Message-ID bekommen eine aus der Prüfsumme des Inhalts (siehe with_id)."""
    end = min([p for p in (data.find(b"\n\n"), data.find(b"\r\n\r\n")) if p >= 0] or [len(data)])
    m = MID_RE.search(data[:end + 1])
    return m.group(1).lower().decode("ascii", "replace") if m else "<%s@vom-server.invalid>" % hashlib.sha256(data).hexdigest()


def with_id(data, key):
    """Mails ohne Message-ID erhalten die aus key_of berechnete, damit ein erneuter Lauf sie beim Anbieter wiedererkennt."""
    end = min([p for p in (data.find(b"\n\n"), data.find(b"\r\n\r\n")) if p >= 0] or [len(data)])
    if MID_RE.search(data[:end + 1]):
        return data
    return b"Message-ID: " + key.encode("ascii") + (b"\r\n" if b"\r\n" in data[:end + 2] else b"\n") + data


def folder_name(rel):
    """Maildir++-Ordner ('.' = Posteingang, '.Archiv.2024') -> 'Archiv/2024'; eckige Klammern entfallen."""
    if rel == ".":
        return "Posteingang"
    name = rel.lstrip(".").replace(".", "/")
    return re.sub(r"[\[\]]", "", name).strip("/")


def local_messages(maildir, skip):
    """[(Zielordner, Pfad, Unterordner cur/new)] mit dem Posteingang zuerst."""
    out = []
    for root, _dirs, files in os.walk(maildir):
        sub = os.path.basename(root)
        if sub not in ("cur", "new"):
            continue
        rel = os.path.relpath(os.path.dirname(root), maildir)
        top = folder_name(rel).split("/")[0].lower()
        if top in skip:
            continue
        for f in sorted(files):
            out.append((folder_name(rel), os.path.join(root, f), sub))
    out.sort(key=lambda t: (t[0] != "Posteingang", t[0], t[2], t[1]))
    return out


def flags_of(path, sub):
    info = os.path.basename(path).partition(":2,")[2]
    fl = [FLAG_MAP[c] for c in info if c in FLAG_MAP]
    if sub == "new" and "\\Seen" in fl:
        fl.remove("\\Seen")
    return "(" + " ".join(fl) + ")" if fl else None


def date_of(data, path):
    end = min([p for p in (data.find(b"\n\n"), data.find(b"\r\n\r\n")) if p >= 0] or [len(data)])
    m = re.search(rb"(?im)^date:\s*(.+)$", data[:end + 1])
    if m:
        try:
            d = email.utils.parsedate_to_datetime(m.group(1).decode("ascii", "replace").strip())
            if d.tzinfo is None:
                d = d.replace(tzinfo=datetime.timezone.utc)
            return d
        except (TypeError, ValueError):
            pass
    return datetime.datetime.fromtimestamp(os.path.getmtime(path), datetime.timezone.utc)


def header_ids(M, uids):
    ids = set()
    for ch in chunks(uids):
        typ, data = M.uid("FETCH", ch, "(UID BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)])")
        if typ != "OK":
            continue
        for item in data or []:
            if isinstance(item, tuple):
                m = MID_RE.search(item[1] or b"")
                if m:
                    ids.add(m.group(1).lower().decode("ascii", "replace"))
    return ids


def ids_in(M, mailbox):
    """Message-IDs eines Ordners beim Anbieter (leer, wenn der Ordner nicht existiert)."""
    if M.select('"%s"' % mailbox, True)[0] != "OK":
        return set()
    typ, data = M.uid("SEARCH", None, "ALL")
    uids = data[0].split() if typ == "OK" and data and data[0] else []
    ids = header_ids(M, uids)
    M.close()
    return ids


def provider_boxes(M):
    """(Trennzeichen, Ordner 'Alle Nachrichten' oder None)."""
    sep, allmail = "/", None
    typ, data = M.list()
    for raw in data or []:
        line = raw.decode("utf-8", "replace") if isinstance(raw, bytes) else str(raw)
        m = LIST_RE.match(line)
        if not m:
            continue
        if m.group("sep"):
            sep = m.group("sep")
        if "\\All" in m.group("flags"):
            allmail = m.group("name").strip().strip('"')
    return sep, allmail


def run(env, connect=None, out=print):
    """Gibt 0 (ok), 1 (Anmeldung/Verbindung fehlgeschlagen) oder 2 (einzelne Mails fehlgeschlagen) zurück."""
    prov, user, pw = env["UP_PROV"], env["UP_USER"], env["UP_PASS"]
    host = env.get("UP_HOST") or HOSTS[prov]
    maildir = env.get("UP_MAILDIR", "/mail")
    label = (env.get("UP_LABEL") or "Vom-Server").strip("/")
    skip = {s.strip().lower() for s in (env.get("UP_SKIP") or "Trash,Junk,Spam,Drafts,Papierkorb").split(",") if s.strip()}
    dry = env.get("UP_DRY") == "1"
    limit = int(env.get("UP_LIMIT", "0") or 0)
    tag = " (Probelauf, es wird nichts hochgeladen)" if dry else ""

    msgs = local_messages(maildir, skip)
    if not msgs:
        out("    übersprungen: lokal liegen keine Mails (außer Papierkorb, Spam und Entwürfe)")
        return 0
    try:
        M = (connect or (lambda h: imaplib.IMAP4_SSL(h)))(host)
        M.login(user, pw)
    except Exception as e:  # noqa: BLE001
        out("    Anmeldung fehlgeschlagen: %s" % e)
        return 1

    sep, allmail = provider_boxes(M)
    have = set()
    if prov == "gmail" and allmail:
        have = ids_in(M, allmail)
        out("    beim Anbieter schon vorhanden: %d Nachrichten (ganzes Konto)" % len(have))
    seen_folder, created = {}, set()
    total = skipped = up = failed = 0
    stop = False
    for folder, path, sub in msgs:
        if stop:
            break
        total += 1
        box = label + sep + folder.replace("/", sep)
        if box not in seen_folder:
            seen_folder[box] = set() if prov == "gmail" and allmail else ids_in(M, box)
            have |= seen_folder[box]
        try:
            with open(path, "rb") as f:
                data = f.read()
        except OSError:
            failed += 1
            continue
        k = key_of(data)
        if k in have:
            skipped += 1
            continue
        if len(data) > MAX_SIZE:
            out("    zu groß (über 25 MB), übersprungen: %s" % os.path.basename(path))
            failed += 1
            continue
        have.add(k)
        up += 1
        if dry:
            continue
        if box not in created:
            M.create('"%s"' % box)  # existiert der Ordner schon, meldet der Server NO: egal
            created.add(box)
        try:
            typ, _ = M.append('"%s"' % box, flags_of(path, sub), date_of(data, path), with_id(data, k))
            if typ != "OK":
                raise OSError(typ)
        except Exception as e:  # noqa: BLE001
            up -= 1
            failed += 1
            out("    Hochladen fehlgeschlagen (%s): %s" % (e, os.path.basename(path)))
        if up and up % 500 == 0:
            out("    ... %d hochgeladen" % up)
        if limit and up >= limit:
            out("    Limit von %d erreicht, erneut aufrufen für den Rest" % limit)
            stop = True
    out("    %d lokale Mails geprüft, %d beim Anbieter schon vorhanden, %d %s%s%s" % (
        total, skipped, up, "würden hochgeladen" if dry else "hochgeladen", " nach '%s'" % label,
        ", %d fehlgeschlagen" % failed if failed else "") + tag)
    try:
        M.logout()
    except Exception:  # noqa: BLE001
        pass
    return 2 if failed else 0


if __name__ == "__main__":
    sys.exit(run(dict(os.environ)))
