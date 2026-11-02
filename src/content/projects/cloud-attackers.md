---
title: "What the internet throws at two cloud nodes"
description: "My two Oracle Cloud nodes have SSH open to the world. Wazuh watches them and active response blocks attackers on its own. Here is what that actually looks like."
date: 2026-11-01
tags: ["wazuh", "active response", "oracle cloud", "oke", "ssh", "incident data"]
category: "security and monitoring"
---

## The setup

Half of this website is served from a free Oracle Cloud Kubernetes cluster in Phoenix that I built with Terraform. The other half comes from my house. Both run behind Cloudflare tunnels, so if one side goes down the other keeps the site up.

The cloud cluster has two worker nodes, and both run a Wazuh agent that reports back to my SIEM at home over Tailscale. Here's the difference that makes this write up possible. Everything in my house sits behind T-Mobile's CGNAT, so nothing out on the internet can even reach it. The cloud nodes are different. They have public IPs and SSH listening, and the internet found them almost immediately.

I never set out to build a honeypot. I just never closed the door, and Wazuh has been taking notes the whole time.

## What hits them

These numbers come from a 24 hour snapshot I pulled out of my Wazuh indexer on August 9. My home network can't be reached from the internet at all, so this traffic is the cloud nodes.

| Rule | One day |
| --- | --- |
| 5710, login attempt with a user that doesn't exist | 95 to 99 |
| 5758, max login attempts on one connection | 4 |
| 651, address blocked by active response | 95 to 99 |
| 652, block lifted on its own | 71 to 90 |

Nearly a hundred bad logins a day, and nearly a hundred automatic blocks a day, against two small nodes that host a portfolio site.

Here's what those rules mean in plain English:

| Rule | What it means |
| --- | --- |
| 5710 | Somebody tried to log in with a username that doesn't exist on the box |
| 5758 | Somebody hit the maximum number of login attempts on one connection |
| 651 | Active response blocked that address at the firewall |
| 652 | Active response lifted an old block on its own |

Almost all of it is bots. They aren't after me, they're after anything with port 22 open, cycling through usernames that don't exist on my nodes.

## The automatic block

This is Wazuh active response with the stock firewall drop script. When sshd logs enough bad attempts from one address, the manager tells the agent on that node to drop that address at the firewall. Later it lifts the block by itself (that's rule 652), so the block list doesn't grow forever. Nobody calls me. Nothing waits for me to wake up.

Here's the funny part. When I hardened my Kubernetes cluster I ran a brute force from Kali against one of my lab servers to show off this exact auto block. It never fired. That server only allows SSH keys, so it refused password logins before Wazuh ever saw enough failures to escalate. My hardening beat the attack before the detection had to. Good security, terrible demo. So I wrote in that write up that the auto block demo was still a to do.

Turns out the real internet ran the demo for me, nonstop, every day.

## Why this doesn't keep me up at night

- **SSH on those nodes only takes keys.** No passwords at all, so even with the block turned off, guessing passwords goes nowhere.
- **They're guessing users that don't exist.** That's literally what rule 5710 is.
- **It's layered.** Hardening stops the login, detection writes it down, and active response throws the address out. Any one of those failing still leaves two.

## Stuff I found along the way

Watching these nodes turned up things I didn't go looking for:

- **CIS benchmark score under 50 percent** on both nodes. Wazuh runs the CIS Oracle Linux 9 checks automatically and the default cloud image doesn't do well. That's a real gap, and it's going to be its own write up.
- **Two scanners, two different answers, both right.** Wazuh's vulnerability detection flagged 107 CVEs on one cloud node while OpenVAS found zero on my home nodes. Wazuh matches installed packages against CVE feeds whether or not they're reachable. OpenVAS only reports what an attacker can actually touch over the network. You want both views.
- **A lot of successful sudo to root on an idle node.** Around 860 a day. My best guess is Wazuh's own scheduled checks, but I haven't proven that yet, so it stays on my open items list until I do.

## What I would do on a real job

To be honest, I'd close SSH to the internet on those nodes. I already reach them over Tailscale, so the public port isn't needed for anything. I've left it open on purpose because right now it's the best free sensor I have, and the data is worth more to me than the attack surface it costs on a box that only takes keys. If this were a company's server, that tradeoff would go the other way, and I'd write it down as a decision instead of just leaving it.
