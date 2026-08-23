#!/usr/bin/env python3
"""
Stamp version.json with the checksum of the shell it describes.

KONEKT OS installs an update only when the bytes it downloaded match the
sha256 the manifest promised, so the manifest has to be re-stamped whenever
demo.html changes. Run this before committing a shell change:

    python tools/stamp-version.py            # stamp
    python tools/stamp-version.py --check    # verify, exit 1 if stale
    python tools/stamp-version.py --bump 1.7.0 --build 2780
"""
import argparse
import hashlib
import io
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
PAYLOAD = "demo.html"          # the shell, as served by the update origin
MANIFEST = os.path.join(REPO, "version.json")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def shell_version(path):
    """Read OS_VERSION / OS_BUILD out of the shell so the two cannot drift."""
    src = io.open(path, encoding="utf-8").read()
    import re
    v = re.search(r"const OS_VERSION = '([^']+)'", src)
    b = re.search(r"const OS_BUILD = (\d+)", src)
    return (v.group(1) if v else None), (int(b.group(1)) if b else None)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="verify without writing")
    ap.add_argument("--bump", metavar="VERSION", help="set the version everywhere")
    ap.add_argument("--build", type=int, help="set the build number everywhere")
    args = ap.parse_args()

    payload_path = os.path.join(REPO, PAYLOAD)
    manifest = json.load(io.open(MANIFEST, encoding="utf-8"))

    # --bump rewrites the shell first, so the hash covers the new version
    if args.bump or args.build:
        src = io.open(payload_path, encoding="utf-8").read()
        import re
        if args.bump:
            src = re.sub(r"const OS_VERSION = '[^']+'", "const OS_VERSION = '%s'" % args.bump, src, count=1)
            manifest["version"] = args.bump
        if args.build:
            src = re.sub(r"const OS_BUILD = \d+", "const OS_BUILD = %d" % args.build, src, count=1)
            manifest["build"] = args.build
        io.open(payload_path, "w", encoding="utf-8", newline="").write(src)

    sv, sb = shell_version(payload_path)
    digest = sha256(payload_path)

    problems = []
    if sv and manifest.get("version") != sv:
        problems.append("manifest version %s != shell OS_VERSION %s" % (manifest.get("version"), sv))
    if sb and manifest.get("build") != sb:
        problems.append("manifest build %s != shell OS_BUILD %s" % (manifest.get("build"), sb))
    stale = (manifest.get("payload") or {}).get("sha256") != digest

    if args.check:
        if stale:
            problems.append("payload sha256 is stale — run tools/stamp-version.py")
        for p in problems:
            print("stale:", p)
        print("ok" if not problems else "STALE")
        return 1 if problems else 0

    manifest["payload"] = {"file": PAYLOAD, "sha256": digest, "bytes": os.path.getsize(payload_path)}
    for p in problems:
        print("fixing:", p)
    if sv:
        manifest["version"] = sv
    if sb:
        manifest["build"] = sb

    io.open(MANIFEST, "w", encoding="utf-8", newline="\n").write(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    print("stamped %s: version %s build %s" % (PAYLOAD, manifest["version"], manifest["build"]))
    print("sha256 %s" % digest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
