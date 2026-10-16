---
title: "Upgrading My Proxmox Host from 8 to 9 Over SSH Without Bricking My Network"
description: "A full Proxmox VE 8.4 to 9.2 major upgrade on a workstation with no out of band management, done over SSH, with the firewall for my whole network living on the same box. Here is how I ran it so nothing broke."
date: 2026-10-16
tags: ["proxmox", "linux", "debian", "homelab", "sysadmin"]
---

My entire homelab runs on one Dell Precision T7910. Proxmox on the bare metal, and stacked on top of it is everything I rely on: my OPNsense firewall, my TrueNAS box, a Windows Server domain, a three node k3s cluster, and the VMs that serve this very site.

Proxmox VE 8 hit end of life on August 31, so the jump to 9 was overdue. Simple enough on paper. The catch is what makes it interesting. This is a workstation, not a rackmount server, so there is no iDRAC and no out of band management. If the upgrade breaks the boot or kills networking, I cannot pull up a remote console to fix it. My firewall is a VM on this exact host, which means a bad upgrade takes my internet down at the precise moment I would need it to troubleshoot. And I was doing the whole thing over SSH from my laptop.

A lot of ways for this to go wrong. Here is how I ran it so none of them did.

## Check before you touch anything

Proxmox ships a pre upgrade checker. It is read only and changes nothing, it just tells you what the upgrade will trip over.

```
pve8to9 --full
```

```
= SUMMARY =
TOTAL:    43
PASSED:   32
SKIPPED:  8
WARNINGS: 3
FAILURES: 0
```

Zero failures is the number I cared about. The three warnings were all minor: some pending 8.4 packages to install first, a note that 9 guests were running, and a missing CPU microcode package. Nothing blocking. Green light.

## Prove your recovery before you need it

Before touching anything major, I brought the host fully current on 8.4 and rebooted. Not because the upgrade required it, but because I wanted to prove the box boots clean and that my VMs autostart in the right order with the firewall coming up first. If my reboot recovery was broken, I wanted to find that now, on the safe version, not after the big upgrade when I could not tell what broke.

```
apt update && apt -y full-upgrade
reboot
```

It came back in about 90 seconds. OPNsense started first, my internet healed itself, SSH answered. Baseline confirmed. That one dress rehearsal is the reason I slept fine later.

## Give yourself a safety net

Running a 600 package distro upgrade over SSH has one obvious way to end badly. Your connection drops partway through and leaves the host half upgraded and unbootable. tmux kills that risk. Run the upgrade inside it and a dropped SSH does not stop a thing, the work keeps going on the server and you just reconnect and reattach.

```
apt install -y tmux && tmux new -As pveupg
```

Everything from here ran inside that session.

## Swap the repos, carefully

PVE 8 is built on Debian 12 "bookworm." PVE 9 is Debian 13 "trixie." The upgrade is really just pointing your package sources at the new release and letting apt do the work. The trap is a single wrong line in a sources file, so I backed everything up first, then made the swap.

```
mkdir -p /root/apt-backup-pre9 && cp -a /etc/apt/sources.list /etc/apt/sources.list.d /root/apt-backup-pre9/
sed -i 's/bookworm/trixie/g' /etc/apt/sources.list /etc/apt/sources.list.d/pve-no-sub.list
```

I also disabled two repos for the upgrade. The Ceph repo, because I do not run Ceph and its old branch does not exist on trixie, and the Tailscale repo, because best practice is to keep third party sources out of the way during a major upgrade. Tailscale kept running the whole time, I just paused apt from touching that one package.

```
apt update
```

Clean. Every trixie repo answered, nothing still reaching for bookworm, and 614 packages queued.

## The big one

This is the step that actually moves you to 9. I ran it to keep all my existing config files on purpose. That is not laziness, it protects my working SSH config so I could never get locked out of my own box mid upgrade, and it preserves my network settings.

```
DEBIAN_FRONTEND=noninteractive apt dist-upgrade -y \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold" 2>&1 | tee /root/pve9-upgrade.log
```

It scrolled for a while. The one line that looked scary was postfix failing to restart with a systemd job conflict. That turned out to be a harmless timing hiccup during the trigger, and it came up fine on the next boot. The rest installed clean, including the new 9 kernel written to all four of my boot partitions.

A quick sanity check before rebooting, because rebooting on a half configured package state is exactly how people brick a host:

```
pveversion
dpkg --audit
```

```
pve-manager/9.2.21/4f6e0ac86f9e8c7f (running kernel: 6.8.12-43-pve)
```

Version says 9.2.21. The audit printed nothing, meaning no package was stuck. Clear to reboot.

## Reboot into 9

```
reboot
```

Gave it a few minutes this time, then checked:

```
uname -r; pveversion; ping -c3 1.1.1.1
```

```
7.0.14-24-pve
pve-manager/9.2.21/4f6e0ac86f9e8c7f (running kernel: 7.0.14-24-pve)
64 bytes from 1.1.1.1: icmp_seq=1 ttl=50 time=58.3 ms
--- 1.1.1.1 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss
```

New kernel, running Proxmox VE 9.2.21, and my network came back on its own with the firewall first. No monitor needed, nothing lost.

## The cleanup nobody warns you about

The upgrade finishing is not the end. A few things needed tidying.

The autostart was staggered, not instant. My VMs come up in a set order with delays between groups so the firewall and storage are ready before anything that depends on them. For a couple minutes after the reboot the later VMs showed as stopped, which looked alarming until I remembered I built those delays myself. They all rolled up to running on schedule.

PVE 9 quietly re enabled the paid enterprise repo, which throws a 401 since I run the free no subscription repo. One command to disable it and apt went spotless. I also re pointed Tailscale back at trixie and installed the Intel microcode I had skipped earlier, which needed the non free firmware component added to my sources.

The last warning I left alone on purpose. PVE 9 wants updated Microsoft Secure Boot certificates enrolled into each EFI VM. It is not urgent, every VM runs fine without it, and rushing EFI key enrollment on a Windows VM with BitLocker at two in the morning is how you meet the recovery key prompt. That one gets its own careful session in daylight.

## What I actually learned

The upgrade itself was maybe six commands. The reason it went clean was everything wrapped around them. Checking first. Rehearsing the reboot on the safe version. Keeping a safety net so a dropped SSH could not hurt me. Backing up the repos before editing them. Keeping my working configs so I never locked myself out. And knowing which warnings to respect and which to ignore.

I am still a student working toward this career, and nights like this are exactly why the lab matters more to me than any slide deck. Zero data lost, no brick, and both of my Proxmox nodes are on 9 now, which means clustering them is the next thing on the bench.
