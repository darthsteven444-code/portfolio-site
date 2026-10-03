---
title: "the backup job that took down the hypervisor"
description: "a backup job hung for 38 hours and dragged the whole hypervisor down with it. then the tools i reached for to diagnose it hung too."
date: 2026-09-29
tags: ["proxmox", "nfs", "zfs", "truenas", "incident"]
category: "infrastructure"
status: "Resolved, full parity restored, backups rebuilt off the pool"
duration: "38 hours hung, 15 minutes to clear"
stack: ["Proxmox VE", "NFS", "ZFS", "TrueNAS SCALE", "vzdump", "Linux kernel diagnostics"]
outcome: "Cleared a 38 hour hypervisor wedge with one command and no reboot, found the architecture mistake behind it, and rebuilt backups onto separate physical hardware so the same failure cannot happen twice."
skills: ["Incident response", "Linux troubleshooting", "NFS", "Kernel diagnostics", "Dependency analysis", "Proxmox administration"]
---

## 17:20

Two new drives had just landed on the porch. I opened Proxmox to check on things before installing them and found this:

```
Uptime:        36 days 19:49
CPU usage:     4.40% of 88 CPU(s)
Load average:  40.49, 40.30, 40.18
IO delay:      0.02%
RAM usage:     82.53%
```

Load of 40 on a box using 4.4 percent of its CPU.

My first thought was that I had killed it, that plugging something in had done this. The three load figures said otherwise before I had finished panicking. One minute 40.49, five minute 40.30, fifteen minute 40.18, all within a third of a point of each other. A problem that started two minutes ago does not produce a flat fifteen minute average. This had been happening for a long time.

Then I looked at the task pane.

```
Sep 28 03:00:02   home   root@pam   Backup Job   [spinner]
```

No end time. Started 3am the previous day. **Thirty eight hours.**

## What load 40 with no CPU actually means

Load average counts processes that are running and processes stuck in uninterruptible sleep. Forty of something, and the CPU was idle, so they were not running. They were blocked, waiting on something that was never going to answer.

Two more numbers narrowed it further. IO delay sat at 0.02 percent, which measures waiting on local block devices, so this was not a disk. And `/proc/loadavg` read `5/1502`, five runnable threads out of 1502.

A pile of tasks frozen on something that was not local storage. That points one place.

## The tools broke too

I went to list the stuck processes:

```
ps -eo state,pid,comm,wchan:28 --no-headers | grep '^D'
```

It printed nothing and hung. `ps` walks `/proc` to read every process, and reading the `/proc` entry of a task wedged in a kernel call blocks too. The command I reached for to count the stuck processes got stuck behind the stuck processes.

So I went to check the NAS VM:

```
qm status 130
```

That hung as well. Every Proxmox command touches the storage layer, and the storage layer was sitting on the dead mount.

This is the part of the night I would want a hiring manager to read. Not the fix. The fact that I was two tools deep before realising the tools themselves were downstream of the failure, and that I had to pick a diagnostic that touched neither `/proc` nor storage.

That turned out to be `dmesg`, which reads the kernel ring buffer and nothing else.

```
[Mon Sep 28 03:12:29 2026] nfs: server 192.168.20.50 not responding, still trying
[Mon Sep 28 03:12:32 2026] nfs: server 192.168.20.50 not responding, still trying
[Mon Sep 28 03:12:35 2026] nfs: server 192.168.20.50 not responding, still trying
```

There it was. 192.168.20.50 is my TrueNAS VM. The backup job started at 03:00:02 and the NAS stopped answering twelve minutes later.

## Why it never gave up

"Still trying" is the giveaway. That share was a hard mount, and a hard mount retries forever rather than returning an error. That is usually what you want, because a NAS that reboots does not corrupt anything, the client just waits and picks up where it left off.

It is not what you want when the server is never coming back on its own. Thirty eight hours of patient retrying, with every process that touched the mount queuing up behind it.

And you cannot kill your way out of it. Uninterruptible sleep means exactly that. Those processes do not accept signals, `kill -9` included. That is not a stubborn process, it is a task parked inside a kernel call that has not returned.

## The fix took one command

The way out was to detach the mount from the namespace so new accesses stopped blocking, rather than waiting on a server that was not going to reply:

```
umount -l -f /mnt/pve/truenas-backups
```

`-l` is lazy, and it is the flag that matters. It returns immediately instead of waiting.

```
umount rc=0
mount detached
qm status 130 -> status: running
```

Proxmox tooling came back instantly. I cancelled the backup job, which finally terminated at 17:28:15 with "Error: unexpected status" after 38 hours and 28 minutes.

Then everything drained on its own.

| Time | Host load | TrueNAS load |
|---|---|---|
| 17:29 | 45.70 | |
| 17:32 | | 9.91 |
| 17:34 | 17.90 | |
| 17:35 | 15.26 | 8.02 |

No reboot. I had been planning for one and telling myself it was fine because I had verified copies of the pool on the shelf. Did not need it.

## The NAS was never down

This is the part I got wrong in my head for the first twenty minutes. Once the tooling worked I checked properly:

```
qm status 130    -> running
ping             -> 0.3ms, 0% packet loss
guest agent      -> alive
nfs-server       -> active
rpcbind          -> active
```

TrueNAS never crashed. It got buried. vzdump tried to push 1.3 TiB into a raidz1 that was reconstructing every read from parity because one member had faulted, the guest saturated, and NFS stopped answering inside twelve minutes. The moment the pressure came off, its load fell from 28 to 8.

My server was not dead. It was holding its breath.

## The actual mistake

The backup job wrote to `truenas-backups`, an NFS export from tank. Tank held every Proxmox VM backup I had.

So the pool that needed protecting was also the target that protected it. When it got sick, the backup job made it sicker, and the hypervisor went down with it. One degraded array took out storage, backups, and the host that ran both.

That is not a tuning problem. That is a dependency I built and never drew on paper.

It also explains why the pool was in that state at all. The whole reason it was degraded and sensitive was the disk I had been waiting to replace, and the drives to fix it were sitting in a box by the front door while the machine tore itself apart trying to back up onto the thing that was failing.

## What I changed the same night

```
pvesm set truenas-backups --disable 1
pvesh set /cluster/backup/<id> --enabled 0
```

Storage disabled so nothing could remount it. Job disabled so it could not fire again while I was asleep or halfway through a rebuild. Both stay off until the array is healthy and the backup target lives somewhere that is not the pool being backed up.

Then I replaced the faulted drive and let it rebuild.

```
scan: resilvered 2.02T in 05:59:24 with 0 errors
tank          ONLINE  0 0 0
  raidz1-0    ONLINE  0 0 0
errors: No known data errors
```

Five hours fifty nine minutes, 2.02 TB, sustained 399 MB/s, zero errors. Temperatures held between 34 and 42 C the whole way, against the 51 to 56 C that started all of this in August. Every surviving member reported 0 read, 0 write and 0 checksum for the entire run, including the drive that had been flagged alongside the one that actually faulted.

## Three things worth keeping

- **Check whether the tool you are using sits downstream of the failure.** If `ps` hangs, that is data, not a broken command. Pick something that touches neither the blocked subsystem nor `/proc`.
- **Read all three load averages, not the first one.** The relationship between the one, five and fifteen minute figures told me this was not my fault before I had touched anything, and that saved me from chasing the drives I had just carried in from the porch.
- **Draw the dependencies.** I had backups. I had monitoring. I had a NAS. What I did not have was a diagram showing that the backup job and its target were the same failure domain, and that is the only thing here that would have prevented the whole night.

## How it actually got fixed

Four days later, and this part matters more than the unmount did.

The backup job now writes to a **Proxmox Backup Server running on a second physical machine**. Not a different dataset, not a different share. A different computer. If the pool degrades again, the backup target is not sitting on top of it.

```
vzdump   daily 02:00  ->  PBS on separate hardware
keep     7 daily, 4 weekly, 3 monthly
```

That changed the economics too. The old job wrote full compressed images and piled up 1.26 TiB on the pool it was supposed to be protecting. PBS stores each unique block once across every machine, so the first test backup I ran came back 62 percent deduplicated before it had anything else to compare itself against.

The pool got what it never had either: snapshot tasks, hourly for two days and daily for a month. Those live on the pool, so they do nothing if it dies, and that is exactly why they are not a substitute for the backups above. They cover the far more common case, which is me deleting something I wanted.

And I added the alert that would have caught this in ten minutes instead of thirty eight hours. Not a load alert. A conventional one compares load average against CPU count, which on 88 cores means a threshold near 88, and this peaked at 45 with the processor 96 percent idle. The metric that matters is `node_procs_blocked`, which counts processes stuck in uninterruptible sleep. There were about forty of them, and nothing in my lab had ever looked at that number.
