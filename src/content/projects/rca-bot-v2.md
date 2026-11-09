---
title: "I Built an AI That Fixes My Cluster, But Only If I Say So"
description: "rca-bot v2 pulls evidence from logs, metrics and my asset inventory, has a local LLM figure out what broke, asks me in Discord before it touches anything, and opens and closes a real ServiceNow ticket the whole time."
date: 2026-11-09
tags: ["automation", "kubernetes", "ai", "itsm", "servicenow", "windmill", "observability"]
status: "Live, every alert runs through it"
duration: "Built over one weekend, v1 retired"
stack: ["Windmill", "Kubernetes (k3s)", "Ollama + Qwen 2.5", "Prometheus", "Loki", "Alertmanager", "GLPI", "ServiceNow", "Discord"]
outcome: "Alerts go in, a root cause with evidence comes out in about 20 seconds, a human approves the fix, and the ServiceNow incident resolves itself with a full audit trail."
skills: ["Incident response", "Root cause analysis", "ITSM / ServiceNow", "Workflow automation", "Kubernetes RBAC", "LLM integration", "Least privilege design", "Observability"]
---

Here is the thing nobody tells you about running a homelab. The alerts never stop. A pod goes NotReady at 1 AM, Discord pings, and now I am on my phone trying to remember which node that pod lives on and what the logs said last time.

So I built a bot to do the boring half of that for me. Then I made sure it can't do anything stupid without asking me first.

This is rca-bot v2. Version 1 was a Python script on a VM that could read an alert and guess. Version 2 actually investigates, writes it up, opens a ticket, waits for my approval, fixes it, and closes the ticket. I'm still a student, but this is the kind of thing I see in every job posting that says "ServiceNow" and "automation" in the same sentence, so I wanted to know how it actually works by building it.

## What happens when an alert fires

Alertmanager sends the alert to a flow in Windmill, which is the automation platform I self host in its own container on Proxmox. The flow has three steps.

<figure class="shot">
  <img src="/shots/rcabot-windmill-flow.webp" alt="Windmill flow run showing gather and analyze, ask for approval, and apply approved fix steps with a timeline" loading="lazy" decoding="async" />
  <figcaption><b>The real run.</b> 19 seconds to gather evidence and analyze, 28 seconds of me reading it and clicking approve, 1 second to fix.</figcaption>
</figure>

**Step 1: gather and analyze.** The bot pulls everything I would pull by hand:

- The pod status, restart count, events and its last 60 log lines from the Kubernetes API
- The last 30 minutes of that pod's logs from Loki
- Restarts, memory against its limit, CPU, and node memory from Prometheus
- The host record from GLPI, my asset inventory, so it knows what that node actually is

All of that goes to Qwen 2.5 running on Ollama on my own GPU box. Nothing leaves my network for the AI part. The model has to answer in JSON with a root cause, up to four pieces of evidence quoted from the data, and one suggested action. And the action can only be one of three things: delete the pod, restart the deployment, or nothing.

That last part matters. The AI does not get to invent commands. If it says anything other than those three, the code throws it out and treats it as "needs a human."

**Step 2: ask me.** The bot posts the whole write up in Discord with an Approve link and a Reject link. The flow just stops and waits. Thirty minutes, then it times out and does nothing.

<figure class="shot">
  <img src="/shots/rcabot-discord-approval.webp" alt="Discord message from rca-bot v2 showing root cause, evidence, suggested fix, ServiceNow incident number, approval links, and confirmation that the deployment was restarted and the incident resolved" loading="lazy" decoding="async" />
  <figcaption><b>Root cause, evidence, fix, ticket.</b> I clicked approve, it restarted the deployment, and the ticket closed. Approval links blurred since they are one time tokens.</figcaption>
</figure>

**Step 3: fix it.** Only after I click approve does it touch the cluster. Then it tells me what it did and updates the ticket.

## The ServiceNow part

Every alert opens a real incident in ServiceNow. I'm using a free Personal Developer Instance, which is the same platform the big companies run, just mine.

The incident gets the alert name, the pod, the AI's root cause, the evidence and the suggested fix. When the bot asks for approval, it adds a work note saying so. If I approve and the fix works, the bot resolves the incident itself. If I reject it or ignore it, the ticket stays open for a human. That is the whole point. Nothing disappears quietly.

<figure class="shot">
  <img src="/shots/rcabot-servicenow-resolved.webp" alt="ServiceNow incident list filtered to tickets created by rca.bot, showing INC0010003 resolved with RCA Bot as the caller" loading="lazy" decoding="async" />
  <figcaption><b>INC0010003.</b> Opened by the bot, resolved by the bot, but only because I approved the fix.</figcaption>
</figure>

## Making sure it can't be used against me

This is the part I spent the most time on, and honestly the part I'm proudest of. An AI with access to your cluster and a cloud ticketing system is a pretty good backdoor if you build it lazy.

**The Kubernetes account is tiny.** The bot has its own service account that can read pods, logs and events, delete a pod, and restart a deployment. That's it. It can't read secrets, can't create anything, can't touch other namespaces' configs.

**ServiceNow is one way only.** My lab talks out to ServiceNow. ServiceNow never talks in. The only thing the bot keeps from a ServiceNow reply is the incident number and its ID, and the code checks that both look exactly like they should before using them. Nothing typed into a ticket can ever trigger an action, because the approve button lives in Discord and Windmill, not in the ticket.

**The ServiceNow user is locked down too.** It has the basic ITIL role, can't log into the website, and I tested it: it can't read or create server scripts, scheduled jobs, outbound REST messages or MID servers. A MID server is an agent you install inside your network so ServiceNow can reach in. I don't have one and I never will for this.

**Lab details get scrubbed before they leave.** IPs, internal hostnames, URLs, passwords, tokens and anything that looks like a key are blanked out before the text goes to ServiceNow. The first version of that filter was too aggressive and blanked out pod names because they looked like keys. Fixed that, tested it on real pod names, moved on.

## What broke along the way

It would not be one of my projects if nothing broke.

- My first approval test said FAIL when it actually passed. The check grabbed the old pod while it was still shutting down instead of the new one.
- The bot couldn't reach the AI because my GPU VM grabbed a new IP from DHCP after a reboot. Fixed with a reservation on the firewall.
- GLPI would not accept the bot's API calls because Tailscale was hiding the real source IP behind Docker's gateway. One Tailscale setting fixed it.
- While locking down the ServiceNow code I accidentally deleted two lines the first step needed, and the bot crashed on every alert for a few minutes. Caught it on the next test, fixed it, retested.

Every one of those got found because I tested end to end instead of assuming.

## Why this matters

Anybody can wire an LLM to kubectl. The hard part is the boring stuff around it: evidence the AI has to cite, a short list of allowed actions, a human in the loop, least privilege everywhere, and a ticket trail an auditor would actually accept.

That's what an incident process looks like at a real company. I just built mine at home, on hardware I already had, for zero dollars.

Next up is pointing it at more alert types and letting it suggest fixes it is not allowed to run, so it can at least hand me the right command for the stuff it can't touch.
