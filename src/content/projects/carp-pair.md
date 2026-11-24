---
title: "two firewalls, one gateway: building a CARP pair"
description: "my firewall was the one box that took the whole lab down when it rebooted. Now there are two, on two different hosts, sharing the same gateway address."
date: 2026-11-23
category: "infrastructure"
tags: ["OPNsense", "CARP", "high availability", "networking", "failover", "VLANs"]
status: "Live, failover tested"
duration: "Planned in October, built and tested in November"
stack: ["OPNsense", "CARP", "pfsync", "Kea DHCP", "Unbound", "Proxmox", "Cisco 3750X"]
outcome: "The standby took over every network with zero packet loss in the failover test, the site kept answering, and the primary took its role back on its own."
skills: ["High availability design", "Firewall administration", "Change management", "VLAN design", "Troubleshooting", "Documentation"]
---

## why I needed this

Every network in my lab goes through one firewall VM. Servers, clients, the DMZ, the demo network, all of it. So every time that VM rebooted for an update, the whole lab went dark. My site, my monitoring, DNS for the house. One box, one point of failure.

The fix is a second firewall that stands by and takes over when the first one goes away. OPNsense does that with CARP.

## how it works, in plain words

Clients never talk to a firewall's own address. They talk to a shared one.

- Each network gets a shared gateway address that belongs to whichever firewall is in charge right now.
- The primary gets its own address on every network, the standby gets another, and the shared one floats between them.
- Both firewalls announce themselves constantly. If the standby stops hearing the primary, it takes the shared addresses within a couple of seconds.
- Clients never change a setting. Their gateway is still the same address, there's just a different box behind it.

The two firewalls run on two different Proxmox hosts. Two firewalls on the same host would just move the single point of failure from the firewall to the host.

## the parts nobody tells you about

A shared address is the easy part. Making the standby actually useful took three more things:

- **State sync.** Every open connection lives in the firewall's state table. If the standby doesn't have a copy, every connection drops on failover. They sync over their own dedicated link, so that traffic never touches the regular networks.
- **Config sync.** Rules, aliases, NAT and the shared addresses get pushed one way, primary to standby. I make changes in one place and the standby follows.
- **The internet side.** My ISP gateway only hands out one address, so there's no shared address on the internet side. The primary keeps its own cable to the gateway, and the standby gets its own lease through the switch. Connections that were already open drop if it fails over, new ones work right away.

## the bug that ate a night

After everything was set up, the primary kept getting stuck in standby mode. CARP has a "demotion" counter, and a firewall that's waiting on its state sync holds itself back on purpose so it doesn't take over with an empty table. Mine was stuck at 240 after every config push and never came back down.

![the status page warning that the two firewalls were on different versions](/shots/carp-version-mismatch.webp)

The two firewalls were on different OPNsense versions. The sync never finished because the two sides didn't agree on the format, so the primary sat there waiting forever. I upgraded both to the exact same build and the counter dropped to zero.

Lesson: an HA pair is one system. Same version, same everything, or it isn't really a pair.

## the failover test

Nothing about HA counts until you've pulled the plug on purpose.

1. Told the primary to step down.
2. The standby took all six shared addresses.
3. Ran a ping to the internet the whole time: 0 percent loss.
4. My site answered through the standby with a normal page load.
5. Let the primary come back. It took its role back on its own.

Only after that passed did the standby get set to start automatically with its host.

## the second bug, a day later

I cut the primary's RAM down to match the standby (it was only using about half a gig) and rebooted it. It came back stuck in standby again, at the same 240.

Same symptom, different cause. This time the sync after a reboot was just slow, about 11 minutes. I cleared the counter by hand so the primary would take over, and then the slow sync finished and cleared it again. Now the counter was at minus 240, which sounds harmless and isn't. If one of the primary's links died, the 240 penalty that's supposed to step it down would only bring it back to zero. The broken firewall would keep the job.

So I wrote a small boot hook. Three minutes after a reboot, if the only thing holding the firewall back is a sync that never reported done, it removes that one penalty. If the late "done" shows up afterwards, the hook adds the penalty back so the math lands at zero. Anything else, like a dead link, it leaves alone, because that one is real.

## the last two gaps

Two things used to live only on the primary, and both are fixed now.

DHCP: a failover kept the internet up, but a new device couldn't get an address. Kea DHCP now runs on both firewalls in hot standby. The primary hands out the leases, the standby keeps a live copy of every one, and it takes over if the primary goes quiet.

DNS: my local host names only existed on the primary, so during a failover they stopped resolving. Those overrides now sync to the standby with everything else.

## things worth keeping

Test failover before you trust it, and test it again after every change that touches it.

A counter that went the wrong direction is still wrong. Minus 240 looked healthier than 240 and was actually worse.

Write the rollback before the change. Every step of this had a snapshot and a saved config before it started, and I used them.
