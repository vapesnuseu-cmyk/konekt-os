#!/usr/bin/env python3
"""
Exercise the KONEKT OS updater without booting anything.

Stands up a fake origin and a fake installation, then checks the four things
that matter:

  1. the service reports what is installed
  2. it notices a newer build at the origin
  3. it installs that build, atomically
  4. it refuses a payload whose bytes do not match the manifest, and leaves
     the running system untouched

    python tools/test-update.py
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
SERVE = os.path.join(REPO, "iso", "serve.py")

ORIGIN_PORT = 8925
SERVICE_PORT = 8926
FAILURES = []


def check(label, ok, detail=""):
    print(("  PASS  " if ok else "  FAIL  ") + label + (" — " + detail if detail else ""))
    if not ok:
        FAILURES.append(label)


def serve_dir(path, port):
    class H(SimpleHTTPRequestHandler):
        def __init__(self, *a, **kw):
            super().__init__(*a, directory=path, **kw)

        def log_message(self, *a):
            pass

    httpd = ThreadingHTTPServer(("127.0.0.1", port), H)
    Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd


def get(url):
    with urllib.request.urlopen(url, timeout=10) as r:
        return json.loads(r.read().decode())


def post(url, payload=None):
    req = urllib.request.Request(
        url, data=json.dumps(payload or {}).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:          # the service reports failures as JSON
        return json.loads(e.read().decode())


def write_manifest(path, version, build, payload_file, digest, notes=None):
    json.dump({
        "version": version, "build": build, "channel": "test",
        "summary": "test build",
        "notes": notes or ["a test note"],
        "payload": {"file": payload_file, "sha256": digest},
    }, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)


def main():
    work = tempfile.mkdtemp(prefix="konekt-update-test-")
    origin = os.path.join(work, "origin")
    installed = os.path.join(work, "installed")
    os.makedirs(origin)
    os.makedirs(installed)

    # the installation: an older build
    old_shell = "<!doctype html><title>KONEKT OS 1.0.0</title>"
    open(os.path.join(installed, "index.html"), "w", encoding="utf-8").write(old_shell)
    write_manifest(os.path.join(installed, "version.json"), "1.0.0", 1, "demo.html", "0" * 64)

    # the origin: a newer build
    new_shell = "<!doctype html><title>KONEKT OS 2.0.0</title><!-- the new one -->"
    open(os.path.join(origin, "demo.html"), "w", encoding="utf-8").write(new_shell)
    good = hashlib.sha256(new_shell.encode()).hexdigest()
    write_manifest(os.path.join(origin, "version.json"), "2.0.0", 2, "demo.html", good,
                   ["workspaces", "self-update"])

    serve_dir(origin, ORIGIN_PORT)

    env = dict(os.environ)
    env["KONEKT_ROOT"] = installed
    env["KONEKT_PORT"] = str(SERVICE_PORT)
    env["KONEKT_ORIGIN"] = "http://127.0.0.1:%d" % ORIGIN_PORT
    svc = subprocess.Popen([sys.executable, SERVE], env=env,
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    base = "http://127.0.0.1:%d" % SERVICE_PORT
    try:
        for _ in range(50):
            try:
                get(base + "/api/status")
                break
            except Exception:
                time.sleep(0.2)
        else:
            err = svc.stderr.read().decode(errors="replace")[-800:]
            raise SystemExit("the service never came up:\n" + err)

        print("\n1. what is installed")
        st = get(base + "/api/status")
        check("status reports the installed version", st.get("version") == "1.0.0", st.get("version"))
        check("status names the update origin", st.get("origin", "").endswith(str(ORIGIN_PORT)), st.get("origin"))

        print("\n2. is there anything newer")
        ck = get(base + "/api/update/check")
        check("sees the newer build", ck.get("newer") is True, "%s -> %s" % (ck.get("local"), (ck.get("remote") or {}).get("version")))
        check("carries the release notes", bool((ck.get("remote") or {}).get("notes")))

        print("\n3. install it")
        ap = post(base + "/api/update/apply")
        check("apply reports success", ap.get("ok") is True, ap.get("error", ""))
        on_disk = open(os.path.join(installed, "index.html"), encoding="utf-8").read()
        check("the new shell is installed", on_disk == new_shell)
        man = json.load(open(os.path.join(installed, "version.json"), encoding="utf-8"))
        check("the manifest moved with it", man.get("version") == "2.0.0", man.get("version"))
        check("nothing was left staged", not [d for d in os.listdir(installed) if d.startswith(".konekt-update-")])
        check("now up to date", get(base + "/api/update/check").get("newer") is False)

        print("\n4. refuse a payload that does not match its checksum")
        tampered = new_shell + "<script>/* not what the manifest promised */</script>"
        open(os.path.join(origin, "demo.html"), "w", encoding="utf-8").write(tampered)
        write_manifest(os.path.join(origin, "version.json"), "3.0.0", 3, "demo.html", good)  # stale hash
        before = open(os.path.join(installed, "index.html"), encoding="utf-8").read()
        bad = post(base + "/api/update/apply")
        check("apply refuses", bad.get("ok") is not True, bad.get("error", "")[:60])
        check("says why", "checksum" in (bad.get("error") or "").lower(), bad.get("error", "")[:60])
        after = open(os.path.join(installed, "index.html"), encoding="utf-8").read()
        check("the running system is untouched", before == after)
        check("no staging left behind", not [d for d in os.listdir(installed) if d.startswith(".konekt-update-")])
    finally:
        svc.terminate()
        shutil.rmtree(work, ignore_errors=True)

    print("\n%s" % ("all checks passed" if not FAILURES else "FAILED: " + ", ".join(FAILURES)))
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
