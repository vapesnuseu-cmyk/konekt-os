#!/usr/bin/env bash
# =============================================================================
# KONEKT OS — bootable live ISO
#
# Builds a Debian-stable live image that boots straight into the KONEKT OS
# shell: no Linux login, no browser chrome, no desktop underneath. This is the
# architecture from RESEARCH.md in its smallest honest form — a boring proven
# base, with everything the user sees belonging to us.
#
# Run as root on any Debian/Ubuntu host (WSL2 works):
#     sudo ./iso/build.sh
#
# Output: dist/konekt-os-<version>-amd64.iso  (BIOS + UEFI hybrid)
# =============================================================================
set -euo pipefail

SUITE="${SUITE:-trixie}"
ARCH="${ARCH:-amd64}"
MIRROR="${MIRROR:-http://deb.debian.org/debian}"

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WORK="${WORK:-/tmp/konekt-iso}"
OUT="${OUT:-$REPO/dist}"
ROOTFS="$WORK/rootfs"
ISODIR="$WORK/iso"

VERSION="$(python3 -c "import json;print(json.load(open('$REPO/version.json'))['version'])" 2>/dev/null || echo 1.6.0)"
BUILD="$(python3 -c "import json;print(json.load(open('$REPO/version.json'))['build'])" 2>/dev/null || echo 0)"
ISO="$OUT/konekt-os-$VERSION-$ARCH.iso"

say(){ printf '\n\033[1m[konekt]\033[0m %s\n' "$*"; }
[ "$(id -u)" = 0 ] || { echo "run me as root"; exit 1; }

# ---------------------------------------------------------------- build deps
say "installing build tools on the host"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  mmdebstrap squashfs-tools xorriso grub-pc-bin grub-efi-amd64-bin \
  mtools dosfstools ca-certificates python3 curl gpg binutils >/dev/null

# The host may be Ubuntu (WSL), whose debian-archive-keyring is older than the
# current Debian release key — then apt inside mmdebstrap refuses the archive.
# Take the keyring from Debian itself, over TLS, and use exactly that.
KEYRING=/usr/share/keyrings/konekt-debian-archive-keyring.gpg
say "fetching Debian's archive keyring"
apt-get install -y -qq debian-archive-keyring >/dev/null 2>&1 || true
KDIR="$(mktemp -d)"
KURL="https://deb.debian.org/debian/pool/main/d/debian-archive-keyring"
KDEB="$(curl -fsSL "$KURL/" | grep -o 'debian-archive-keyring_[^\"]*_all\.deb' | sort -V | tail -1)"
[ -n "$KDEB" ] || { echo "could not find the keyring package"; exit 1; }
curl -fsSL -o "$KDIR/k.deb" "$KURL/$KDEB"
( cd "$KDIR" && ar x k.deb && tar -xf data.tar.* )
if [ -f "$KDIR/usr/share/keyrings/debian-archive-keyring.gpg" ]; then
  cp "$KDIR/usr/share/keyrings/debian-archive-keyring.gpg" "$KEYRING"
elif [ -f "$KDIR/usr/share/keyrings/debian-archive-keyring.asc" ]; then
  gpg --dearmor < "$KDIR/usr/share/keyrings/debian-archive-keyring.asc" > "$KEYRING"
else
  echo "keyring package had no keyring in it"; exit 1
fi
rm -rf "$KDIR"
echo "keyring: $KDEB"

# ---------------------------------------------------------------- rootfs
say "bootstrapping Debian $SUITE — this is the long part"
rm -rf "$WORK"
mkdir -p "$ROOTFS" "$ISODIR/live" "$ISODIR/boot/grub" "$OUT"

PKGS="linux-image-$ARCH,live-boot,systemd-sysv,init,dbus,udev,libpam-systemd,
xserver-xorg-core,xserver-xorg-input-libinput,xserver-xorg-video-vmware,
xserver-xorg-video-fbdev,xserver-xorg-video-vesa,xinit,x11-xserver-utils,
chromium,python3,fonts-dejavu-core,fontconfig,
iproute2,iputils-ping,ca-certificates,pciutils,usbutils,less,nano,psmisc,
network-manager,wpasupplicant,wireless-regdb,
nodejs,npm,libxmu6,libxt6,
bluez,rfkill,
pipewire,pipewire-pulse,pipewire-audio,wireplumber,libspa-0.2-bluetooth,alsa-utils,
firmware-linux,firmware-iwlwifi,firmware-realtek,firmware-atheros,
firmware-brcm80211,firmware-sof-signed,intel-microcode,amd64-microcode"
PKGS="$(echo "$PKGS" | tr -d ' \n')"

mmdebstrap \
  --arch="$ARCH" \
  --variant=important \
  --keyring="$KEYRING" \
  --components="main,contrib,non-free-firmware" \
  --include="$PKGS" \
  "$SUITE" "$ROOTFS" "$MIRROR"

# ---------------------------------------------------------------- identity
say "branding the system"
echo "konekt" > "$ROOTFS/etc/hostname"
cat > "$ROOTFS/etc/hosts" <<EOF
127.0.0.1   localhost konekt
::1         localhost ip6-localhost ip6-loopback
EOF

cat > "$ROOTFS/etc/os-release" <<EOF
PRETTY_NAME="KONEKT OS $VERSION"
NAME="KONEKT OS"
VERSION_ID="$VERSION"
VERSION="$VERSION (build $BUILD)"
ID=konekt
ID_LIKE=debian
HOME_URL="https://konekt-os.vercel.app"
SUPPORT_URL="https://konekt-os.vercel.app"
EOF

cat > "$ROOTFS/etc/issue" <<EOF

KONEKT OS $VERSION — NKO Intl. Foundation of Technological Research & Development
The desktop starts by itself. Ctrl+Alt+F2 for a terminal.

EOF

# ---------------------------------------------------------------- the OS payload
say "installing the KONEKT OS shell into /opt/konekt"
mkdir -p "$ROOTFS/opt/konekt"
cp "$REPO/demo.html"    "$ROOTFS/opt/konekt/index.html"
cp "$REPO/version.json" "$ROOTFS/opt/konekt/version.json"

# ---------------------------------------------------------------- KONEKT BROWSER
# The real one - the Electron app - not a stock Chromium wearing its name.
say "vendoring KONEKT BROWSER"
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

# the service that lets the shell update the system and power it off
cp "$REPO/iso/serve.py" "$ROOTFS/opt/konekt/serve.py"
chmod +x "$ROOTFS/opt/konekt/serve.py"
# the updater runs as the session user and must replace these files
chown -R 1000:1000 "$ROOTFS/opt/konekt"
# a fleet points itself at its own mirror by writing this file
mkdir -p "$ROOTFS/etc/konekt"
[ -f "$REPO/README.md" ] && cp "$REPO/README.md" "$ROOTFS/opt/konekt/README.md" || true

# ---------------------------------------------------------------- session user

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

say "installing Electron for KONEKT BROWSER (chroot npm)"
ensure_electron
chown -R 1000:1000 "$ROOTFS/opt/konekt-browser" 2>/dev/null || true
chown root:root "$ROOTFS/opt/konekt-browser/node_modules/electron/dist/chrome-sandbox" 2>/dev/null || true


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

say "creating the session"
chroot "$ROOTFS" useradd -m -s /bin/bash -G audio,video,input,netdev,bluetooth konekt
mkdir -p "$ROOTFS/home/konekt/Downloads"
chroot "$ROOTFS" passwd -d konekt >/dev/null 2>&1 || true

# autologin on tty1
mkdir -p "$ROOTFS/etc/systemd/system/getty@tty1.service.d"
cat > "$ROOTFS/etc/systemd/system/getty@tty1.service.d/autologin.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin konekt --noclear %I $TERM
EOF

# tty1 starts the shell session, nothing else does
cat > "$ROOTFS/home/konekt/.bash_profile" <<'EOF'
if [ -z "${DISPLAY:-}" ] && [ "$(tty)" = "/dev/tty1" ]; then
  exec startx >/dev/null 2>&1
fi
EOF

# the session itself: serve the OS locally, then show it fullscreen
cat > "$ROOTFS/home/konekt/.xinitrc" <<'EOF'
#!/bin/bash
# KONEKT OS session. The shell is served over loopback so that its own
# update check (version.json) works exactly as it does on a real install.
xset -dpms s off s noblank 2>/dev/null || true

# Guest Additions: the guest follows the VirtualBox window size
VBoxClient --vmsvga >/dev/null 2>&1 &
VBoxClient --clipboard >/dev/null 2>&1 &

python3 /opt/konekt/serve.py >/dev/null 2>&1 &
for _ in $(seq 1 60); do
  if (exec 3<>/dev/tcp/127.0.0.1/8923) 2>/dev/null; then exec 3>&- 3<&-; break; fi
  sleep 0.25
done

exec chromium \
  --kiosk \
  --app=http://localhost:8923/ \
  --user-data-dir=/home/konekt/.konekt-profile \
  --no-first-run --no-default-browser-check --noerrdialogs --disable-infobars \
  --disable-translate --disable-features=TranslateUI,Translate \
  --disable-pinch --overscroll-history-navigation=0 \
  --check-for-update-interval=31536000 \
  --password-store=basic \
  --disable-session-crashed-bubble --hide-crash-restore-bubble \
  --enable-features=OverlayScrollbar \
  --window-position=0,0
EOF
chmod +x "$ROOTFS/home/konekt/.xinitrc"

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
echo 'root:konekt' | chroot "$ROOTFS" chpasswd

# X may be started by a normal user from tty1
mkdir -p "$ROOTFS/etc/X11"
cat > "$ROOTFS/etc/X11/Xwrapper.config" <<'EOF'
allowed_users=anybody
needs_root_rights=yes
EOF

# ---------------------------------------------------------------- network
say "wiring the network: NetworkManager owns wired, Wi-Fi and DNS"
chroot "$ROOTFS" systemctl enable NetworkManager >/dev/null 2>&1 || true
chroot "$ROOTFS" systemctl enable bluetooth >/dev/null 2>&1 || true
# no dangling resolved symlink: a real file with public resolvers, so names
# resolve from the first second; NetworkManager rewrites it with the lease DNS
rm -f "$ROOTFS/etc/resolv.conf"
cat > "$ROOTFS/etc/resolv.conf" <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 77.88.8.8
EOF
# stray networkd config would fight NM for the interface
rm -f "$ROOTFS/etc/systemd/network/20-wired.network" 2>/dev/null || true
chroot "$ROOTFS" systemctl disable systemd-networkd >/dev/null 2>&1 || true

# quieter, faster boot: nothing here waits on a network
chroot "$ROOTFS" systemctl disable NetworkManager-wait-online >/dev/null 2>&1 || true

# ---------------------------------------------------------------- initramfs
say "rebuilding the initramfs with live-boot"
mount --bind /proc "$ROOTFS/proc"
mount --bind /sys  "$ROOTFS/sys"
mount --bind /dev  "$ROOTFS/dev"
trap 'umount -l "$ROOTFS/proc" "$ROOTFS/sys" "$ROOTFS/dev" 2>/dev/null || true' EXIT
chroot "$ROOTFS" update-initramfs -u -k all
umount -l "$ROOTFS/proc" "$ROOTFS/sys" "$ROOTFS/dev" 2>/dev/null || true
trap - EXIT

# ---------------------------------------------------------------- squash
say "squashing the filesystem"
KVER="$(basename "$(ls -1 "$ROOTFS"/boot/vmlinuz-* | sort | tail -1)" | sed 's/vmlinuz-//')"
cp "$ROOTFS/boot/vmlinuz-$KVER"    "$ISODIR/live/vmlinuz"
cp "$ROOTFS/boot/initrd.img-$KVER" "$ISODIR/live/initrd"

rm -rf "$ROOTFS/var/cache/apt/archives" "$ROOTFS/var/lib/apt/lists"
mkdir -p "$ROOTFS/var/cache/apt/archives" "$ROOTFS/var/lib/apt/lists"

mksquashfs "$ROOTFS" "$ISODIR/live/filesystem.squashfs" \
  -comp xz -b 1M -noappend -e boot

# ---------------------------------------------------------------- bootloader
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
grub-mkrescue -o "$ISO" "$ISODIR" -- -volid "KONEKT_OS"

chmod 644 "$ISO"
say "done: $ISO"
ls -lh "$ISO"
sha256sum "$ISO" | tee "$ISO.sha256"
