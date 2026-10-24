#!/usr/bin/env python3
"""merge_mailboxes.py - bringt Mails aus einem zur Seite gelegten Postfach (z. B. data/alt-mailboxen/<alte-domain>/<name>)
in das passende aktuelle Postfach (data/mail-data/<DOMAIN>/<name>) zurück.

  sudo python3 merge_mailboxes.py               Probelauf: zeigt nur, was kopiert würde (ändert nichts)
  sudo python3 merge_mailboxes.py --apply       kopiert die fehlenden Mails

Schutzregeln:
  * Es wird nur KOPIERT. Die Quelle wird nie verändert oder gelöscht.
  * Eine Mail wird übernommen, wenn ihre Message-ID im Zielpostfach noch nicht vorkommt (ohne Message-ID: Prüfsumme des Inhalts).
    Dadurch entstehen keine Doppelten, auch nicht bei wiederholtem Aufruf.
  * Das Zielpostfach muss schon existieren (das Konto muss angelegt sein). Eigentümer und Rechte werden vom Zielordner übernommen.
  * Danach wird der Dovecot-Index des Kontos neu aufgebaut (doveadm force-resync), außer mit --no-resync.

Optionen: --from DIR (Standard data/alt-mailboxen)  --target DIR (Standard data/mail-data)  --domain NAME (Standard: DOMAIN aus accounts.conf)
          --user NAME (nur dieses Postfach)  --apply  --no-resync
"""
import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys

MID_RE = re.compile(rb"(?im)^message-id:\s*(<[^>\s]+>)")


def read_domain(conf):
    dom = ""
    try:
        with open(conf, encoding="utf-8") as f:
            for line in f:
                m = re.match(r"^\s*DOMAIN=(\S*)\s*$", line)
                if m:
                    dom = m.group(1)
    except OSError:
        pass
    return dom


def msg_key(path):
    """Message-ID (klein) oder 'sha:<Prüfsumme>' für Mails ohne Message-ID. None, wenn nicht lesbar."""
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError:
        return None
    end = min([p for p in (data.find(b"\n\n"), data.find(b"\r\n\r\n")) if p >= 0] or [len(data)])
    m = MID_RE.search(data[:end + 1])
    if m:
        return m.group(1).lower().decode("ascii", "replace")
    return "sha:" + hashlib.sha256(data).hexdigest()


def messages(mailbox):
    """Liefert (Ordner, Unterordner cur/new, Pfad) für alle Mails eines Maildir-Postfachs. Ordner '.' = Posteingang."""
    for root, _dirs, files in os.walk(mailbox):
        sub = os.path.basename(root)
        if sub not in ("cur", "new"):
            continue
        folder = os.path.relpath(os.path.dirname(root), mailbox)
        for name in sorted(files):
            yield folder, sub, os.path.join(root, name)


def unique_name(directory, name):
    if not os.path.exists(os.path.join(directory, name)):
        return name
    n = 1
    while os.path.exists(os.path.join(directory, "%s.merge%d" % (name, n))):
        n += 1
    return "%s.merge%d" % (name, n)


def merge_one(src, dst, apply, out=print):
    """Gibt (gesamt, schon_vorhanden, kopiert, nicht_lesbar) zurück."""
    have = set()
    for _f, _s, p in messages(dst):
        k = msg_key(p)
        if k:
            have.add(k)
    st = os.stat(dst)
    total = present = copied = bad = 0
    for folder, sub, path in messages(src):
        total += 1
        k = msg_key(path)
        if k is None:
            bad += 1
            continue
        if k in have:
            present += 1
            continue
        have.add(k)
        copied += 1
        if not apply:
            continue
        tdir = os.path.join(dst, folder, sub)
        if not os.path.isdir(tdir):
            for part in ("cur", "new", "tmp"):
                d = os.path.join(dst, folder, part)
                os.makedirs(d, exist_ok=True)
                os.chown(d, st.st_uid, st.st_gid)
                os.chmod(d, 0o700)
            if folder != ".":
                os.chown(os.path.join(dst, folder), st.st_uid, st.st_gid)
        target = os.path.join(tdir, unique_name(tdir, os.path.basename(path)))
        shutil.copy2(path, target)
        os.chown(target, st.st_uid, st.st_gid)
    return total, present, copied, bad


def main(argv=None, out=print):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    base = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument("--from", dest="src", default=os.path.join(base, "data", "alt-mailboxen"))
    ap.add_argument("--target", default=os.path.join(base, "data", "mail-data"))
    ap.add_argument("--domain", default=None)
    ap.add_argument("--user", default=None)
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--no-resync", action="store_true")
    a = ap.parse_args(argv)

    domain = a.domain or read_domain(os.path.join(base, "accounts.conf"))
    if not domain:
        out("Fehler: Maildomain unbekannt (DOMAIN in accounts.conf fehlt, oder --domain angeben).")
        return 1
    if not os.path.isdir(a.src):
        out("Fehler: Quellordner fehlt: %s" % a.src)
        return 1
    srcs = []
    for d in sorted(os.listdir(a.src)):
        for u in sorted(os.listdir(os.path.join(a.src, d))) if os.path.isdir(os.path.join(a.src, d)) else []:
            if os.path.isdir(os.path.join(a.src, d, u)) and (not a.user or a.user == u):
                srcs.append((d, u))
    if not srcs:
        out("Nichts zu tun: keine Postfächer unter %s" % a.src)
        return 0

    out("%s: Quelle %s -> Ziel %s/%s" % ("ÜBERNAHME" if a.apply else "PROBELAUF (es wird nichts geändert)", a.src, a.target, domain))
    rc = 0
    for d, u in srcs:
        src = os.path.join(a.src, d, u)
        dst = os.path.join(a.target, domain, u)
        if os.path.realpath(src) == os.path.realpath(dst):
            out("  %s/%s: Quelle und Ziel sind gleich, übersprungen" % (d, u))
            continue
        if not os.path.isdir(dst):
            out("  %s/%s: Zielpostfach %s fehlt (Konto %s@%s existiert nicht), übersprungen" % (d, u, dst, u, domain))
            rc = 1
            continue
        total, present, copied, bad = merge_one(src, dst, a.apply)
        out("  %s/%s -> %s@%s: %d Mails in der Quelle, %d schon vorhanden, %d %s%s" % (
            d, u, u, domain, total, present, copied, "kopiert" if a.apply else "würden kopiert",
            ", %d nicht lesbar" % bad if bad else ""))
        if a.apply and copied and not a.no_resync:
            r = subprocess.run(["docker", "exec", "mailserver", "doveadm", "force-resync", "-u", "%s@%s" % (u, domain), "*"],
                               capture_output=True, text=True)
            out("    Index neu aufgebaut" if r.returncode == 0 else "    Hinweis: Index-Neuaufbau fehlgeschlagen (%s). Von Hand: docker exec mailserver doveadm force-resync -u %s@%s '*'" % (
                (r.stderr or r.stdout).strip()[:120], u, domain))
    if not a.apply:
        out("Zum Übernehmen: sudo python3 merge_mailboxes.py --apply")
    else:
        out("Die Quelle blieb unverändert. Nach Kontrolle in Roundcube kann sie manuell gelöscht werden.")
    return rc


if __name__ == "__main__":
    sys.exit(main())
