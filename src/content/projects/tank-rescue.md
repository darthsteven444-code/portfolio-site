---
title: "getting 5.87 TiB off a dying array"
description: "one disk faulted, a second one flagged, and zero backups configured on the pool holding every VM backup i had. what it took to get all of it off."
date: 2026-09-26
tags: ["zfs", "truenas", "rsync", "backup", "data-recovery"]
category: "infrastructure"
status: "Complete, both copies verified"
duration: "27 hours of copying, five days end to end"
stack: ["ZFS", "TrueNAS SCALE", "rsync", "NFS", "ext4", "e2fsck", "Proxmox VE"]
outcome: "Moved 6.55 TB across 31,383 files off a degraded raidz1 with zero read errors, then verified the copies three independent ways before touching a disk."
skills: ["Data recovery", "Backup verification", "ZFS", "rsync", "Filesystem integrity checking", "Risk assessment", "Incident triage"]
---

## Start with the embarrassing part

On September 21 a disk in tank faulted and I went to look at my backup configuration.

TrueNAS Data Protection was empty. No replication tasks. No cloud sync. No rsync tasks. Not even a snapshot schedule.

5.87 TiB of data, one copy, on a pool that had just lost its only parity disk.

I want that sentence to sit on this page because I had spent months building a SIEM, a Kubernetes cluster, a metrics stack, and a Velero pipeline that ships Kubernetes objects offsite to Oracle Cloud. I had written a restore drill and passed it. And the pool underneath all of it had never had a single backup task configured against it.

You do not find out what you actually protected until something breaks.

## What was actually at stake

tank is a single RAIDZ1 vdev, four wide, 10.44 TiB usable, with three datasets on it:

| dataset | size | what it is |
|---|---|---|
| media | 4.70 TiB | movies and books, source originals also on a USB drive |
| backups | 1.26 TiB | every Proxmox vzdump VM backup, exported over NFS |
| files | about 1 MB | effectively empty |

Look at the middle row again. Every VM backup for the entire lab lived on the pool that was degraded. Losing tank would have cost me the pool and, in the same stroke, the ability to restore any VM from it. Velero has an offsite copy of the Kubernetes objects. The Proxmox VM backups had nowhere else to be.

That is not a backup strategy. That is seventeen virtual machines and their only safety net stacked on the same four disks.

## The rule I wrote before touching anything

August had already taught me not to start a resilver on a hunch. This time the SMART data was different and worse.

sdf, serial K4JSAPLB, threw a real `Medium Error / Unrecovered read error` at sector 17232863. In August the drives were hot and the reads recovered. This was an actual unrecoverable read.

Two of the four survivors were clean, zero grown defects and zero uncorrected errors. But sda, serial K4JSG7TB, was showing the same WARNING status as the drive that had just faulted. Two of four compromised.

So the rule, written down before I ran anything:

> Do not scrub and do not resilver until replacement drives are in hand and a copy is off the pool.

Both conditions. Not either. A resilver on a four wide RAIDZ1 with zero parity reads every sector of every remaining disk, and one of those remaining disks was already flagged. That is the single most likely moment for this to become a total loss.

Which made the copy the whole job. The disks could wait. The data could not.

## Getting it off

Two USB drives, both ext4, both labeled clearly, because device letters shift the moment you plug something in and I was not going to lose 27 hours of copying to an `sda` that turned into `sdb`.

- TANKBACKUP-A, 7.3 TB, full copy of everything on tank
- BigDrive, 10.9 TB, second copy of the VM backups, and it already holds the media originals

tank mounted on my workstation over NFS, read only on all three exports, so nothing in this process could write a single byte back to a degraded pool.

Then rsync, chained with `&&` on purpose. If any file had been unreadable, rsync would have exited 23 or 24 and the chain would have stopped cold instead of quietly carrying on and leaving me with a partial copy I believed was complete.

```
rsync -ah --info=progress2 /mnt/tank-backups/ /run/media/steven/TANKBACKUP-A/tank-rescue/backups/ && \
rsync -ah --info=progress2 /mnt/tank-files/ /run/media/steven/TANKBACKUP-A/tank-rescue/files/ && \
rsync -ah --info=progress2 /mnt/tank-media/ /run/media/steven/TANKBACKUP-A/tank-rescue/media/
```

## The numbers

| dataset | copied | files | elapsed | average |
|---|---|---|---|---|
| backups | 1.38 T | 348 | 4:45:31 | 76.61 MB/s |
| files | 450.80 K | 2 | 0:00:00 | 36.24 MB/s |
| media | 5.17 T | 31,033 | 22:25:45 | 61.08 MB/s |

Total 27 hours, 11 minutes, 16 seconds. The shell's own timer read 1d 3h 11m 17s. One second of drift across 27 hours, which tells me it never stalled, never got suspended, and never sat waiting on a hung NFS mount.

The second copy of the VM backups onto BigDrive took 11:14:22 at 32.44 MB/s. Same 348 files, same 1.38 T.

And the number that matters most is the one that is not in that table.

Zero read errors.

Every rsync exited 0. All 31,383 files came off a RAIDZ1 with one disk faulted and a second one flagged. Every block ZFS could not read directly it reconstructed from parity, and it checksummed each one on the way out, so nothing silently wrong could have made it into the copy. A 5.87 TiB read across a degraded array with a known bad sector, and it gave up everything.

That was the gamble and it paid.

## Verified three ways

A copy you have not verified is a feeling, not a backup. So:

- **Content.** `rsync -ahn --itemize-changes` back across every dataset on both drives, four runs. Every path, size and timestamp compared. All four silent.
- **Filesystem.** `e2fsck -fn` on both drives while unmounted, read only so it could report without changing anything. Both clean. The only thing either one raised was a cosmetic note that one large file's extent tree could be shorter, which I declined, because writing to a rescue drive for a performance micro optimization is a bad trade at any time and a worse one that week.
- **Arithmetic.** ext4's own block accounting against rsync's byte count, which are completely independent measurements.

| | TANKBACKUP-A | BigDrive |
|---|---|---|
| filesystem size | 8.00 TB | 12.00 TB |
| used | 6.61 TB | 6.75 TB |
| files | 33,085 | 33,459 |
| non contiguous | 10.3% | 6.4% |

rsync moved 6.55 TB. TANKBACKUP-A reports 6.61 TB used. The gap is 62.5 GB, which is exactly what 244,191,232 inodes at 256 bytes each costs in inode tables. The two numbers agree to within the filesystem's own overhead.

Then a README on each drive saying what it is, when it was made, and that the source pool was degraded at the time. Future me will not remember. Clean unmount, NFS exports dropped, both drives unplugged and off the desk before I opened the chassis.

## One thing I got wrong along the way

Partway through the copy I was heading to work and wanted to check progress from there. I have Tailscale on everything, so I assumed I was covered.

I was not. My reachable inbound targets were linux-lab and the Proxmox host. linux-lab is a virtual machine running on the exact server I wanted to check on. My workstation, the machine actually running the rsync with both USB drives attached, had never had SSH enabled at all. In every session I had ever run, it was the client and never the destination.

So my remote access plan depended on the thing it was supposed to observe. That is a circular dependency and it took me until I needed it to notice.

The fix was `tailscale set --ssh=true` on the workstation, thirty seconds, no keys to move around. But it is worth writing down that I had built a mesh network across seventeen VMs, three cloud nodes and a phone, and left the one machine doing the work off the list.

## What is still broken

The copy is done and verified. The rest is not.

- Replacement drives first. sdf comes out first, full resilver back to ONLINE, temperature check, and only then sda as a separate operation. Never both at once on a single parity array.
- Both rescue copies are USB externals of the same brand and roughly the same age. That is a bridge, not a plan. Getting a copy made was to buy me the freedom to resilver safely, not to become the new architecture.
- tank still has no automated protection. Snapshot schedule and a real replication target, and TANKBACKUP-A is the cheapest seed for it I will ever have.

The whole reason this incident took 27 hours of copying instead of ten minutes of confidence is that item three was never done. I had backups of the layer I was proud of and none of the layer everything sat on.
