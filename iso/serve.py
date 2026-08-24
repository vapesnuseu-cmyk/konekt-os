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
import tempfile
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
    newer = cmp_version(remote.get("version"), local.get("version")) > 0
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


def open_outside(url):
    """Open a URL in a real, windowed Chromium on the OS.

    A separate profile, so it is a normal browser — tabs, address bar,
    downloads into ~/Downloads — instead of joining the kiosk process.
    """
    if not re.match(r"^https?://", str(url or "")):
        raise ValueError("only http(s) URLs can be opened")
    subprocess.Popen([
        "chromium",
        "--user-data-dir=" + os.path.expanduser("~/.konekt-web"),
        "--no-first-run", "--no-default-browser-check",
        "--password-store=basic",
        "--new-window", url,
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return {"ok": True, "opened": url}


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
        return super().do_GET()

    def do_POST(self):
        path = self.path.split("?")[0]
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        if path == "/api/update/apply":
            return self._guard(apply_update)
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
