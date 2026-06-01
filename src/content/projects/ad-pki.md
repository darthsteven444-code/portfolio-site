---
title: "ad-pki"
description: "windows server domain controller, enterprise root ca, custom certificate templates — the identity and trust backbone of the lab."
date: 2026-05-26
tags: ["windows-server", "active-directory", "pki", "tls"]
---
## The Setup
Active Directory and PKI are the kind of thing every IT job description mentions, but no tutorial really makes them click until you've built one yourself. So I did. A Windows Server 2022 domain controller, a real Enterprise Root CA running on it, and custom certificate templates issuing real trusted TLS certs to my lab services.

This is the part of the homelab that turned "I know what these acronyms mean" into "I know how they actually work."

## The Domain Controller
`dc01.lab.local` runs Windows Server 2022 with the *Active Directory Domain Services* role installed. AD DS is the identity backbone — it handles user accounts, group memberships, computer accounts, group policy, and DNS for the entire `lab.local` domain.

When I promoted the server to a domain controller, the wizard walked me through creating the forest (`lab.local`) and the first domain inside it. That installed AD DS, configured the server as the *primary DNS* for the domain, and set up the *NTDS database* — the local Jet database where every directory object actually lives. Every user account, every group, every OU, every certificate template — they're all rows in that database.

## DNS and DHCP
The DC is also the primary DNS server for the entire lab. Every client queries it to resolve internal hostnames like `dc01.lab.local`, `grafana.lab.local`, or `opnsense.lab.local`.

DHCP runs separately on a *Kea DHCP server* (the modern ISC replacement) and hands out IP addresses to clients across every VLAN. The DHCP scope is configured to push the DC as the primary DNS — so when a Windows 11 client boots up, it gets an IP, gets the DC as DNS, queries the DC for the domain, and is ready to join with one click.

This is the part most "set up Active Directory" tutorials skip — DNS and DHCP aren't optional decorations, they're the *plumbing* that makes domain joining work. Without correct DNS, a client can't even find the DC. Without DHCP pushing the right DNS server, every machine needs manual config. Get this part right and the rest just works.

## Group Policy
Group Policy is one of those features that sounds boring until you realize it's how every Windows enterprise on the planet enforces configuration at scale.

I configured a real password policy via *Default Domain Policy*:

- 12-character minimum length
- 90-day rotation
- Account lockout after 5 failed attempts (15-minute lockout duration)
- Password history of 24 (can't reuse your last 24 passwords)

That's not just compliance theater. Those numbers are roughly what a corporate IT team would enforce on day one. Every domain-joined client inherits the policy automatically, and there's no way for a user to opt out.

I also set up an *Organizational Unit* (OU) structure — not flat, but actually organized. Servers OU, Workstations OU, Service Accounts OU, each with its own GPO scope. That's how real AD environments are structured, and getting in the habit of organizing things properly now saves a mess later.

## PKI — The Part That Made It Click
Here's where Active Directory goes from "user database with DNS" to "trust authority for the whole domain."

I installed *Active Directory Certificate Services* (AD CS) on the DC and configured it as an *Enterprise Root CA* — named `lab-Root-CA`. An Enterprise CA is different from a Standalone CA in one critical way: it's *integrated with Active Directory*. Certificates can be auto-enrolled, templates are managed in AD, and most importantly — the root CA certificate gets pushed to every domain-joined client automatically via Group Policy.

Translation: every Windows client on the domain trusts my CA out of the box. No manual import. No "your connection is not private" warnings. Just real, browser-trusted HTTPS on internal services.

That's the whole magic of an Enterprise CA. Scale trust without paying Let's Encrypt or DigiCert for every internal service.

## Custom Certificate Templates
Built-in certificate templates work, but they're limited. The default Web Server template, for example, doesn't allow *Subject Alternative Names (SANs)* — which means every certificate can only secure exactly one hostname. That's a deal-breaker for modern TLS, where SAN-based certs are the standard.

So I authored a custom template. Here's what that involved:

1. Open the *Certificate Templates* console (`certtmpl.msc`)
2. Duplicate the default Web Server template
3. Rename it (`Web Server with SAN`)
4. On the *Subject Name* tab, switch to "Supply in the request" — meaning the requester provides the subject, not AD
5. On the *Extensions* tab, enable *Subject Alternative Name* support
6. On the *Security* tab, grant Enroll permission to the right group
7. Publish the template via the *Certification Authority* console (`certsrv.msc`)

Sounds simple. Took me an embarrassing amount of trial and error the first time — getting the right permissions on the right group, figuring out which extensions actually matter, learning that the template has to be *both* defined AND *published* before it shows up to clients.

But once it works, you have a reusable pattern for issuing any kind of internal cert — multi-hostname web servers, code signing certs, user auth certs, whatever. You define the template once. Then you issue certs against it whenever you need them.

## Issuing Real Certificates
With the custom template in place, I issued real TLS certs to two lab services:

- **OPNsense web UI** — `https://opnsense.lab.local` with a SAN covering both the FQDN and the short hostname
- **Grafana** — `https://grafana.lab.local`, same pattern

The process for each: generate a *Certificate Signing Request* (CSR) on the target server, paste the CSR into the *Web Enrollment* page on the CA (`https://dc01.lab.local/certsrv`), select the `Web Server with SAN` template, download the issued cert, install it on the service.

The first time I hit `https://grafana.lab.local` from a domain-joined client and saw the green padlock — no warnings, no overrides, just trusted HTTPS — that was the moment the whole thing clicked.

I built a real CA. I issued a real cert. Real Windows trusts it. That's enterprise PKI in miniature, running on hardware in my office.

## What This Unlocks
Every internal service in the lab can now have real trusted HTTPS without paying anyone or jumping through hoops:

- Grafana ✅ (issued)
- OPNsense web UI ✅ (issued)
- Any future internal service (Prometheus, Loki, ArgoCD, k8s ingress for internal endpoints) — already have the template, already have the trust chain pushed to clients. Just issue another cert.

That's the difference between a hobby setup and an enterprise pattern. Once the PKI is in place, every new service inherits it for free.

## What I Learned
- *Active Directory* isn't just "user accounts in a database" — it's identity, DNS, group policy, and trust, all integrated into one system. That integration is the whole point.
- *DNS and DHCP* aren't optional infrastructure — they're the plumbing that makes domain join work. Tutorials that skip this part are setting you up to fail.
- *Group Policy* is how enterprises enforce configuration at scale. Once you have it working, you stop configuring individual machines.
- *Enterprise CAs* are the cleanest way to scale TLS trust internally. Push the root once via GPO, and every internal service gets browser-trusted HTTPS for free.
- *Custom certificate templates* are where AD CS goes from "issues certs" to "issues exactly the certs your environment needs." SAN support alone is worth the effort.
- *PKI hierarchies in production* usually run a tiered CA model — an offline Root CA that signs an Issuing CA, which is what actually hands out day-to-day certs. I ran flat for the lab (Root CA = Issuing CA) because it's simpler. The next iteration will probably split the roles.
