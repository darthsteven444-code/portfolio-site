---
title: "rca-bot: a local AI that reads my alerts first"
description: "When a pod crash loops, Alertmanager wakes up a small Python service that gathers the evidence, asks a model running on my own GPU what happened, and posts the answer in Discord."
date: 2026-11-01
tags: ["ai", "ollama", "alertmanager", "prometheus", "kubernetes", "python", "automation"]
category: "security and monitoring"
---

## The problem

An alert tells you that something broke. It doesn't tell you why. Every time a pod went down in my cluster I did the same five minutes of work: describe the pod, pull the logs, check the events, look at what command it was running, then start guessing.

I work nights at a hospital and I'm in school full time. I wanted those first five minutes done before I ever opened my laptop. And I wanted it done locally, on my own hardware, because I'm not shipping my logs off to somebody else's AI.

## What I tried first

I didn't start by writing my own. I tried two existing tools first:

- **k8sgpt operator** with a local model backend. The operator wrote the right settings, but the version I was running wouldn't actually use them. That turned out to be an upstream problem, not my config, so I parked it.
- **HolmesGPT.** It could never finish a run against my local model. It kept choking on the streaming responses.

So I wrote a small one that does exactly one thing well.

<figure>
<a href="/shots/writeups/rca-pipeline.svg" target="_blank" rel="noopener" title="Click to open full size"><img src="/shots/writeups/rca-pipeline.svg" alt="Diagram of the rca-bot flow: a pod crash loops, Prometheus fires an alert, Alertmanager sends a webhook to rca_server.py, rca.py gathers the pod evidence and asks a local model on a Quadro P4000, and the root cause gets posted to a Discord channel" loading="lazy" style="width:100%;height:auto;border:1px solid #C9CCC4;border-radius:4px;cursor:zoom-in;background:#EDEFEA" /></a>
<figcaption style="font-size:0.85em;color:#4A5054">From crash to explanation with no human in the loop. Click to open full size.</figcaption>
</figure>

## How it works

There are two pieces.

**rca.py** finds the broken pod and gathers the evidence: the pod spec, `kubectl describe`, the logs from the last crash, and the recent events. It sends all of that to qwen3:8b running in Ollama on a Quadro P4000 in my lab. It's one call that waits for the full answer instead of streaming, which is exactly what HolmesGPT couldn't handle. Then it strips out the model's thinking block and forces the answer into three parts: **ROOT CAUSE**, **REASONING**, and **NEXT STEP**.

**rca_server.py** is a tiny webhook receiver running as a systemd service. Alertmanager sends it pod failure alerts like `KubePodCrashLooping`. It pulls the pod and namespace out of the alert, runs rca.py, and posts the result to a dedicated `#rca` channel in Discord. It also remembers what it already looked at. A crashing pod usually fires two alerts at once, and without that check I'd get every answer twice.

## The first answer was wrong

My first test pod was built to fail. Its whole command was `exit 1`. The model came back with a nicely formatted answer that said the container was crashing because of a missing log file. Totally wrong. It had locked onto a kubelet log path that's just normal plumbing and invented a story around it.

The fix wasn't a bigger model. It was better evidence. I changed rca.py to pull the container's command and arguments out of the spec and put them right at the top, and I told the model to trust the spec over log noise. Next run:

```
AI Root-Cause Analysis  Alert: KubePodCrashLooping  Pod: default/rca-final-test
ROOT CAUSE: The container is explicitly configured to exit with a non-zero
status code (exit 1), causing repeated crashes and CrashLoopBackOff.
REASONING: The container's Args field specifies 'exit 1', a command
intentionally designed to terminate with an error code. This non-zero exit
code (1) triggers Kubernetes to restart the container, leading to the
observed CrashLoopBackOff after 7 restarts. The exit code and command are
the direct cause, not environmental issues.
NEXT STEP: kubectl get pod rca-final-test -o yaml to verify the container's
command and exit code configuration.
```

That one is right, and it showed up in Discord at 10:43 PM with nobody touching anything between the crash and the post.

## Three bugs between "works on my terminal" and "works on its own"

1. **I was checking the wrong secret.** I kept looking at the Alertmanager config secret to see if my route got added, and it always said no. The operator actually merges everything into a separate generated secret, and it's gzipped. My route had been there the whole time. I was measuring the wrong thing.
2. **The operator was quietly filtering my alerts.** By default it adds a hidden match that only lets alerts through from the same namespace as the config. My test pods lived somewhere else, so their alerts never reached my receiver. Switching the matcher strategy to `None` fixed it.
3. **My own firewall ate the webhook.** UFW on the box running the receiver was silently dropping traffic from the cluster nodes on the webhook port. One allow rule, scoped to just the cluster subnet, and alerts started landing.

Every one of those was silent. No errors anywhere, just nothing happening. That's the kind of bug that teaches you to check each hop on its own instead of staring at the whole chain.

## What small models still get wrong

In one run the diagnosis was perfect, but the suggested fix was a `kubectl` command with a flag that doesn't exist. The model just made it up because it looked right. That's why rca-bot only explains. It never runs anything. A person reads the answer and decides what to do.

## What's next

Right now it only reads the pod. The next version gets tools it can call on its own: pull logs from Loki, check metrics in Prometheus, and look up the host in my GLPI help desk. It also gets a human approval step before it's allowed to touch anything. An agent with guardrails, not an agent with root.
