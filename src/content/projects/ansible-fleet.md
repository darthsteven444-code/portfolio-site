---
title: "patching my whole lab without taking it down"
description: "one Ansible setup that hardens every Linux box I run and patches my Kubernetes nodes one at a time, so my site stays up the whole time it happens."
date: 2026-11-13
category: "infrastructure"
tags: ["Ansible", "patch management", "hardening", "Kubernetes", "automation", "Linux"]
status: "Live, first full run done"
duration: "One late night, plus the bugs"
stack: ["Ansible", "Ubuntu 24.04", "Kubernetes (k3s)", "fail2ban", "tmux", "GitHub"]
outcome: "Four boxes hardened and patched in about 20 minutes, every pending security update installed, three cluster nodes rebooted one at a time with zero failed tasks and not one monitoring alert."
skills: ["Configuration management", "Patch management", "Linux hardening", "Kubernetes operations", "Change safety", "Infrastructure as code"]
---

## why I needed this

Here is how I used to patch my lab. SSH into a box, run apt upgrade, move on to the next one, and hope I remembered all of them. Spoiler, I didn't.

When I finally ran a report across the whole fleet, every single box had between 61 and 80 updates waiting, and 6 to 11 of those were security fixes. That is the kind of thing that doesn't hurt at all, right up until the day it really hurts.

And the cluster makes it harder. If I reboot a Kubernetes node without warning, whatever was running on it goes down with it, my site included. So "just patch it" was never just patch it.

## the setup

One control node, linux-lab, which is already my jump box. Ansible lives there, it has its own SSH key on every box it manages, and it manages itself too. The first fleet is four boxes, linux-lab plus my three k3s nodes.

Three playbooks:

- **report** is read only. Pending updates, security updates, kernel, uptime, and whether a reboot is waiting, for every box in one place.
- **harden** puts the same security baseline on every box.
- **patch** updates everything, and handles the cluster nodes carefully.

Everything runs as a dry run first. Ansible shows me the exact change it would make to every file on every box, and nothing actually happens until I've read it.

## patching a cluster without breaking it

This is the part I'm proudest of. The patch playbook does the k3s nodes one at a time, and for each one it:

1. checks that all three nodes are Ready before it touches anything
2. drains the node, so Kubernetes moves the pods over to the other two
3. upgrades it, and reboots only if the upgrade actually asked for it
4. waits for the node to come back Ready and puts it back in service
5. waits for my site and my SIEM to be fully healthy again before it even looks at the next node

If anything fails, the whole rollout stops and that node gets put back in service on the way out. One broken node is a bad night. Three broken nodes is my whole lab.

The first real run took about 20 minutes. All four boxes upgraded, all three nodes drained and rebooted, zero failed tasks. The best part is what didn't happen. My monitoring didn't fire a single real alert the whole time. The only alerts in that 24 hour window were the two heartbeat alerts that are built to fire nonstop.

## hardening, with guard rails

Every box gets the same baseline. SSH keys only, no root login, fewer login attempts, fail2ban watching SSH, some kernel network settings, and automatic reboots turned off.

That last one has a story. A while back, unattended upgrades rebooted one of my k3s nodes on its own, the shutdown hung, and the node sat half dead for 23 hours. Security updates still install on their own every day. Reboots wait for me, or for this playbook, which reboots on purpose and one node at a time.

Turning off password login is also the classic way to lock yourself out of your own server. So before the playbook touches SSH, it checks that the box has an SSH key in place. If it doesn't, it refuses and moves on. It also checks the full SSH config on every run before anything reloads.

One thing I didn't know going in: SSH reads its extra config files in alphabetical order and keeps the first value it sees for each setting. Ubuntu drops in its own file that can turn password login right back on. So my hardening file is named with a 00 in front, it loads first, and it wins.

## what broke

It wouldn't be one of my projects if nothing broke.

- My first check of which boxes Ansible could reach froze solid. One of the boxes sits behind Tailscale SSH, which stopped and waited for a browser login my script could never give it. Fix was a hard 10 second limit per box.
- The dry run said fail2ban failed on all three k3s nodes. It hadn't. fail2ban wasn't installed yet, and a dry run doesn't really install anything, so there was no service to find.
- The real run failed on linux-lab checking its own SSH config. Ubuntu 24.04 only starts SSH when somebody connects, so a folder the check needs didn't exist yet. The same check passed on the cluster nodes because their SSH was already running. Fix was creating the folder first, on every run.
- Halfway through patching, my terminal got kicked off. linux-lab was upgrading the packages that were carrying my own connection. The run was inside tmux, so it kept going without me and finished clean.

## still a student, still on the list

- My AI server and my media server use a different login, so they aren't in the fleet yet.
- The Proxmox hosts stay report only on purpose. Patching those reboots everything that runs on them, so that's still a hands on job.
- Right now I start the patch run myself. Next is putting it on a schedule and having each run open a change record in ServiceNow, so planned maintenance gets logged the way a real shop would log it.

The playbooks are on GitHub: [darthsteven444-code/ansible-fleet](https://github.com/darthsteven444-code/ansible-fleet)

## things worth keeping

If you automate reboots, automate the waiting too. The reboot is the easy part. Knowing it's safe to move on to the next box is the real job.

Dry run first, every time. Reading the diff takes two minutes. Rebuilding a box takes a lot longer.

Build the guard rail before the dangerous step, not after. The check that refuses to touch SSH without a key in place was written before the line that turns passwords off.
