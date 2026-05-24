---
title: "homelab"
description: "Multi-VLAN Proxmox lab running Active Directory, PKI, monitoring, and services."
date: 2026-05-23
tags: ["proxmox", "active-directory", "opnsense", "monitoring"]
---

## The Lab

Dell Precision T7910 — dual Intel Xeon E5-2699 v4 @ 2.2 GHz (22 cores each, 88 threads total), 128 GB RAM, running Proxmox VE as the hypervisor. Mixed-SSD RAID handles fast VM delivery, and a 4-drive SAS ZFS pool handles bulk retention.

## Network

OPNsense fronts the entire stack as the perimeter firewall, with five VLANs separating concerns:

- **LAN (1)** — flat home network
- **MGMT (10)** — admin access to hypervisors and infrastructure
- **Servers (20)** — domain controller, web server, monitoring
- **Clients (30)** — domain-joined workstations
- **DMZ (40)** — Kali Linux for offensive testing, Metasploitable for targets

Inter-VLAN traffic is default-deny. Only required Active Directory ports (LDAP, SMB, DNS) are allowed Clients → Servers; everything else must be explicitly permitted.

## Active Directory

A Windows Server 2022 domain controller (`dc01.lab.local`) runs Active Directory Domain Services with integrated DNS. A Kea DHCP server distributes the DC as primary DNS to clients across every VLAN. Password policy is enforced via Group Policy: 12-character minimum, 90-day rotation, account lockout after 5 failed attempts.

## PKI

An Enterprise Root CA runs on the DC. I authored a custom Web Server certificate template with Subject Alternative Name (SAN) support and issued trusted TLS certificates to the OPNsense web UI and a Linux Grafana server. The root certificate is pushed to all domain-joined clients via GPO, so every issued cert is browser-trusted out of the box.

## Monitoring

Prometheus runs on a dedicated Ubuntu VM and scrapes:

- `node_exporter` on Linux hosts
- `windows_exporter` on the DC and a Windows 11 client
- `os-node_exporter` on OPNsense

Grafana runs on HTTPS with a lab-CA-signed certificate and hosts dashboards for node health, Windows Server resources, and OPNsense throughput.

## AI Infrastructure

A dedicated VM uses PCI passthrough to grant direct access to an NVIDIA Quadro P4000 (8 GB VRAM). The VM runs Ollama for local LLM hosting, so data never leaves the lab.

## Self-Hosted Services

CasaOS runs on its own VM as a container dashboard for the rest of my self-hosted stack:

- **Jellyfin** — media server, with an NVIDIA GTX 1650 passed through for hardware-accelerated video transcoding (NVENC/NVDEC)
- **Shoko Server** — anime library manager with a SQLite/MySQL backend on the SSD tier; tuned for fast hash and metadata processing across thousands of files
- **Audiobookshelf** — self-hosted audiobook library, accessible from mobile and web

## What I Learned

- VLAN design and inter-VLAN firewall rule authoring in OPNsense
- Active Directory OU structure, GPO authoring, certificate template design
- Prometheus relabeling and dashboard editing
- PCI passthrough (IOMMU/VFIO) for GPU-accelerated VMs
- The difference between "it works" and "it's hardened" — and how to get from one to the other
