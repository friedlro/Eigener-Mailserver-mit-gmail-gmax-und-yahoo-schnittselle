#!/usr/bin/env python3
"""Testet upload_to_provider.py gegen einen nachgebauten IMAP-Server (keine Verbindung ins Internet)."""
import os
import shutil
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
import upload_to_provider as up  # noqa: E402

fails = 0


def check(name, ok):
    global fails
    print(("  ok    " if ok else "  FEHLER ") + name)
    fails += 0 if ok else 1


class FakeIMAP:
    """Minimaler IMAP-Server: Ordner -> Liste von Nachrichten (uid, Rohdaten, Flags, Datum)."""

    def __init__(self, folders=None, listing=None, bad_login=False, fail_append=None):
        self.f = {k: [dict(uid=i + 1, raw=r, flags=None, date=None) for i, r in enumerate(v)] for k, v in (folders or {}).items()}
        self.listing = listing or ['(\\HasNoChildren) "/" "INBOX"']
        self.bad_login = bad_login
        self.fail_append = fail_append
        self.cur = None
        self.created = []
        self.appended = []

    def login(self, u, p):
        if self.bad_login:
            raise OSError("AUTHENTICATIONFAILED")

    def list(self):
        return "OK", [x.encode() for x in self.listing]

    def select(self, name, readonly=False):
        name = name.strip('"')
        if name not in self.f:
            return "NO", []
        self.cur = name
        return "OK", [b"1"]

    def close(self):
        return "OK", []

    def logout(self):
        return "BYE", []

    def create(self, name):
        name = name.strip('"')
        self.created.append(name)
        if name in self.f:
            return "NO", [b"exists"]
        self.f[name] = []
        return "OK", []

    def uid(self, cmd, *a):
        cmd = cmd.upper()
        if cmd == "SEARCH":
            return "OK", [b" ".join(str(m["uid"]).encode() for m in self.f[self.cur])]
        if cmd == "FETCH":
            want = set(int(x) for x in a[0].decode().split(","))
            out = []
            for m in self.f[self.cur]:
                if m["uid"] in want:
                    hdr = up.MID_RE.search(m["raw"])
                    body = (b"Message-ID: " + hdr.group(1) + b"\r\n\r\n") if hdr else b"\r\n"
                    out.append((b"1 (UID %d BODY[HEADER.FIELDS (MESSAGE-ID)] {%d}" % (m["uid"], len(body)), body))
                    out.append(b")")
            return "OK", out
        raise AssertionError("unbekannt: " + cmd)

    def append(self, box, flags, date, data):
        box = box.strip('"')
        if self.fail_append and self.fail_append in data:
            return "NO", [b"nope"]
        self.appended.append((box, flags, date, data))
        self.f.setdefault(box, []).append(dict(uid=len(self.f.get(box, [])) + 1, raw=data, flags=flags, date=date))
        if "[Gmail]/Alle Nachrichten" in self.f and box != "[Gmail]/Alle Nachrichten":   # wie bei Gmail: jedes Label zeigt auch in "Alle Nachrichten"
            self.f["[Gmail]/Alle Nachrichten"].append(dict(uid=len(self.f["[Gmail]/Alle Nachrichten"]) + 1, raw=data, flags=flags, date=date))
        return "OK", []


def mail(root, folder, sub, name, mid, body="Text", date="Mon, 05 Jan 2026 10:00:00 +0000"):
    d = os.path.join(root, folder, sub) if folder != "." else os.path.join(root, sub)
    os.makedirs(d, exist_ok=True)
    head = "Message-ID: %s\n" % mid if mid else ""
    with open(os.path.join(d, name), "w") as f:
        f.write("%sDate: %s\nSubject: x\n\n%s\n" % (head, date, body))


def go(e, srv):
    lines = []
    rc = up.run(e, connect=lambda h: srv, out=lines.append)
    return rc, lines


def env(md, **kw):
    e = {"UP_PROV": "gmail", "UP_USER": "u", "UP_PASS": "p", "UP_MAILDIR": md}
    e.update(kw)
    return e


GMAIL = ['(\\HasNoChildren) "/" "INBOX"', '(\\HasNoChildren \\All) "/" "[Gmail]/Alle Nachrichten"',
         '(\\HasNoChildren \\Trash) "/" "[Gmail]/Papierkorb"']
tmp = tempfile.mkdtemp()
try:
    md = os.path.join(tmp, "mail")
    mail(md, ".", "cur", "1:2,S", "<a@x>")             # gelesen, schon bei Gmail
    mail(md, ".", "cur", "2:2,SR", "<b@x>")            # gelesen + beantwortet, neu
    mail(md, ".", "new", "3", "<c@x>")                 # ungelesen, neu
    mail(md, ".Archiv", "cur", "4:2,SF", "<d@x>")      # Unterordner, markiert, neu
    mail(md, ".Archiv.2024", "cur", "5:2,S", "<e@x>")  # verschachtelter Ordner
    mail(md, ".[Gmail].Alle Nachrichten", "cur", "6:2,S", "<f@x>")   # Gmail-Ordner mit Klammern
    mail(md, ".Trash", "cur", "7:2,S", "<trash@x>")    # wird nicht hochgeladen
    mail(md, ".Junk", "cur", "8:2,S", "<junk@x>")      # wird nicht hochgeladen
    mail(md, ".Drafts", "cur", "9:2,S", "<draft@x>")   # wird nicht hochgeladen
    mail(md, ".", "cur", "10:2,S", None, "ohne Message-ID")   # Prüfsumme
    mail(md, ".", "cur", "99:2,S", "<B@X>", "andere Schreibweise")  # gleiche ID wie b

    srv = FakeIMAP({"[Gmail]/Alle Nachrichten": [b"Message-ID: <a@x>\r\n\r\nx"]}, GMAIL)
    rc, out = go(env(md, UP_DRY="1"), srv)
    check("Probelauf: nichts wird hochgeladen oder angelegt", rc == 0 and not srv.appended and not srv.created)
    check("Probelauf: Zahlen stimmen (6 neue, 2 vorhanden, Papierkorb/Spam/Entwürfe nicht gezählt)",
          any("8 lokale Mails geprüft, 2 beim Anbieter schon vorhanden, 6 würden hochgeladen" in l for l in out))

    srv = FakeIMAP({"[Gmail]/Alle Nachrichten": [b"Message-ID: <a@x>\r\n\r\nx"]}, GMAIL)
    rc, out = go(env(md), srv)
    boxes = {b for b, _f, _d, _x in srv.appended}
    check("Hochladen: Ordner unter dem Label Vom-Server (nicht im Posteingang)",
          boxes == {"Vom-Server/Posteingang", "Vom-Server/Archiv", "Vom-Server/Archiv/2024", "Vom-Server/Gmail/Alle Nachrichten"})
    check("Hochladen: Papierkorb, Spam und Entwürfe bleiben lokal", not any(b"trash@x" in x or b"junk@x" in x or b"draft@x" in x for _b, _f, _d, x in srv.appended))
    check("Hochladen: schon vorhandene Mail (gleiche Message-ID) wird übersprungen", not any(b"<a@x>" in x for _b, _f, _d, x in srv.appended))
    check("Hochladen: gleiche ID in anderer Schreibweise nur einmal", sum(1 for _b, _f, _d, x in srv.appended if b"@x>" in x.lower() and b"<b@x>" in x.lower()) == 1)
    fl = {up.MID_RE.search(x).group(1).lower(): f for _b, f, _d, x in srv.appended if up.MID_RE.search(x)}
    check("Flags: gelesen+beantwortet bleiben, ungelesene Mail ohne \\Seen, markiert bleibt",
          fl[b"<b@x>"] == "(\\Seen \\Answered)" and fl[b"<c@x>"] is None and fl[b"<d@x>"] == "(\\Seen \\Flagged)")
    check("Datum: Originaldatum aus der Kopfzeile", all(d is not None and d.year == 2026 and d.month == 1 and d.day == 5 for _b, _f, d, _x in srv.appended))
    check("Hochladen: Mail ohne Message-ID wird übernommen", any(b"ohne Message-ID" in x for _b, _f, _d, x in srv.appended))
    check("Hochladen: Quelle bleibt unverändert", sum(1 for _ in up.local_messages(md, set())) == 11)

    n = len(srv.appended)
    rc, out = go(env(md), srv)
    check("Zweiter Lauf: nichts doppelt", len(srv.appended) == n and any("0 hochgeladen" in l for l in out))

    srv = FakeIMAP({"[Gmail]/Alle Nachrichten": []}, GMAIL)
    rc, out = go(env(md, UP_LIMIT="2"), srv)
    check("Limit: nach 2 Mails ist Schluss, mit Hinweis", len(srv.appended) == 2 and any("Limit von 2" in l for l in out))

    srv = FakeIMAP({"[Gmail]/Alle Nachrichten": []}, GMAIL)
    rc, out = go(env(md, UP_LABEL="Mein Label"), srv)
    check("Eigenes Label", all(b.startswith("Mein Label/") for b, _f, _d, _x in srv.appended))

    srv = FakeIMAP({"[Gmail]/Alle Nachrichten": []}, GMAIL, fail_append=b"<c@x>")
    rc, out = go(env(md), srv)
    check("Einzelne Mail abgelehnt: Rest läuft weiter, Exit-Code 2, Meldung", rc == 2 and len(srv.appended) == 6 and not any(b"<c@x>" in x for _b, _f, _d, x in srv.appended) and any("fehlgeschlagen" in l for l in out))

    rc, out = go(env(md), FakeIMAP(bad_login=True))
    check("Anmeldung fehlgeschlagen: Exit-Code 1", rc == 1 and any("Anmeldung fehlgeschlagen" in l for l in out))

    # GMX: kein "Alle Nachrichten", Abgleich nur im Zielordner
    gmx = FakeIMAP({"Vom-Server/Posteingang": [b"Message-ID: <b@x>\r\n\r\nx"]}, ['(\\HasNoChildren) "/" "INBOX"'])
    rc, out = go(env(md, UP_PROV="gmx"), gmx)
    check("GMX: Abgleich im Zielordner, vorhandene Mail wird nicht doppelt abgelegt",
          not any(b"<b@x>" in x.lower() for b, _f, _d, x in gmx.appended if b == "Vom-Server/Posteingang"))

    empty = os.path.join(tmp, "leer")
    os.makedirs(os.path.join(empty, "cur"))
    srv = FakeIMAP({}, GMAIL)
    rc, out = go(env(empty), srv)
    check("Keine lokalen Mails: übersprungen, keine Verbindung nötig", rc == 0 and any("übersprungen" in l for l in out) and not srv.created)
finally:
    shutil.rmtree(tmp, ignore_errors=True)

print("\n== upload_to_provider: %s" % ("alles ok" if not fails else "%d Fehler" % fails))
sys.exit(1 if fails else 0)
