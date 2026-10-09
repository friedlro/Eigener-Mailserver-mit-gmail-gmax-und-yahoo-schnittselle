#!/usr/bin/env python3
"""webui.py - Installationsassistent im Browser (Alternative zu install.sh).

Startet einen kleinen Webserver (nur Python-Standardbibliothek), in dem Konten und Einstellungen
eingetragen werden. Daraus entsteht accounts.conf; danach laufen "setup-mailserver.sh --check"
bzw. "setup-mailserver.sh -y", und das Protokoll erscheint live im Browser.

Nutzung:
  sudo python3 webui.py                 Port 8099, im ganzen Netz erreichbar
  sudo python3 webui.py --port 9000     anderer Port
  sudo python3 webui.py --bind 127.0.0.1  nur auf dem Server selbst (z. B. per SSH-Tunnel)

Schutz: Beim Start wird ein Einmal-Passwort im Terminal angezeigt, ohne das der Zugriff nicht möglich ist.
Nach 5 falschen Versuchen beendet sich der Server. Die Verbindung ist NICHT verschlüsselt (HTTP):
nur in einem vertrauenswürdigen Netz benutzen (Heimnetz, Tailscale) oder per SSH-Tunnel.
"""
import argparse
import hmac
import json
import os
import re
import secrets
import socket
import subprocess
import sys
import threading
import time
from http import cookies
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

BASE = os.path.dirname(os.path.abspath(__file__))
SETUP = os.environ.get("MAILSERVER_SETUP", os.path.join(BASE, "setup-mailserver.sh"))
CONF = os.path.join(BASE, "accounts.conf")
CREDS = os.path.join(BASE, "zugangsdaten.txt")
IDLE_EXIT = int(os.environ.get("WEBUI_IDLE_EXIT", "900"))  # Sekunden ohne Zugriff nach Abschluss
MAX_FAILS = 5
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")

RE_ADDR = re.compile(r"^[^\s|@]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$")
RE_LOCAL = re.compile(r"^[a-z0-9._-]*$")
RE_QUOTA = re.compile(r"^([0-9]+[KMGT])?$")
RE_DOMAIN = re.compile(r"^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$")
RE_TOKEN = re.compile(r"^[A-Za-z0-9_.=-]*$")
RE_MAIL = re.compile(r"^[^\s@|]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$")
PROVIDERS = ("", "gmail", "gmx", "yahoo")


class State:
    def __init__(self, password):
        self.password = password
        self.sessions = set()
        self.fails = 0
        self.lock = threading.Lock()
        self.job = None        # {"action", "lines", "done", "rc"}
        self.last_seen = time.time()
        self.finished_at = None
        self.server = None


S = None


def clean(v):
    return v.strip() if isinstance(v, str) else ""


def validate(data):
    """Prüft die Eingaben. Gibt (conf_text, fehlerliste) zurück."""
    errors = []
    lines = []
    accounts = data.get("accounts") or []
    if not isinstance(accounts, list) or not accounts:
        errors.append("Mindestens ein Konto eintragen.")
        accounts = []
    seen = set()
    for i, a in enumerate(accounts, 1):
        if not isinstance(a, dict):
            errors.append(f"Konto {i}: ungültig.")
            continue
        addr = clean(a.get("address")).lower()
        pw = a.get("password") if isinstance(a.get("password"), str) else ""
        local = clean(a.get("local")).lower()
        lpw = a.get("localpw") if isinstance(a.get("localpw"), str) else ""
        quota = clean(a.get("quota")).upper()
        prov = clean(a.get("provider")).lower()
        where = f"Konto {i} ({addr or 'leer'})"
        if not RE_ADDR.match(addr):
            errors.append(f"{where}: ungültige Adresse.")
        if addr in seen:
            errors.append(f"{where}: Adresse doppelt.")
        seen.add(addr)
        if not pw.strip():
            errors.append(f"{where}: Passwort fehlt.")
        for label, val in (("Passwort", pw), ("Lokales Passwort", lpw)):
            if "|" in val or "\n" in val or "\r" in val:
                errors.append(f"{where}: {label} darf kein | und keinen Zeilenumbruch enthalten.")
        if lpw and len(lpw) < 8:
            errors.append(f"{where}: Lokales Passwort braucht mindestens 8 Zeichen (oder leer lassen).")
        if not RE_LOCAL.match(local):
            errors.append(f"{where}: lokaler Name nur aus a-z, 0-9, . _ - ")
        if not RE_QUOTA.match(quota):
            errors.append(f"{where}: Quota wie 10G (oder leer).")
        if prov not in PROVIDERS:
            errors.append(f"{where}: unbekannter Anbieter.")
        is_gmx = prov == "gmx" or (prov == "" and addr.rsplit("@", 1)[-1].startswith("gmx."))
        lines.append("|".join([addr, pw if is_gmx else pw.strip(), local, lpw, quota, prov]).rstrip("|"))

    opt = data.get("options") or {}
    out = []
    mode = clean(opt.get("import_mode")) or "ordner"
    if mode not in ("ordner", "alles"):
        errors.append("Importmodus: ordner oder alles.")
    out.append(f"IMPORT_MODE={mode}")
    port = clean(opt.get("webmail_port")) or "8080"
    if not (port.isdigit() and 1 <= int(port) <= 65535):
        errors.append("Webmail-Port: Zahl von 1 bis 65535.")
    out.append(f"WEBMAIL_PORT={port}")
    bind = clean(opt.get("webmail_bind")) or "0.0.0.0"
    if bind not in ("0.0.0.0", "127.0.0.1"):
        errors.append("Webmail-Zugriff: 0.0.0.0 oder 127.0.0.1.")
    out.append(f"WEBMAIL_BIND={bind}")
    tz = clean(opt.get("timezone"))
    if tz:
        if not re.match(r"^[A-Za-z_]+/[A-Za-z_+-]+(/[A-Za-z_+-]+)?$", tz):
            errors.append("Zeitzone wie Europe/Vienna.")
        out.append(f"TIMEZONE={tz}")
    domain = clean(opt.get("domain")).lower()
    if domain:
        if not RE_DOMAIN.match(domain):
            errors.append("Domain wie meinedomain.at (ohne http:// und ohne Pfad).")
        out.append(f"DOMAIN={domain}")
        for key, label, rx in (("cf_api_token", "Cloudflare API-Token", RE_TOKEN), ("le_email", "E-Mail für Let's Encrypt", RE_MAIL)):
            val = clean(opt.get(key))
            if not val or not rx.match(val):
                errors.append(f"{label}: fehlt oder ungültig (nötig, sobald eine Domain gesetzt ist).")
            else:
                out.append(f"{'CF_API_TOKEN' if key == 'cf_api_token' else 'LE_EMAIL'}={val}")
        out.append("DDNS=" + ("1" if opt.get("ddns") else "0"))
    tunnel = clean(opt.get("cf_tunnel_token"))
    if tunnel:
        if not RE_TOKEN.match(tunnel):
            errors.append("Cloudflare-Tunnel-Token: ungültige Zeichen.")
        out.append(f"CF_TUNNEL_TOKEN={tunnel}")
    if opt.get("gmail_cleanup"):
        days = clean(opt.get("gmail_trash_days")) or "30"
        if not days.isdigit():
            errors.append("Tage für das Gmail-Aufräumen: Zahl.")
        out.append("GMAIL_EMPTY_TRASH=1")
        out.append(f"GMAIL_TRASH_DAYS={days}")
    text = "# Von webui.py geschrieben\n" + "\n".join(lines) + "\n\n" + "\n".join(out) + "\n"
    return text, errors


def write_conf(text):
    if os.path.exists(CONF):
        bk = f"{CONF}.bak-{time.strftime('%Y%m%d-%H%M%S')}"
        fd = os.open(bk, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as f, open(CONF, "rb") as src:
            f.write(src.read())
    fd = os.open(CONF, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(CONF, 0o600)


def run_job(action):
    args = ["bash", SETUP] + (["--check"] if action == "check" else ["-y"])
    job = {"action": action, "lines": [], "done": False, "rc": None}
    S.job = job

    def worker():
        try:
            p = subprocess.Popen(args, cwd=BASE, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, text=True, errors="replace", bufsize=1)
            for line in p.stdout:
                job["lines"].append(ANSI.sub("", line.rstrip("\n")))
            job["rc"] = p.wait()
        except Exception as e:  # noqa: BLE001
            job["lines"].append(f"Start fehlgeschlagen: {e}")
            job["rc"] = 1
        job["done"] = True
        S.finished_at = time.time()

    threading.Thread(target=worker, daemon=True).start()


PAGE_CSS = """
:root{--bg:#f6f7f9;--fg:#1c2330;--mut:#5b6678;--card:#fff;--line:#d9dee7;--acc:#0b63ce;--bad:#b3261e;--ok:#1a7f37}
@media(prefers-color-scheme:dark){:root{--bg:#10141b;--fg:#e6e9ef;--mut:#9aa5b8;--card:#171d27;--line:#2a3342;--acc:#5aa2ff;--bad:#ff8a80;--ok:#5ad27a}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.5 system-ui,sans-serif}
main{max-width:860px;margin:0 auto;padding:16px}h1{font-size:1.4rem;margin:.2em 0}h2{font-size:1.1rem;margin:0 0 .6em}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:16px;margin:14px 0}
label{display:block;font-size:.85rem;color:var(--mut);margin:.5em 0 .15em}
input,select{width:100%;padding:9px;border:1px solid var(--line);border-radius:7px;background:var(--bg);color:var(--fg);font:inherit}
button{padding:10px 16px;border:0;border-radius:8px;background:var(--acc);color:#fff;font:inherit;cursor:pointer}
button.sec{background:transparent;color:var(--acc);border:1px solid var(--acc)}button:disabled{opacity:.5;cursor:default}
.row{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:8px}.acc{border-top:1px dashed var(--line);padding-top:8px;margin-top:10px}
.hint{color:var(--mut);font-size:.85rem}.err{color:var(--bad);white-space:pre-wrap}.ok{color:var(--ok)}
pre{background:#0d1117;color:#e6edf3;padding:12px;border-radius:8px;overflow:auto;max-height:55vh;font-size:.82rem;white-space:pre-wrap;word-break:break-word}
details summary{cursor:pointer;color:var(--acc)}.bar{display:flex;gap:10px;flex-wrap:wrap;margin-top:12px}
"""

LOGIN = """<!doctype html><html lang="de"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Mailserver-Installation</title><style>%s</style><main><div class="card"><h1>Mailserver-Installation</h1>
<p class="hint">Das Einmal-Passwort steht im Terminal, in dem webui.py gestartet wurde.</p>
<form method="post" action="/login"><label for="p">Einmal-Passwort</label><input id="p" name="p" type="password" autofocus autocomplete="off">
<div class="bar"><button>Anmelden</button></div></form><p class="err">%s</p></div></main>"""

APP = """<!doctype html><html lang="de"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Mailserver-Installation</title><style>__CSS__</style><main>
<h1>Mailserver-Installation</h1>
<p class="hint">Holt Mails von Gmail, GMX (auch gmx.at) und Yahoo ab und speichert sie lokal. Vorher beim Anbieter POP/IMAP freischalten und bei Gmail/Yahoo ein App-Passwort erstellen (siehe README, Abschnitt „Anbieter vorbereiten“). Diese Seite ist <b>unverschlüsselt</b>: nur im vertrauenswürdigen Netz benutzen.</p>
<form id="f" autocomplete="off">
<div class="card"><h2>Konten</h2><div id="accs"></div>
<div class="bar"><button type="button" class="sec" id="add">+ Konto hinzufügen</button></div>
<p class="hint">Passwort: Gmail/Yahoo = App-Passwort, GMX = GMX-Passwort. Lokales Passwort leer = wird erzeugt (steht danach in zugangsdaten.txt). Kein | in Passwörtern.</p></div>
<div class="card"><h2>Webmail und Import</h2><div class="row">
<div><label>Webmail-Port</label><input id="webmail_port" value="8080" inputmode="numeric"></div>
<div><label>Webmail erreichbar</label><select id="webmail_bind"><option value="0.0.0.0">im Heimnetz</option><option value="127.0.0.1">nur auf dem Server</option></select></div>
<div><label>Gmail-Import: ordner = Labels als Ordner, alles = ohne Ordner</label><select id="import_mode"><option value="ordner">ordner</option><option value="alles">alles</option></select></div>
<div><label>Zeitzone (optional)</label><input id="timezone" placeholder="Europe/Vienna"></div></div></div>
<div class="card"><details><summary>Fortgeschritten: Domain, Cloudflare, Gmail aufräumen</summary>
<div class="row"><div><label>Domain (optional)</label><input id="domain" placeholder="meinedomain.at"></div>
<div><label>Cloudflare API-Token</label><input id="cf_api_token" type="password"></div>
<div><label>E-Mail für Let's Encrypt</label><input id="le_email"></div>
<div><label>Cloudflare-Tunnel-Token (optional)</label><input id="cf_tunnel_token" type="password"></div></div>
<label><input type="checkbox" id="ddns" checked style="width:auto"> DNS-Adresse mail.&lt;Domain&gt; automatisch aktuell halten</label>
<label><input type="checkbox" id="gmail_cleanup" style="width:auto"> Gmail-Papierkorb täglich leeren (löscht bei Google <b>endgültig</b>, erst nach erfolgreichem Test)</label>
<div class="row"><div><label>Nur Mails älter als (Tage)</label><input id="gmail_trash_days" value="30" inputmode="numeric"></div></div>
</details></div>
<div class="bar"><button type="button" id="check" class="sec">Zugangsdaten prüfen</button><button type="button" id="install">Installieren</button></div>
<p class="err" id="err"></p></form>
<div class="card" id="logcard" style="display:none"><h2 id="logtitle">Protokoll</h2><pre id="log"></pre><p id="status"></p>
<div class="bar" id="after" style="display:none"><button type="button" class="sec" id="creds">Zugangsdaten anzeigen</button><button type="button" class="sec" id="quit">Assistent beenden</button></div>
<pre id="credbox" style="display:none"></pre></div>
<script>
const $=id=>document.getElementById(id);let n=0;
function acc(){const d=document.createElement('div');d.className='acc';d.innerHTML=
'<div class="row"><div><label>Adresse beim Anbieter</label><input class="a" placeholder="name@gmx.at"></div>'+
'<div><label>Passwort / App-Passwort</label><input class="p" type="password"></div>'+
'<div><label>Anbieter</label><select class="v"><option value="">automatisch</option><option value="gmail">Gmail</option><option value="gmx">GMX</option><option value="yahoo">Yahoo</option></select></div></div>'+
'<div class="row"><div><label>Lokaler Name (optional)</label><input class="l"></div><div><label>Lokales Passwort (optional)</label><input class="lp" type="password"></div>'+
'<div><label>Quota (optional)</label><input class="q" placeholder="10G"></div></div><button type="button" class="sec rm" style="margin-top:8px">Entfernen</button>';
d.querySelector('.rm').onclick=()=>{if(document.querySelectorAll('.acc').length>1)d.remove()};$('accs').appendChild(d)}
function collect(){const accounts=[...document.querySelectorAll('.acc')].map(d=>({address:d.querySelector('.a').value,password:d.querySelector('.p').value,
provider:d.querySelector('.v').value,local:d.querySelector('.l').value,localpw:d.querySelector('.lp').value,quota:d.querySelector('.q').value})).filter(a=>a.address.trim()||a.password||a.local.trim()||a.localpw||a.quota.trim());
const o={};['webmail_port','webmail_bind','import_mode','timezone','domain','cf_api_token','le_email','cf_tunnel_token','gmail_trash_days'].forEach(k=>o[k]=$(k).value);
o.ddns=$('ddns').checked;o.gmail_cleanup=$('gmail_cleanup').checked;return {accounts,options:o}}
let timer=null,pos=0;
async function start(action){$('err').textContent='';
if(action==='install'&&!confirm('Installation jetzt starten? Das kann bei großen Postfächern Stunden dauern.'))return;
const r=await fetch('/api/run',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action,...collect()})});
const j=await r.json();if(!r.ok){$('err').textContent=(j.errors||[j.error||'Fehler']).join('\\n');return}
$('logcard').style.display='block';$('log').textContent='';$('status').textContent='läuft …';$('after').style.display='none';$('credbox').style.display='none';
$('logtitle').textContent=action==='check'?'Zugangsdaten werden geprüft':'Installation';pos=0;['check','install'].forEach(i=>$(i).disabled=true);poll();$('logcard').scrollIntoView()}
async function poll(){const r=await fetch('/api/log?from='+pos);if(r.status===401){location.reload();return}const j=await r.json();
if(j.lines.length){const el=$('log');el.textContent+=j.lines.join('\\n')+'\\n';el.scrollTop=el.scrollHeight;pos=j.next}
if(j.done){$('status').textContent=j.rc===0?'Fertig.':'Beendet mit Fehlercode '+j.rc+' (siehe Protokoll).';$('status').className=j.rc===0?'ok':'err';
['check','install'].forEach(i=>$(i).disabled=false);$('after').style.display='flex';return}timer=setTimeout(poll,1000)}
$('add').onclick=acc;$('check').onclick=()=>start('check');$('install').onclick=()=>start('install');
$('creds').onclick=async()=>{const r=await fetch('/api/creds');const t=await r.text();const b=$('credbox');b.textContent=t;b.style.display='block'};
$('quit').onclick=async()=>{await fetch('/api/quit',{method:'POST'});document.body.innerHTML='<main><div class="card">Der Assistent wurde beendet. Dieses Fenster kann geschlossen werden.</div></main>'};
acc();
</script></main>""".replace("__CSS__", PAGE_CSS)


class Handler(BaseHTTPRequestHandler):
    server_version = "mailserver-webui"

    def log_message(self, *a):  # keine Zugriffsprotokolle mit Daten im Terminal
        pass

    def _send(self, code, body, ctype="text/html; charset=utf-8", headers=None):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def _json(self, code, obj):
        self._send(code, json.dumps(obj), "application/json")

    def _authed(self):
        c = cookies.SimpleCookie(self.headers.get("Cookie", ""))
        m = c.get("sid")
        return bool(m and m.value in S.sessions)

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n > 200_000:
            return b""
        return self.rfile.read(n)

    def do_GET(self):
        S.last_seen = time.time()
        u = urlparse(self.path)
        if u.path == "/":
            return self._send(200, APP if self._authed() else LOGIN % (PAGE_CSS, ""))
        if not self._authed():
            return self._json(401, {"error": "nicht angemeldet"})
        if u.path == "/api/log":
            job = S.job
            if not job:
                return self._json(200, {"lines": [], "next": 0, "done": True, "rc": None})
            try:
                frm = max(0, int(parse_qs(u.query).get("from", ["0"])[0]))
            except ValueError:
                frm = 0
            lines = job["lines"][frm:]
            return self._json(200, {"lines": lines, "next": frm + len(lines), "done": job["done"] and frm + len(lines) >= len(job["lines"]), "rc": job["rc"]})
        if u.path == "/api/creds":
            try:
                with open(CREDS, encoding="utf-8") as f:
                    return self._send(200, f.read(), "text/plain; charset=utf-8")
            except OSError:
                return self._send(404, "zugangsdaten.txt gibt es noch nicht (erst nach der Installation).", "text/plain; charset=utf-8")
        self._send(404, "nicht gefunden", "text/plain; charset=utf-8")

    def do_POST(self):
        S.last_seen = time.time()
        u = urlparse(self.path)
        if u.path == "/login":
            form = parse_qs(self._body().decode("utf-8", "replace"))
            given = (form.get("p") or [""])[0]
            with S.lock:
                if hmac.compare_digest(given.encode(), S.password.encode()):
                    sid = secrets.token_urlsafe(24)
                    S.sessions.add(sid)
                    return self._send(303, "", headers={"Location": "/", "Set-Cookie": f"sid={sid}; HttpOnly; SameSite=Strict; Path=/"})
                S.fails += 1
                left = MAX_FAILS - S.fails
            if left <= 0:
                self._send(403, LOGIN % (PAGE_CSS, "Zu viele Fehlversuche. Der Assistent wurde beendet."))
                print("Zu viele falsche Passwörter: Assistent beendet.", file=sys.stderr)
                threading.Thread(target=S.server.shutdown, daemon=True).start()
                return
            return self._send(401, LOGIN % (PAGE_CSS, f"Falsches Passwort ({left} Versuche übrig)."))
        if not self._authed():
            return self._json(401, {"error": "nicht angemeldet"})
        if u.path == "/api/quit":
            self._json(200, {"ok": True})
            threading.Thread(target=S.server.shutdown, daemon=True).start()
            return
        if u.path == "/api/run":
            try:
                data = json.loads(self._body() or b"{}")
            except ValueError:
                return self._json(400, {"error": "Ungültige Anfrage."})
            action = data.get("action")
            if action not in ("check", "install"):
                return self._json(400, {"error": "Unbekannte Aktion."})
            if S.job and not S.job["done"]:
                return self._json(409, {"error": "Es läuft bereits ein Vorgang."})
            text, errors = validate(data)
            if errors:
                return self._json(400, {"errors": errors})
            try:
                write_conf(text)
            except OSError as e:
                return self._json(500, {"error": f"accounts.conf konnte nicht geschrieben werden: {e}"})
            run_job(action)
            return self._json(200, {"ok": True})
        self._send(404, "nicht gefunden", "text/plain; charset=utf-8")


def local_ips():
    ips = []
    try:
        out = subprocess.run(["hostname", "-I"], capture_output=True, text=True, timeout=3).stdout.split()
        ips = [i for i in out if ":" not in i]
    except Exception:  # noqa: BLE001
        pass
    if not ips:
        try:
            ips = [socket.gethostbyname(socket.gethostname())]
        except OSError:
            pass
    return ips


def main():
    global S
    ap = argparse.ArgumentParser(description="Mailserver-Installation im Browser")
    ap.add_argument("--port", type=int, default=int(os.environ.get("WEBUI_PORT", "8099")))
    ap.add_argument("--bind", default=os.environ.get("WEBUI_BIND", "0.0.0.0"))
    args = ap.parse_args()
    if os.geteuid() != 0 and os.environ.get("WEBUI_ALLOW_NONROOT") != "1":
        sys.exit("Bitte mit sudo starten: sudo python3 webui.py")
    if not os.path.isfile(SETUP):
        sys.exit(f"setup-mailserver.sh nicht gefunden: {SETUP}")
    alphabet = "abcdefghjkmnpqrstuvwxyz23456789"
    pw = os.environ.get("WEBUI_PASSWORD") or "".join(secrets.choice(alphabet) for _ in range(10))
    S = State(pw)
    srv = ThreadingHTTPServer((args.bind, args.port), Handler)
    S.server = srv

    def watchdog():
        while True:
            time.sleep(10)
            if S.finished_at and time.time() - S.last_seen > IDLE_EXIT:
                print("Keine Aktivität nach der Installation: Assistent beendet.")
                srv.shutdown()
                return

    threading.Thread(target=watchdog, daemon=True).start()
    print("\nMailserver-Installation im Browser")
    for ip in (local_ips() if args.bind == "0.0.0.0" else [args.bind]):
        print(f"  Adresse:   http://{ip}:{args.port}")
    print(f"  Passwort:  {pw}   (Einmal-Passwort, nur für diese Sitzung)")
    print("  Beenden:   Strg+C oder Schaltfläche im Browser. Verbindung ist unverschlüsselt (HTTP)!\n")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        srv.server_close()


if __name__ == "__main__":
    main()
