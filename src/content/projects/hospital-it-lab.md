---
title: "hospital-it-lab"
description: "an isolated hospital IT environment — active directory, hardened workstations, a GLPI service desk, and zero-trust browser RDP, all sealed off from production."
date: 2026-06-07
tags: ["active-directory", "group-policy", "glpi", "cloudflare-zero-trust", "hipaa"]
---
## The Setup

Anybody can list "Active Directory" on a résumé. I wanted to *show* it. So I built a tiny hospital — the kind of environment a help desk tech or systems admin actually walks into on day one — and wired it up the way a real regulated shop would.

The whole thing lives on its own firewalled network segment and its own Active Directory forest. It's a hospital *in a jar*: fully functional on the inside, completely sealed off from anything real. Three ideas drove every decision, because in healthcare IT they're everything — **least privilege, audit logging, and segmentation**.

Three machines, one isolated VLAN, zero paths into production. If something in here ever got popped, the blast radius is zero. That's segmentation doing its job.

## The Layout

Everything runs as virtual machines on Proxmox, on a dedicated VLAN (`192.168.50.0/24`) carved out on OPNsense. Firewall rules let the lab reach the internet for updates — and block every single path into my production subnets.

- **DC-DEMO** — Windows Server 2022. The brain: domain controller for `demo.lab`, plus DNS and DHCP for the segment.
- **WIN11-DEMO** — Windows 11. A domain-joined clinical workstation — this is where you *see* the policies and account management actually happen.
- **GLPI-DEMO** — Ubuntu Server 24.04. The help desk: GLPI in Docker, published to the internet through a Cloudflare Tunnel.

## The Brain — Active Directory

`DC-DEMO` runs a brand-new Active Directory forest, `demo.lab`, that I stood up and promoted from nothing. It also runs the plumbing the whole domain leans on:

- *AD Domain Services* — the forest itself.
- *DNS* — the domain's resolver. AD literally will not work without it.
- *DHCP* — hands out addresses and points every client at the right DNS and gateway automatically.

## Organized Like a Real Hospital

I didn't dump users in a pile. I built an *Organizational Unit* structure that mirrors an actual hospital, with role-based security groups — the exact thing a help desk tech lives in every day.

- **The org chart:** `Hospital > Departments (Nursing, Providers, IT)`, plus Workstations, Groups, and ServiceAccounts.
- **The groups:** `Nursing-Staff`, `Providers`, `IT-Helpdesk` — these drive who can do what, and who tickets get assigned to.
- **The robot:** a dedicated, *read-only* service account the help desk uses to query the directory. Read-only on purpose — least privilege means it only gets what it needs.

## Locking It Down — Group Policy, HIPAA-Style

Here's where it gets fun. I pushed one *Group Policy Object* across the Hospital OU that enforces the kind of controls a HIPAA shop actually requires on any machine that touches patient data:

- **Screen auto-locks** after sitting idle. Walk away, it locks. Done.
- **A legal logon banner** at every sign-in — "authorized use only, you're being monitored." Standard healthcare move.
- **USB storage is blocked.** Nobody's walking out with patient data on a thumb drive.
- **A hardened password policy** — length, complexity, expiration, and lockout after too many bad attempts.

Every workstation inherits it automatically from the domain. No per-machine config, no opting out.

## The Help Desk — and the SSO Trick

The service desk is *GLPI* running in Docker on the Ubuntu box, and here's the part I'm proud of: it authenticates against the **same Active Directory over LDAP**. So a nurse logs into the help desk with the *exact* account she uses on her workstation. One identity, everywhere — that's real single sign-on.

I set it up like a real shop, too: hospital ticket categories, SLAs, technician profiles (staff are self-service, IT folks are technicians — least privilege again), and a knowledge base. Every ticket logs full history, so you always know who touched what. That's your audit trail.

And it's live on the internet through an **outbound-only Cloudflare Tunnel** — meaning I opened *zero* inbound ports on the firewall. The tunnel reaches out; nothing reaches in.

## Zero-Trust Browser RDP

For remote review, I didn't want to hand anyone a VPN client or make them install anything. So I stood up *Cloudflare Access for Infrastructure* with browser-rendered RDP.

A reviewer goes to a link, enters their email, gets a one-time PIN, and lands on a launcher with a tile for each machine. Click a tile, and a full Windows desktop opens **right in the browser** — gated by an email allow-list, logged on every connection, working on any OS with zero setup.

Why Cloudflare instead of a peer-to-peer VPN? My lab sits behind T-Mobile Home Internet — carrier-grade NAT — stacked on top of an OPNsense VLAN. That's double, even triple NAT, and it's exactly the situation where a mesh VPN can't punch a direct path and falls back to a laggy relay. Cloudflare Tunnel is outbound-only and doesn't care about NAT at all. Right tool for the constraint.

## Broke It, Fixed It

The build taught me as much in its failures as its wins:

- **CGNAT is a wall — go around it.** Once I understood *why* peer-to-peer kept relaying, the Cloudflare Tunnel approach was obvious.
- **The silent-failure step is the one that matters.** Browser-RDP needs a Gateway "allow infrastructure target" policy that breaks everything quietly if it's missing. Reading the docs beat guessing.
- **Never saw off the branch you're sitting on.** Force-restarting Remote Desktop Services *while connected over RDP* locks you out. I learned the recovery path — console access — the hard way, then documented it so I never repeat it.
- **Authentication is a stack, not a switch.** FreeRDP defaulting to Kerberos, a server demanding NLA, TLS negotiation — each failure had a specific cause and a specific fix. Reading the actual error beats pattern-matching every time.

## What This Proves I Can Do

- **Active Directory:** stand up a forest, DNS, DHCP, design OUs and groups, run the full account lifecycle.
- **Endpoint & security policy:** Group Policy, workstation hardening, password and lockout policy, lining it all up with HIPAA.
- **Service management:** GLPI / ITIL ticketing, SLAs, knowledge base, role-based access, audit logging.
- **Networking & security:** VLAN segmentation, firewall rule design, identity-based remote access, publishing a service without opening a single inbound port.
- **Linux & containers:** Ubuntu Server, Docker / Compose, exposing a service safely through Cloudflare Tunnel.

Built it. Broke it. Fixed it. Documented it. Let's talk.
