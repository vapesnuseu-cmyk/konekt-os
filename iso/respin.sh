#!/usr/bin/env bash
# =============================================================================
# KONEKT OS — respin the ISO without bootstrapping Debian again.
#
# build.sh is slow because it builds a Debian filesystem from the archive.
# Everything that actually changes day to day — the shell payload and the
# session — lives on top of that. This refreshes those and rebuilds the ISO.
#
# It works from the build tree if it is still there, and from the last ISO if
# it is not (a rebooted WSL clears /tmp, so that is the common case).
#
#     sudo ./iso/respin.sh
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WORK="${WORK:-/tmp/konekt-iso}"
OUT="${OUT:-$REPO/dist}"
ROOTFS="$WORK/rootfs"
ISODIR="$WORK/iso"
ARCH="${ARCH:-amd64}"

VERSION="$(python3 -c "import json;print(json.load(open('$REPO/version.json'))['version'])" 2>/dev/null || echo 1.6.0)"
BUILD="$(python3 -c "import json;print(json.load(open('$REPO/version.json'))['build'])" 2>/dev/null || echo 0)"
ISO="$OUT/konekt-os-$VERSION-$ARCH.iso"

say(){ printf '\n\033[1m[konekt]\033[0m %s\n' "$*"; }
[ "$(id -u)" = 0 ] || { echo "run me as root"; exit 1; }

apt-get install -y -qq --no-install-recommends squashfs-tools xorriso grub-pc-bin \
  grub-efi-amd64-bin mtools libarchive-tools >/dev/null 2>&1 || true

mkdir -p "$ISODIR/live" "$ISODIR/boot/grub" "$OUT"

# ---------------------------------------------------------------- get a rootfs
if [ ! -d "$ROOTFS" ]; then
  # unpack whatever image we last built — it need not be this version, since a
  # respin usually exists to produce a *new* version from the previous one
  SRC_ISO="$ISO"
  [ -f "$SRC_ISO" ] || SRC_ISO="$(ls -1t "$OUT"/konekt-os-*.iso 2>/dev/null | head -1)"
  [ -n "$SRC_ISO" ] && [ -f "$SRC_ISO" ] || { echo "no build tree at $ROOTFS and no ISO in $OUT — run iso/build.sh"; exit 1; }
  say "no build tree; unpacking $(basename "$SRC_ISO")"
  MNT="$(mktemp -d)"
  if mount -o loop,ro "$SRC_ISO" "$MNT" 2>/dev/null; then
    cp "$MNT/live/vmlinuz" "$ISODIR/live/vmlinuz"
    cp "$MNT/live/initrd"  "$ISODIR/live/initrd"
    unsquashfs -f -d "$ROOTFS" "$MNT/live/filesystem.squashfs" >/dev/null
    umount "$MNT"
  else
    say "loop mount unavailable — reading the ISO with bsdtar"
    EX="$(mktemp -d)"
    bsdtar -xf "$SRC_ISO" -C "$EX" live/vmlinuz live/initrd live/filesystem.squashfs
    cp "$EX/live/vmlinuz" "$ISODIR/live/vmlinuz"
    cp "$EX/live/initrd"  "$ISODIR/live/initrd"
    unsquashfs -f -d "$ROOTFS" "$EX/live/filesystem.squashfs" >/dev/null
    rm -rf "$EX"
  fi
  rmdir "$MNT" 2>/dev/null || true
fi

# the kernel may be missing even when the rootfs survived - WSL clears /tmp in
# pieces - so fetch it from the newest ISO whenever it is not already staged
if [ ! -f "$ISODIR/live/vmlinuz" ] && ! ls "$ROOTFS"/boot/vmlinuz-* >/dev/null 2>&1; then
  K_ISO="$(ls -1t "$OUT"/konekt-os-*.iso 2>/dev/null | head -1)"
  if [ -n "$K_ISO" ]; then
    say "kernel not staged; taking it from $(basename "$K_ISO")"
    KX="$(mktemp -d)"
    bsdtar -xf "$K_ISO" -C "$KX" live/vmlinuz live/initrd 2>/dev/null || true
    [ -f "$KX/live/vmlinuz" ] && cp "$KX/live/vmlinuz" "$ISODIR/live/vmlinuz"
    [ -f "$KX/live/initrd" ] && cp "$KX/live/initrd" "$ISODIR/live/initrd"
    rm -rf "$KX"
  fi
fi
# the squashfs excludes /boot, so take the kernel from the tree only when it has one
if ls "$ROOTFS"/boot/vmlinuz-* >/dev/null 2>&1; then
  KVER="$(basename "$(ls -1 "$ROOTFS"/boot/vmlinuz-* | sort | tail -1)" | sed 's/vmlinuz-//')"
  cp "$ROOTFS/boot/vmlinuz-$KVER"    "$ISODIR/live/vmlinuz"
  cp "$ROOTFS/boot/initrd.img-$KVER" "$ISODIR/live/initrd"
fi
[ -f "$ISODIR/live/vmlinuz" ] && [ -f "$ISODIR/live/initrd" ] || { echo "no kernel to boot"; exit 1; }

# ---------------------------------------------------------------- refresh
say "refreshing the KONEKT OS shell"
mkdir -p "$ROOTFS/opt/konekt"
cp "$REPO/demo.html"    "$ROOTFS/opt/konekt/index.html"
cp "$REPO/version.json" "$ROOTFS/opt/konekt/version.json"
# the service that lets the shell update the system and power it off
cp "$REPO/iso/serve.py" "$ROOTFS/opt/konekt/serve.py"
chmod +x "$ROOTFS/opt/konekt/serve.py"
# the updater runs as the session user and must replace these files
chown -R 1000:1000 "$ROOTFS/opt/konekt"
# a fleet points itself at its own mirror by writing this file
mkdir -p "$ROOTFS/etc/konekt"


# ---------------------------------------------------------------- KONEKT BROWSER
# The real one - the Electron app - not a stock Chromium wearing its name.
say "refreshing KONEKT BROWSER sources"
KB_SRC="$REPO/../KONEKT BROWSER"
mkdir -p "$ROOTFS/opt/konekt-browser"
for f in main.js browser.html preload.js package.json package-lock.json icon.png icon-192.png; do
  [ -f "$KB_SRC/$f" ] && cp "$KB_SRC/$f" "$ROOTFS/opt/konekt-browser/$f"
done
# first launch should honour a URL argument; later launches use second-instance
if ! grep -q 'KONEKT OS: honour a URL' "$ROOTFS/opt/konekt-browser/main.js"; then
  python3 - "$ROOTFS/opt/konekt-browser/main.js" <<'PYEOF2'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
anchor = "  createWindow();"
snippet = anchor + """
  /* KONEKT OS: honour a URL passed on first launch */
  const kosUrl = process.argv.find(a => /^https?:\/\//i.test(a));
  if (kosUrl && win) win.webContents.once('did-finish-load', () => win.webContents.send('open-url', kosUrl, false));"""
assert s.count(anchor) >= 1
s = s.replace(anchor, snippet, 1)
io.open(p, "w", encoding="utf-8", newline="\n").write(s)
print("main.js: first-launch URL snippet added")
PYEOF2
fi


# ---------------------------------------------------------------- guest additions
# trixie has no virtualbox-guest packages; the kernel side (vboxguest,
# vboxvideo) is mainline already. The userspace VBoxClient comes from the
# host's own Guest Additions ISO - present wherever VirtualBox is installed.
GA_ISO="${GA_ISO:-/mnt/c/Program Files/Oracle/VirtualBox/VBoxGuestAdditions.iso}"
if [ -f "$GA_ISO" ] && [ ! -x "$ROOTFS/usr/bin/VBoxClient" ]; then
  say "extracting VBoxClient from the host's Guest Additions ISO"
  GA_TMP="$(mktemp -d)"
  if mount -o loop,ro "$GA_ISO" "$GA_TMP" 2>/dev/null; then
    cp "$GA_TMP/VBoxLinuxAdditions.run" /tmp/vbox-ga.run
    umount "$GA_TMP"
  else
    bsdtar -xf "$GA_ISO" -C "$GA_TMP" VBoxLinuxAdditions.run 2>/dev/null || true
    [ -f "$GA_TMP/VBoxLinuxAdditions.run" ] && cp "$GA_TMP/VBoxLinuxAdditions.run" /tmp/vbox-ga.run
  fi
  if [ -f /tmp/vbox-ga.run ]; then
    sh /tmp/vbox-ga.run --noexec --nox11 --target "$GA_TMP/run" >/dev/null 2>&1 || true
    GA_TAR="$(ls "$GA_TMP"/run/VBoxGuestAdditions-amd64.tar.bz2 2>/dev/null | head -1)"
    if [ -n "$GA_TAR" ]; then
      mkdir -p "$GA_TMP/tree"
      tar -xjf "$GA_TAR" -C "$GA_TMP/tree"
      for b in bin/VBoxClient bin/VBoxControl sbin/VBoxService; do
        SRC="$GA_TMP/tree/$b"
        [ -f "$SRC" ] && install -m 755 "$SRC" "$ROOTFS/usr/$b"
      done
      if [ -x "$ROOTFS/usr/bin/VBoxClient" ]; then
        MISSING="$(chroot "$ROOTFS" ldd /usr/bin/VBoxClient 2>/dev/null | grep 'not found' || true)"
        [ -z "$MISSING" ] && say "VBoxClient installed - the guest will follow the window size" \
                          || echo "WARNING: VBoxClient missing libs: $MISSING"
      fi
    else
      echo "WARNING: could not unpack the Guest Additions run file - resize stays manual"
    fi
    rm -f /tmp/vbox-ga.run
  else
    echo "WARNING: could not read $GA_ISO - resize stays manual"
  fi
  rm -rf "$GA_TMP"
fi

# electron's binary arrives via a postinstall download that can fail quietly;
# verify it and say so, loudly, because a silent miss cost us a build already
ensure_electron() {
  chroot "$ROOTFS" bash -c "cd /opt/konekt-browser && HOME=/root npm install --no-audit --no-fund" || true
  if [ ! -x "$ROOTFS/opt/konekt-browser/node_modules/electron/dist/electron" ]; then
    say "electron binary missing - running its installer directly"
    chroot "$ROOTFS" bash -c "cd /opt/konekt-browser/node_modules/electron && HOME=/root node install.js" || true
  fi
  if [ -x "$ROOTFS/opt/konekt-browser/node_modules/electron/dist/electron" ]; then
    say "KONEKT BROWSER runtime present"
    chown root:root "$ROOTFS/opt/konekt-browser/node_modules/electron/dist/chrome-sandbox" 2>/dev/null || true
    chmod 4755 "$ROOTFS/opt/konekt-browser/node_modules/electron/dist/chrome-sandbox" 2>/dev/null || true
  else
    echo "ERROR: electron runtime still missing - the OS will fall back to Chromium" >&2
  fi
}

if [ ! -x "$ROOTFS/opt/konekt-browser/node_modules/electron/dist/electron" ]; then
  say "electron runtime absent in this tree - installing"
  ensure_electron
fi

# ---------------------------------------------------------------- real applications
# a respin works from an existing filesystem, so the window manager has to be
# fetched here rather than assumed from the package list
if [ ! -x "$ROOTFS/usr/bin/openbox" ] || [ ! -x "$ROOTFS/usr/bin/wget" ]; then
  say "installing openbox and wget into the tree"
  mount --bind /proc "$ROOTFS/proc" 2>/dev/null || true
  mount --bind /dev  "$ROOTFS/dev"  2>/dev/null || true
  cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf.respin" 2>/dev/null || true
  chroot "$ROOTFS" bash -c "apt-get update -qq && apt-get install -y -qq --no-install-recommends openbox wget"     || echo "WARNING: openbox/wget not installed - real app windows will be unmanaged"
  umount -l "$ROOTFS/proc" 2>/dev/null || true
  umount -l "$ROOTFS/dev"  2>/dev/null || true
fi

say "installing the KONEKT products as real applications"
mkdir -p "$ROOTFS/opt/konekt-apps/src"
cp -r "$REPO/iso/appshell" "$ROOTFS/opt/konekt-apps/shell"

# The products themselves, downloaded into the image. Each is a self-contained
# build of a few hundred kilobytes, so all of them fit with room to spare, and
# an application that cannot reach the network still opens and works.
mkdir -p "$ROOTFS/opt/konekt-apps/site"
for spec in \
  "konekt|konekt-tawny.vercel.app" \
  "koach|konekt-kouch.vercel.app" \
  "studio|lastochka-studio.vercel.app" ; do
  id="${spec%%|*}"; host="${spec##*|}"
  dest="$ROOTFS/opt/konekt-apps/site/$id"
  rm -rf "$dest"; mkdir -p "$dest"
  timeout 240 wget \
    --recursive --level=4 --page-requisites --convert-links \
    --no-parent --no-host-directories --domains="$host" \
    --directory-prefix="$dest" \
    --timeout=20 --tries=2 --quiet --reject-regex='/api/' \
    "https://$host/" || true
  if [ -f "$dest/index.html" ]; then
    say "  $id downloaded - $(du -sh "$dest" | cut -f1)"
  else
    rm -rf "$dest"
    echo "  WARNING: could not download $host; $id will open its deployment only"
  fi
done

# The products' own source is NOT shipped by default, and this is deliberate.
# Five of the six product repositories are private, and this ISO is published
# for anyone to download - putting their source inside it would publish them
# too. Nothing is lost by leaving it out: each product is installed as a real
# application window onto its own deployment, which is what makes it real.
#
# To ship the source anyway, fetch it first on a machine that can already read
# those repositories:
#     bash tools/fetch-app-sources.sh
# then build with:
#     KONEKT_APP_SOURCES=1 bash iso/build.sh
# The credential stays on that machine. Nothing here writes one into the image.
if [ "${KONEKT_APP_SOURCES:-0}" = "1" ]; then
  cache="$REPO/dist/appsrc"
  for id in konekt koach studio ; do
    if [ -d "$cache/$id" ]; then
      rm -rf "${ROOTFS:?}/opt/konekt-apps/src/$id"
      cp -r "$cache/$id" "$ROOTFS/opt/konekt-apps/src/$id"
      rm -rf "$ROOTFS/opt/konekt-apps/src/$id/.git"
      say "  $id — source installed"
    else
      echo "  WARNING: $cache/$id is missing - run tools/fetch-app-sources.sh first"
    fi
  done
else
  say "  source not shipped (private repositories) - each product runs from its deployment"
fi
chown -R 1000:1000 "$ROOTFS/opt/konekt-apps"

say "rewriting the session"
cat > "$ROOTFS/home/konekt/.bash_profile" <<'EOF'
if [ -z "${DISPLAY:-}" ] && [ "$(tty)" = "/dev/tty1" ]; then
  exec startx >/dev/null 2>&1
fi
EOF

cat > "$ROOTFS/home/konekt/.xinitrc" <<'EOF'
#!/bin/bash
# KONEKT OS session. The KONEKT service serves the shell over loopback and
# gives it the things a page cannot do for itself: fetch a new build from the
# update origin, verify it, install it, and power the machine off.
xset -dpms s off s noblank 2>/dev/null || true

# a window manager, so real applications have windows you can move and stack.
# The shell stays fullscreen underneath: it is the desktop.
openbox --config-file /etc/xdg/openbox/konekt-rc.xml >/dev/null 2>&1 &

# Guest Additions: the guest follows the VirtualBox window size
VBoxClient --vmsvga >/dev/null 2>&1 &
VBoxClient --clipboard >/dev/null 2>&1 &

python3 /opt/konekt/serve.py >/dev/null 2>&1 &

for _ in $(seq 1 60); do
  if (exec 3<>/dev/tcp/127.0.0.1/8923) 2>/dev/null; then exec 3>&- 3<&-; break; fi
  sleep 0.25
done

# The shell is supervised, not exec'd. Losing it should cost you the desktop for
# a second, not the machine: without this loop, a shell that dies takes X down
# with it and the screen goes dead.
while true; do
  chromium \
  --kiosk \
  --app=http://localhost:8923/ \
  --user-data-dir=/home/konekt/.konekt-profile \
  --no-first-run --no-default-browser-check --noerrdialogs --disable-infobars \
  --disable-translate --disable-features=TranslateUI,Translate \
  --disable-pinch --overscroll-history-navigation=0 \
  --check-for-update-interval=31536000 \
  --password-store=basic \
  --disable-session-crashed-bubble --hide-crash-restore-bubble \
  --window-position=0,0
  sleep 1
done
EOF
chmod +x "$ROOTFS/home/konekt/.xinitrc"

# openbox with no decorations: KONEKT applications draw their own chrome
mkdir -p "$ROOTFS/etc/xdg/openbox"
cat > "$ROOTFS/etc/xdg/openbox/konekt-rc.xml" <<'OBEOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <theme><titleLayout></titleLayout><keepBorder>no</keepBorder></theme>
  <applications>
    <application class="*">
      <decor>no</decor>
    </application>
    <application name="chromium" class="Chromium">
      <layer>below</layer>
      <maximized>yes</maximized>
    </application>
  </applications>
  <!-- No keybindings here on purpose. A window manager binding is global: it
       would close whatever has focus, and the desktop shell is a window too, so
       Alt+F4 on the desktop destroyed the whole session. Applications close
       themselves from the inside, where they know what they are closing. -->
</openbox_config>
OBEOF

# the mainline vboxguest module creates /dev/vboxguest root-only; the udev rule
# that opens it ships in a Debian package trixie does not have - so we are it
mkdir -p "$ROOTFS/etc/udev/rules.d"
cat > "$ROOTFS/etc/udev/rules.d/60-vboxguest.rules" <<'UEOF'
KERNEL=="vboxguest", SUBSYSTEM=="misc", MODE="0666"
KERNEL=="vboxuser", SUBSYSTEM=="misc", MODE="0666"
UEOF



# A PC's RTC usually holds local time (VirtualBox presents it that way, and so
# does any machine that dual-boots Windows). Read it as local so the clock on
# the lock screen is the time in the room.
printf '0.0 0 0.0\n0\nLOCAL\n' > "$ROOTFS/etc/adjtime"

mkdir -p "$ROOTFS/home/konekt/Music" "$ROOTFS/home/konekt/Videos" "$ROOTFS/home/konekt/Pictures"
chroot "$ROOTFS" chown -R konekt:konekt /home/konekt
# maintenance access: su on any console (password: konekt). A preview OS must
# never lock out its owner - the /opt/konekt permission bug proved the point.
echo 'root:konekt' | chroot "$ROOTFS" chpasswd 2>/dev/null || \
  chown -R 1000:1000 "$ROOTFS/home/konekt"

# ---------------------------------------------------------------- rebuild
say "squashing"
rm -f "$ISODIR/live/filesystem.squashfs"
mksquashfs "$ROOTFS" "$ISODIR/live/filesystem.squashfs" -comp xz -b 1M -noappend -e boot

say "writing the boot menu"
cat > "$ISODIR/boot/grub/grub.cfg" <<EOF
set default=0
set timeout=3

menuentry "KONEKT OS $VERSION" {
    linux /live/vmlinuz boot=live components quiet loglevel=2 persistence
    initrd /live/initrd
}
menuentry "KONEKT OS $VERSION (safe graphics)" {
    linux /live/vmlinuz boot=live components quiet loglevel=2 nomodeset
    initrd /live/initrd
}
menuentry "KONEKT OS $VERSION (verbose boot)" {
    linux /live/vmlinuz boot=live components
    initrd /live/initrd
}
EOF

say "building the ISO"
rm -f "$ISO"
grub-mkrescue -o "$ISO" "$ISODIR" -- -volid "KONEKT_OS" >/dev/null 2>&1
chmod 644 "$ISO"
ls -lh "$ISO"
sha256sum "$ISO" | tee "$ISO.sha256"
say "done: $ISO"
