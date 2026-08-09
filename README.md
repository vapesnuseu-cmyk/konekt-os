# KONEKT OS

A Russian desktop operating system people choose — not one they are assigned.
NKO Intl. Foundation of Technological Research & Development · KONEKT HOLDING.

This repo is the **product site + concept shell + build plan**. The OS itself is
deliberately not being built yet — the research says exactly how to build it when
the time comes.

- `index.html` — the product site (RU/EN, one file, no build step)
- `demo.html` — the interactive concept shell: boot → login → a full desktop with
  window manager, **KONEKT BROWSER preinstalled**, Files, Terminal (`neofetch`!),
  Notes, KALC and Settings — one HTML file, everything stays in `localStorage`
- `version.json` — the update manifest the shell checks at every start
- `RESEARCH.md` — the deep research: five web-research sweeps + an adversarial
  review, distilled into the architecture
- `MASTER-PROMPT.md` — the production prompt for the future Phase 1 build agent,
  generated with the Master Prompt Factory method

## The architecture, in one breath

Debian stable + existing atomic-image tooling (A/B, rollback, reproducible) +
a KONEKT experience layer on Plasma 6/Wayland under a hard ~20-patch budget +
a curated sovereign Flatpak store + the Russian-life layer (GOST TLS, CryptoPro,
Gosuslugi, 1C — one click) as the flagship + per-app-verified Wine/Proton +
**KONEKT BROWSER preinstalled as the default** — OEM/fleet-first distribution,
free for individuals forever.

## Appearance and updates

The whole appearance system is shared with KONEKT BROWSER, control for control:
five colour schemes (Dark, Light, System, **Liquid Glass**, and **Custom** — pick a
background, outline and text colour and every grey is derived from them, with a
live contrast warning), seven accents plus a colour wheel, text size, corner
rounding from 0 to 24px, round-avatar / uppercase / reduced-motion toggles, ten
wallpapers, layout density, and one-button reset.

Updates are checked **at every launch on desktop and mobile alike**, then wait for
consent: the dialog shows the version pair and what changed, and installs only on
"Обновить сейчас" — staged, atomic, undone by a reboot. `update` in the terminal
checks on demand; `update preview` shows the dialog without installing anything.

What we are explicitly not doing: writing a kernel (ReactOS: 30 years, still
alpha), forking compositors (COSMIC: 4 years to a spartan 1.0), chasing
Windows binary compatibility, or selling certificates.

## Run the site locally

Any static server, e.g.:

```bash
python -m http.server 8923
```

Then open <http://localhost:8923>. (Don't open via `file://` — the demo's
`localStorage` needs a real origin.)

## Deploy

Static folder, no build step: import into Vercel/Netlify/Pages as-is
(Framework Preset: Other).
