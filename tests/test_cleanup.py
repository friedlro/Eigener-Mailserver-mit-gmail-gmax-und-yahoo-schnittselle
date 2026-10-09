#!/usr/bin/env python3
"""Testet cleanup.py gegen einen nachgebauten IMAP-Server (keine Verbindung ins Internet)."""
import datetime
import os
import re
import shutil
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
import cleanup  # noqa: E402

fails = 0


def check(name, ok):
    global fails
    print(("  ok    " if ok else "  FEHLER ") + name)
    fails += 0 if ok else 1


def day(n):
    return datetime.date.today() - datetime.timedelta(days=n)


class FakeIMAP:
    """Minimaler IMAP-Server: Ordner mit Nachrichten (uid, mid, date, deleted)."""

    def __init__(self, folders, listing, fail_copy=False, bad_login=False):
        self.f = folders
        self.listing = listing
        self.fail_copy = fail_copy
        self.bad_login = bad_login
        self.cur = None
        self.next_uid = 1000
        self.log = []

    def login(self, u, p):
        if self.bad_login:
            raise OSError("AUTHENTICATIONFAILED")

    def list(self):
        return "OK", [x.encode() for x in self.listing]

    def select(self, name):
        name = name.strip('"')
        if name not in self.f:
            return "NO", []
        self.cur = name
        return "OK", [b"1"]

    def close(self):
        self.cur = None
        return "OK", []

    def logout(self):
        return "BYE", []

    def _sel(self, spec):
        want = set(int(x) for x in spec.decode().split(","))
        return [m for m in self.f[self.cur] if m["uid"] in want]

    def uid(self, cmd, *a):
        cmd = cmd.upper()
        if cmd == "SEARCH":
            msgs = self.f[self.cur]
            if a[1] == "BEFORE":
                lim = datetime.datetime.strptime(a[2], "%d-%b-%Y").date()
                msgs = [m for m in msgs if m["date"] < lim]
            return "OK", [b" ".join(str(m["uid"]).encode() for m in msgs)]
        if cmd == "FETCH":
            out = []
            for m in self._sel(a[0]):
                body = (b"Message-ID: " + m["mid"].encode() + b"\r\n\r\n") if m["mid"] else b"\r\n"
                out.append((b"1 (UID %d BODY[HEADER.FIELDS (MESSAGE-ID)] {%d}" % (m["uid"], len(body)), body))
                out.append(b")")
            return "OK", out
        if cmd == "STORE":
            self.log.append(("store", self.cur))
            for m in self._sel(a[0]):
                m["deleted"] = True
            return "OK", []
        if cmd == "COPY":
            if self.fail_copy:
                return "NO", []
            dest = a[1].strip('"')
            self.log.append(("copy", self.cur, dest))
            for m in self._sel(a[0]):
                self.next_uid += 1
                self.f[dest].append(dict(m, uid=self.next_uid, deleted=False))
            return "OK", []
        raise AssertionError("unbekannt: " + cmd)

    def expunge(self):
        self.f[self.cur] = [m for m in self.f[self.cur] if not m["deleted"]]
        return "OK", []


def msg(uid, mid, date=None):
    return {"uid": uid, "mid": mid, "date": date or day(1), "deleted": False}


GMAIL_LIST = ['(\\HasNoChildren) "/" "INBOX"', '(\\HasNoChildren \\Sent) "/" "[Gmail]/Gesendet"',
              '(\\HasNoChildren \\Trash) "/" "[Gmail]/Papierkorb"', '(\\HasNoChildren \\Junk) "/" "[Gmail]/Spam"']


def maildir(ids, extra_files=0):
    d = tempfile.mkdtemp()
    os.makedirs(os.path.join(d, "cur"))
    os.makedirs(os.path.join(d, ".Archiv", "cur"))
    for i, mid in enumerate(ids):
        p = os.path.join(d, "cur" if i % 2 == 0 else ".Archiv/cur", "m%d" % i)
        with open(p, "w") as f:
            f.write("From: x\nMessage-ID:\n %s\nSubject: s\n\nText\n" % mid if i == 0 else "From: x\nMessage-Id: %s\n\nText\n" % mid)
    return d


def env(prov, md, **kw):
    e = {"CL_PROV": prov, "CL_USER": "u", "CL_PASS": "p", "CL_MAILDIR": md, "CL_DAYS": "0"}
    e.update({k: v for k, v in kw.items()})
    return e


def go(e, srv, out=None):
    lines = []
    rc = cleanup.run(e, connect=lambda h: srv, out=lines.append)
    return rc, lines


# --- 1. Gmail: Posteingang nur mit lokalem Nachweis, über den Papierkorb
md = maildir(["<a@x>", "<c@x>"])
srv = FakeIMAP({"INBOX": [msg(1, "<A@x>"), msg(2, "<b@x>"), msg(3, None), msg(4, "<c@x>")],
                "[Gmail]/Papierkorb": [], "[Gmail]/Spam": [], "[Gmail]/Gesendet": []}, GMAIL_LIST)
rc, _ = go(env("gmail", md, CL_INBOX="1"), srv)
left = sorted(m["mid"] or "-" for m in srv.f["INBOX"])
check("Gmail Posteingang: nur lokal vorhandene Mails werden entfernt", rc == 0 and left == ["-", "<b@x>"])
check("Gmail Posteingang: Message-ID-Vergleich ohne Beachtung der Groß-/Kleinschreibung", len(srv.f["[Gmail]/Papierkorb"]) == 2)
check("Gmail Posteingang: erst in den Papierkorb kopiert, dann entfernt", srv.log.index(("copy", "INBOX", "[Gmail]/Papierkorb")) < srv.log.index(("store", "INBOX")))
check("Gmail Posteingang: Mails ohne Message-ID bleiben", any(m["mid"] is None for m in srv.f["INBOX"]))

# --- 2. Probelauf verändert nichts
srv = FakeIMAP({"INBOX": [msg(1, "<a@x>")], "[Gmail]/Papierkorb": [msg(5, "<t@x>")], "[Gmail]/Spam": [msg(6, "<s@x>")],
                "[Gmail]/Gesendet": [msg(7, "<g@x>")]}, GMAIL_LIST)
rc, lines = go(env("gmail", md, CL_INBOX="1", CL_SPAM="1", CL_TRASH="1", CL_SENT="1", CL_DRY="1"), srv)
check("Probelauf: nichts wird verändert", rc == 0 and not srv.log and len(srv.f["INBOX"]) == 1 and len(srv.f["[Gmail]/Papierkorb"]) == 1 and len(srv.f["[Gmail]/Spam"]) == 1)
check("Probelauf: Ausgabe nennt es", any("Probelauf" in l for l in lines))

# --- 3. Gmail: Posteingang + Papierkorb + Spam: nach dem Verschieben endgültig weg
srv = FakeIMAP({"INBOX": [msg(1, "<a@x>")], "[Gmail]/Papierkorb": [msg(5, "<t@x>")], "[Gmail]/Spam": [msg(6, "<s@x>")],
                "[Gmail]/Gesendet": []}, GMAIL_LIST)
rc, _ = go(env("gmail", md, CL_INBOX="1", CL_SPAM="1", CL_TRASH="1"), srv)
check("Gmail: Posteingang, Spam und Papierkorb sind danach leer", rc == 0 and not srv.f["INBOX"] and not srv.f["[Gmail]/Spam"] and not srv.f["[Gmail]/Papierkorb"])

# --- 4. Fehlgeschlagenes Verschieben: Posteingang bleibt unberührt
srv = FakeIMAP({"INBOX": [msg(1, "<a@x>")], "[Gmail]/Papierkorb": [], "[Gmail]/Spam": [], "[Gmail]/Gesendet": []}, GMAIL_LIST, fail_copy=True)
rc, _ = go(env("gmail", md, CL_INBOX="1"), srv)
check("Verschieben fehlgeschlagen: nichts wird gelöscht", len(srv.f["INBOX"]) == 1 and ("store", "INBOX") not in srv.log)

# --- 5. GMX: Ordner ohne Kennzeichen (nur Namen), Posteingang bleibt, wenn nicht gewählt
GMX_LIST = ['(\\HasNoChildren) "/" "INBOX"', '(\\HasNoChildren) "/" "Papierkorb"', '(\\HasNoChildren) "/" "Spam"', '(\\HasNoChildren) "/" "Entwürfe"']
srv = FakeIMAP({"INBOX": [msg(1, "<a@x>")], "Papierkorb": [msg(2, "<t@x>"), msg(3, None)], "Spam": [msg(4, "<s@x>")], "Entwürfe": [msg(5, "<d@x>")]}, GMX_LIST)
rc, _ = go(env("gmx", md, CL_SPAM="1", CL_TRASH="1"), srv)
check("GMX: Papierkorb und Spam werden anhand der Namen geleert", not srv.f["Papierkorb"] and not srv.f["Spam"])
check("GMX: Posteingang und andere Ordner bleiben", len(srv.f["INBOX"]) == 1 and len(srv.f["Entwürfe"]) == 1)

# --- 6. GMX: Posteingang wird direkt gelöscht (nur lokal Vorhandenes)
srv = FakeIMAP({"INBOX": [msg(1, "<a@x>"), msg(2, "<fremd@x>")], "Papierkorb": [], "Spam": []}, GMX_LIST)
rc, _ = go(env("gmx", md, CL_INBOX="1"), srv)
check("GMX Posteingang: lokal gesicherte Mail gelöscht, andere bleibt", [m["mid"] for m in srv.f["INBOX"]] == ["<fremd@x>"] and not any(x[0] == "copy" for x in srv.log))

# --- 7. Yahoo: Bulk Mail als Spam erkannt
Y_LIST = ['(\\HasNoChildren) "/" "Inbox"', '(\\HasNoChildren) "/" "Bulk Mail"', '(\\HasNoChildren) "/" "Trash"']
srv = FakeIMAP({"Bulk Mail": [msg(1, "<s@x>")], "Trash": [msg(2, "<t@x>")]}, Y_LIST)
rc, _ = go(env("yahoo", md, CL_SPAM="1", CL_TRASH="1"), srv)
check("Yahoo: Bulk Mail und Trash werden geleert", not srv.f["Bulk Mail"] and not srv.f["Trash"])

# --- 8. Altersgrenze
srv = FakeIMAP({"INBOX": [], "Papierkorb": [msg(1, "<alt@x>", day(40)), msg(2, "<neu@x>", day(3))], "Spam": []}, GMX_LIST)
rc, _ = go(env("gmx", md, CL_TRASH="1", CL_DAYS="30"), srv)
check("Altersgrenze: nur Mails älter als 30 Tage werden gelöscht", [m["mid"] for m in srv.f["Papierkorb"]] == ["<neu@x>"])

# --- 9. Gmail: Gesendet in den Papierkorb
srv = FakeIMAP({"INBOX": [], "[Gmail]/Papierkorb": [], "[Gmail]/Spam": [], "[Gmail]/Gesendet": [msg(1, "<g@x>")]}, GMAIL_LIST)
rc, _ = go(env("gmail", md, CL_SENT="1"), srv)
check("Gmail Gesendet: in den Papierkorb verschoben", not srv.f["[Gmail]/Gesendet"] and len(srv.f["[Gmail]/Papierkorb"]) == 1)
srv = FakeIMAP({"INBOX": [], "Papierkorb": [], "Spam": []}, GMX_LIST)
rc, _ = go(env("gmx", md, CL_SENT="1"), srv)
check("'Gesendet' wird nur bei Gmail bereinigt", not srv.log)

# --- 10. Schutz: keine lokalen Mails -> keine Verbindung, keine Löschung
empty = tempfile.mkdtemp()
os.makedirs(os.path.join(empty, "cur"))
called = []
rc = cleanup.run(env("gmx", empty, CL_INBOX="1", CL_TRASH="1", CL_SPAM="1"), connect=lambda h: called.append(h), out=lambda s: called.append(s))
check("ohne lokale Mails wird nichts angefasst", rc == 0 and len(called) == 1 and "übersprungen" in called[0])

# --- 11. Anmeldung schlägt fehl
srv = FakeIMAP({"INBOX": []}, GMX_LIST, bad_login=True)
rc, lines = go(env("gmx", md, CL_TRASH="1"), srv)
check("Anmeldefehler: Rückgabe 1 und Meldung", rc == 1 and any("Anmeldung fehlgeschlagen" in l for l in lines))

# --- 12. Ordner nicht gefunden
srv = FakeIMAP({"INBOX": [msg(1, "<a@x>")]}, ['(\\HasNoChildren) "/" "INBOX"'])
rc, lines = go(env("gmx", md, CL_TRASH="1", CL_SPAM="1"), srv)
check("Fehlende Spam-/Papierkorb-Ordner werden gemeldet, nichts sonst gelöscht", len(srv.f["INBOX"]) == 1 and sum("gefunden" in l for l in lines) == 2)

# --- 13. lokale Message-IDs: gefaltete Kopfzeile und Unterordner
ids, n = cleanup.local_ids(md)
check("lokale Message-IDs: gefaltete Zeile und Unterordner werden gelesen", n == 2 and ids == {b"<a@x>", b"<c@x>"})

for d in (md, empty):
    shutil.rmtree(d, ignore_errors=True)
sys.exit(1 if fails else 0)
