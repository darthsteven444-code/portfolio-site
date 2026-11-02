---
title: "Catching brand new domains in my own DNS"
description: "Somebody on a Linux forum suggested it, so I built it. Every DNS lookup in my house gets checked against 30 days of newly registered domains, and a hit lands in Discord."
date: 2026-11-01
tags: ["wazuh", "dns", "detection engineering", "opnsense", "unbound", "rsyslog"]
category: "security and monitoring"
---

## Where this came from

I posted about my lab on the linuxcommunity.io forums and one of the members replied with an idea I had never thought about: watch for lookups of domains that were only registered in the last few weeks. Phishing kits, malware callbacks and scam shops love fresh domains. They burn through them fast and a brand new domain has zero reputation, so a lot of blocklists don't know about it yet. If a domain showed up on the internet four days ago and a machine in my house is already talking to it, I want to know.

To be straight with you, I already had most of the pieces. My firewall runs Unbound for DNS, Wazuh is my SIEM, and anything worth reading already goes to Discord. What I did not have was anything connecting DNS to Wazuh. So that became the project.

<figure>
<a href="/shots/writeups/nrd-pipeline.svg" target="_blank" rel="noopener" title="Click to open full size"><img src="/shots/writeups/nrd-pipeline.svg" alt="Diagram of the pipeline: a device asks Unbound, Unbound logs the query over syslog to a Linux box, the Wazuh agent ships it to the manager, rule 100200 checks it against the newly registered domain list, and a hit goes to Discord" loading="lazy" style="width:100%;height:auto;border:1px solid #C9CCC4;border-radius:4px;cursor:zoom-in;background:#EDEFEA" /></a>
<figcaption style="font-size:0.85em;color:#4A5054">How a DNS lookup becomes an alert. Click to open full size.</figcaption>
</figure>

## How it works

1. **Unbound logs every query.** I turned on query logging in OPNsense and pointed the firewall's remote syslog at a small Linux box in my lab.
2. **rsyslog sorts it.** That box was already catching logs from my Cisco router and switch, so I added the firewall to the same ruleset and gave it its own file.
3. **The Wazuh agent ships it.** The agent on that box tails the file and sends it to the Wazuh manager, which runs inside my k3s cluster.
4. **A custom decoder pulls it apart.** It grabs who asked, the full name they asked for, the record type, and the registrable domain. That last one is the last two labels, so `cdn.something.xyz` gets checked as `something.xyz`.
5. **Rule 100200 makes the call.** It looks that domain up in a list of newly registered domains. A hit is a level 10 alert tagged MITRE T1071.004, and level 10 and up goes straight to Discord.

```xml
<rule id="100200" level="10">
  <if_sid>500101, 500102</if_sid>
  <list field="dns_domain" lookup="match_key">etc/lists/nrd-domains</list>
  <description>DNS lookup of a newly registered domain: $(dns_domain) asked by $(srcip)</description>
  <mitre><id>T1071.004</id></mitre>
</rule>
```

The list itself comes from the free daily newly registered domain feed that WhoisFreaks publishes. A script runs every morning, grabs the last 30 days of files, lowercases and dedupes everything, and writes it in the `domain:nrd` format Wazuh wants. The first build came out to **281,201 domains**. Twenty minutes later a second cron job pushes the fresh list into both Wazuh manager pods and restarts them, so the list never goes stale.

## What fought me

**Wazuh's own Unbound decoder.** Wazuh ships a stock decoder for Unbound and it was grabbing my log lines before mine ever saw them. I had to exclude it in the manager config so my decoder got the line.

**Config that lives in two places.** In my cluster the manager's ossec.conf comes from a ConfigMap. You can edit the file inside the pod and it works great, right up until the pod restarts and your change is gone. I patched the live pods and the ConfigMap both, so the list and the decoder exclusion survive a restart.

**rsyslog was already using the port.** My Cisco gear was already sending syslog to that box, so the UDP listener was already loaded. My first try loaded it a second time and rsyslog flat out refused to start. I rolled back, extended the ruleset that was already there, and made the script restore the old config on its own if the new one ever fails the syntax check.

## Proving it works

You can't sit around waiting for real malware to test a detection. So every time the list deploys, the script adds one fake domain to it: `wazuh-nrd-canary.test`. Then I just look it up from my workstation:

```
dig www.wazuh-nrd-canary.test
```

Unbound logged it, the line made it to Wazuh, rule 100200 fired at level 10, and the alert showed up in Discord a few seconds later. That same canary lives in my test file right next to a normal lookup that should NOT alert, so any time I change the rules I can prove both directions in one run.

## So far

In the 2 days since it went live on October 30, rule 100200 has fired **zero** times on real traffic, not counting my canary. Honestly, that's what I want to see on a home network. The canary still fires every single time I test it, so I know the pipeline is alive and just nothing brand new has come through it yet.

## The limits I know about

- **The free feed only covers generic TLDs.** Think .com, .xyz, .shop. Country code domains are not in it.
- **"Last two labels" is wrong for some domains.** Something like `something.co.uk` gets checked as `co.uk`. A public suffix list would fix that and it's on my list.
- **It only sees DNS that goes through my resolver.** A browser using DNS over HTTPS walks right past all of this.
- **The feed runs a day behind.** A domain registered this morning won't be on my list until tomorrow.
- **New doesn't mean bad.** Plenty of brand new domains are just somebody's new business. That's why this alerts a person instead of blocking anything.

## What's next

Block the well known DNS over HTTPS providers at the firewall so browsers fall back to my resolver, then add a "first time this network has ever seen this domain" alert, using a top sites list so the big names don't spam me. All of it lives in Git in my detections repo: rules, decoder, tests and the deploy script. A pod restart can't wipe it anymore.

Thanks again to the forum member who threw the idea out there. This is one of my favorite things I've built.
