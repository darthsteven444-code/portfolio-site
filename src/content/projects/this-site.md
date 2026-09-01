---
title: "this-site"
description: "how this site is built, hosted, and watched, from astro source to discord alerts."
date: 2026-05-24
tags: ["astro", "nginx", "cloudflare-tunnel", "monitoring"]
---
## The Stack

Most personal sites get deployed to Vercel or Netlify with one click. Not this one. This runs on hardware I own, on a VM I built, behind a firewall I configured, watched by a monitoring stack I wired up myself. More work than clicking "deploy"? Absolutely. Worth it? Also absolutely, because now I understand every single layer.

The site is Astro 5 with Tailwind v4. Astro does *static site generation*, every page compiles to plain HTML at build time. No runtime. No database. No server-side rendering. Just files on disk that nginx hands to whoever asks.

I picked Astro on purpose: I wanted a stack I could fully reason about. No framework magic, no opaque rendering layer, nothing to debug at 1am that I didn't already understand. Project pages are markdown files in what Astro calls *content collections*. A typed folder of `.md` files with a schema. Writing a new project page means dropping in a `.md` file and rebuilding. That's the whole workflow.

## Hosting

Ubuntu Server 24.04 VM on the lab's Proxmox host, hardened the way I'd want any internet-facing box hardened:

- SSH is key-only, no password auth, no exceptions
- UFW restricts inbound traffic to a tight allowlist
- fail2ban watches the auth log and bans IPs that brute-force
- nginx serves the built static files out of `/var/www/steven-garcia.dev`
- Standard security headers, HSTS, X-Content-Type-Options, X-Frame-Options, Referrer-Policy

That last line took some reading. Each header does a specific job, HSTS forces browsers to HTTPS forever, X-Frame-Options blocks the site from being embedded in a malicious iframe, and so on. Every "secure your nginx" guide says to add them. Now I actually know *why* I added them.

## Deploy Pipeline

Source lives at `~/portfolio-site` on the VM and on GitHub. One shell script handles the whole deploy:

```
git pull → npm install → npm run build → rsync dist/ to /var/www
```

That's it. No CI/CD, no GitHub Actions, no clever automation. And that's not laziness. It's deliberate. The script runs in under 30 seconds, its failure modes are obvious, and I can trace every step when something breaks. I'll graduate to a real pipeline when I have a real reason to. *Premature automation* is its own flavor of technical debt.

## The Edge

Here's the part I'm most proud of: there are zero inbound ports open on my home network. None.

Normally, hosting from home means port-forwarding 80 and 443 through your router, exposing your residential IP to the whole internet, and hoping for the best. I do none of that. Instead, `cloudflared` runs on the web VM as a systemd service and holds a persistent *outbound* connection to Cloudflare's edge. A *Cloudflare Tunnel*.

The flow:

1. Public request hits Cloudflare's edge servers
2. TLS 1.3 / HTTP/3 terminates at Cloudflare
3. The request rides the encrypted tunnel back to nginx on my VM
4. nginx serves the static file
5. Response heads back the same path

My residential IP never shows up in public DNS. OPNsense never opens an inbound HTTP/HTTPS port. The only connection in or out is the outbound tunnel *I* initiated. For a site hosted from a home network, zero exposed ports plus DDoS protection at the CDN edge is genuinely hard to beat.

## Monitoring

I wanted to know the site went down *before* anyone tried to use it. So I set up real external monitoring.

A separate VM runs the observability stack, deliberately not the same host as the site, because a monitor that dies with its target isn't a monitor. Prometheus scrapes `blackbox_exporter` every 15 seconds, probing three URLs through Cloudflare: the apex domain, the `www` subdomain, and a project page.

Here's the trick: probing the *public* hostnames tests the full delivery path, Cloudflare edge → Tunnel → nginx → static file. If any link breaks (Cloudflare outage, tunnel down, nginx crashed, file missing), the probe fails and I know within seconds. Probing the origin directly would only catch the last hop. Probing through the CDN catches all of them.

## Visualization

Grafana runs over HTTPS with a cert signed by my lab's internal Enterprise Root CA. That sentence is doing a lot of work: I built my own certificate authority inside Active Directory, issued a TLS cert to Grafana, and pushed the root CA to my browser so it actually trusts the thing. (Whole separate project, see ad-pki.)

The dashboard is "Site Uptime, steven-garcia.dev," adapted from a community Grafana dashboard (id 7587) with some customization. It tracks probe success, response time, and TLS cert days-remaining for each target. As useful for spotting patterns as for catching incidents.

## Alerting

Alertmanager routes to a dedicated Discord webhook. Four rules cover the failure modes that actually matter:

- **SiteDown**: `probe_success == 0` for one minute
- **SiteSlow**: `probe_duration_seconds > 2` for five minutes
- **CertExpiringSoon**: fewer than 14 days left on the TLS cert
- **CertExpired**: already past expiration

Tuning these took a couple passes. First version was too aggressive, every blip became a ping. Second swung too far the other way. Outages took forever to alert. Landed on 30-second group wait, 5-minute group interval, 4-hour repeat interval. Fast enough to notify, slow enough to confirm recovery, never so aggressive that a sustained outage spams Discord every minute.

## Hardening

Every monitoring service runs as a dedicated unprivileged user under a hardened systemd unit:

- `ProtectHome=yes`, can't read /home
- `ProtectSystem=strict`, filesystem read-only by default
- `PrivateTmp=yes`, isolated /tmp
- `NoNewPrivileges=yes`, can't escalate via setuid

The Prometheus admin API is enabled but bound to localhost. Grafana is reachable only from the internal lab network, never through the public tunnel. None of this is strictly required for a personal site. I added it because hardened units are how real teams ship services, and I'd rather build that muscle now, on a stack I control, than learn it mid-incident on something I don't.

## What I Learned

- Static site generation kills entire vulnerability classes, no PHP, no database, no runtime to compromise. The trade-off is no real dynamic content, but for a portfolio that's the right call.
- Cloudflare Tunnel is the cleanest way to host from a residential connection: no NAT punching, no dynamic DNS, no exposed origin IP. It should be the default pattern for any homelab serving public traffic.
- Probing through the CDN tests the full delivery path, not just origin health. That distinction matters when your edge is doing real work.
- Alert tuning is the difference between a pager you trust and a channel you mute by week two.
- A deploy script you fully understand beats a clever pipeline you don't.

## Update, July 2026

Two big changes since launch: the site got a face, and it got a live demo wing.

## The Terminal Theme

The first version of this site looked like every other developer portfolio, clean, minimal, forgettable. So I rebuilt the front end as a full terminal aesthetic: prompt-style headers, monospace everything, project pages that read like a session log instead of a resume bullet.

Design choice? Sure. But also a filter. The people I want reading this site, hiring managers for datacenter and infrastructure roles. See a terminal and feel at home. The theme *is* the message: this person lives in a shell.

Same Astro content collections underneath. The redesign touched layouts and CSS, not the pipeline. Drop in a `.md` file, rebuild, done. That workflow survived the facelift untouched, which was the whole point of picking a stack I could reason about.

## The Helpdesk Wing

New subdomain: `helpdesk.steven-garcia.dev`, a live GLPI helpdesk instance anyone can log into with demo credentials.

Why run a real ticketing system on the public internet? Because "I set up a helpdesk lab" on a resume is a claim. A URL a hiring manager can click, log into, and poke around in is *proof*. Tickets, asset inventory, knowledge base articles. The stuff a Tier 1 tech actually touches, running live.

The security model is the interesting part. GLPI is a PHP app with a database, exactly the attack surface this site was built to avoid. So it doesn't face the internet raw. It sits behind Cloudflare Access: every request has to pass Cloudflare's authentication layer before it ever reaches the tunnel, and the origin still exposes zero inbound ports. Same edge pattern as the main site, with an identity check bolted on in front. Defense in depth, on a residential connection, for free.

## What I've Learned Since

- A portfolio's design is a signal, not decoration. Build for the audience you actually want.
- Static-only is a great default, but the moment you need a dynamic app, an identity-aware proxy like Cloudflare Access lets you serve it without abandoning the zero-open-ports model.
- Demo credentials beat screenshots. Let people touch the thing.
