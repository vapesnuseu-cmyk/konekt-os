# KONEKT OS

A Russian desktop operating system people choose — not one they are assigned.
NKO Intl. Foundation of Technological Research & Development · KONEKT HOLDING.

This repo is the **product site + concept shell + build plan**. The OS itself is
deliberately not being built yet — the research says exactly how to build it when
the time comes.

- `index.html` — the product site (RU/EN, one file, no build step)
- `demo.html` — the interactive concept shell: boot → login → a full desktop with
  window manager, Files, Terminal (`neofetch`!), Notes, KALC and Settings — one
  HTML file, everything stays in `localStorage`
- `RESEARCH.md` — the deep research: five web-research sweeps + an adversarial
  review, distilled into the architecture
- `MASTER-PROMPT.md` — the production prompt for the future Phase 1 build agent,
  generated with the Master Prompt Factory method

## The architecture, in one breath

Debian stable + existing atomic-image tooling (A/B, rollback, reproducible) +
a KONEKT experience layer on Plasma 6/Wayland under a hard ~20-patch budget +
a curated sovereign Flatpak store + the Russian-life layer (GOST TLS, CryptoPro,
Gosuslugi, 1C — one click) as the flagship + per-app-verified Wine/Proton —
OEM/fleet-first distribution, free for individuals forever.

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
