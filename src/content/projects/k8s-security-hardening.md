---
title: "hardening a kubernetes cluster"
description: "taking a live k3s cluster from 'it works' to 'it's defended', image scanning, RBAC, pod security, default-deny networking, and proving detection with a real attack."
date: 2026-07-24
tags: ["kubernetes", "security", "wazuh", "networkpolicy", "trivy"]
---

## "It Works" Is Not "It's Secure"

I had a three-node Kubernetes cluster running my portfolio, a Wazuh SIEM, monitoring, and a handful of operators. It *worked*. Every pod was green. And it was wide open.

Default Kubernetes is a trusting place. Any pod can talk to any other pod. Workloads run with more privilege than they need. Nothing checks your container images for known vulnerabilities. None of that shows up as a red light, the cluster hums along perfectly while quietly being one compromised pod away from a very bad day.

So I spent a stretch of late nights closing that gap, one layer at a time. Not "install a security tool and call it done". Actual defense in depth, where each layer assumes the one in front of it might fail.

## Layer 1: Know What You're Running (Trivy)

You can't fix what you can't see. First move was deploying the Trivy Operator, which continuously scans every image in the cluster and writes the findings back into Kubernetes as objects I can query with `kubectl`.

The results were honest: a stack of critical and high CVEs across Wazuh, Velero, and the rest. All of them in *upstream vendor dependencies* (Go standard library, gRPC, a Java crypto library). Here's the part that actually matters, and the thing a lot of people get wrong: I was already on the latest release of every one of those images. There was nothing to patch. The vendors hadn't rebuilt yet.

That's real-world vulnerability management. The mature move isn't to panic-chase a CVE that has no fix, it's to *document the accepted risk*: the affected services aren't internet-facing, they're segmented onto their own VLAN, and Wazuh is watching them. Knowing when not to act is as much a skill as patching.

## Layer 2: Least Privilege (RBAC)

Next I audited who could do what. Found two problems worth fixing:

- **Six pods**: my portfolio and every Wazuh component, were mounting a Kubernetes API token they had no reason to hold. If any of those containers got popped, the attacker got a free credential to start mapping my cluster. Turned that off.
- Two leftover `cluster-admin` bindings from install jobs that finished twelve days earlier. Dead credentials with god-mode privileges, just sitting there. Deleted.

"Least privilege" sounds abstract until you go looking and find six workloads holding keys they never use.

## Layer 3: Pod Security Standards

Kubernetes ships built-in security tiers, `baseline` and `restricted`, that the API server can *enforce*, rejecting any pod that violates them. The catch: some workloads legitimately need elevated privileges. My SIEM runs a privileged container on purpose; my monitoring agent needs host access to collect metrics.

So I didn't slam `restricted` on everything and break the cluster. I ran it in audit mode first to see exactly what *would* break, then enforced `baseline` where it was clean and left documented exceptions where it wasn't. That distinction. "this namespace is an exception *because* the SIEM needs SYS_CHROOT". Is the difference between security theater and a real posture.

## Layer 4: Default-Deny Networking (This Is the Scary One)

This is where you can lock yourself out of your own cluster if you're careless. NetworkPolicy flips the default: instead of every pod talking to every pod, *nothing* gets in unless you explicitly allow it.

I rolled it out one namespace at a time, testing after every single change, with an instant rollback ready. A bad rule here doesn't throw an error. It silently strangles your SIEM's agents or kills Prometheus scraping, and you find out later. The nerve-wracking one was Wazuh: its agents connect from *outside* the cluster, so a blanket deny would've cut off my entire security monitoring. That policy needed surgical allowances. Specific source networks, specific ports, while blocking everything else. All five agents stayed connected. Nothing broke.

## The Payoff: Proving It Actually Works

Here's the thing about building defenses, untested defenses are just decoration. So I attacked my own cluster.

I moved my Kali box onto the server VLAN (simulating an attacker who'd already breached the perimeter, an "insider" scenario), pointed `hydra` at a monitored host, and launched an SSH brute-force. Then I watched Wazuh's alert feed in real time.

It lit up. Rules fired on every attempt, tagged with the attacker's IP, and every single alert came pre-mapped to the compliance controls it satisfies: PCI-DSS, HIPAA, NIST 800-53, GDPR. That last part matters for the kind of work I'm aiming at: when an auditor asks "show me you'd detect this," the answer is a live alert with the regulation number already attached.

There was a twist, and it's my favorite part of the whole exercise. The attack got *detected* but never *escalated* to the auto-block, because the target host was already hardened to key-only SSH and rejected the password attempts before they could pile up. The target's own hardening defeated the attack before my active-response even needed to fire. That's not a failure of the test. That's defense in depth working exactly as designed, and it's a far more interesting thing to explain than "the block fired."

## Scanning It Like an Attacker Would

For good measure, I ran a full OpenVAS/Greenbone vulnerability scan against the cluster nodes from that same insider position. (That tool is a saga of its own, the vulnerability feed took twelve hours to load and grew a database to 21 GB before it would even show me a scan profile. Homelab bandwidth is a character-building experience.)

The scan came back clean: zero critical, zero high, and a handful of low-severity informational findings. Weak SSH MAC algorithms, TCP timestamps. I remediated the SSH MACs across all three nodes and re-scanned to confirm they were gone. Scan → prioritize → fix → verify. The whole loop.

But the sharpest lesson came from comparing OpenVAS against a plain `nmap` scan. Nmap found seventeen open ports on each node, the Kubernetes API, the kubelet, my exposed services. OpenVAS flagged findings on *three* of them. That gap is the whole point: a network vulnerability scanner grades known CVEs in recognized services. It does not reason about whether exposing your cluster API to an entire network segment is a bad architectural idea. A clean vuln scan is not a secure architecture. The control that actually covers that exposure isn't a scanner. It's the VLAN segmentation sitting underneath everything.

## What I Learned

- *Defense in depth is not a slogan*, it's building each layer to assume the one in front of it fails, and then testing that assumption with a real attack
- *Trivy and honest vulnerability management*, including the discipline to accept and document a risk instead of chasing an unfixable CVE
- *RBAC least-privilege auditing*, and how much unused privilege accumulates quietly in a running cluster
- *Pod Security Standards*, audit-first, enforce-carefully, document your exceptions
- *NetworkPolicy default-deny*, rolled out namespace-by-namespace without taking the cluster down, including a SIEM whose agents live outside the cluster
- *Detection engineering with Wazuh*, proving a SIEM catches a live attack, with compliance mappings attached
- The single most important idea in the whole project: an untested defense is just a decoration, and a clean scan is not the same as a secure design
