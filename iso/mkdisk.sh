#!/usr/bin/env bash
# =============================================================================
# KONEKT OS — an installed disk, not a live CD.
#
# The ISO boots from RAM and forgets everything. This writes KONEKT OS onto a
# virtual hard disk: it boots on its own, keeps your files, and — because the
# updater installs into /opt/konekt — keeps the updates it downloads.
#
#     sudo ./iso/mkdisk.sh
#
# Output: dist/konekt-os-<version>-amd64.img  (raw, sparse)
# Turn it into a VirtualBox disk on the Windows side with:
#     VBoxManage convertfromraw <img> <vdi> --format VDI
# or let iso/install-vbox.ps1 do the whole thing for you.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WORK="${WORK:-/tmp/konekt-iso}"
OUT="${OUT:-$REPO/dist}"
ROOTFS="$WORK/rootfs"
ARCH="${ARCH:-amd64}"
SIZE="${SIZE:-12G}"

VERSION="$(python3 -c "import json;print(json.load(open('$REPO/version.json'))['version'])" 2>/dev/null || echo 1.7.0)"
IMG="$OUT/konekt-os-$VERSION-$ARCH.img"

say(){ printf '\n\033[1m[konekt]\033[0m %s\n' "$*"; }
[ "$(id -u)" = 0 ] || { echo "run me as root"; exit 1; }

apt-get install -y -qq --no-install-recommends \
  parted e2fsprogs squashfs-tools grub-pc-bin grub2-common libarchive-tools >/dev/null 2>&1 || true

mkdir -p "$OUT" "$WORK"

# ---------------------------------------------------------------- source tree
KERNEL=""; INITRD=""
if [ ! -d "$ROOTFS" ]; then
  SRC_ISO="$(ls -1t "$OUT"/konekt-os-*.iso 2>/dev/null | head -1)"
  [ -n "$SRC_ISO" ] || { echo "no rootfs and no ISO in $OUT — run iso/build.sh first"; exit 1; }
  say "unpacking $(basename "$SRC_ISO")"
  EX="$(mktemp -d)"
  bsdtar -xf "$SRC_ISO" -C "$EX" live/vmlinuz live/initrd live/filesystem.squashfs
  unsquashfs -f -d "$ROOTFS" "$EX/live/filesystem.squashfs" >/dev/null
  KERNEL="$EX/live/vmlinuz"; INITRD="$EX/live/initrd"
fi
# the squashfs deliberately excludes /boot, so the kernel comes from the ISO
if [ -z "$KERNEL" ]; then
  if ls "$ROOTFS"/boot/vmlinuz-* >/dev/null 2>&1; then
    KERNEL="$(ls -1 "$ROOTFS"/boot/vmlinuz-* | sort | tail -1)"
    INITRD="$(ls -1 "$ROOTFS"/boot/initrd.img-* | sort | tail -1)"
  else
    SRC_ISO="$(ls -1t "$OUT"/konekt-os-*.iso 2>/dev/null | head -1)"
    [ -n "$SRC_ISO" ] || { echo "no kernel anywhere — run iso/build.sh"; exit 1; }
    EX="$(mktemp -d)"
    bsdtar -xf "$SRC_ISO" -C "$EX" live/vmlinuz live/initrd
    KERNEL="$EX/live/vmlinuz"; INITRD="$EX/live/initrd"
  fi
fi

# ---------------------------------------------------------------- the disk
say "creating a ${SIZE} disk"
rm -f "$IMG"
truncate -s "$SIZE" "$IMG"
parted -s "$IMG" mklabel msdos
parted -s "$IMG" mkpart primary ext4 1MiB 100%
parted -s "$IMG" set 1 boot on

LOOP="$(losetup -Pf --show "$IMG")"
cleanup(){
  mountpoint -q /mnt/konekt-target/dev  && umount -l /mnt/konekt-target/dev  || true
  mountpoint -q /mnt/konekt-target/proc && umount -l /mnt/konekt-target/proc || true
  mountpoint -q /mnt/konekt-target/sys  && umount -l /mnt/konekt-target/sys  || true
  mountpoint -q /mnt/konekt-target      && umount -l /mnt/konekt-target      || true
  losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

PART="${LOOP}p1"
[ -b "$PART" ] || PART="${LOOP}"          # some kernels expose it differently
say "formatting $PART"
mkfs.ext4 -q -L KONEKTOS "$PART"
UUID="$(blkid -s UUID -o value "$PART")"

mkdir -p /mnt/konekt-target
mount "$PART" /mnt/konekt-target

say "copying the system onto it"
cp -a "$ROOTFS"/. /mnt/konekt-target/
mkdir -p /mnt/konekt-target/boot /mnt/konekt-target/proc /mnt/konekt-target/sys /mnt/konekt-target/dev
cp "$KERNEL" /mnt/konekt-target/boot/vmlinuz
cp "$INITRD" /mnt/konekt-target/boot/initrd.img

# an installed system mounts its own root; nothing here is a live session
cat > /mnt/konekt-target/etc/fstab <<EOF
UUID=$UUID  /  ext4  errors=remount-ro  0  1
EOF

say "installing the bootloader"
mount --bind /dev  /mnt/konekt-target/dev
mount --bind /proc /mnt/konekt-target/proc
mount --bind /sys  /mnt/konekt-target/sys
grub-install --target=i386-pc --boot-directory=/mnt/konekt-target/boot \
  --modules="part_msdos ext2 normal linux" "$LOOP" >/dev/null

mkdir -p /mnt/konekt-target/boot/grub
cat > /mnt/konekt-target/boot/grub/grub.cfg <<EOF
set default=0
set timeout=3

menuentry "KONEKT OS $VERSION" {
    linux /boot/vmlinuz root=UUID=$UUID ro quiet loglevel=2
    initrd /boot/initrd.img
}
menuentry "KONEKT OS $VERSION (safe graphics)" {
    linux /boot/vmlinuz root=UUID=$UUID ro quiet nomodeset
    initrd /boot/initrd.img
}
menuentry "KONEKT OS $VERSION (verbose)" {
    linux /boot/vmlinuz root=UUID=$UUID ro
    initrd /boot/initrd.img
}
EOF

sync
cleanup
trap - EXIT

say "done: $IMG"
ls -lh "$IMG"
du -h --apparent-size "$IMG" | awk '{print "allocated:", $1}'
echo
echo "On Windows, turn it into a VirtualBox disk:"
echo "  VBoxManage convertfromraw \"$IMG\" \"${IMG%.img}.vdi\" --format VDI"
