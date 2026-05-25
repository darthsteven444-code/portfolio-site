---
title: "this-site"
description: "how this site is built, hosted, and watched — from astro source to discord alerts."
date: 2026-05-24
tags: ["astro", "nginx", "cloudflare-tunnel", "monitoring"]
---
## The Stack
Most personal sites are deployed to Vercel or Netlify with a click. This one isn't. It runs on hardware I own, on a VM I built, behind a firewall I configured, monitored by a stack I wired up myself. Was that more work than clicking "deploy"? Yes. Was it worth it? Also yes — because now I understand every layer.

The site itself is Astro 5 with Tailwind v4. Astro does *static site generation* — meaning every page compiles to plain HTML at build time. No runtime. No database. No server-side rendering. Just files on disk that nginx hands to whoever asks.

I picked Astro specifically because I wanted a stack I could fully reason about. No framework magic, no opaque rendering layer, nothing to debug at 1am that I didn't already understand. Project pages are markdown files in what Astro calls *content collections* — basically a typed folder of `.md` files with a schema. Writing a new project page means dropping a `.md` file in and rebuilding. That's it.

## Hosting
Ubuntu Server 24.04 VM on the lab's Proxmox host. Hardened the way I'd want any internet-facing box hardened:

- SSH is key-only — no password auth, no exceptions
- UFW restricts inbound traffic to a tight allowlist
- fail2ban watches the auth log and bans IPs that brute-force
- nginx serves the built static files out of `/var/www/stevin-garcia.dev`
- Standard security headers — HSTS, X-Content-Type-Options, X-Frame-Options, Referrer-Policy

That last one took some reading. Each header does a specific thing — HSTS forces browsers to use HTTPS forever, X-Frame-Options prevents the site from being embedded in a malicious iframe, and so on. I added them because every "secure your nginx" guide says to, and now I actually know why.

## Deploy Pipeline
Source lives at `~/portfolio-site` on the VM and on GitHub. One shell script handles deploys:

```
git pull → npm install → npm run build → rsync dist/ to /var/www
```

That's it. No CI/CD pipeline, no GitHub Actions, no clever automation. And that's not laziness — it's a deliberate choice. The script runs in under 30 seconds, its failure modes are obvious, and I can trace every step if something breaks. I'll move to a proper pipeline eventually, but only when I have a real reason to. *Premature automation* is its own kind of technical debt.

## The Edge
Here's the part I'm most proud of: there are no inbound ports open on my home network. Zero.

Normally, hosting from home means port-forwarding 80 and 443 through your router, exposing your residential IP to the public internet, and praying. I do none of that. Instead, `cloudflared` runs on the web VM as a systemd service and establishes a persistent *outbound* connection to Cloudflare's edge — what's called a *Cloudflare Tunnel*.

Here's the flow:
1. Public request hits Cloudflare's edge servers
2. TLS 1.3 / HTTP/3 terminates at Cloudflare
3. The request rides the encrypted tunnel back to nginx on my VM
4. nginx serves the static file
5. Response goes back the same path

My residential IP never appears in public DNS. OPNsense (my perimeter firewall) never opens an inbound HTTP or HTTPS port. The only connection in or out is the outbound tunnel I initiated. For a site hosted from a home network, that combination of *zero exposed ports plus DDoS protection at the CDN edge* is honestly hard to beat.

## Monitoring
I wanted to know if the site went down *before* anyone tried to use it. So I set up real external monitoring.

A separate VM on the lab runs the observability stack — deliberately not the same host as the site, because a monitor that dies with its target isn't a monitor. Prometheus scrapes `blackbox_exporter` every 15 seconds, which probes three URLs through Cloudflare: the apex domain, the `www` subdomain, and a project page.

The trick: probing the *public* hostnames means I'm testing the full delivery path. Cloudflare edge → Tunnel → nginx → static file. If any link in that chain breaks — Cloudflare outage, tunnel down, nginx crashed, file missing — the probe fails and I find out within seconds. Probing the origin directly would only catch the last hop. Probing through the CDN catches all of them.

## Visualization
Grafana runs over HTTPS with a certificate signed by my lab's internal Enterprise Root CA. That sentence is doing a lot of work — what it means is that I built my own certificate authority inside Active Directory, issued a TLS cert to Grafana, and pushed the root CA to my browser so it actually trusts the cert. (That's a whole other project page; see ad-pki when it lands.)

The dashboard is called "Site Uptime — steven-garcia.dev." Adapted from a community Grafana dashboard (id 7587) with some customization. Tracks probe success, response time, and TLS certificate days remaining for each target. Useful as much for spotting patterns as catching incidents.

## Alerting
Alertmanager routes to a dedicated Discord webhook. Four rules cover the failure modes that actually matter:

- **SiteDown** — `probe_success == 0` for one minute
- **SiteSlow** — `probe_duration_seconds > 2` for five minutes
- **CertExpiringSoon** — fewer than 14 days remaining on the TLS certificate
- **CertExpired** — already past expiration

Tuning these took a couple iterations. First version was too aggressive — every blip became a ping. Second version went too far the other way — outages took forever to alert. Settled on 30-second group wait, 5-minute group interval, 4-hour repeat interval. Long enough to notify fast, short enough to confirm recovery, not so aggressive that a sustained outage spams Discord every minute.

## Hardening
Every monitoring service runs as a dedicated unprivileged user under a hardened systemd unit:

- `ProtectHome=yes` — can't read /home
- `ProtectSystem=strict` — filesystem is read-only by default
- `PrivateTmp=yes` — isolated /tmp
- `NoNewPrivileges=yes` — can't escalate via setuid

The Prometheus admin API is enabled but bound to localhost. Grafana is reachable only from the internal lab network — never through the public tunnel. None of this is strictly required for a personal site. I added it because hardened units are how real teams ship services, and I'd rather build that muscle now on a stack I control than learn it during an incident on something I don't.

## What I Learned
- Static site generation eliminates entire vulnerability classes — no PHP, no database, no runtime to compromise. The trade-off is no real dynamic content, but for a portfolio that's the right call.
- Cloudflare Tunnel is the cleanest way to host from a residential connection: no NAT punching, no dynamic DNS, no exposed origin IP. Should be the default pattern for any homelab serving public traffic.
- Probing through the CDN tests the full delivery path, not just origin health. That distinction matters when your edge layer is doing real work.
- Alert tuning is the difference between a pager you trust and a channel you mute by week two.
- A deploy script you fully understand beats a clever pipeline you don't.
