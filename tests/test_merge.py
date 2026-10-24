#!/usr/bin/env python3
"""Testet merge_mailboxes.py mit nachgebauten Maildir-Postfächern (kein Docker nötig)."""
import os
import shutil
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
import merge_mailboxes as mm  # noqa: E402

fails = 0


def check(name, ok):
    global fails
    print(("  ok    " if ok else "  FEHLER ") + name)
    fails += 0 if ok else 1


def mail(box, folder, sub, name, mid, body="Text"):
    d = os.path.join(box, folder, sub)
    os.makedirs(d, exist_ok=True)
    head = "Message-ID: %s\n" % mid if mid else ""
    with open(os.path.join(d, name), "w") as f:
        f.write(head + "Subject: x\n\n" + body + "\n")


def count(box):
    return sum(1 for _ in mm.messages(box))


tmp = tempfile.mkdtemp()
try:
    src = os.path.join(tmp, "alt", "alt.example.at", "anna")
    dst = os.path.join(tmp, "mail-data", "neu.example.at", "anna")
    os.makedirs(os.path.join(dst, "cur"))
    mail(dst, ".", "cur", "1:2,S", "<a@x>")
    mail(dst, ".", "cur", "2:2,S", "<b@x>")
    mail(src, ".", "cur", "1:2,S", "<a@x>")          # schon vorhanden
    mail(src, ".", "cur", "9:2,S", "<c@x>")          # neu
    mail(src, ".", "new", "10", "<d@x>")             # neu, ungelesen
    mail(src, ".Archiv", "cur", "11:2,S", "<e@x>")   # neu, Unterordner fehlt im Ziel
    mail(src, ".", "cur", "12:2,S", None, "ohne ID")  # ohne Message-ID
    mail(src, ".", "cur", "13:2,S", "<C@X>")         # gleiche ID wie c, andere Schreibweise
    out = []
    args = ["--from", os.path.join(tmp, "alt"), "--target", os.path.join(tmp, "mail-data"), "--domain", "neu.example.at", "--no-resync"]

    rc = mm.main(args, out=out.append)
    text = "\n".join(out)
    check("Probelauf: nichts wird kopiert", count(dst) == 2 and rc == 0)
    check("Probelauf: 6 Mails in der Quelle, 2 schon vorhanden, 4 würden kopiert (gleiche ID in anderer Schreibweise zählt einmal)", "6 Mails in der Quelle, 2 schon vorhanden, 4 würden kopiert" in text)

    out.clear()
    rc = mm.main(args + ["--apply"], out=out.append)
    check("Übernahme: fehlende Mails sind da (2 + 4)", count(dst) == 6)
    check("Übernahme: Unterordner wurde mit cur/new/tmp angelegt", all(os.path.isdir(os.path.join(dst, ".Archiv", d)) for d in ("cur", "new", "tmp")))
    check("Übernahme: ungelesene Mail bleibt in new/", os.path.exists(os.path.join(dst, "new", "10")))
    check("Übernahme: Mail ohne Message-ID wird übernommen", os.path.exists(os.path.join(dst, "cur", "12:2,S")))
    check("Übernahme: Quelle bleibt vollständig unverändert", count(src) == 6)
    check("Übernahme: Meldung nennt die kopierten Mails", any("4 kopiert" in l for l in out))

    out.clear()
    mm.main(args + ["--apply"], out=out.append)
    check("Zweiter Lauf: keine Doppelten", count(dst) == 6 and any("0 kopiert" in l for l in out))

    mail(src, ".", "cur", "1:2,S", "<neu@x>")          # gleicher Dateiname, andere Mail
    mm.main(args + ["--apply"], out=out.append)
    check("Gleicher Dateiname, andere Mail: nichts wird überschrieben", count(dst) == 7 and open(os.path.join(dst, "cur", "1:2,S")).read().startswith("Message-ID: <a@x>"))

    out.clear()
    rc = mm.main(["--from", os.path.join(tmp, "alt"), "--target", os.path.join(tmp, "mail-data"), "--domain", "andere.example.at", "--no-resync", "--apply"], out=out.append)
    check("Zielpostfach fehlt: übersprungen, nichts angelegt", rc == 1 and not os.path.exists(os.path.join(tmp, "mail-data", "andere.example.at")))
finally:
    shutil.rmtree(tmp, ignore_errors=True)

print("\n== merge_mailboxes: %s" % ("alles ok" if not fails else "%d Fehler" % fails))
sys.exit(1 if fails else 0)
