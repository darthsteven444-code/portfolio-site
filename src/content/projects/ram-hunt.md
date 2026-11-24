---
title: "finding one bad RAM stick without guessing"
description: "my backups started failing their integrity checks, a whole new set of RAM failed the same way, and the only way out was a tester that could point at one physical stick."
date: 2026-11-23
category: "infrastructure"
tags: ["hardware", "troubleshooting", "memory", "C", "Proxmox", "backups"]
status: "Resolved, bad stick pulled, every backup verified clean"
duration: "Two days, most of it remote"
stack: ["C", "Linux", "AMD memory controller registers", "Proxmox Backup Server", "Wake on LAN"]
outcome: "Found the one failing stick out of four, proved it on the bench, rebuilt to 32 GB with zero errors over 84 passes, and cleaned every backup the bad RAM had touched."
skills: ["Hardware fault isolation", "Root cause analysis", "Systems programming", "Remote troubleshooting", "Backup integrity", "Documentation"]
---

## the symptom

My second Proxmox box hosts my backup server. Then the backup verify job came back with failures, and not one or two. Snapshots that had been fine for weeks were suddenly corrupt.

Bad backups usually mean bad disks, so that's where I looked first. The disks were fine. Then I ran memtester and it came back with 913 failures.

Here's the part that made it interesting. That box had just gotten a full set of new RAM. So I put in a different set, ran it again, and it failed too. Two sets of RAM failing the same way points everywhere except at a stick: the board, the memory controller, the BIOS. That's an expensive list.

## why memtester wasn't enough

memtester tells you something failed. It doesn't tell you where. And I was at work, with a box I couldn't open.

So I wrote my own tester in C. For every error it logs:

- the physical memory address, not just the virtual one the program sees
- which CPU core saw it
- which bits flipped
- and then it has a second core read the same word back, to rule out a bad core

That turned "it fails" into data I could actually work with.

## what the data said

23,100 errors in 45 minutes, and every single one landed inside the same 32 KB block. Same block, same wrong value every pass, and every core agreed on it. That is not a flaky board or a tired memory controller. That is one bad spot on one chip.

There was one curveball. The errors came back as fully scrambled words instead of a clean flipped bit, and for a minute I read that as a controller fault. Wrong. This CPU encrypts memory with a per boot key, so one bad bit underneath turns into a whole garbled block on the way out. The encryption hid the bit pattern, but it couldn't hide the address.

Then I read the memory controller's own registers, the ones that say how physical addresses get split across channels and slots, and turned that one address into a channel and a slot.

![the four DIMM slots on the board, labeled DIMM1 through DIMM4](/shots/pve2-dimm-slots.webp)

## proving it on the bench

My first slot guess was wrong. The board's labels didn't line up with the order the controller counts in. This is why you don't trust the math alone.

So when I got home I went old school. One stick in, boot, test. Add the next one, boot, test. The moment the suspect stick went back in, the errors came back at the same address. Pull it, and they're gone.

![the label on the stick that failed, the part number matched the one my tester pointed at](/shots/pve2-dimm-label.webp)

Final build is 32 GB that ran 84 passes over 28.5 GB with zero errors.

## while it was open anyway

The BIOS was out of date, so I updated it. I tried to do it remotely first and the flash tool stopped dead at a question nobody could answer from an SSH session: did I want to update the serial number. That's a hard no, but I had to be at the console to say it, so it got done from a USB stick.

![the BIOS flash running from USB](/shots/pve2-bios-flash.webp)

![the prompt that stopped the remote flash: would you like to update the serial number](/shots/pve2-bios-serial-prompt.webp)

The flash shuts the box down when it's done, so I used that shutdown to clean off the original thermal paste and put new paste on the CPU. One power off instead of two.

## cleaning up the damage

This is the part people skip. Bad RAM doesn't just crash things, it quietly writes garbage. Every backup written while that stick was in could be bad.

1. Ran a full verify on the backup server that ignored old results and checked every chunk again. 24 snapshots failed.
2. Took fresh backups of every guest on both hosts.
3. Deleted the failed snapshots, but only for a guest that already had a fresh, verified backup to replace it.
4. Ran garbage collection, which threw out 121 corrupt chunks and freed 118 GB.
5. Scheduled a weekly verify job so this gets caught in days next time, not weeks.

Everything got logged as tickets in my GLPI service desk while I worked it.

## what broke along the way

- I started my tester a second time while the first one was still running. Two copies each grabbing most of the RAM left nothing for the second one to test. I added a guard so it refuses to start if another copy is already going.
- The remote BIOS flash hung on that serial number prompt, which I didn't know existed until it was on screen.
- My slot mapping was off by one because the silkscreen and the controller don't count the same way. The bench test caught it.

## things worth keeping

Make the test point at something you can hold in your hand. "Memory errors" isn't a fix. "This stick, this slot" is.

Two sets failing didn't prove the board was bad. Test one stick at a time before you start blaming the expensive parts.

When hardware writes bad data, the repair isn't done when the hardware is fixed. It's done when everything it touched has been checked.
