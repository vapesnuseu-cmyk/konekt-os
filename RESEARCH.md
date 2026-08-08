# KONEKT OS — Deep Research: the best way to build a Russian macOS/Windows alternative

Research date: August 2026. Method: five independent web-research sweeps (Russian OS
landscape · foundation options · shell strategy · app/hardware compatibility · case
studies of every OS alternative that ever tried), followed by an adversarial review
that attacked every decision. ~170 sources; the load-bearing ones are cited inline.

---

## The verdict in one paragraph

**Do not build an operating system in the kernel sense. Build an experience layer with
a sovereign spine.** Every from-scratch kernel or Windows-binary-compatible attempt is
still alpha decades later (ReactOS: 30 years; Haiku: 25; SerenityOS's own creator left
it for a browser). Every success shipped on a proven base through one narrow channel:
Zorin (2–10 people, profitable Ubuntu skin, 2M downloads in 3 months by launching the
day Windows 10 died), SteamOS (one device + Proton + own store), ChromeOS (education
fleets), China's UOS (procurement mandates + OEM bundling). The winning KONEKT OS is:
**Debian-stable + existing atomic-image tooling + a Plasma-based KONEKT experience
layer under a hard patch budget + a curated sovereign app store + the "Russian-life
layer" (GOST/CryptoPro/Gosuslugi/1C in one click) as the flagship feature — distributed
OEM/fleet-first with a free consumer edition as the brand halo.**

---

## 1. The gap is real: nobody in Russia builds an OS people choose

- The domestic OS market is **31 bn RUB (2025)** and ~98% of it is three vendors —
  Astra (~75%), RED OS (~13%), ALT (~10%) — **all selling compliance** to mandated
  B2G/B2B buyers (CII foreign-software ban from 2025, Decree No. 1937 from 2026).
- Meanwhile actual usage: **Windows holds 91% of Russian desktops (StatCounter, July
  2026)**, mostly pirated ($3–4 keys installed at the shop counter); all Linux = 3.25%.
  Displaced licensed Windows went to piracy, not to domestic Linux.
- Nobody owns the experience layer. Astra's Fly is a Windows-7 pastiche criticized for
  lag and "no HIG"; ALT/RED OS/ROSA/MSVSphere ship stock GNOME/KDE with wallpapers.
  The consumer attempts failed for identifiable reasons: Aurora OS sold **800 phones
  in 4 months** despite Rostelecom billions (security positioning, empty catalog);
  Uncom OS ("free Ubuntu for 3,990 RUB") was rejected on value; ROSA — the one team
  with design DNA — is starving at 352M RUB revenue, −11%/yr.
- **No design-led consumer desktop OS was announced by anyone in 2025–2026.** The
  flank is open. It is open because it is hard, not because nobody noticed.

## 2. Foundation: Debian-stable + existing atomic tooling (no own kernel, no bespoke pipeline)

The team-size table that settles it (time to credible v1 / sustaining team):

| Path | Time | Team | Evidence |
|---|---|---|---|
| From-scratch kernel | 10–25 yrs | 30–50, still no product | Redox 11 yrs in; Haiku 25; Ladybird needs 7 FTE for a browser alpha |
| FreeBSD base | 4–6 yrs | 10–20 (drivers) | $750k bought one year of laptop basics |
| Independent repo (ALT path) | 5–10 yrs | ~150 | BaseALT headcount; Solus nearly died below ~15 |
| Fedora bootc derivative | 1–2 yrs | 5–10 | Bazzite — but Red Hat/US governance |
| **Debian-stable + atomic images + Flatpak** | **1.5–2.5 yrs** | **6–12** | elementary (1–8), Zorin (8), Vanilla OS, Astra at scale |

Decisions, post-adversarial-review:

- **Base: Debian stable.** Proven in Russia at enterprise scale (Astra), at consumer
  polish (Deepin), at tiny-team scale (elementary, Zorin, Vanilla OS). Debian's
  reproducible-builds regime (mandatory for Debian 14 "Forky"; ~97–98% reproducible
  today) is inherited free and becomes KONEKT's trust story — the only honest answer
  to "is the Kremlin/NSA in it?" from either direction.
- **Kernel: stock Debian LTS + backports HWE.** Debian 13 ships 6.12 LTS, supported
  to ~Dec 2028 (CIP: ~10 years). A house kernel build is pure maintenance waste —
  cut it. Fresh drivers come from backports, not from owning the kernel.
- **Delivery: atomic A/B images via existing open tooling** — ABRoot (Vanilla OS,
  small-team-proven on Debian) or self-hosted ostree/bootc (Apache/MIT licensed;
  self-hostable without touching US infrastructure). One signed image per release
  collapses the QA surface from 50,000 package permutations to one artifact; a failed
  update rolls back on reboot. **Do not build a bespoke update pipeline** — that is a
  multi-year systems project the team cannot staff. Budget static deltas/zstd:chunked
  from day one or updates are multi-GB per device.
- **Cut the "base-agnostic ALT-swap" hedge.** A permanent abstraction tax for a hedge
  a deb→rpm rebase would invalidate anyway. Mirror Debian + security.debian.org +
  kernel.org in-country (~50–100 TB, 2 part-time sysadmins) — source consumption is
  GPL-protected even where contribution is constrained (the Oct 2024 removal of 11
  Russian kernel maintainers constrains *contribution*, not *consumption*).

## 3. Shell: a KONEKT experience layer on Plasma 6 — not a fork, not a new DE

- **Building a DE from scratch is disqualified by arithmetic:** COSMIC took System76
  ~4 years and ~8 excellent Rust engineers to a spartan 1.0 (Dec 2025), and they had
  to write their own text renderer and animation framework on the way. Cutefish died
  trying. Deepin — with an order of magnitude more engineers — chose Qt-on-wlroots
  rather than a from-scratch compositor, and Treeland still needed ~18 months to
  outgrow teething problems.
- **GNOME skinning (Zorin's path) works but rides a treadmill:** a July 2026 GNOME
  point release broke every Zorin extension at once; libadwaita is theming-hostile;
  System76 and elementary both bear scars.
- **KDE Plasma 6 is the only mainstream shell where a full visual identity is
  achievable without forking C++ cores:** the entire shell is QML; Plasma Style SVGs,
  Aurorae window decorations, custom plasmoids (dock/launcher/overview), KWin
  JS/QML effects, and a Kvantum/Union application style cover ~95% of the cubic
  KONEKT brand language. Valve judged Plasma good enough to skin for SteamOS; TUXEDO
  differentiates on defaults at OEM-team cost. Plasma 6.8 goes Wayland-only — aligned
  with KONEKT being Wayland-only anyway (Waydroid and modern NVIDIA require it).
- **The adversarial review's hard rule, adopted:** the delta is a
  **theme-plus-plasmoids layer with a budget of ~20 carried patches**; anything
  needing more gets contributed upstream as a hook instead. During the Union theming
  transition (Plasma 6.7/6.8), a deep shell-QML rewrite would mean rebase hell —
  don't. **No phase-2 custom compositor.** Distinctiveness comes from the design
  system, the first-party apps, and the Russian-life layer — where macOS's premium
  feel actually lives anyway: one typeface (commission a Cyrillic-first SF-class
  family; lock fontconfig so exactly one rendering config exists), one HIG every
  dialog obeys, spring-curve interruptible animation, curated defaults.
- What Plasma brings free that no small team can rebuild: fractional scaling, the
  Feb-2025 color-management/HDR protocol, accessibility (AT-SPI/Orca — skipping it
  forecloses education deals), input methods, xdg-portals/PipeWire screen capture,
  NVIDIA explicit-sync fixes.

## 4. Apps: curated sovereign store; system-extension layer for the GOST stack

- **Flatpak is the app format** (Flathub: 435M downloads in 2025 — the de facto Linux
  consumer store). **Snap is disqualified** (proprietary Canonical server side,
  cannot self-host).
- **The sovereign mirror is a necessity, not paranoia:** dl.flathub.org has been
  intermittently unreachable from Russia since 2022; Docker Hub geo-blocked Russia
  outright in May 2024; Cisco's openh264 repo blocks Russian IPs today.
  **But "full Flathub mirror" is legally wrong:** proprietary `extra-data` apps fetch
  payloads from vendor servers (which geo-block), and some licenses forbid
  redistribution — SJTU's Chinese mirror excludes NVIDIA and JetBrains for exactly
  this reason. **Adopted shape:** a KONEKT-branded store (Flathub is a trademark)
  mirroring the FOSS subset + individually negotiated proprietary apps, operating as
  a caching proxy where redistribution is barred.
- **Flatpak-only absolutism dies on contact with the Russian stack:** CryptoPro CSP,
  the Gosuslugi IFCPlugin (native messaging into a system CSP), and the 1C client are
  system-level components that break inside the sandbox. **Adopted shape:** a signed
  system-extension layer (ostree package layering / systemd-sysext) carries the
  GOST/1C stack; everything else is sandboxed Flatpak.
- **Top-100 national apps via direct deals, HarmonyOS-style** (Huawei negotiated
  WeChat/WPS/Bilibili before launch): Telegram, VK, MAX (native Linux client since
  Sept 2025), Yandex Browser (official Linux builds with GOST TLS), OnlyOffice /
  MyOffice Home (free) / R7-Office, Kaspersky (consumer Linux AV since Feb 2025), 1C.

## 5. The Russian-life layer — the flagship feature (upheld unanimously)

The one thing neither Windows nor any registry OS does out of the box, and the reason
to build the product at all:

- **One-click wizard**: CryptoPro CSP 5.0 (Linux builds exist, incl. ARM) + Gosuslugi
  IFC plugin + GOST TLS browser (Yandex Browser for Linux or Chromium-Gost) +
  e-signature tooling. RED OS and Astra document the manual 40-step version; KONEKT
  ships the one-click version. **Caveat found in review: CryptoPro is a paid product
  (90-day trial) — the wizard requires an OEM licensing deal with CryptoPro. That
  deal IS the feature; negotiate it early.**
- **1C is not a blocker:** native Linux thin/thick clients since 8.3.1 (2013),
  officially supported on Astra/ALT/RED OS — package it well.
- **Banking:** sanctions pushed Russian banks to adaptive web versions (apps purged
  from the stores) — on desktop this is an *advantage*: Sber/T-Bank/VTB web cabinets
  need no Windows. Ship them as first-class PWA wrappers. Waydroid+RuStore for bank
  APKs is demoted to experimental (can't pass integrity checks; arm64-only APKs need
  proprietary translation layers; web versions are strong).
- **Legacy business Windows apps** (Consultant+, SBIS, Kontur with CryptoPro inside
  Wine): the WINE@Etersoft precedent proves the recipes work — license or replicate.

## 6. Windows compatibility: per-app verified, never binary-compatible

- Wine 10/Proton, integrated and preconfigured (umu/Bottles pattern), with a
  **"KONEKT Verified" per-app badge program** — the Deck Verified model, which made
  ~90% of Steam's catalog playable and, crucially, *told users the truth per title*.
- The whitelist is capped by QA reality: ~30–50 apps ≈ one dedicated regression
  engineer per Wine bump. Scope is the feature.
- **Gaming honesty:** CS2 and Dota 2 — Russia's most-played — are native. Kernel
  anti-cheat titles (Valorant, Battlefield) run on nobody's Linux; the badge says so
  before install, not after. (Expectation management is a support-cost line item:
  the most common workload on pirated Windows is exactly these games.)
- ReactOS is the tombstone of the alternative: 30 years chasing kernel-level binary
  compatibility, still alpha, celebrating running Half-Life (1998) in 2026.

## 7. Hardware: x86_64, honestly scoped

- **x86_64 only at launch.** The RU laptop market (3.4M units/2025) is Asus, Huawei,
  Honor, Acer, Lenovo + a Chinese second tier — standard Intel/AMD. aarch64 stays a
  build target; **Elbrus/Baikal are rejected** (no fab since 2022, no mainline
  toolchain for e2k, government-channel volumes only).
- **The real QA battleground found in review:** the Chinese-brand fleet
  (Honor/Tecno/Infinix/Mechrevo) with IPU6 MIPI webcams, Goodix fingerprint readers,
  ES8336 audio — exactly where Linux "just works" least. **Adopted: a published,
  funded per-SKU QA matrix for the top ~30 retail laptops.**
- **NVIDIA needs a two-driver story:** open kernel modules cover Turing+ only; the
  GTX 10-series still common in Russia needs the legacy proprietary driver; and the
  proprietary userspace cannot be mirrored freely — a legal/redistribution answer is
  required before "automated" is promised.
- Printers: Pantum is 60%+ of the RU market and ships Linux debs; Katusha certifies
  against Russian distros; HPLIP covers the HP legacy; IPP Everywhere for the rest.

## 8. Go-to-market: OEM/fleet-first, consumer as the halo (reversed by the review — and the evidence is brutal)

- **The consumer-payments thesis fails:** pirated Windows is functionally free and
  installed at the point of sale — including on the "no-OS" laptops (43% of corporate
  shipments) that look like a channel but mostly get a $3 key at the counter. A
  one-time Pro tier internationally is dead (no Visa/MC; Mir/SBP sanctioned from Jan
  2026; foreign receipts risk foreign-agent designation for an NKO). Zorin's model
  transplants only as a domestic SBP patronage button.
- **The segments that convert are fleets:** education, municipal/regional
  deployments, OEM preloads, state-adjacent employers stranded by Windows EOLs and
  CII bans. ChromeOS's actual killer feature in education was the admin console —
  **a fleet-management console is worth more to the first 100k seats than any
  visual polish.**
- **Reestr inclusion is required for those channels and is NOT FSTEC certification:**
  rights-holder registration in the Unified Register — weeks of paperwork, not years
  of lab audits or frozen kernels. The commercial arm registers; the product stays
  design-led. (The "no certificates" brand stance survives: no FSTEC protection-class
  play, no MoD editions.)
- **OEM preloads solve Secure Boot** — the single biggest missing piece found in
  review: a Microsoft-signed shim for a new Russian NKO in 2026 is near-fantasy, but
  partner OEMs can enroll KONEKT's own PK/KEK/db keys in firmware. Retail ISO
  installs remain the enthusiast path (SB toggle documented honestly).
- **Structure:** the NKO foundation holds code and brand (projects must outlive
  founders — Haiku Inc. preserves but can't ship; elementary nearly died with one
  founder's exit); a commercial arm sells fleet subscriptions, consoles, OEM deals.
  Free for individuals, forever, no telemetry — the brand halo that the procurement
  products borrow credibility from.
- **Timing:** Zorin got 2M downloads in a quarter by launching on Windows 10's EOL
  day. Russia has a standing forced-migration moment (stranded Win10 hardware +
  sanctioned Windows + CII deadlines). The window is open now and stays open.

## 9. What the plan must also carry (found by the adversarial pass)

1. **Secure Boot signing story** — OEM key enrollment (above); document the retail
   reality honestly.
2. **Full-disk encryption by default** — TPM-sealed LUKS with PCR policies that
   survive A/B image swaps is genuinely hard; budget it as a first-class feature.
   Shipping a 2026 consumer OS unencrypted is malpractice.
3. **Team-to-scope arithmetic** — the plan is only buildable by 6–12 people *because
   of* the cuts: no own kernel, no bespoke pipeline, no fork, no compositor. Guard
   the cuts.
4. **Bandwidth/CDN budget** — image updates with static deltas + a tens-of-TB store
   mirror need a funded domestic CDN line item.
5. **Support organization** — consumer OS = consumer support: helpdesk, opt-in crash
   reporting, OEM return policy.
6. **Upstream friction** — post-2024, patches from Russian corporate addresses face
   compliance screening; route contributions through individual maintainers, expect
   delays, and never depend on upstream acceptance for shipping.

## 10. Phased roadmap

- **Phase 0 — done:** the concept shell (this repo's `demo.html`) — the design
  language, window model, and first-party app concepts, testable in any browser.
- **Phase 1 (months 0–9):** KONEKT experience layer on Plasma 6/Wayland on Debian
  stable — global theme, plasmoids (dock/launcher/overview), KWin effects, the
  typeface, fontconfig lockdown, first-party app shells. Alpha images for
  enthusiasts (Calamares installer, SB-off documented).
- **Phase 2 (months 6–18):** atomic delivery via ABRoot/ostree; the KONEKT store
  (FOSS mirror + first deals); the Russian-life wizard (CryptoPro deal permitting);
  Live-USB beta; TPM-LUKS FDE; first KONEKT Verified badges.
- **Phase 3 (months 12–30):** Reestr registration; fleet console MVP; first OEM
  pilot (firmware keys, per-SKU QA matrix); education/municipal pilots; 1.0.

## Appendix: source reports

The five raw research reports (with ~170 source links) and the adversarial review
are preserved in the project's session records; headline sources include ComNews,
Interfax, StatCounter, TAdviser, Habr, LWN, Phoronix, The Register, official vendor
announcements (BaseALT, Red Soft, Astra, deepin/UnionTech, System76, Zorin,
elementary, Valve), reproducible-builds.org, and the Flathub/Docker Hub/kernel.org
incident record.
