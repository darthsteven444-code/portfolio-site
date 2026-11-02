---
title: "The node that died once a week"
description: "One of my Kubernetes nodes kept going dark for most of a day. I was wrong twice before my own data showed me it was a shutdown that never finished. The fix was a change control decision, not a patch."
date: 2026-11-01
tags: ["incident", "change control", "kubernetes", "k3s", "linux", "systemd", "patching"]
category: "infrastructure"
---

## Symptom

About once a week, one of the three nodes in my k3s cluster would just go dead. Kubernetes marked it NotReady, the pods on it stopped answering, and I couldn't SSH in. The strange part was that the cluster API stayed up the whole time, so at first glance it looked like a network problem.

Then hours later it would come back like nothing happened.

## Theory one: the hypervisor was starving it

My first guess was Proxmox memory ballooning. Ballooning lets the host take memory back from a VM when the host needs it, and a Kubernetes node that suddenly loses memory can absolutely fall over.

So I turned ballooning off on all three nodes and then measured instead of assuming. The guest was holding its full 8 GB and the host had taken nothing back. And the node died again anyway. Theory one, dead.

## Theory two: something was leaking

My second guess was that systemd mount units were piling up over time (Kubernetes creates a lot of them) until init got wedged. That one sounded really convincing to me.

This time I didn't argue with myself. I wrote a little script that logged the mount unit count, put it on an hourly cron, and let it run for two weeks.

The data killed theory two as well. But it handed me the real clue.

The count wasn't climbing. It was collapsing. It sat at 19 for seventeen straight hours, then jumped back to 127 after the node recovered. A leak goes up. This went down to almost nothing and stayed there. That's not a leak. That's a machine in the middle of shutting down.

## Root cause

I pulled the boot history:

```
journalctl --list-boots
```

There was a 23 hour gap between one boot ending and the next one starting, and the last lines of the old boot were a clean, normal shutdown sequence.

Nobody had told that node to shut down. **unattended-upgrades** had. Ubuntu was installing security updates on its own, deciding a reboot was needed, and starting one. Then the shutdown hung partway through, waiting on a service that never stopped, and the node sat there half shut down for most of a day until something finally timed out.

## Correction

Two changes on all three nodes:

```
# /etc/apt/apt.conf.d/  (local override)
Unattended-Upgrade::Automatic-Reboot "false";

# systemd manager drop in
[Manager]
DefaultTimeoutStopSec=45s
```

The first one stops Ubuntu from rebooting on its own. The second one means that if anything ever hangs a shutdown again, systemd gives it 45 seconds and moves on instead of waiting forever. The weekly deaths stopped.

## This was a change control decision, not just a fix

Turning off automatic reboots is a tradeoff and I want to be honest about it. Security updates still install automatically. The difference is that a kernel update now waits for me to reboot instead of the node picking its own time. That means a patched kernel can sit waiting for a reboot longer than it would have.

I chose that on purpose. A node that reboots itself at a random time and then hangs for a day is a bigger risk to me than a kernel patch that waits a few days for a planned window. So now the plan looks like this: check which nodes say a reboot is required, drain one node, reboot it, make sure it comes back healthy, uncordon it, then move to the next one. One at a time, while I'm watching, never all three at once.

That's what change control really is to me. Not paperwork. Deciding ahead of time when a change is allowed to happen, and who is around when it does.

## What I learned

I was wrong twice, and I only found out because I measured instead of arguing. And the script I wrote to prove I was right is the exact thing that proved me wrong. That's the whole point of instrumenting something.
