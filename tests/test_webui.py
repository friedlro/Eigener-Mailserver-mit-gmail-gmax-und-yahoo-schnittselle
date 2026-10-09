#!/usr/bin/env python3
"""Testet webui.py gegen ein Platzhalter-Setup-Skript (kein Docker, kein echter Server)."""
import http.client
import json
import os
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
fails = 0


def check(name, ok):
    global fails
    print(("  ok    " if ok else "  FEHLER ") + name)
    fails += 0 if ok else 1


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


tmp = tempfile.mkdtemp()
shutil.copy(os.path.join(ROOT, "webui.py"), tmp)
fake = os.path.join(tmp, "setup-mailserver.sh")
with open(fake, "w") as f:
    f.write('#!/usr/bin/env bash\necho "Platzhalter: $*"\nprintf "\\033[1m==> fertig\\033[0m\\n"\ncat accounts.conf > seen.conf\n'
            'echo "anna@home.lan: Geheim123" > zugangsdaten.txt\n[[ "$1" == "--check" ]] && exit 3\nexit 0\n')
port = free_port()
env = dict(os.environ, MAILSERVER_SETUP=fake, WEBUI_ALLOW_NONROOT="1", WEBUI_PASSWORD="testpw12345")
proc = subprocess.Popen([sys.executable, "-I", os.path.join(tmp, "webui.py"), "--bind", "127.0.0.1", "--port", str(port)],
                        env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
for _ in range(50):
    try:
        socket.create_connection(("127.0.0.1", port), 0.2).close()
        break
    except OSError:
        time.sleep(0.1)


def req(method, path, body=None, cookie=None, ctype=None):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    h = {}
    if cookie:
        h["Cookie"] = cookie
    if ctype:
        h["Content-Type"] = ctype
    c.request(method, path, body=body, headers=h)
    r = c.getresponse()
    data = r.read().decode()
    hdr = dict(r.getheaders())
    c.close()
    return r.status, data, hdr


try:
    st, body, _ = req("GET", "/")
    check("ohne Anmeldung nur das Anmeldeformular", st == 200 and "Einmal-Passwort" in body and "accs" not in body)
    check("API ohne Anmeldung ist gesperrt", req("GET", "/api/log")[0] == 401 and req("GET", "/api/creds")[0] == 401)
    check("API-Start ohne Anmeldung ist gesperrt", req("POST", "/api/run", "{}", ctype="application/json")[0] == 401)
    st, _, _ = req("POST", "/login", "p=falsch", ctype="application/x-www-form-urlencoded")
    check("falsches Passwort wird abgelehnt", st == 401)
    st, _, hdr = req("POST", "/login", "p=testpw12345", ctype="application/x-www-form-urlencoded")
    cookie = (hdr.get("Set-Cookie") or "").split(";")[0]
    check("richtiges Passwort: Weiterleitung und Cookie", st == 303 and cookie.startswith("sid=") and "HttpOnly" in hdr.get("Set-Cookie", ""))
    st, body, _ = req("GET", "/", cookie=cookie)
    check("Formular nach Anmeldung", st == 200 and "Konten" in body and "gmx.at" in body)

    def run(payload):
        return req("POST", "/api/run", json.dumps(payload), cookie=cookie, ctype="application/json")

    good = {"action": "check", "accounts": [
        {"address": "Gina@GMX.at", "password": " mit leer ", "provider": "", "local": "", "localpw": "", "quota": ""},
        {"address": "anna@gmail.com", "password": "abcd efgh ijkl mnop", "provider": "", "local": "anna", "localpw": "", "quota": "10g"}],
        "options": {"webmail_port": "8080", "webmail_bind": "0.0.0.0", "import_mode": "ordner"}}
    bad = json.loads(json.dumps(good))
    bad["accounts"][0]["password"] = "ge|fahr"
    bad["accounts"][1]["address"] = "keine-adresse"
    st, body, _ = run(bad)
    errs = " ".join(json.loads(body).get("errors", [])) if st == 400 else ""
    check("Eingaben mit | und ungültiger Adresse werden abgelehnt", st == 400 and "kein |" in errs and "ungültige Adresse" in errs)
    check("bei Fehlern wird accounts.conf nicht geschrieben", not os.path.exists(os.path.join(tmp, "accounts.conf")))
    st, body, _ = run(dict(good, options=dict(good["options"], domain="http://x.at/pfad")))
    check("Domain mit Pfad wird abgelehnt", st == 400 and "Domain" in json.loads(body)["errors"][0])
    st, body, _ = run(dict(good, options=dict(good["options"], domain="meine.at")))
    check("Domain ohne Cloudflare-Token wird abgelehnt", st == 400 and "Cloudflare" in body)
    st, body, _ = run(dict(good, accounts=good["accounts"] + good["accounts"][:1]))
    check("doppelte Adresse wird abgelehnt", st == 400 and "doppelt" in body)

    st, body, _ = run(good)
    check("gültige Eingabe wird angenommen", st == 200)
    done = None
    for _ in range(50):
        _, body, _ = req("GET", "/api/log?from=0", cookie=cookie)
        done = json.loads(body)
        if done["done"]:
            break
        time.sleep(0.1)
    check("Protokoll läuft durch, Exit-Code des Skripts kommt an", done and done["done"] and done["rc"] == 3)
    check("Farbcodes werden aus dem Protokoll entfernt", done and "==> fertig" in done["lines"] and not any("\x1b" in l for l in done["lines"]))
    check("Skript wurde mit --check gestartet", done and "Platzhalter: --check" in done["lines"])
    conf = os.path.join(tmp, "accounts.conf")
    mode = stat.S_IMODE(os.stat(conf).st_mode)
    text = open(conf).read()
    check("accounts.conf hat Rechte 600", mode == 0o600)
    check("gmx.at-Passwort behält Leerzeichen", "gina@gmx.at| mit leer " in text)
    check("Gmail-Zeile mit kleingeschriebener Quota", "anna@gmail.com|abcd efgh ijkl mnop|anna||10G" in text)
    check("Optionen stehen in der Datei", "WEBMAIL_PORT=8080" in text and "WEBMAIL_BIND=0.0.0.0" in text and "IMPORT_MODE=ordner" in text)

    time.sleep(0.2)
    st, _, _ = run(dict(good, action="install"))
    time.sleep(0.5)
    baks = [f for f in os.listdir(tmp) if f.startswith("accounts.conf.bak-")]
    check("vorhandene accounts.conf wird gesichert (600)", len(baks) == 1 and stat.S_IMODE(os.stat(os.path.join(tmp, baks[0])).st_mode) == 0o600)
    for _ in range(50):
        _, body, _ = req("GET", "/api/log?from=0", cookie=cookie)
        if json.loads(body)["done"]:
            break
        time.sleep(0.1)
    j = json.loads(body)
    check("Installation: Skript mit -y gestartet, Exit-Code 0", "Platzhalter: -y" in j["lines"] and j["rc"] == 0)
    st, body, _ = req("GET", "/api/creds", cookie=cookie)
    check("Zugangsdaten sind nach Anmeldung abrufbar", st == 200 and "Geheim123" in body)
    st, _, _ = req("POST", "/api/quit", "{}", cookie=cookie, ctype="application/json")
    for _ in range(30):
        if proc.poll() is not None:
            break
        time.sleep(0.1)
    check("Beenden-Schaltfläche stoppt den Server", st == 200 and proc.poll() is not None)
finally:
    if proc.poll() is None:
        proc.terminate()
    shutil.rmtree(tmp, ignore_errors=True)

# Sperre nach 5 Fehlversuchen
tmp = tempfile.mkdtemp()
shutil.copy(os.path.join(ROOT, "webui.py"), tmp)
shutil.copy(fake if os.path.exists(fake) else os.path.join(ROOT, "setup-mailserver.sh"), os.path.join(tmp, "setup-mailserver.sh"))
port = free_port()
proc = subprocess.Popen([sys.executable, "-I", os.path.join(tmp, "webui.py"), "--bind", "127.0.0.1", "--port", str(port)],
                        env=dict(os.environ, WEBUI_ALLOW_NONROOT="1", WEBUI_PASSWORD="richtig12345"), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    for _ in range(50):
        try:
            socket.create_connection(("127.0.0.1", port), 0.2).close()
            break
        except OSError:
            time.sleep(0.1)
    for _ in range(5):
        try:
            req("POST", "/login", "p=x", ctype="application/x-www-form-urlencoded")
        except OSError:
            break
    time.sleep(1)
    check("nach 5 Fehlversuchen beendet sich der Server", proc.poll() is not None)
finally:
    if proc.poll() is None:
        proc.terminate()
    shutil.rmtree(tmp, ignore_errors=True)
sys.exit(1 if fails else 0)
