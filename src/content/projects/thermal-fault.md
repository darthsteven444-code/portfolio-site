---
title: "the disks my monitoring couldn't see"
description: "a scrub said one disk was dying. the real problem was on all four, and not one layer of my monitoring could see it."
date: 2026-08-18
tags: ["zfs", "truenas", "proxmox", "monitoring", "smart"]
category: "infrastructure"
status: "Resolved, pool back online"
duration: "About 26 hours from fault to resolution"
stack: ["ZFS", "TrueNAS SCALE", "Proxmox VE", "smartctl", "Prometheus", "Grafana", "Wazuh"]
outcome: "Root caused a month long thermal problem that three separate monitoring layers missed, and brought the pool back with no replacement drive and no data loss."
skills: ["Storage troubleshooting", "ZFS administration", "SMART analysis", "Root cause analysis", "Observability gap analysis", "Thermal management"]
---

## What the scrub said

Monday, August 17. The weekly scrub on tank started around 03:00 and finished at 07:14:47. Somewhere in the middle of it, the Proxmox host logged this at 06:27:49:

```
sd 2:0:5:0: [sdf] Sense Key : Medium Error
critical medium error, dev sdf, sector 17232863 op READ
```

ZFS counted 189 read errors on that device and faulted it out. tank is a single RAIDZ1 vdev, four wide, 10.44 TiB usable. One disk gone means zero parity left. The pool went DEGRADED with 5.56 TiB sitting on it.

The scrub still finished clean. It repaired 752K on the way through and reported `errors: No known data errors`. Nothing was lost. But I had four drives holding everything I own and only three of them counted.

The obvious read is a dying disk. Order a replacement, clear the pool, get on with your day.

I almost did exactly that.

## Why that was wrong

I pulled SMART before spending any money, and sdf did not look like a dying disk at all.

```
Elements in grown defect list:     0
Total uncorrected read errors:     1
Total uncorrected write errors:    0
Total uncorrected verify errors:   0
Non-medium error count:            0
```

Zero grown defects. A platter going bad reallocates sectors, and this drive had reallocated nothing. One uncorrected read across roughly 414 TB of reads is an event, not a pattern.

Then I checked the other three, and the whole thing turned over.

| disk | SMART health status |
|---|---|
| sdf | WARNING, ascq=0x97 |
| sda | WARNING, ascq=0x96 |
| sdg | WARNING, SPECIFIED TEMPERATURE EXCEEDED |
| sdh | OK |

Three of four throwing warnings is not three of four failing drives. And sdg spelled it out in plain English. The drives were cooking. When I finally read temperatures off the host they came back 51, 52, 55 and 56 C.

## The part that actually bothers me

I have a Wazuh SIEM. I have Prometheus, Grafana, Alertmanager and Loki. I have TrueNAS itself watching its own pool. Three separate layers whose entire job is to tell me when something is wrong.

All three missed this for a month.

TrueNAS was the one that hurt. Its dashboard does not say the drives are hot and it does not say they are cool. It says:

```
No disk temperature is available
```

The four SAS disks are passed into the TrueNAS VM individually by `/dev/disk/by-id` over virtio. Virtio passes block devices. It does not pass the SCSI command set SMART rides on. So the guest can read and write every sector on those drives and cannot ask them a single question about their own health.

Which means TrueNAS had no temperatures to alert on. Prometheus was scraping a node exporter inside a guest that could not see them either. Wazuh was reading logs from a system where the condition never generated a log. Every layer was working correctly and every layer was pointed at a place where the data did not exist.

I built all of that myself and I still did not notice the hole in it until a disk fell out of the pool.

## Why nothing was spinning the fans up

The T7910 is a workstation with no iDRAC. Its embedded controller sets fan speed from CPU and motherboard sensors only, and the four SAS drives hang off an HBA where the EC cannot see them at all.

Host fans were running at 2548 and 2572 RPM against a 5755 maximum, and 2011 and 2003 against a 5000 maximum. About 40 percent.

So the chain was: idle Xeons, cool motherboard, happy embedded controller, lazy fans, cooked drives. The machine was doing what it was told. Nothing in that loop knew the drives existed.

The front drive cage did not help. It was designed for a couple of SATA disks, not four 7200 RPM enterprise SAS drives packed side by side.

The fix that night was not sophisticated. I took the side panel off and pointed a box fan at the case.

## Proving it before touching the pool

Here is the rule I set for myself, and it is the part I would keep if I lost everything else from this incident.

Do not clear a faulted device and do not start a scrub while the array has zero parity and the temperatures are unknown.

A resilver is hours of sustained reads across every remaining disk. If the drives are marginal because they are hot, that is the exact workload that pushes a second one over, and a second one is the whole pool. On a ship you do not load test a system you have not yet measured. Same idea.

So: cool first, measure, then act.

The box fan answered it in minutes.

| disk | before | after |
|---|---|---|
| sda | 55 C | 47 C |
| sdg | 56 C | 47 C |
| sdf | 51 C | 44 C |
| sdh | 52 C | 44 C |

Eight degrees across all four, and the fan RPM never changed. That rules out the machine having quietly fixed itself and confirms the problem was airflow into that cage.

## Recovery

Clear, not scrub. A scrub is the heaviest read load ZFS can generate and it does not bring a faulted device back anyway.

```
zpool clear tank
```

Resolved 15:38 on August 18. The resilver ran for 28 seconds and moved 715M, because it was replaying the roughly 32 hours of writes since the fault rather than rebuilding 5.56 TiB from scratch. Zero errors. All four devices ONLINE with 0 READ, 0 WRITE, 0 CKSUM. No known data errors.

Temperatures kept falling straight through it: 44, 42, 43, 41. Eleven to fourteen degrees of headroom against the zero I had that morning.

DEGRADED to ONLINE in under an hour. It cost nothing. I did not replace a drive, because there was never a drive to replace.

## What I took out of it

The lesson is not about ZFS or about fans. It is that an observability stack only covers what it can actually reach, and I had never once asked what my monitoring could not see.

Three layers of watching, one blind spot, and the blind spot is where the problem lived for a month.

Open items I am tracking from this:

- Airflow is still the real fix. A box fan on the floor is a bridge, not a solution, and I still owe that cage a proper answer.
- Get drive temperatures into Grafana. Since SMART cannot cross virtio, the collector has to live on the Proxmox host and feed node exporter from there. That closes the hole permanently rather than for one incident.
- A scrub is optional and last. Monday's scrub already repaired the damage and the resilver verified the returned disk.

I would rather publish this one than the version where the disk was simply bad and I simply replaced it. Nobody learns anything from that page.
