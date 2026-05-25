---
title: "this-site"
description: "how this site is built, hosted, and watched."
date: 2026-05-24
tags: ["astro", "nginx", "cloudflare-tunnel", "monitoring"]
---
## The Stack
This site is built with Astro 5 and Tailwind v4 — static site generation, so every page compiles to plain HTML at build time. No runtime, no database, no server-side anything. I picked Astro specifically because I wanted a stack I could fully reason about: no framework magic, no opaque rendering layers, nothing to debug at 1am that I didn't already understand. Project pages are markdown files in Astro content collections; writing a new one means dropping a `.md` file in and rebuilding.

## Hosting
The site runs on a hardened Ubuntu Server 24.04 VM inside my homelab — not Vercel, not Netlify, not any managed host. That's deliberate. SSH is key-only, UFW restricts inbound traffic to a tight allowlist, fail2ban watches for brute-force attempts, and nginx serves the built static files out of `/var/www/steven-garcia.dev` with standard security headers (HSTS, X-Content-Type-Options, X-Frame-Options, Referrer-Policy). It's more work than clicking "deploy" on a SaaS dashboard, and that's the point — I wanted to know every layer.

## Deploy Pipeline
Source lives at `~/portfolio-site` on the web VM and on GitHub. A single shell script handles deploys: `git pull` → `npm install` → `npm run build` → `rsync` the `dist/` directory into the nginx web root. No CI/CD pipeline yet, and that's not laziness — the script runs in under 30 seconds, its failure modes are obvious, and I can trace every step if something breaks. I'll move to GitHub Actions eventually, but only when I have a real reason to.

## The Edge
No port forwarding on the perimeter firewall. Cloudflare Tunnel (`cloudflared`) on the web VM establishes a persistent outbound connection to Cloudflare's edge. Public requests hit Cloudflare first — they terminate TLS 1.3 / HTTP/3 there, then ride the encrypted tunnel back to nginx. My residential IP never appears in public DNS, and OPNsense never opens an inbound HTTP or HTTPS port. For a site running out of a home network, that combination of zero exposed ports plus DDoS protection at the edge is hard to beat.

## Monitoring
I wanted to know if the site went down *before* anyone tried to use it. A separate VM on the lab runs the observability stack — deliberately not the same host as the site, because a monitor that dies with its target isn't a monitor. Prometheus scrapes `blackbox_exporter` every 15 seconds, which probes three URLs through Cloudflare: the apex domain, the `www` subdomain, and a project page. Hitting the public hostnames means the probe tests the *full* delivery path: Cloudflare edge → Tunnel → nginx → static files. If any link in that chain breaks, I find out within seconds.

## Visualization
Grafana runs over HTTPS with a certificate signed by my lab's internal Enterprise Root CA — which took its own afternoon of certificate template authoring on the AD side, but means my browser actually trusts it. The dashboard ("Site Uptime — steven-garcia.dev") is adapted from community dashboard 7587 and tracks probe success, response time, and TLS certificate days remaining for each target. Useful as much for spotting patterns as catching incidents.

## Alerting
Alertmanager routes to a Discord webhook. Four rules cover the failure modes that actually matter:
- **SiteDown** — `probe_success == 0` for one minute
- **SiteSlow** — `probe_duration_seconds > 2` for five minutes
- **CertExpiringSoon** — fewer than 14 days remaining on the TLS certificate
- **CertExpired** — already past expiration

Timings are tuned for signal over noise: 30-second group wait, 5-minute group interval, 4-hour repeat interval. Long enough to notify quickly, short enough to confirm recovery, not so aggressive that a sustained outage turns Discord into spam. Tuning that took a couple iterations.

## Hardening
Every monitoring service runs as a dedicated unprivileged user under a hardened systemd unit — `ProtectHome=yes`, `ProtectSystem=strict`, `PrivateTmp=yes`, `NoNewPrivileges=yes`. The Prometheus admin API is enabled but bound to localhost. Grafana is reachable only from the internal lab network, never through the tunnel. None of this is required for a personal site, but it's how real teams run things, and I'd rather learn the hardened version now.

## What I Learned
- Static site generation eliminates entire vulnerability classes — no PHP, no database, no runtime to compromise. The trade-off is no real dynamic content, but for a portfolio that's the right call.
- Cloudflare Tunnel is the cleanest way to host from a residential connection: no NAT punching, no dynamic DNS, no exposed origin IP. Should be the default for any homelab.
- Probing through the CDN tests the full delivery path, not just origin health — that distinction matters when your edge layer is doing real work.
- Alert tuning is the difference between a pager you trust and a channel you mute by week two.
- A deploy script you fully understand beats a clever pipeline you don't.
