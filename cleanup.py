#!/usr/bin/env python3
"""cleanup.py - löscht beim Anbieter (Gmail, GMX, Yahoo) Mails aus Posteingang, Spam und Papierkorb.

Wird von setup-mailserver.sh --cleanup in einem python:3-alpine-Container gestartet (nur Standardbibliothek).
Alles Löschen geschieht ENDGÜLTIG beim Anbieter und lässt sich nicht rückgängig machen. Schutzregeln:

  * POSTEINGANG: Es wird nur eine Mail gelöscht, deren Message-ID nachweislich im lokalen Mailordner
    liegt. Mails ohne Message-ID und Mails, die lokal nicht gefunden werden, bleiben beim Anbieter.
    Bei Gmail wird eine Mail dafür in den Papierkorb verschoben (sonst würde IMAP nur das Label entfernen).
  * SPAM und PAPIERKORB werden bei GMX und Yahoo ohnehin nie importiert und deshalb ohne Abgleich geleert.
  * Ein Konto wird übersprungen, solange lokal noch keine Mails liegen.
  * CL_DRY=1: nur zählen, nichts verändern.

Eingaben (Umgebungsvariablen): CL_PROV, CL_USER, CL_PASS, CL_HOST, CL_MAILDIR, CL_INBOX, CL_SPAM, CL_TRASH,
CL_SENT (nur Gmail: "Gesendet" in den Papierkorb), CL_DAYS, CL_SENT_DAYS, CL_DRY.
"""
import datetime
import imaplib
import os
import re
import sys

HOSTS = {"gmail": "imap.gmail.com", "gmx": "imap.gmx.net", "yahoo": "imap.mail.yahoo.com"}
TRASH_NAMES = {"trash", "papierkorb", "deleted items", "deleted messages", "deleted", "gel&apy-schte elemente", "gel&apy-scht"}
JUNK_NAMES = {"spam", "junk", "bulk", "bulk mail", "junk e-mail", "junk email"}
LIST_RE = re.compile(r'\((?P<flags>[^)]*)\)\s+(?:"(?P<sep>[^"]*)"|NIL)\s+(?P<name>.+)$')
MID_RE = re.compile(rb"(?im)^message-id:\s*(<[^>\s]+>)")


def chunks(items, n=200):
    items = list(items)
    for i in range(0, len(items), n):
        yield b",".join(items[i:i + n])


def local_ids(maildir):
    """Message-IDs aller lokal gespeicherten Mails (cur/ und new/ in allen Ordnern)."""
    ids = set()
    count = 0
    for root, _dirs, files in os.walk(maildir):
        if os.path.basename(root) not in ("cur", "new"):
            continue
        for name in files:
            try:
                with open(os.path.join(root, name), "rb") as f:
                    head = f.read(65536)
            except OSError:
                continue
            count += 1
            end = min([p for p in (head.find(b"\n\n"), head.find(b"\r\n\r\n")) if p >= 0] or [len(head)])
            m = MID_RE.search(head[:end + 1])
            if m:
                ids.add(m.group(1).lower())
    return ids, count


def list_boxes(M):
    """Gibt {'Trash': name, 'Junk': name, 'Sent': name} zurück (Kennzeichen zuerst, dann Namen)."""
    box = {}
    byname = []
    typ, data = M.list()
    for raw in data or []:
        line = raw.decode("utf-8", "replace") if isinstance(raw, bytes) else str(raw)
        m = LIST_RE.match(line)
        if not m:
            continue
        flags, name = m.group("flags"), m.group("name").strip().strip('"')
        byname.append(name)
        for key in ("Trash", "Sent", "Junk"):
            if "\\" + key in flags:
                box.setdefault(key, name)
    for name in byname:
        low = name.lower().split("/")[-1]
        if "Trash" not in box and low in TRASH_NAMES:
            box["Trash"] = name
        if "Junk" not in box and low in JUNK_NAMES:
            box["Junk"] = name
    return box


def search(M, days):
    if days > 0:
        d = (datetime.date.today() - datetime.timedelta(days=days)).strftime("%d-%b-%Y")
        typ, data = M.uid("SEARCH", None, "BEFORE", d)
    else:
        typ, data = M.uid("SEARCH", None, "ALL")
    if typ != "OK" or not data or not data[0]:
        return []
    return data[0].split()


def header_ids(M, uids):
    """{uid(bytes): message-id(bytes, klein) oder None}"""
    out = {u: None for u in uids}
    for ch in chunks(uids):
        typ, data = M.uid("FETCH", ch, "(UID BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)])")
        if typ != "OK":
            continue
        for item in data or []:
            if not isinstance(item, tuple):
                continue
            u = re.search(rb"UID (\d+)", item[0])
            if not u:
                continue
            m = MID_RE.search(item[1] or b"")
            out[u.group(1)] = m.group(1).lower() if m else None
    return out


def select(M, name):
    return M.select('"%s"' % name)[0] == "OK"


def remove(M, uids):
    for ch in chunks(uids):
        M.uid("STORE", ch, "+FLAGS", "(\\Deleted)")
    M.expunge()


def run(env, connect=None, out=print):
    """Führt das Aufräumen aus. Gibt 0 (ok) oder 1 (Anmeldung/Verbindung fehlgeschlagen) zurück."""
    prov, user, pw = env["CL_PROV"], env["CL_USER"], env["CL_PASS"]
    host = env.get("CL_HOST") or HOSTS[prov]
    maildir = env.get("CL_MAILDIR", "/mail")
    dry = env.get("CL_DRY") == "1"
    flag = lambda k: env.get(k) == "1"  # noqa: E731
    num = lambda k: int(env.get(k, "0") or 0)  # noqa: E731
    do_inbox, do_spam, do_trash, do_sent = flag("CL_INBOX"), flag("CL_SPAM"), flag("CL_TRASH"), flag("CL_SENT") and prov == "gmail"
    days, sent_days = num("CL_DAYS"), num("CL_SENT_DAYS")
    tag = " (Probelauf, es wird nichts gelöscht)" if dry else ""

    ids, nlocal = local_ids(maildir)
    if nlocal == 0:
        out("    übersprungen: lokal liegen noch keine Mails (erst den Import prüfen)")
        return 0

    try:
        M = (connect or (lambda h: imaplib.IMAP4_SSL(h)))(host)
        M.login(user, pw)
    except Exception as e:  # noqa: BLE001
        out("    Anmeldung fehlgeschlagen: %s" % e)
        return 1

    box = list_boxes(M)
    gm = prov == "gmail"

    # 1) Posteingang: nur, was lokal nachweislich vorhanden ist
    if do_inbox:
        if not select(M, "INBOX"):
            out("    INBOX: nicht lesbar")
        else:
            uids = search(M, days)
            hdr = header_ids(M, uids)
            safe = [u for u in uids if hdr.get(u) and hdr[u] in ids]
            kept = len(uids) - len(safe)
            if gm and safe and "Trash" not in box:
                out("    INBOX: Papierkorb-Ordner nicht gefunden, Posteingang übersprungen")
            elif safe and not dry:
                ok = True
                if gm:  # Gmail: erst in den Papierkorb, sonst wird nur das Label entfernt
                    for ch in chunks(safe):
                        if M.uid("COPY", ch, '"%s"' % box["Trash"])[0] != "OK":
                            ok = False
                            out("    INBOX: Verschieben in den Papierkorb fehlgeschlagen, Abbruch")
                            break
                if ok:
                    remove(M, safe)
            out("    INBOX: %d lokal gesicherte Nachrichten %s, %d bleiben (lokal nicht gefunden)%s" % (
                len(safe), "würden gelöscht" if dry else ("in den Papierkorb verschoben" if gm else "gelöscht"), kept, tag))
            M.close()

    # 2) Gmail: "Gesendet" in den Papierkorb
    if do_sent:
        if "Sent" not in box or "Trash" not in box:
            out("    Gesendet- oder Papierkorb-Ordner nicht gefunden, übersprungen")
        elif select(M, box["Sent"]):
            uids = search(M, sent_days)
            if uids and not dry:
                for ch in chunks(uids):
                    if M.uid("COPY", ch, '"%s"' % box["Trash"])[0] != "OK":
                        out("    Verschieben in den Papierkorb fehlgeschlagen, Abbruch")
                        uids = []
                        break
                    M.uid("STORE", ch, "+FLAGS", "(\\Deleted)")
                if uids:
                    M.expunge()
            out("    %s: %d Nachrichten %s%s" % (box["Sent"], len(uids), "würden verschoben" if dry else "in den Papierkorb verschoben", tag))
            M.close()
        else:
            out("    %s: nicht lesbar" % box["Sent"])

    # 3) Spam und Papierkorb leeren
    targets = []
    if do_spam:
        targets.append(("Spam", box.get("Junk")))
    if do_trash:
        targets.append(("Papierkorb", box.get("Trash")))
    for label, name in targets:
        if not name:
            out("    kein %s-Ordner gefunden" % label)
            continue
        if not select(M, name):
            out("    %s: nicht lesbar" % name)
            continue
        uids = search(M, days)
        if uids and not dry:
            remove(M, uids)
        out("    %s: %d Nachrichten %s%s" % (name, len(uids), "würden gelöscht" if dry else "endgültig gelöscht", tag))
        M.close()

    M.logout()
    return 0


if __name__ == "__main__":
    sys.exit(run(dict(os.environ)))
