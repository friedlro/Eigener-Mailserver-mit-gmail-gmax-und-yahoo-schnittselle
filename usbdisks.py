#!/usr/bin/env python3
"""usbdisks.py - findet USB-Datenträger, die sich als Backup-Ziel eignen (nur Standardbibliothek).

  python3 usbdisks.py list           JSON-Liste der geeigneten Partitionen/Datenträger
  python3 usbdisks.py check /dev/sdb1   prüft ein Gerät und gibt key=value-Zeilen aus (Exit 1 + Grund, wenn ungeeignet)

Nie angeboten werden: Datenträger, auf denen das System läuft (/, /boot, /home, /var, /usr, Swap ...),
und alles, was nicht per USB oder als Wechseldatenträger angeschlossen ist (also nie die Systemplatte).
Für Tests liest USBDISKS_LSBLK_JSON eine lsblk-Ausgabe aus einer Datei.
"""
import json
import os
import subprocess
import sys

BACKUP_MOUNT = os.environ.get("BACKUP_MOUNT", "/mnt/mail-backup")
SYSTEM_MOUNTS = {"/", "/boot", "/home", "/var", "/usr", "/opt", "/srv", "/etc", "/tmp", "[SWAP]"}
GOOD_FS = ("ext2", "ext3", "ext4", "xfs", "btrfs")  # brauchen Hardlinks und Unix-Rechte (rsync --link-dest)
COLS = "NAME,PATH,SIZE,MODEL,VENDOR,TRAN,RM,HOTPLUG,FSTYPE,LABEL,UUID,TYPE"


def truthy(v):
    return str(v).strip().lower() in ("1", "true", "yes")


def lsblk():
    f = os.environ.get("USBDISKS_LSBLK_JSON")
    if f:
        with open(f, encoding="utf-8") as fh:
            return json.load(fh)["blockdevices"]
    last = None
    for mp in ("MOUNTPOINTS", "MOUNTPOINT"):
        try:
            out = subprocess.run(["lsblk", "-J", "-b", "-o", COLS + "," + mp], capture_output=True, text=True, check=True).stdout
            return json.loads(out)["blockdevices"]
        except (subprocess.CalledProcessError, FileNotFoundError) as e:
            last = e
    raise SystemExit("lsblk ist nicht verfügbar: %s" % last)


def mounts_of(node):
    mps = node.get("mountpoints")
    if mps is None:
        mps = [node.get("mountpoint")]
    return [m for m in mps if m]


def walk(node):
    yield node
    for c in node.get("children") or []:
        yield from walk(c)


def human(n):
    try:
        n = float(n)
    except (TypeError, ValueError):
        return "?"
    for u in ("B", "KB", "MB", "GB", "TB"):
        if n < 1000 or u == "TB":
            return ("%.0f %s" if n >= 100 or u == "B" else "%.1f %s") % (n, u)
        n /= 1000


def is_system(mp):
    return mp in SYSTEM_MOUNTS or mp.startswith("/boot") or mp.startswith("/var/lib")


def candidates():
    out = []
    for disk in lsblk():
        if disk.get("type") != "disk":
            continue
        if not (disk.get("tran") == "usb" or truthy(disk.get("rm")) or truthy(disk.get("hotplug"))):
            continue
        nodes = list(walk(disk))
        if any(is_system(m) for n in nodes for m in mounts_of(n)):
            continue  # dort läuft das System
        kids = [c for c in (disk.get("children") or []) if c.get("type") == "part"]
        for n in (kids or [disk]):
            if not n.get("path"):
                continue
            fs = n.get("fstype") or ""
            mps = [m for m in mounts_of(n) if m != BACKUP_MOUNT]
            model = " ".join(x.strip() for x in (disk.get("vendor"), disk.get("model")) if x and x.strip())
            out.append({
                "path": n["path"], "size": n.get("size"), "size_h": human(n.get("size")), "model": model or "USB-Datenträger",
                "label": n.get("label") or "", "fstype": fs, "uuid": n.get("uuid") or "", "mountpoints": mps,
                "keeps_data": fs in GOOD_FS,
                "note": "" if fs in GOOD_FS else ("Dateisystem %s ist für das Backup ungeeignet (keine Hardlinks): nur nach Formatieren" % fs if fs else "ohne Dateisystem: nur nach Formatieren"),
            })
    return out


def main(argv):
    if len(argv) >= 2 and argv[1] == "list":
        print(json.dumps(candidates()))
        return 0
    if len(argv) == 3 and argv[1] == "check":
        for c in candidates():
            if c["path"] == argv[2]:
                for k in ("path", "fstype", "uuid", "label", "size_h", "keeps_data"):
                    print("%s=%s" % (k, c[k]))
                for m in c["mountpoints"]:
                    print("mountpoint=%s" % m)
                return 0
        print("%s ist kein geeigneter USB-Datenträger (nicht angeschlossen, kein USB/Wechseldatenträger oder Systemplatte)." % argv[2])
        return 1
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
