---
title: "homelab"
description: "multi-vlan proxmox lab — active directory, pki, opnsense, monitoring, and a whole lot of learning."
date: 2026-05-23
tags: ["proxmox", "active-directory", "opnsense", "monitoring"]
---
## The Lab
Most people learn IT from a textbook or a $15/month sandbox in someone else's cloud. I wanted something I could actually break. So I built a real lab — on real hardware, running real enterprise software, behaving like a real production network. Smaller than what a Fortune 500 runs, sure. But every concept is the same.

The hardware is a Dell Precision T7910 — dual Intel Xeon E5-2699 v4 processors (22 cores each, 88 threads total), 128 GB of RAM, mixed-SSD RAID for fast VM storage plus a 4-drive SAS pool running ZFS for bulk retention. It runs *Proxmox VE* as the hypervisor — basically an open-source equivalent to VMware ESXi, except free and with a web UI that doesn't feel like it's stuck in 2008.

One physical box, a couple dozen VMs, segmented like a real corporate network.

## The Network
Here's the part that took the longest to get right: *the network*.

OPNsense — an open-source BSD-based firewall — fronts the entire stack as the perimeter. Everything goes through it. Inside that perimeter, I split the lab into five VLANs, each one isolated from the others by default:

- **LAN (1)** — flat home network, the "outside world" from the lab's perspective
- **MGMT (10)** — admin access to hypervisors and infrastructure
- **Servers (20)** — domain controller, web server, monitoring stack
- **Clients (30)** — domain-joined workstations
- **DMZ (40)** — Kali Linux for offensive testing, Metasploitable for targets

Inter-VLAN traffic is *default-deny*. Meaning: by default, nothing on one VLAN can talk to anything on another VLAN. Period. Want a Clients machine to talk to a Servers machine? You have to explicitly allow the specific ports for the specific protocols.

In my case, only the required Active Directory ports (LDAP, SMB, DNS) are allowed from Clients → Servers. Everything else has to be deliberately permitted. That's how real enterprise networks are built — *zero trust* between segments — and it's a completely different mindset from "everything on the same network can see everything else," which is what most home labs default to.

Writing those rules was the first time I really understood *why* network segmentation matters. If a Clients machine gets compromised, the attacker can't just freely pivot to my domain controller. They'd have to find a way through the explicit firewall rules first.

## Active Directory
A Windows Server 2022 domain controller (`dc01.lab.local`) runs *Active Directory Domain Services* — the identity backbone that virtually every Windows-based enterprise on the planet uses. AD handles user accounts, group memberships, group policy, and DNS for the entire lab.

A *Kea DHCP server* hands out IP addresses to clients across every VLAN, configured to push the DC as the primary DNS server. So when a Windows 11 client boots up, it gets an IP from DHCP, gets the DC's address as DNS, queries the DC to find the domain, joins as a member, and is fully governed by Group Policy within minutes.

Speaking of Group Policy — I configured it to enforce a real password policy: 12-character minimum, 90-day rotation, account lockout after 5 failed attempts. That's not just compliance theater. That's the actual baseline security a corporate IT team would enforce on day one.

## PKI
This was the section that made me feel like I was actually learning enterprise IT.

I built an *Enterprise Root CA* on the domain controller — a Public Key Infrastructure that issues TLS certificates trusted by every domain-joined client automatically. Then I went one step further and authored a custom *Web Server certificate template* with *Subject Alternative Name (SAN) support* — meaning a single cert can secure multiple hostnames (`grafana.lab.local`, `opnsense.lab.local`, etc.).

With the template in place, I issued real trusted TLS certs to the OPNsense web UI and a Linux Grafana server. The root certificate gets pushed to all domain-joined clients via Group Policy, so every issued cert is browser-trusted out of the box. No more "your connection is not private" warnings. No more clicking through certificate errors. Just real HTTPS on internal services, the way enterprises actually do it.

That's the whole point of an internal PKI: scale trust without paying Let's Encrypt or DigiCert for every internal service.

## Monitoring
You can't manage what you can't measure. So I built an observability stack.

*Prometheus* runs on a dedicated Ubuntu VM and scrapes metrics from:

- `node_exporter` on Linux hosts (CPU, memory, disk, network)
- `windows_exporter` on the DC and a Windows 11 client (same metrics, Windows flavor)
- `os-node_exporter` on OPNsense (firewall throughput, connection counts, interface stats)

*Grafana* runs on HTTPS with a lab-CA-signed certificate (one of the certs I issued from the PKI above — full circle) and hosts dashboards for node health, Windows Server resources, and OPNsense throughput. Now when something gets slow or breaks, I can actually point at the graph that proves it.

## AI Infrastructure
One VM is dedicated to local AI. I used *PCI passthrough* — a Proxmox feature that gives a VM direct, exclusive access to a physical PCI device, bypassing the hypervisor — to hand an NVIDIA Quadro P4000 (8 GB VRAM) straight to the VM.

The VM runs *Ollama*, a local LLM host, so I can run open-source language models without sending a single byte to OpenAI or Anthropic. Data never leaves the lab. Privacy is the entire point.

Configuring PCI passthrough was a rabbit hole all on its own — IOMMU groups, VFIO drivers, blacklisting the host's nouveau driver so it doesn't grab the GPU at boot. Worth it.

## Self-Hosted Services
*CasaOS* runs on its own VM as a container dashboard — basically a friendly web UI for managing a stack of self-hosted Docker containers:

- **Jellyfin** — open-source media server, similar to Plex. An NVIDIA GTX 1650 is passed through for hardware-accelerated video transcoding (NVENC/NVDEC), which means it can re-encode 4K streams in real time without the CPU breaking a sweat.
- **Shoko Server** — anime library manager with a SQLite/MySQL backend on the SSD tier, tuned for fast hash and metadata processing across thousands of files
- **Audiobookshelf** — self-hosted audiobook library, accessible from mobile and web

Two GPUs, two purposes: the Quadro P4000 for AI, the GTX 1650 for video. Both physical cards. Both pinned to specific VMs. Both doing real work.

## What I Learned
- *VLAN design and inter-VLAN firewall rule authoring* in OPNsense — and why "zero trust between segments" beats "everything on the same network"
- *Active Directory* OU structure, GPO authoring, password policy enforcement — the bones of every Windows enterprise
- *Certificate template design* and internal PKI — how to issue trusted TLS certs at scale without paying a public CA
- *Prometheus relabeling and dashboard editing* — making metrics actually useful instead of just numerous
- *PCI passthrough (IOMMU/VFIO)* for GPU-accelerated VMs — and how to wrestle the host kernel into giving up a device
- The difference between *"it works"* and *"it's hardened"* — and how to get from one to the other
