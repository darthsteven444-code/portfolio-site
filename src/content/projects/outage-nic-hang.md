---
title: "The night my whole lab went dark"
description: "Everything on my network dropped at once while I was away from home. A WiFi access point, my DHCP server and my core switch all looked guilty. The real cause was a network card on the hypervisor."
date: 2026-11-01
tags: ["incident", "change control", "proxmox", "networking", "opnsense", "linux kernel", "troubleshooting"]
category: "infrastructure"
---

## Symptom

On the night of October 29 I was at another house on a different internet provider, working on my lab remotely over Tailscale. Then all at once, nothing on my home LAN would answer. Not the Proxmox host, not the firewall, not the switch, not the media server. Everything.

Then things got weird. Devices started showing up with addresses on a subnet I don't use anywhere. My very first thought was the scary one: was I hacked?

Short answer, no. But I went through three wrong suspects before I found the real one, and every wrong suspect looked guilty for a good reason.

## How my lab is wired (and why this hurt so much)

My firewall, OPNsense, runs as a VM on my main Proxmox host. That host's onboard Intel network port is the uplink for the whole LAN. So if that one port stops talking, I lose the gateway, DHCP, DNS and the firewall all at the same time.

I knew that was a single point of failure on paper. This was the night it stopped being on paper.

## Wrong suspect one: a rogue router

The weird subnet was coming from my TP-Link Archer. I use it as a plain WiFi access point, not a router. But it was handing out its own addresses, and to me that looked exactly like a device that had been reset or taken over.

<figure>
<a href="/shots/writeups/outage-archer-dhcp-auto.webp" target="_blank" rel="noopener" title="Click to open full size"><img src="/shots/writeups/outage-archer-dhcp-auto.webp" alt="TP-Link Archer DHCP Server settings page with the DHCP server option set to Auto" loading="lazy" style="width:100%;height:auto;border:1px solid #C9CCC4;border-radius:4px;cursor:zoom-in" /></a>
<figcaption style="font-size:0.85em;color:#4A5054">The setting behind the scare: DHCP Server on "Auto". Addresses blurred. Click to open full size.</figcaption>
</figure>

Here's what was really going on. Even in access point mode, this Archer has a DHCP server setting that defaults to **Auto**. Auto means "if I can't find another DHCP server on the network, I'll become one." My real DHCP server lives on the firewall. The firewall was gone. So the Archer did exactly what it was told and stepped in with its own range.

The Archer wasn't the cause. It was the first thing that noticed. I set it to **Off** so it can never do that again, and confirmed it was still in access point mode.

<figure>
<a href="/shots/writeups/outage-archer-ap-mode.webp" target="_blank" rel="noopener" title="Click to open full size"><img src="/shots/writeups/outage-archer-ap-mode.webp" alt="TP-Link Archer Operation Mode page showing Access Point Mode as the current mode" loading="lazy" style="width:100%;height:auto;border:1px solid #C9CCC4;border-radius:4px;cursor:zoom-in" /></a>
<figcaption style="font-size:0.85em;color:#4A5054">Still in access point mode the whole time. Nothing changed its mode. Click to open full size.</figcaption>
</figure>

## Wrong suspect two: the DHCP server

When I got into OPNsense, almost every lease in Kea, my DHCP server, said **expired reclaimed**. That looked like DHCP was broken.

<figure>
<a href="/shots/writeups/outage-kea-leases-expired.webp" target="_blank" rel="noopener" title="Click to open full size"><img src="/shots/writeups/outage-kea-leases-expired.webp" alt="OPNsense Kea DHCP lease table where most leases show the state expired reclaimed" loading="lazy" style="width:100%;height:auto;border:1px solid #C9CCC4;border-radius:4px;cursor:zoom-in" /></a>
<figcaption style="font-size:0.85em;color:#4A5054">Almost every lease expired inside the same window. IPs, MACs and hostnames blurred. Click to open full size.</figcaption>
</figure>

But leases only expire when clients can't reach the server to renew them. My leases are a little over an hour long, and nearly all of them expired inside the same short window. That's not a broken DHCP server. That's a DHCP server nobody could reach. Another symptom.

## Wrong suspect three: the core switch

My Cisco 3750X is the core switch, so I figured it froze. I power cycled it, consoled in, and it showed five minutes of uptime. For a second that looked like proof it had crashed.

Except the five minutes was me. I had just power cycled it myself. When I finally checked Prometheus, the switch had been up and answering the entire night. The switch was innocent, and my reboot had just erased the one piece of evidence that would have told me so. That one still bugs me.

## Root cause

The answer was sitting in the kernel log on the Proxmox host the whole time:

```
e1000e ... enp0s25: Detected Hardware Unit Hang
```

Over and over. That's the Intel onboard network port carrying the entire LAN. The e1000e driver has a known problem on some of these Intel chips where the card's offload features (it splits and merges packets in hardware to save CPU) get the card stuck. The card just stops sending. The worst part is the link light stays on, so nothing upstream thinks anything is wrong.

So one hung network card took out the firewall VM's LAN side, which took out DHCP, DNS and the gateway, which made the Archer step in with its own addresses, which made everything look hacked.

## Correction

Turn off the offload features that trigger the hang, and make it survive a reboot. I backed up the network config first, then added this to the bridge's physical port in `/etc/network/interfaces`:

```
iface enp0s25 inet manual
    post-up /usr/sbin/ethtool -K enp0s25 tso off gso off gro off
```

Real talk on how that went: my first edit wrote `tpost-up` instead of a tab plus `post-up`, because my editing command didn't turn `\t` into a tab like I expected. I caught it because I read the file back before rebooting. If I had rebooted blind, that line would have been ignored and I'd have been back where I started the next time the card hung. Read it back. Every time.

After that I cleaned up the side effects: Archer DHCP set to Off, and the firewall's Tailscale connection logged back in, since it had dropped off my tailnet during all this.

## Was I hacked?

No. Every weird thing lines up with the hang: the strange subnet was the Archer's own fallback, no device I didn't recognize showed up, and the timing matches the kernel log. But I didn't just decide I wasn't hacked. I checked, and the evidence agreed.

## What changes now

- **Alert on the actual failure.** A Wazuh rule on the host for "Hardware Unit Hang" in the kernel log, so next time I find out in minutes instead of from a dead network.
- **A check from outside my house.** My monitoring lives inside the lab, so when the lab goes dark, so does the thing that's supposed to warn me. A probe from my cloud nodes that checks home will catch that.
- **Get the LAN off that onboard port.** I have a Mellanox ConnectX-3 10 gig card for the host, and moving the LAN onto it takes this exact failure off the table.

## What I learned

Check the box everything depends on first. I spent my time on the three devices that were showing symptoms, when the one device every one of them depends on was the one actually broken. And check your monitoring before you reboot anything, because a reboot destroys evidence. My switch proved that for me.
