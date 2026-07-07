---
title: "system-health"
description: "bash health monitor, 15-minute timer, discord alerts — and one silent bug i missed for weeks."
date: 2026-05-25
tags: ["bash", "systemd", "monitoring", "discord"]
---
## The Script

Every homelab needs a watchdog — something that pokes around every few minutes and *yells* when stuff breaks. So I built one: `system-health.sh`, a single Bash script that runs five checks against linux-lab (a small Ubuntu VM in my homelab) and ships alerts to Discord the moment something looks off.

It lives at `~/scripts/system-health.sh` and fires every 15 minutes via a *systemd timer* — the modern Linux replacement for cron. About 150 lines total, mostly comments.

First line after the shebang: `set -euo pipefail`. Three flags — exit on errors, exit on unset variables, exit on pipe failures. Picked it up from a Bash style guide and now I won't write a script without it. It turns "the script kinda worked" into "it worked or it didn't." Night and day for debugging. (Remember this line. It comes back to bite me later.)

After that it's five functions: `check_disk`, `check_memory`, `check_load`, `check_services`, `check_failed_logins`. Each runs, and if it smells trouble, it appends to a global `ALERTS` array. At the end, if anything piled up, the script ships a summary to Discord and exits 1. Clean run? Exit 0. That exit code matters later — it's how systemd knows whether a run succeeded.

Five inspectors. One mailbox. One shipping clerk. That's the whole architecture.

## What It Watches

- **Disk** — `df -h` filtered to real filesystems (skip tmpfs and devtmpfs — those live in RAM); alerts above 80%
- **Memory** — `free -m` parsed with `awk`; alerts above 85% used
- **Load** — 5-minute load average from `/proc/loadavg`, one of those magic kernel-exposed files that hands you live stats the second you `cat` it; alerts above 2.0
- **Services** — `systemctl is-active` against ssh, cron, tailscaled, heartbeat
- **Failed SSH logins** — `journalctl _COMM=sshd` over the last 24 hours, piped to `grep -c "Failed password"`; alerts above 10

Honestly, half of writing this script was learning *which tool exposes which piece of data*. `/proc/loadavg` for load. `free` for memory. `df` for disk. `systemctl` for service state. `journalctl` for logs. Linux gives you a dozen ways to ask "is this thing healthy?" — the skill is knowing which one to reach for.

## Logging

Every line written is `ISO-8601 timestamp [hostname] message`. Plain text, easy to grep, easy to feed into a future log-aggregation pipeline (Loki, when I hit Phase 8 of the homelab plan).

The log file at `/var/log/system-health.log` is owned `itachixkurosaki:adm`, mode 664 — my user writes, the `adm` group reads, everyone else reads. Translation: my user appends directly, no `sudo` needed at runtime.

Sounds like a boring permissions detail. Hold onto it. It becomes *extremely* important in about three sections.

## Alerting

When alerts fire, the script POSTs a JSON payload to a Discord webhook via `curl` and `jq`. Quick side note — if you've never used `jq`, go learn it. It's a tiny command-line language for building and parsing JSON, and once it clicks you'll invent excuses to use it.

The interesting part isn't that there's a webhook. It's that I run *three* of them, each pointed at a different channel:

- **Grafana alerts** — dashboard-level alerts from the monitoring stack on the WebServer VM
- **Site uptime** — Alertmanager probes on steven-garcia.dev (SiteDown, SiteSlow, cert expiry)
- **system-health** — this script, on linux-lab

One source per channel. Why? Because when a Discord ping lands at 2am, you want to know *what kind of thing is broken* before you've even read the message. A ping in `#system-health` is a Linux VM problem. A ping in `#site-uptime` is a public-site problem. No overlap, no decoding, no squinting.

Found out later this pattern has a name — *alert routing*. Enterprise teams build entire tools around it (PagerDuty, Opsgenie). I've got three webhooks and three channels, but the principle's identical, and it scales.

## The systemd Unit

The timer fires every 15 minutes, with a 2-minute boot delay and `Persistent=true` so missed runs catch up on the next start. The service is `Type=oneshot` — runs once, exits, doesn't hang around as a daemon. Perfect for periodic checks.

The webhook URL does *not* live in the script. That'd be sloppy — it'd end up in git, get scraped by a bot, get abused. Instead it lives in `/etc/system-health.env`, a separate root-owned file with mode 600 (only root can even read it). systemd reads it via `EnvironmentFile=`, exports the variable, *then* drops privileges to `itachixkurosaki` before running the script. The script never sees the secret in source — it just inherits an env var.

Proper name for this: *secret separation*. Turns out it's a whole thing in security circles, and for good reason.

I also bolted on the hardening directives I'd want on any production service:

- `NoNewPrivileges=yes` — the process can't escalate
- `ProtectSystem=strict` — the whole filesystem goes read-only to the process
- `ProtectHome=read-only` — `/home` is read-only too
- `PrivateTmp=yes` — fresh, isolated `/tmp` per invocation
- `ReadWritePaths=/var/log/system-health.log` — whitelist the one file we actually need to write

None of that is required for a personal monitor on a personal box. I added it because that's the version of the unit I'd want shipping in production, and learning to write hardened units on a script I fully control is way cheaper than learning it later, under fire.

## What Tripped Me Up

Here's where the story gets good.

The first version logged its lines with `echo "$line" | sudo tee -a "$LOG_FILE"`. Looked fine. Worked great when I ran it by hand — sudo had a terminal, my cached credentials were warm, the log got written, everybody happy.

Then I wired it up to the systemd timer.

And here's the thing nobody tells you while you're learning systemd: services run *non-interactively*. No TTY. No cached sudo credentials. No password prompt — there's literally no human at a keyboard to type one. So every 15 minutes the timer fired, the script tried to log its first line, and `sudo` immediately threw:

```
sudo: a terminal is required to read the password
```

`set -euo pipefail` saw a failed command in a pipeline and killed the whole script. Right there. At the first log line. Before a single check ran, before any threshold got evaluated, before any alert could possibly fire.

And I didn't notice. Because:

- The script worked when I ran it manually (TTY present, sudo happy)
- The default `DISCORD_WEBHOOK_URL=""` meant no Discord pings could fire even if it *had* worked
- The log file existed — root created it on the first interactive run — it just quietly stopped *growing*
- `systemctl status` was screaming "FAILED" every 15 minutes, but I wasn't looking at it

Every. Fifteen. Minutes. For weeks. The timer fired, the script died at line one, systemd dutifully logged a failure to a journal I never read. A flawless silent failure.

The fix? Two characters and one chown:

1. Swap `| sudo tee -a "$LOG_FILE"` for `>> "$LOG_FILE"` — drop the privilege escalation entirely
2. `sudo chown itachixkurosaki:adm /var/log/system-health.log` — fix the ownership

That's it. Two changes. The script came back to life. The next manual trigger landed a real ping in Discord within three seconds. And to prove the alert path worked end-to-end, I tripped the disk threshold to 1% on purpose, fired the service, and watched `#system-health` light up.

There's a lesson buried in that: a monitor you've never verified end-to-end isn't a monitor. It's a story you tell yourself about your infrastructure. Until an alert actually fires and lands somewhere you actually look, you don't have monitoring — you have *hope*.

Now I have monitoring.

## What I Learned

- `set -euo pipefail` is your best friend when the script works and your worst enemy when it doesn't. Silent failures stop being silent the moment you wire up a real alert path.
- Anything non-interactive — cron, systemd timer, CI runner, lambda — can't assume sudo, ssh-agent, a TTY, or anything else that needs a human at a keyboard. Plan for that from line one.
- Secret separation matters even in a personal lab. `EnvironmentFile=` plus a 600 root-owned env file is the simplest pattern that works, and it keeps the webhook out of git forever.
- Alert routing — splitting alerts by source channel — beats one giant firehose. Triage shouldn't require reading the message body.
- The most valuable monitor is one that's actually fired at least once. Until then, it's untested code.
