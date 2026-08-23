# KONEKT OS — the bootable image

This turns the KONEKT OS shell into a real operating system image: a Debian
stable base that boots straight into KONEKT OS with no Linux login, no browser
chrome and no desktop underneath. You can run it in a virtual machine, or write
it to a USB stick and boot a real laptop from it.

It is the architecture from [RESEARCH.md](../RESEARCH.md) in its smallest honest
form — a boring, proven base with everything the user sees belonging to us.

## Build it

Any Debian or Ubuntu host with root. On Windows, WSL2 is enough:

```bash
sudo ./iso/build.sh
```

Output: `dist/konekt-os-<version>-amd64.iso` (BIOS + UEFI hybrid) plus a
`.sha256` next to it. Expect roughly 15–40 minutes on a first run — it
bootstraps a Debian filesystem, installs the session, rebuilds the initramfs
and squashes the lot. Later runs reuse your apt cache and go faster.

What goes in:

| Piece | Why |
|---|---|
| Debian stable (`trixie`), `main` + `non-free-firmware` | proven base, security updates, firmware for real laptops |
| `live-boot` | boots the squashfs image, with optional persistence |
| X + Chromium in kiosk mode | the engine the shell needs; KONEKT BROWSER is Chromium too |
| `python3 -m http.server` on 127.0.0.1:8923 | serves the shell so its own update check works exactly as on a real install |
| autologin as `konekt` on tty1 | no Linux login screen — the OS you see is the one you booted |

## Run it in a virtual machine

**VirtualBox** (installed on this machine):

```powershell
.\iso\run-vbox.ps1
```

That creates a disposable VM called `KONEKT OS` (4 GB RAM, 2 CPUs, VMSVGA
graphics), attaches the newest ISO and starts it. Useful flags:
`-Headless`, `-Recreate`, `-Iso <path>`, `-MemoryMB 8192`.

**QEMU**, if you prefer:

```bash
qemu-system-x86_64 -enable-kvm -m 4096 -smp 2 -vga virtio -display gtk \
  -cdrom dist/konekt-os-1.6.0-amd64.iso
```

**A real machine**: write the ISO to a USB stick (`dd`, Rufus, balenaEtcher in
DD mode) and boot from it. Nothing is written to the internal disk.

## Living in it

- The desktop starts on its own. There is no Linux login.
- `Ctrl+Alt+F2` drops to a Linux terminal (`konekt`, no password); `Ctrl+Alt+F1`
  returns to the shell. In VirtualBox, press the host key with F2.
- The keyboard map inside KONEKT OS is in Settings → System → Клавиши, or type
  `keys` in the terminal app.
- Networking is DHCP on the first wired interface, which is what a VM's NAT
  adapter gives you — so KONEKT and the browser reach the internet.

## What has been verified

Built and booted on this machine (VirtualBox 7.1.8, headless, 4 GB RAM):

| | |
|---|---|
| ISO | 439 MB, hybrid BIOS + UEFI, volume `KONEKT_OS` |
| Kernel | `6.12.94+deb13-amd64` — Debian 6.12.94-1, the trixie LTS line |
| Boot | GRUB to the KONEKT OS first-run screen in roughly 90 seconds cold |
| Session | fullscreen, no browser chrome, no Linux login, mouse cursor present |
| Network | DHCP on the NAT adapter; the tray shows UPLINK green |
| Clock | reads local time (the RTC is treated as local, as VirtualBox presents it) |
| Verified in the VM | typing a name into first-run, the desktop and its icons, `Ctrl+Space` search returning apps/actions/web, `Ctrl+Alt+2` switching workspace, the welcome notification |

Re-run that check any time with `.\iso\boot-test.ps1 -PowerOff`; screenshots
land in `dist\boot-test\`.

## Persistence

The live image is ephemeral by design: every boot is clean, which is the point
of an image-based OS. The boot line already asks for `persistence`, so if you
attach a second disk with an **ext4 partition labelled `persistence`** that
contains a file `/persistence.conf` with the line `/ union`, your files and
settings survive reboots. Without such a disk, live-boot simply ignores it.

## What this preview is, and is not

**Is**: a genuinely bootable KONEKT OS you can run, hand to someone, and put on
a USB stick. The shell, its apps, the appearance system and the update flow are
all the real ones.

**Is not**: the Phase 1 product from [MASTER-PROMPT.md](../MASTER-PROMPT.md).
That replaces the kiosk browser with a KONEKT experience layer on Plasma 6 /
Wayland, adds the atomic A/B image and its signed update channel, the sovereign
store, the Russian-life wizard and Secure Boot via OEM keys. This image is the
first honest step: the product boots, on hardware, today.
