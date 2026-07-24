---
title: "homelab"
description: "multi-vlan proxmox lab — active directory, pki, opnsense, monitoring, and a whole lot of learning."
date: 2026-05-23
tags: ["proxmox", "active-directory", "opnsense", "monitoring"]
---
## The Lab

Most people learn IT from a textbook or a $15/month sandbox sitting in someone else's cloud. I wanted something I could actually *break*. So I built a real lab — real hardware, real enterprise software, behaving like a real production network. Smaller than what a Fortune 500 runs, sure. But every concept is identical.

The hardware is a Dell Precision T7910 — dual Intel Xeon E5-2699 v4 CPUs (22 cores each, 88 threads total), 128 GB of RAM, mixed-SSD RAID for fast VM storage, plus a 4-drive SAS pool running ZFS for bulk retention. It runs *Proxmox VE* as the hypervisor — basically the open-source answer to VMware ESXi, except free and with a web UI that doesn't feel stuck in 2008.

One physical box. A couple dozen VMs. Segmented like a real corporate network.

## The Network

Here's the part that took the longest to get right: *the network*. And it's the part I'm proudest of.

OPNsense — an open-source BSD-based firewall — fronts the entire stack as the perimeter. Everything routes through it. Inside that perimeter, I carved the lab into five VLANs, each isolated from the others by default:

- **LAN (1)** — flat home network, the "outside world" from the lab's view
- **MGMT (10)** — admin access to hypervisors and infrastructure
- **Servers (20)** — domain controller, web server, monitoring stack
- **Clients (30)** — domain-joined workstations
- **DMZ (40)** — Kali Linux for offensive testing, Metasploitable for targets

Inter-VLAN traffic is *default-deny*. Nothing on one VLAN can talk to anything on another, period. Want a Clients machine to reach a Servers machine? You explicitly allow the specific ports for the specific protocols — or it doesn't happen.

In my case, only the required Active Directory ports (LDAP, SMB, DNS) are allowed Clients → Servers. Everything else has to be deliberately permitted. That's how real enterprise networks are built — *zero trust between segments* — and it's a completely different mindset from the "everything on one flat network can see everything" that most home labs default to.

Writing those rules was the first time I really *got* why segmentation matters. If a Clients machine gets popped, the attacker can't just stroll over to my domain controller. They've got to beat the explicit firewall rules first. That's the whole idea.

## Active Directory

A Windows Server 2022 domain controller (`dc01.lab.local`) runs *Active Directory Domain Services* — the identity backbone behind basically every Windows enterprise on the planet. AD handles user accounts, group memberships, group policy, and DNS for the entire lab.

A *Kea DHCP server* hands out addresses across every VLAN, configured to push the DC as primary DNS. So a Windows 11 client boots, grabs an IP, gets the DC as DNS, queries it for the domain, joins as a member, and is fully governed by Group Policy within minutes. One click.

And Group Policy enforces a real password policy: 12-character minimum, 90-day rotation, lockout after 5 failed attempts. Not compliance theater — that's the actual baseline a corporate IT team enforces on day one.

## PKI

This was the section that made me feel like I was genuinely learning *enterprise* IT, not just lab tinkering.

I built an *Enterprise Root CA* on the domain controller — a Public Key Infrastructure that issues TLS certs trusted by every domain-joined client automatically. Then I went a step further and authored a custom *Web Server certificate template* with *Subject Alternative Name (SAN) support*, so one cert can secure multiple hostnames (`grafana.lab.local`, `opnsense.lab.local`, and so on).

With the template in place, I issued real trusted TLS certs to the OPNsense web UI and a Linux Grafana server. The root cert gets pushed to all domain-joined clients via Group Policy, so every issued cert is browser-trusted out of the box. No "your connection is not private." No clicking through cert errors. Just real HTTPS on internal services, the way enterprises actually do it.

That's the entire point of an internal PKI: scale trust without paying a public CA for every service.

## Monitoring

You can't manage what you can't measure. So I built an observability stack.

*Prometheus* runs on a dedicated Ubuntu VM and scrapes metrics from:

- `node_exporter` on Linux hosts (CPU, memory, disk, network)
- `windows_exporter` on the DC and a Windows 11 client (same metrics, Windows flavor)
- `os-node_exporter` on OPNsense (firewall throughput, connection counts, interface stats)

*Grafana* runs over HTTPS with a lab-CA-signed cert — one of the certs I issued from the PKI above, full circle — and hosts dashboards for node health, Windows Server resources, and OPNsense throughput. Now when something slows down or breaks, I can point at the exact graph that proves it.

## AI Infrastructure

One VM is dedicated to local AI. I used *PCI passthrough* — a Proxmox feature that hands a VM direct, exclusive access to a physical PCI device, bypassing the hypervisor — to give an NVIDIA Quadro P4000 (8 GB VRAM) straight to the VM.

That VM runs *Ollama*, a local LLM host, so I can run open-source models without shipping a single byte to OpenAI or Anthropic. Data never leaves the lab. Privacy is the entire point.

Configuring passthrough was a rabbit hole all by itself — IOMMU groups, VFIO drivers, blacklisting the host's nouveau driver so it doesn't grab the GPU at boot. Worth every minute.

## Self-Hosted Services

*CasaOS* runs on its own VM as a container dashboard — a friendly web UI over a stack of self-hosted Docker containers:

- **Jellyfin** — open-source media server, Plex-style. An NVIDIA GTX 1650 is passed through for hardware-accelerated transcoding (NVENC/NVDEC), so it re-encodes 4K streams in real time without the CPU breaking a sweat.
- **Shoko Server** — anime library manager with a SQLite/MySQL backend on the SSD tier, tuned for fast hashing and metadata across thousands of files
- **Audiobookshelf** — self-hosted audiobook library, on mobile and web

Two GPUs, two jobs: the Quadro P4000 for AI, the GTX 1650 for video. Both physical cards, both pinned to specific VMs, both doing real work.

## What I Learned

- *VLAN design and inter-VLAN firewall rules* in OPNsense — and why "zero trust between segments" beats "everything on one network"
- *Active Directory* OU structure, GPO authoring, password policy — the bones of every Windows enterprise
- *Certificate template design* and internal PKI — issuing trusted TLS at scale without a public CA
- *Prometheus relabeling and dashboard editing* — making metrics useful, not just numerous
- *PCI passthrough (IOMMU/VFIO)* for GPU-accelerated VMs — and how to wrestle the host kernel into giving up a device
- The difference between *"it works"* and *"it's hardened"* — and how to get from one to the other

## Where It's Going Now

That lab was the foundation. Since then, the story moved up the stack — from *building* the infrastructure to *defending, backing up, and automating* it. The portfolio site you're reading now runs on a three-node Kubernetes cluster inside this lab, and I've spent a run of late nights turning it into something that behaves like a real production environment:

- **[Hardening a Kubernetes Cluster](/projects/k8s-security-hardening)** — image scanning, RBAC least-privilege, Pod Security Standards, default-deny networking, and proving detection with a live attack against my own cluster.
- **[Backups That Actually Restore](/projects/backup-dr)** — a two-layer disaster-recovery strategy for the cluster and its VMs, restore-tested by deliberately deleting things.
- **[Building the Pipeline That Ships This Site](/projects/cicd-pipeline)** — a GitHub Actions CI/CD pipeline that builds a hardened, non-root container image and publishes it automatically on every version tag.

Same box. Same lab. A whole lot more *hardened* than where it started.
