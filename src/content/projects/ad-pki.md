---
title: "ad-pki"
description: "windows server domain controller, enterprise root ca, custom certificate templates. The identity and trust backbone of the lab."
date: 2026-05-26
tags: ["windows-server", "active-directory", "pki", "tls"]
---
## The Setup

Active Directory and PKI show up on every IT job description on the planet, and no tutorial makes them actually *click* until you've built one with your own hands. So I did. A Windows Server 2022 domain controller, a real Enterprise Root CA running on it, and custom certificate templates issuing genuinely trusted TLS certs to my lab services.

This is the project that turned "I know what these acronyms mean" into "I know how they actually work." Big difference. That's the whole game.

## The Domain Controller

`dc01.lab.local` runs Windows Server 2022 with the *Active Directory Domain Services* role. AD DS is the identity backbone, user accounts, group memberships, computer accounts, group policy, and DNS for the entire `lab.local` domain all live here.

When I promoted the server to a domain controller, the wizard built the forest (`lab.local`) and the first domain inside it. That installed AD DS, made the server the *primary DNS* for the domain, and stood up the *NTDS database*. The local Jet database where every directory object actually lives. Every user, every group, every OU, every certificate template. They're all rows in that database. Wrap your head around that and AD stops being magic.

## DNS and DHCP

The DC is also the primary DNS server for the whole lab. Every client queries it to resolve internal hostnames like `dc01.lab.local`, `grafana.lab.local`, or `opnsense.lab.local`.

DHCP runs separately on a *Kea DHCP server* (the modern ISC replacement) and hands out addresses to clients across every VLAN. The scope is configured to push the DC as primary DNS, so when a Windows 11 client boots, it grabs an IP, gets the DC as DNS, queries the DC for the domain, and joins with one click.

Here's what most "set up Active Directory" tutorials skip right past: DNS and DHCP aren't decorations, they're the *plumbing* that makes domain join work at all. Wrong DNS? The client can't even find the DC. No DHCP pushing the right DNS server? Every machine needs manual config. Get this part right and everything else just falls into place.

## Group Policy

Group Policy sounds boring until it clicks that this is how *every* Windows enterprise on Earth enforces configuration at scale.

I configured a real password policy through *Default Domain Policy*:

- 12-character minimum length
- 90-day rotation
- Account lockout after 5 failed attempts (15-minute lockout)
- Password history of 24, no recycling your last 24 passwords

That's not compliance theater. Those are roughly the numbers a corporate IT team enforces on day one. Every domain-joined client inherits the policy automatically, and there's no opting out.

I also built a real *Organizational Unit* structure, not a flat pile, but organized: Servers OU, Workstations OU, Service Accounts OU, each with its own GPO scope. That's how real AD environments look, and building the habit now saves a mess later.

## PKI, The Part That Made It Click

Here's where AD levels up from "user database with DNS" to "trust authority for the entire domain."

I installed *Active Directory Certificate Services* (AD CS) on the DC and stood it up as an *Enterprise Root CA*, `lab-Root-CA`. An Enterprise CA differs from a Standalone CA in one massive way: it's *integrated with Active Directory*. Certs can auto-enroll, templates are managed in AD, and. The magic part. The root CA certificate gets pushed to every domain-joined client automatically through Group Policy.

Translation: every Windows client on the domain trusts my CA right out of the box. No manual import. No "your connection is not private." Just real, browser-trusted HTTPS on internal services.

That's the whole point of an Enterprise CA, scale trust across the domain without paying Let's Encrypt or DigiCert a dime for every internal service.

## Custom Certificate Templates

The built-in templates work, but they're limited. The default Web Server template won't allow *Subject Alternative Names (SANs)*, meaning one cert can only secure exactly one hostname. That's a dealbreaker for modern TLS, where SAN-based certs are the standard.

So I authored my own template. Here's the play:

1. Open the *Certificate Templates* console (`certtmpl.msc`)
2. Duplicate the default Web Server template
3. Rename it (`Web Server with SAN`)
4. *Subject Name* tab → switch to "Supply in the request" so the requester provides the subject, not AD
5. *Extensions* tab → enable *Subject Alternative Name* support
6. *Security* tab → grant Enroll permission to the right group
7. Publish it via the *Certification Authority* console (`certsrv.msc`)

Looks simple written out. Cost me an embarrassing amount of trial and error the first time, wrangling the right permissions on the right group, figuring out which extensions actually matter, and learning the hard way that a template has to be *both* defined AND *published* before clients can see it.

But once it works? You've got a reusable pattern for any internal cert you'll ever need, multi-hostname web servers, code signing, user auth, whatever. Define the template once. Issue against it forever.

## Issuing Real Certificates

With the template live, I issued real TLS certs to two lab services:

- **OPNsense web UI**: `https://opnsense.lab.local`, with a SAN covering both the FQDN and the short hostname
- **Grafana**: `https://grafana.lab.local`, same pattern

The flow for each: generate a *Certificate Signing Request* (CSR) on the target server, paste it into the *Web Enrollment* page on the CA (`https://dc01.lab.local/certsrv`), pick the `Web Server with SAN` template, download the issued cert, install it.

The first time I hit `https://grafana.lab.local` from a domain-joined client and saw the green padlock, no warning, no override, just trusted HTTPS. *that* was the moment the whole thing clicked. I built a real CA. I issued a real cert. Real Windows trusts it. That's enterprise PKI in miniature, running on hardware in my office.

## What This Unlocks

Every internal service in the lab can now have real trusted HTTPS without paying anyone or jumping through hoops:

- Grafana ✅ (issued)
- OPNsense web UI ✅ (issued)
- Any future internal service (Prometheus, Loki, ArgoCD, internal k8s ingress). The template's already built and the trust chain's already pushed to clients. Just issue another cert.

That's the line between a hobby setup and an enterprise pattern. Once the PKI is in place, every new service inherits trust for free.

## What I Learned

- *Active Directory* isn't "user accounts in a database", it's identity, DNS, group policy, and trust, all fused into one system. That fusion is the entire point.
- *DNS and DHCP* are the plumbing that makes domain join work. Any tutorial that skips them is setting you up to fail.
- *Group Policy* is how enterprises enforce config at scale. Once it's working, you stop touching individual machines.
- *Enterprise CAs* are the cleanest way to scale TLS trust internally, push the root once via GPO, every service gets browser-trusted HTTPS free.
- *Custom certificate templates* are where AD CS goes from "issues certs" to "issues exactly the certs your environment needs." SAN support alone earns its keep.
- *PKI hierarchies in production* usually run tiered, an offline Root CA signing an Issuing CA that hands out the day-to-day certs. I ran flat (Root = Issuing) for simplicity. Splitting the roles is the next iteration.
