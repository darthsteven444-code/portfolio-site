---
title: "backups that actually restore"
description: "building a two-layer disaster recovery strategy for a kubernetes cluster and its VMs, and then proving it works by deleting things on purpose."
date: 2026-07-24
tags: ["velero", "proxmox", "kubernetes", "disaster-recovery", "backup"]
---

## The Backup You Never Tested Is a Prayer, Not a Plan

Everybody backs up. Almost nobody *restores*. That gap is where careers end, the backup job's been green for a year, disaster hits, and it turns out you were faithfully backing up nothing, or backing up something you can't actually bring back.

I run a three-node Kubernetes cluster and a couple dozen VMs on Proxmox. Losing any of it would mean rebuilding weeks of work by hand. So I built a real disaster-recovery strategy, and, more importantly, I *tested the restore*, because a backup you haven't restored from is just a hopeful guess.

## Two Layers, Because One Isn't Enough

Here's the thing most tutorials skip: a Kubernetes cluster has *two completely different kinds of state*, and one tool can't cover both.

There's the cluster's shape, every Deployment, Secret, ConfigMap, and StatefulSet definition. And there's the data inside the volumes. The actual bytes your databases and applications have written to disk. Back up one without the other and your restore comes back looking healthy while being completely empty.

So I ran two tools, each doing what it's good at.

## Layer 1: Velero for the Cluster's Shape

Velero backs up the Kubernetes objects. I pointed it at an S3-compatible object store running on my TrueNAS box, so backups land on separate, checksummed, ZFS-backed storage, not on the same hardware they're protecting. (First lesson: backups that live on the same machine as the thing they back up aren't backups. They're a single point of failure with extra steps.)

Nightly schedule, seven-day retention, automatic. Good.

Then I hit the wall that makes this project actually interesting.

## The hostPath Problem (a real finding)

I told Velero to back up the volume *data* too, and it politely skipped it. Every single volume: `not supported for pod volume backup`.

The reason is genuinely worth understanding. My cluster's storage uses k3s's built-in `local-path` provisioner, which creates hostPath volumes. They're just directories on the node's own disk. And Velero's file-level backup engine flat-out cannot back up hostPath volumes. No flag fixes it. It's a structural limitation, not a misconfiguration.

This is exactly the kind of thing that would silently ruin a restore. Velero reports success, your objects come back perfectly, and every volume is empty because the data was never in Velero's reach to begin with.

## Layer 2: Proxmox for the Data Underneath

Once I understood *why* Velero couldn't reach the volume data, the fix was obvious: those volumes are directories on the node VMs' disks, and I can back up entire VMs at the hypervisor level.

Proxmox vzdump snapshots every VM to that same TrueNAS storage on a schedule. So the layered strategy is:

- Velero → the cluster's shape (fast, granular, restores the *structure*)
- Proxmox → the VM disks, which contain the hostPath volume data (restores the *data*)

Together, complete coverage. And being able to explain *why* it's layered. "local-path uses hostPath volumes Velero can't file-back-up, so VM-level backups cover that data". Shows I actually understand my storage stack, not just that I ran a backup command.

## One More Trap: Don't Back Up Your Backup Target

My TrueNAS VM is where the backups *go*. It also has four physical drives passed through to it, about 16 TB of pool. If a naive "back up all VMs" job had tried to include it, it would've attempted to copy 16 TB into a share hosted *by that same VM*. That's a snake eating its own tail, and it would've failed catastrophically, possibly hanging the whole host.

So I explicitly excluded it and marked those passthrough disks `backup=0` as a hard safety net. TrueNAS gets protected a different way, a config export plus ZFS snapshots, because the tool that backs up everything else fundamentally can't back up the thing it backs up *to*.

## The Part Everyone Skips: The Restore Drill

Here's where I earned the confidence. I didn't just trust the green checkmarks.

- Velero: I restored my Wazuh SIEM backup into a *throwaway* namespace, side by side with the live one, and watched every StatefulSet, Service, ConfigMap, and Secret land correctly. My entire SIEM configuration. Provably recoverable.
- Proxmox: I restored a full VM backup as a *new* VM, confirmed the disk and data came back, and then destroyed the test copy.

Both drills passed. That's the difference between "I have backups" and "I have *tested* backups", and it's the exact question a hiring manager asks to separate the two.

## A Bonus Disaster (that I caused)

While I was in there, one of my cluster nodes went `NotReady` mid-project. The guest OS swore it only had 3.7 GB of RAM even though Proxmox had assigned it 8. The culprit was memory ballooning. Proxmox's balloon driver had inflated inside the guest and clawed back half its memory, starving the container runtime until it fell over.

Not a backup problem, but a good reminder that in a real environment, the disaster you plan for is rarely the one that shows up. Disabled ballooning on the cluster nodes, power-cycled, and the RAM came back. Onward.

## What I Learned

- *A backup is worthless until you've restored from it*, so I restore-tested both layers, deliberately
- *Kubernetes has two kinds of state*, object definitions and volume data, and covering both takes two different tools
- *k3s local-path uses hostPath volumes Velero can't back up*, understanding that limitation is what drove the layered design
- *Never let a backup job try to back up its own backup target*, exclude it, and add a hard `backup=0` safety net
- *Object storage on separate, checksummed ZFS* beats writing backups next to the thing they protect
- The whole philosophy in one line: untested backups aren't a disaster-recovery plan, they're a disaster waiting for a plan
