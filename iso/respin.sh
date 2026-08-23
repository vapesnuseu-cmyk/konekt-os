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
# a fleet points itself at its own mirror by writing this file
mkdir -p "$ROOTFS/etc/konekt"

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

python3 /opt/konekt/serve.py >/dev/null 2>&1 &

for _ in $(seq 1 60); do
  if (exec 3<>/dev/tcp/127.0.0.1/8923) 2>/dev/null; then exec 3>&- 3<&-; break; fi
  sleep 0.25
done

exec chromium \
  --kiosk \
  --app=http://127.0.0.1:8923/index.html \
  --user-data-dir=/home/konekt/.konekt-profile \
  --no-first-run --no-default-browser-check --noerrdialogs --disable-infobars \
  --disable-translate --disable-features=TranslateUI,Translate \
  --disable-pinch --overscroll-history-navigation=0 \
  --check-for-update-interval=31536000 \
  --password-store=basic \
  --disable-session-crashed-bubble --hide-crash-restore-bubble \
  --window-position=0,0
EOF
chmod +x "$ROOTFS/home/konekt/.xinitrc"
# A PC's RTC usually holds local time (VirtualBox presents it that way, and so
# does any machine that dual-boots Windows). Read it as local so the clock on
# the lock screen is the time in the room.
printf '0.0 0 0.0\n0\nLOCAL\n' > "$ROOTFS/etc/adjtime"

chroot "$ROOTFS" chown -R konekt:konekt /home/konekt 2>/dev/null || \
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
