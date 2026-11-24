---
title: "the hardware bench"
description: "the physical side of my lab: what broke, how I narrowed it down, and what I replaced. Screens are great, but a lot of real support work happens with the case open."
date: 2026-11-24
category: "infrastructure"
tags: ["hardware", "troubleshooting", "repair", "memory", "firmware", "storage"]
status: "Ongoing, I add to it every time something breaks"
duration: "Ongoing"
stack: ["Lenovo ThinkCentre", "Dell Precision T7910", "Proxmox", "memtester", "dmidecode", "multimeter"]
outcome: "A running log of real hardware faults on real machines, each one narrowed down before anything got replaced."
skills: ["Hardware troubleshooting", "Component replacement", "Firmware updates", "Fault isolation", "Asset documentation"]
---

## how I work a hardware problem

Same order every time:

1. What's the actual symptom, and can I make it happen again on purpose?
2. What's the cheapest thing that could cause it?
3. Test one variable at a time. Swap one part, check, then the next.
4. Write down what I checked, even when it was fine. "Not the disk" is a result.

## the bad RAM stick in my second Proxmox box

The full story is on [its own page](/projects/ram-hunt/). The short version: my backups started failing their integrity checks, a whole new set of RAM failed too, and I had to find which stick out of four was bad while I was away at work.

I wrote a tester that logs the physical address of every error, read the memory controller's registers to turn that address into a slot, and then proved it on the bench one stick at a time.

![the four DIMM slots, labeled DIMM1 to DIMM4](/shots/pve2-dimm-slots.webp)

![the label on the stick that failed](/shots/pve2-dimm-label.webp)

## the BIOS that wouldn't flash remotely

Same box. The vendor flash tool stops and asks whether you want to update the serial number, and there's no way to answer that from a remote session. It got done from a USB stick at the console instead.

![the BIOS update running](/shots/pve2-bios-flash.webp)

## new thermal paste

The flash powers the box off when it finishes, so I used that power off to clean the original paste off the CPU and apply new paste. Planning maintenance around downtime you already have is a habit worth having.

## auditing the RAM in my main server

Before buying anything for my main Proxmox server, I checked what was actually in it with dmidecode instead of trusting a listing. Every one of its 16 slots is full of 8 GB ECC registered sticks, and they run slower than the CPUs support because two sticks per channel drops the speed. That one audit answered two questions at once: any upgrade is a swap, not an add, and the slower speed isn't a fault.

## the MacBook logic board

A liquid damaged MacBook Pro board. I cleaned the corrosion around the CPU power circuit and took resistance readings to see what was still shorted before deciding what was worth replacing. Board level work is slow, and that's the point. You measure before you touch anything.

## moving a laptop into a new body

When I got a new ThinkPad, I moved the NVMe drive and both RAM sticks over from the old one instead of reinstalling. Same OS, same files, new machine.

## still a student, still on the list

- A failed drive in my NAS got swapped in its caddy. I want to write that one up properly, with the rebuild timing.
- Faults like these go into my GLPI service desk as tickets now, so the history lives somewhere other than my memory.
