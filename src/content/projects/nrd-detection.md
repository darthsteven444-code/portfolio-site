---
title: "Catching brand new domains in my own DNS"
description: "Somebody on a Linux forum suggested it, so I built it. Every DNS lookup in my house gets checked against 30 days of newly registered domains, DNS over HTTPS is blocked so nothing sneaks around it, and a second rule flags the first time my network ever sees a domain."
date: 2026-11-01
tags: ["wazuh", "dns", "detection engineering", "opnsense", "unbound", "rsyslog", "doh", "firewall"]
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

## Zero hits, and why that bugged me

The newly registered domain rule went live on October 30. Since then it has fired zero times on real traffic, not counting my canary. On a home network, that's what I want to see. The canary still fires every single time I test it, so I know the pipeline is alive. Nobody in my house has been talking to anything that fresh.

But zero alerts made me ask a fair question. Is nothing happening, or is something going around my resolver where I can't see it? That question turned into the next two pieces of this project.

## Blocking DNS over HTTPS

When I first published this, my limits list said it plainly: a browser using DNS over HTTPS walks right past all of this. Firefox, Chrome and a bunch of phone apps can tuck DNS inside normal HTTPS traffic to Cloudflare, Google or whoever, and my resolver never sees the lookup. So I shut that door at the firewall.

- **Block the known DoH servers.** Floating rules in OPNsense drop traffic to a public list of DNS over HTTPS server addresses on port 443, and DNS over TLS on port 853 gets dropped everywhere. My monitoring box is the one exception, because it probes 1.1.1.1 and 8.8.8.8 on purpose to tell me when the internet itself is down.
- **Tell Firefox to stand down.** Unbound now answers NXDOMAIN for `use-application-dns.net`. That's the canary domain Firefox checks, and when it can't resolve it, Firefox turns its own DoH off and uses the network's resolver.
- **Turn off iCloud Private Relay.** `mask.icloud.com` and `mask-h2.icloud.com` get NXDOMAIN too, so Apple devices fall back to normal DNS.
- **Block the DoH hostnames.** The same public list includes the server names, and those go into an Unbound blocklist, so a client can't just look up the DoH server and connect to it anyway.

### The part where I broke my own stuff

The day after I turned the block on, my Oracle Cloud retry job started timing out. That's a script that keeps asking Oracle for free ARM servers until they have room. I figured Oracle was having a bad day. Nope. The DoH address list I imported included a chunk of Oracle's Phoenix address space, which is right where their API lives. My own firewall rule was eating my own Terraform runs.

The fix was one pass rule, placed above the block, that lets that single lab box reach Oracle's API range on 443. The lesson is the bigger deal though. When you import somebody else's blocklist, you are trusting every line in it. I checked that my own DNS still worked before I flipped it on, but I never checked what else lived inside those address ranges. Now I do.

## A second alert for domains my network has never seen

The newly registered list catches new domains. It does nothing for an old domain that's only new to me, like a five year old site that got compromised last week and now my laptop is talking to it. So I built rule 100201. It alerts the first time anything in my house looks up a domain it has never looked up before.

1. **Build a "seen" list every morning.** A script builds it from the copy of the firewall's DNS log my lab box keeps. The very first build seeded it with 759 domains my network had looked up in the past week.
2. **Stagger the schedule.** The newly registered feed pulls at 6:20, the seen list rebuilds at 6:35, and the deploy to both Wazuh managers runs at 6:40, so nothing steps on anything.
3. **Keep it quiet on purpose.** Rule 100201 fires at level 5 when a domain isn't on the seen list. Level 5 stays in the Wazuh dashboard and never pings Discord. I want these for digging through later. I don't need my phone buzzing every time somebody installs an app.
4. **Let the scary one win.** If a domain is brand new to the internet AND new to my network, the newly registered rule wins at level 10, and that's the alert that hits Discord.

Testing works the same way as before, just with canaries on both sides now. `example.com` has to stay quiet, and a domain my network has never seen has to fire 100201. All 6 live tests passed before I called it done.

## The numbers from the first two days

| Rule | Window | Alerts |
| --- | --- | --- |
| 100200, newly registered | since October 30 | 0 |
| 100201, first seen | day one | 560 |
| 100201, first seen | day two | 76 |

Across those two days, 100201 fired 636 times on 182 different domains.

Day one was loud, and I expected that. A week of history isn't much. Anything a device only touches once in a while, like update servers or an app that only checks in on the weekend, looked brand new. Then the seen list rebuilt overnight, picked all of that up, and day two dropped about 86 percent. That drop is exactly how a learning baseline is supposed to behave. It should keep shrinking until what's left is actually worth a look.

## The limits I know about

- **The free feed only covers generic TLDs.** Think .com, .xyz, .shop. Country code domains are not in it.
- **"Last two labels" is wrong for some domains.** Something like `something.co.uk` gets checked as `co.uk`. A public suffix list would fix that and it's on my list.
- **The DoH block is list based.** A DoH server that isn't on the public list, or anything riding inside a VPN, still gets past it. It stops the easy stuff, and for a home network I'm good with that.
- **The seen list only knows what my resolver saw.** Same blind spot as everything else here, which is exactly why the DoH block matters.
- **The feed runs a day behind.** A domain registered this morning won't be on my list until tomorrow.
- **New doesn't mean bad.** Plenty of brand new domains are just somebody's new business, and plenty of first seen domains are just a new app. That's why these alert a person instead of blocking anything.

## What's next

Let the first seen baseline bake for a few more weeks before I tune anything, then add an allowlist from a top sites list so the giant names never count as new. Fix the `co.uk` problem with a public suffix list. And put both rules on a Grafana panel, so I can watch that first seen curve flatten instead of just telling you about it.

All of it lives in Git in my detections repo: rules, decoder, tests and the deploy scripts. A pod restart can't wipe any of it.

Still a student, still learning, and still grateful to the forum member who threw the original idea out there. One suggestion turned into three detections and one lesson about trusting other people's blocklists.
