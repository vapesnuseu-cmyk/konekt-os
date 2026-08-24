#!/usr/bin/env python3
"""
KONEKT OS — the system service behind the shell.

The shell is a page; this is the small piece of the OS underneath it that can
do the things a page cannot: reach the update origin, verify what came back,
replace the installed build, and power the machine off.

It listens on 127.0.0.1 only and is started by the session, so its callers are
the shell and nothing else.

  GET  /api/status         what is installed, and where updates come from
  GET  /api/update/check   ask the origin what the newest build is
  POST /api/update/apply   download it, verify it, install it
  POST /api/power          {"action": "poweroff" | "reboot"}

Everything else is served from /opt/konekt as ordinary files.
"""

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.environ.get("KONEKT_ROOT", "/opt/konekt")
PORT = int(os.environ.get("KONEKT_PORT", "8923"))
DEFAULT_ORIGIN = "https://konekt-os.vercel.app"
ORIGIN_FILE = "/etc/konekt/update-origin"
PAYLOAD_LOCAL = "index.html"          # what the shell is called once installed
TIMEOUT = 15


def update_origin():
    """Where new builds come from.

    KONEKT_ORIGIN in the environment wins, which is how the build and the tests
    point this at something other than the public origin.

    A fleet points at its own mirror by writing /etc/konekt/update-origin, or
    for one boot with konekt.update=<url> on the kernel command line — which is
    also how you test an update without touching the real origin.
    """
    env = os.environ.get("KONEKT_ORIGIN")
    if env:
        return env.rstrip("/")
    try:
        cmdline = open("/proc/cmdline", encoding="utf-8", errors="replace").read()
        m = re.search(r"konekt\.update=(\S+)", cmdline)
        if m:
            return m.group(1).rstrip("/")
    except OSError:
        pass
    try:
        with open(ORIGIN_FILE, encoding="utf-8") as fh:
            line = fh.read().strip()
            if line:
                return line.rstrip("/")
    except OSError:
        pass
    return DEFAULT_ORIGIN


def local_manifest():
    try:
        with open(os.path.join(ROOT, "version.json"), encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def fetch(url, binary=False):
    req = urllib.request.Request(url, headers={"User-Agent": "KONEKT-OS-updater"})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        data = resp.read()
    return data if binary else data.decode("utf-8")


def cmp_version(a, b):
    """-1, 0, 1 — the same comparison the shell does, so both agree."""
    def parts(v):
        return [int(x) if x.isdigit() else 0 for x in str(v or "0").split(".")]
    pa, pb = parts(a), parts(b)
    for i in range(max(len(pa), len(pb))):
        x = pa[i] if i < len(pa) else 0
        y = pb[i] if i < len(pb) else 0
        if x != y:
            return 1 if x > y else -1
    return 0


def check():
    origin = update_origin()
    local = local_manifest()
    remote = json.loads(fetch(origin + "/version.json?t=" + str(os.getpid())))
    vc = cmp_version(remote.get("version"), local.get("version"))
    newer = vc > 0 or (vc == 0 and int(remote.get("build") or 0) > int(local.get("build") or 0))
    return {
        "ok": True,
        "origin": origin,
        "local": local.get("version"),
        "remote": remote,
        "newer": newer,
    }


def apply_update():
    """Download the new shell, verify it, then put it in place atomically.

    The manifest names the payload and its sha256. A build whose bytes do not
    match what the manifest promised is not installed — the running system is
    left exactly as it was.
    """
    origin = update_origin()
    remote = json.loads(fetch(origin + "/version.json?t=" + str(os.getpid())))
    payload = remote.get("payload") or {}
    name = payload.get("file")
    want = (payload.get("sha256") or "").lower()
    if not name or not want:
        raise ValueError("the manifest does not say what to install, or its checksum")

    blob = fetch(origin + "/" + name, binary=True)
    got = hashlib.sha256(blob).hexdigest()
    if got != want:
        raise ValueError("checksum mismatch: expected %s, got %s" % (want[:16], got[:16]))

    staged = tempfile.mkdtemp(prefix=".konekt-update-", dir=ROOT)
    try:
        shell_path = os.path.join(staged, PAYLOAD_LOCAL)
        with open(shell_path, "wb") as fh:
            fh.write(blob)
        manifest_path = os.path.join(staged, "version.json")
        with open(manifest_path, "w", encoding="utf-8") as fh:
            json.dump(remote, fh, ensure_ascii=False, indent=2)
        for f in (PAYLOAD_LOCAL, "version.json"):
            os.replace(os.path.join(staged, f), os.path.join(ROOT, f))
    finally:
        shutil.rmtree(staged, ignore_errors=True)

    return {"ok": True, "version": remote.get("version"), "sha256": got}


def _nmcli(*args, timeout=25):
    out = subprocess.run(["nmcli", "-t", "--colors", "no"] + list(args),
                         capture_output=True, text=True, timeout=timeout)
    if out.returncode != 0:
        raise ValueError((out.stderr or out.stdout or "nmcli failed").strip().splitlines()[-1])
    return out.stdout


def net_status():
    """What the network looks like right now, in the shell's terms."""
    devices = []
    have_wifi = False
    for line in _nmcli("-f", "DEVICE,TYPE,STATE,CONNECTION", "device").splitlines():
        parts = (line.split(":") + ["", "", "", ""])[:4]
        dev, typ, state, conn = parts
        if typ in ("loopback",):
            continue
        if typ == "wifi":
            have_wifi = True
        devices.append({"device": dev, "type": typ, "state": state, "connection": conn})
    connected = any(d["state"].startswith("connected") for d in devices)
    wifi_on = False
    try:
        wifi_on = _nmcli("radio", "wifi").strip() == "enabled"
    except Exception:
        pass
    return {"ok": True, "connected": connected, "haveWifi": have_wifi,
            "wifiOn": wifi_on, "devices": devices}


def wifi_scan():
    if not net_status()["haveWifi"]:
        return {"ok": True, "haveWifi": False, "networks": []}
    try:
        _nmcli("device", "wifi", "rescan", timeout=20)
    except Exception:
        pass                                      # a scan may be throttled; list what is cached
    nets, seen = [], set()
    for line in _nmcli("-f", "IN-USE,SSID,SIGNAL,SECURITY", "device", "wifi", "list").splitlines():
        parts = (line.split(":") + ["", "", "", ""])[:4]
        in_use, ssid, signal, security = parts
        if not ssid or ssid in seen:
            continue
        seen.add(ssid)
        nets.append({"ssid": ssid, "inUse": in_use == "*",
                     "signal": int(signal) if signal.isdigit() else 0,
                     "secured": bool(security and security != "--")})
    nets.sort(key=lambda n: (-n["inUse"], -n["signal"]))
    return {"ok": True, "haveWifi": True, "networks": nets[:12]}


def wifi_connect(ssid, password):
    if not ssid:
        raise ValueError("which network?")
    args = ["device", "wifi", "connect", ssid]
    if password:
        args += ["password", password]
    _nmcli(*args, timeout=45)
    return {"ok": True, "ssid": ssid}


def _xrandr(*args):
    env = dict(os.environ)
    env.setdefault("DISPLAY", ":0")
    out = subprocess.run(["xrandr"] + list(args), capture_output=True, text=True,
                         timeout=10, env=env)
    if out.returncode != 0:
        raise ValueError((out.stderr or out.stdout or "xrandr failed").strip().splitlines()[-1])
    return out.stdout


def display_modes():
    """The connected output, its current resolution, and what it offers."""
    txt = _xrandr()
    output, current, modes, seen = None, None, [], set()
    for line in txt.splitlines():
        m = re.match(r"^(\S+) connected", line)
        if m:
            output = m.group(1)
            continue
        m = re.match(r"^\s+(\d+)x(\d+)\S*\s", line)
        if m and output:
            w, h = int(m.group(1)), int(m.group(2))
            if (w, h) in seen:
                continue
            seen.add((w, h))
            star = "*" in line
            modes.append({"w": w, "h": h, "current": star})
            if star:
                current = {"w": w, "h": h}
    return {"ok": True, "output": output, "current": current, "modes": modes[:24]}


def display_set(w, h):
    """Switch resolution; invent the mode with cvt when the driver lacks it."""
    w, h = int(w), int(h)
    if not (640 <= w <= 7680 and 480 <= h <= 4320):
        raise ValueError("unreasonable size %dx%d" % (w, h))
    info = display_modes()
    out = info.get("output") or "Virtual-1"
    name = "%dx%d" % (w, h)
    if not any(m["w"] == w and m["h"] == h for m in info["modes"]):
        cvt = subprocess.run(["cvt", str(w), str(h), "60"],
                             capture_output=True, text=True, timeout=10).stdout
        m = re.search(r'Modeline\s+"[^"]+"\s+(.+)', cvt)
        if not m:
            raise ValueError("no such mode and cvt cannot compute one")
        try:
            _xrandr("--newmode", name, *m.group(1).split())
        except ValueError:
            pass                                  # already defined
        _xrandr("--addmode", out, name)
    _xrandr("--output", out, "--mode", name)
    return {"ok": True, "width": w, "height": h}


KB_ORIGIN = "https://konekt-browser.vercel.app"


def kb_freshness():
    """Which deployment of KONEKT BROWSER is live right now.

    The site ships no version manifest, but every Vercel deployment answers
    with a fresh ETag — so a changed tag IS a new release of the browser.
    """
    req = urllib.request.Request(KB_ORIGIN + "/", method="HEAD",
                                 headers={"User-Agent": "KONEKT-OS"})
    with urllib.request.urlopen(req, timeout=10) as resp:
        et = resp.headers.get("etag") or resp.headers.get("last-modified") or ""
    return {"ok": True, "origin": KB_ORIGIN, "etag": et.strip('"W/ ')}


def battery():
    """Battery state from /sys, for the tray. Absent hardware is not an error."""
    base = "/sys/class/power_supply"
    try:
        names = sorted(os.listdir(base))
    except OSError:
        names = []
    for n in names:
        d = os.path.join(base, n)
        try:
            with open(os.path.join(d, "type")) as fh:
                if fh.read().strip() != "Battery":
                    continue
            with open(os.path.join(d, "capacity")) as fh:
                cap = int(fh.read().strip())
            status = ""
            try:
                with open(os.path.join(d, "status")) as fh:
                    status = fh.read().strip()
            except OSError:
                pass
            return {"ok": True, "present": True, "percent": cap,
                    "charging": status in ("Charging", "Full")}
        except (OSError, ValueError):
            continue
    return {"ok": True, "present": False}


def _wpctl(*args):
    out = subprocess.run(["wpctl"] + list(args), capture_output=True, text=True, timeout=10)
    if out.returncode != 0:
        raise ValueError((out.stderr or out.stdout or "wpctl failed").strip().splitlines()[-1])
    return out.stdout


def audio_status():
    txt = _wpctl("get-volume", "@DEFAULT_AUDIO_SINK@")
    m = re.search(r"Volume:\s+([\d.]+)", txt)
    if not m:
        raise ValueError("no default audio sink")
    return {"ok": True, "volume": round(float(m.group(1)) * 100),
            "muted": "MUTED" in txt}


def audio_set(volume, muted):
    if volume is not None:
        v = max(0, min(150, int(volume)))
        _wpctl("set-volume", "@DEFAULT_AUDIO_SINK@", "%d%%" % v)
    if muted is not None:
        _wpctl("set-mute", "@DEFAULT_AUDIO_SINK@", "1" if muted else "0")
    return audio_status()


MEDIA_DIRS = {
    "music": os.path.expanduser("~/Music"),
    "videos": os.path.expanduser("~/Videos"),
    "pictures": os.path.expanduser("~/Pictures"),
}
MEDIA_EXT = {
    "music": (".mp3", ".ogg", ".oga", ".flac", ".wav", ".m4a", ".opus"),
    "videos": (".mp4", ".webm", ".mkv", ".ogv", ".m4v"),
    "pictures": (".jpg", ".jpeg", ".png", ".gif", ".webp", ".svg", ".bmp", ".avif"),
}


def media_list():
    """What KONEKT MEDIA can play: real files in the real home directory."""
    out = {}
    for kind, root in MEDIA_DIRS.items():
        items = []
        for base, _dirs, files in os.walk(root):
            for f in sorted(files):
                if f.lower().endswith(MEDIA_EXT[kind]):
                    full = os.path.join(base, f)
                    rel = os.path.relpath(full, root).replace(os.sep, "/")
                    try:
                        size = os.path.getsize(full)
                    except OSError:
                        continue
                    items.append({"name": f, "path": rel, "bytes": size,
                                  "url": "/api/media/file?kind=%s&path=%s" % (kind, urllib.parse.quote(rel))})
            if len(items) > 200:
                break
        out[kind] = items[:200]
    return {"ok": True, "library": out, "dirs": MEDIA_DIRS}


def media_open(kind, rel):
    """Resolve a library path safely - nothing outside the three folders."""
    root = MEDIA_DIRS.get(kind)
    if not root:
        raise ValueError("unknown library")
    full = os.path.realpath(os.path.join(root, rel))
    if not full.startswith(os.path.realpath(root) + os.sep):
        raise ValueError("outside the library")
    if not os.path.isfile(full):
        raise ValueError("no such file")
    return full


APP_CATALOGUE = [
    {"id": "konekt",   "name": "KONEKT",           "url": "https://konekt-tawny.vercel.app/",
     "host": "konekt-tawny.vercel.app",    "port": 8931},
    {"id": "koach",    "name": "KONEKT KOACH",     "url": "https://konekt-kouch.vercel.app/",
     "host": "konekt-kouch.vercel.app",    "port": 8932},
    {"id": "studio",   "name": "LASTOCHKA STUDIO", "url": "https://lastochka-studio.vercel.app/",
     "host": "lastochka-studio.vercel.app", "port": 8933},
]
APP_SHELL = "/opt/konekt-apps/shell"
APP_SITES = "/opt/konekt-apps/site"
ELECTRON = "/opt/konekt-browser/node_modules/electron/dist/electron"


# ------------------------------------------------------- the downloaded copies
# Every product is downloaded into the image, whole, and served back from this
# machine. An application opens its live deployment first, so what you get is
# always current; when there is no network it falls back to the copy on disk and
# still works. That is why these are applications and not bookmarks.
SITE_SERVERS = {}


def site_dir(app_id):
    return os.path.join(APP_SITES, app_id)


def site_bytes(app_id):
    total = 0
    for base, _dirs, files in os.walk(site_dir(app_id)):
        for f in files:
            try:
                total += os.path.getsize(os.path.join(base, f))
            except OSError:
                pass
    return total


def site_serve(entry):
    """Serve a downloaded product on loopback, and give back its address.

    It gets a port of its own rather than a path under this service because the
    pages ask for their assets from the root; served under a prefix they would
    ask the wrong place and come back broken.
    """
    d = site_dir(entry["id"])
    if not os.path.isdir(d) or not os.path.isfile(os.path.join(d, "index.html")):
        return None
    live = SITE_SERVERS.get(entry["id"])
    if live is None or live.poll() is not None:
        SITE_SERVERS[entry["id"]] = subprocess.Popen(
            [sys.executable, "-m", "http.server", str(entry["port"]),
             "--bind", "127.0.0.1", "--directory", d],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True)
    return "http://127.0.0.1:%d/" % entry["port"]


def apps_refresh():
    """Download the products again, so the copies on disk are current."""
    if not shutil.which("wget"):
        raise ValueError("wget is not installed")
    done, failed = [], []
    for a in APP_CATALOGUE:
        dest = site_dir(a["id"])
        staging = dest + ".new"
        shutil.rmtree(staging, ignore_errors=True)
        os.makedirs(staging, exist_ok=True)
        rc = subprocess.call(
            ["wget", "--recursive", "--level=4", "--page-requisites",
             "--convert-links", "--no-parent", "--no-host-directories",
             "--domains=" + a["host"], "--directory-prefix=" + staging,
             "--timeout=20", "--tries=2", "--quiet", "--reject-regex=/api/",
             a["url"]],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if os.path.isfile(os.path.join(staging, "index.html")):
            shutil.rmtree(dest, ignore_errors=True)
            os.replace(staging, dest)
            done.append(a["id"])
        else:
            shutil.rmtree(staging, ignore_errors=True)
            failed.append(a["id"])
        del rc
    return {"ok": True, "refreshed": done, "failed": failed}


def apps_list():
    """What is installed, and whether it can actually be launched."""
    have_runtime = os.path.isfile(ELECTRON) and os.path.isdir(APP_SHELL)
    out = []
    for a in APP_CATALOGUE:
        downloaded = os.path.isfile(os.path.join(site_dir(a["id"]), "index.html"))
        out.append({"id": a["id"], "name": a["name"], "url": a["url"],
                    "installed": have_runtime,
                    "downloaded": downloaded,
                    "bytes": site_bytes(a["id"]) if downloaded else 0,
                    "source": os.path.isdir("/opt/konekt-apps/src/" + a["id"])})
    return {"ok": True, "runtime": have_runtime, "apps": out}


RUNNING = {}          # app id -> the process showing that product's window


def _spawn_shell(args):
    """Run the app shell. It draws on the session's display, not on this one."""
    if not os.path.isfile(ELECTRON):
        raise ValueError("the application runtime is not installed")
    env = dict(os.environ)
    env.setdefault("DISPLAY", ":0")
    env.setdefault("XAUTHORITY", os.path.expanduser("~/.Xauthority"))
    return subprocess.Popen(
        [ELECTRON, APP_SHELL] + args + ["--no-sandbox"],
        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True)


def app_launch(app_id):
    """Start a product as a real application window.

    One window per product is kept here rather than in the shell, because every
    product shares a single Electron user directory - that is what makes the
    KONEKT sign-in shared - and Electron's own single-instance lock is keyed on
    exactly that directory. Left to it, the first application would open and
    every one after it would silently do nothing.
    """
    entry = next((a for a in APP_CATALOGUE if a["id"] == app_id), None)
    if not entry:
        raise ValueError("no such application")
    live = RUNNING.get(app_id)
    if live is not None and live.poll() is None:
        return {"ok": True, "launched": entry["id"], "name": entry["name"], "already": True}
    args = ["--id=" + entry["id"], "--url=" + entry["url"], "--title=" + entry["name"]]
    local = site_serve(entry)
    if local:
        args.append("--offline-url=" + local)
    RUNNING[app_id] = _spawn_shell(args)
    return {"ok": True, "launched": entry["id"], "name": entry["name"],
            "already": False, "offline": bool(local)}


# ---------------------------------------------------------------- KONEKT SSO
# The desktop signs in through the same Electron session its applications use,
# so one sign-in covers all of them. It hands the authorize URL here, a window
# walks the flow, and the code comes back through this box.
SSO_RESULT = {"code": "", "state": "", "error": "", "pending": False}


def sso_open(url):
    if not url.startswith("https://"):
        raise ValueError("the sign-in address must be https")
    SSO_RESULT.update({"code": "", "state": "", "error": "", "pending": True})
    _spawn_shell(["--sso", "--url=" + url, "--title=KONEKT"])
    return {"ok": True}


def sso_deliver(code, state, error):
    SSO_RESULT.update({"code": code or "", "state": state or "",
                       "error": error or "", "pending": False})
    return {"ok": True}


def sso_take():
    """Read the result once - a code is not something to leave lying around."""
    out = dict(SSO_RESULT)
    if not out["pending"]:
        SSO_RESULT.update({"code": "", "state": "", "error": ""})
    return {"ok": True, "pending": out["pending"], "code": out["code"],
            "state": out["state"], "error": out["error"]}


def sso_signout(url):
    """One session out. The applications lose the sign-in with the desktop."""
    if url and not url.startswith("https://"):
        raise ValueError("the sign-out address must be https")
    _spawn_shell(["--sso-logout", "--url=" + (url or "https://konekt-sso.vercel.app/logout")])
    return {"ok": True}


def open_outside(url):
    """Open a URL in a real, windowed Chromium on the OS.

    A separate profile, so it is a normal browser — tabs, address bar,
    downloads into ~/Downloads — instead of joining the kiosk process.
    """
    if not re.match(r"^https?://", str(url or "")):
        raise ValueError("only http(s) URLs can be opened")
    kb = "/opt/konekt-browser"
    electron = os.path.join(kb, "node_modules", "electron", "dist", "electron")
    if os.path.exists(electron):
        # the real KONEKT BROWSER; its single-instance lock turns every later
        # call into an open-in-new-tab of the running app
        subprocess.Popen([electron, kb, url], cwd=kb,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return {"ok": True, "opened": url, "browser": "konekt"}
    subprocess.Popen([
        "chromium",
        "--user-data-dir=" + os.path.expanduser("~/.konekt-web"),
        "--no-first-run", "--no-default-browser-check",
        "--password-store=basic",
        "--new-window", url,
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return {"ok": True, "opened": url, "browser": "chromium"}


def power(action):
    if action not in ("poweroff", "reboot"):
        raise ValueError("unknown power action")
    subprocess.Popen(["systemctl", action])
    return {"ok": True, "action": action}


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=ROOT, **kw)

    def log_message(self, *a):
        pass

    def _json(self, payload, code=200):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _guard(self, fn):
        try:
            self._json(fn())
        except Exception as exc:                      # the shell shows this text
            self._json({"ok": False, "error": str(exc)}, 500)

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/api/status":
            local = local_manifest()
            return self._json({
                "ok": True,
                "system": "KONEKT OS",
                "version": local.get("version"),
                "build": local.get("build"),
                "origin": update_origin(),
                "canUpdate": True,
                "canPower": True,
                "canOpen": True,
            })
        if path == "/api/update/check":
            return self._guard(check)
        if path == "/api/apps":
            return self._guard(apps_list)
        if path == "/api/sso/code":
            return self._guard(sso_take)
        if path == "/api/media":
            return self._guard(media_list)
        if path == "/api/media/file":
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            try:
                full = media_open((q.get("kind") or [""])[0], (q.get("path") or [""])[0])
            except Exception as exc:
                return self._json({"ok": False, "error": str(exc)}, 404)
            return self._send_file(full)
        if path == "/api/battery":
            return self._guard(battery)
        if path == "/api/audio":
            return self._guard(audio_status)
        if path == "/api/kb/fresh":
            return self._guard(kb_freshness)
        if path == "/api/display":
            return self._guard(display_modes)
        if path == "/api/net/status":
            return self._guard(net_status)
        if path == "/api/net/wifi":
            return self._guard(wifi_scan)
        return super().do_GET()

    def _send_file(self, full):
        """Serve a media file, honouring Range so seeking works in <video>."""
        import mimetypes
        size = os.path.getsize(full)
        ctype = mimetypes.guess_type(full)[0] or "application/octet-stream"
        rng = self.headers.get("Range")
        start, end = 0, size - 1
        status = 200
        if rng and rng.startswith("bytes="):
            part = rng.split("=", 1)[1].split(",")[0]
            a, _, b = part.partition("-")
            if a.strip():
                start = int(a)
            if b.strip():
                end = min(int(b), size - 1)
            status = 206
        length = max(0, end - start + 1)
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(length))
        self.send_header("Accept-Ranges", "bytes")
        if status == 206:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        self.end_headers()
        with open(full, "rb") as fh:
            fh.seek(start)
            remaining = length
            while remaining > 0:
                chunk = fh.read(min(65536, remaining))
                if not chunk:
                    break
                try:
                    self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    return
                remaining -= len(chunk)

    def do_POST(self):
        path = self.path.split("?")[0]
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        if path == "/api/update/apply":
            return self._guard(apply_update)
        if path == "/api/audio/set":
            try:
                body = json.loads(raw or b"{}") or {}
            except ValueError:
                body = {}
            return self._guard(lambda: audio_set(body.get("volume"), body.get("muted")))
        if path == "/api/net/connect":
            try:
                body = json.loads(raw or b"{}") or {}
            except ValueError:
                body = {}
            return self._guard(lambda: wifi_connect(body.get("ssid", ""), body.get("password", "")))
        if path == "/api/display/set":
            try:
                body = json.loads(raw or b"{}") or {}
            except ValueError:
                body = {}
            return self._guard(lambda: display_set(body.get("width", 0), body.get("height", 0)))
        if path == "/api/app/launch":
            try:
                body = json.loads(raw or b"{}") or {}
            except ValueError:
                body = {}
            return self._guard(lambda: app_launch(body.get("id", "")))
        if path == "/api/apps/refresh":
            return self._guard(apps_refresh)
        if path == "/api/sso/open":
            try:
                body = json.loads(raw or b"{}") or {}
            except ValueError:
                body = {}
            return self._guard(lambda: sso_open(body.get("url", "")))
        if path == "/api/sso/code":
            try:
                body = json.loads(raw or b"{}") or {}
            except ValueError:
                body = {}
            return self._guard(lambda: sso_deliver(
                body.get("code", ""), body.get("state", ""), body.get("error", "")))
        if path == "/api/sso/signout":
            try:
                body = json.loads(raw or b"{}") or {}
            except ValueError:
                body = {}
            return self._guard(lambda: sso_signout(body.get("url", "")))
        if path == "/api/open":
            try:
                url = (json.loads(raw or b"{}") or {}).get("url", "")
            except ValueError:
                url = ""
            return self._guard(lambda: open_outside(url))
        if path == "/api/power":
            try:
                action = (json.loads(raw or b"{}") or {}).get("action", "")
            except ValueError:
                action = ""
            return self._guard(lambda: power(action))
        self.send_error(404)


if __name__ == "__main__":
    os.chdir(ROOT)
    ThreadingHTTPServer.allow_reuse_address = True
    with ThreadingHTTPServer(("127.0.0.1", PORT), Handler) as httpd:
        httpd.serve_forever()
