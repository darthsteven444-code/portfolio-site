---
title: "putting a used cisco router on the grid"
description: "i wired a secondhand Cisco 2911 into my SIEM and my monitoring stack in one night. the test alert at the end caught my alerting system dead for two days."
date: 2026-10-18
category: security and monitoring
tags: [Cisco IOS, Wazuh, rsyslog, SNMPv3, Prometheus, Grafana, Alertmanager, Kubernetes, Proxmox LXC]
status: "Complete, two follow ups open"
duration: "One evening, about four hours"
stack: [Cisco 2911 on IOS 15.7, Wazuh 4.14 on k3s, rsyslog, snmp_exporter, Prometheus, Grafana, Alertmanager, Discord]
outcome: "Failed logins on the router now alert in Wazuh at level 9, router health is on a Grafana dashboard with four Discord alerts behind it, and a test alert exposed an Alertmanager that had been down for 53 hours without anyone knowing."
skills: [Log pipeline design, SIEM integration, SNMPv3, Prometheus alerting, Root cause analysis, Linux troubleshooting, Change validation and rollback]
---

## Start with what I found

I sat down to add one router to my monitoring. By the end of the night I had found out that my alerting had been dead for a little over two days, and I only found out because I tested it.

No alert told me. No dashboard went red. Prometheus was scraping, Grafana was drawing graphs, and everything looked healthy. The piece that actually delivers the bad news to my phone was sitting in a failed state, and it had nobody to tell.

That is the part of this write up I care about most. The router work is how I got there.

## The goal

I have a secondhand Cisco 2911 I had been labbing on over a console cable. Static IP, SSH only, scrypt secrets, login lockout, NTP, a config archive with rollback. It was time for it to stop being a toy on a shelf and become part of the lab.

That means two things:

1. **Security events go to Wazuh.** If someone fails a login on my router, I want the same alert I would get for a failed login on any server.
2. **Health goes to Prometheus and Grafana.** Is it up, how long has it been up, what is each port doing, is a cable throwing errors.

Two different questions, two different tools. That split is on purpose. Logs tell you what happened. Metrics tell you how it is doing.

## Plan A: syslog straight into the cluster

My Wazuh stack runs inside my Kubernetes cluster. Wazuh can listen for syslog directly, so the clean design looked obvious: add a syslog listener to the Wazuh worker, expose UDP 514 with a LoadBalancer service, point the router at it.

I backed up the Wazuh config first, added the listener, created the service, and confirmed the worker pod was listening on 514.

Then nothing. Not from the router. Not from a Linux box sending a test message with `logger`. Not even from a test pod **inside the same cluster** sending straight at the service.

When a packet from inside the cluster cannot reach a service inside the cluster, the router is not the problem. Something between the service and the pod was eating UDP, and I had already burned a good chunk of the evening proving it.

## Plan B: stop fighting the cluster

I already had a pipeline that worked. One of my Linux servers runs a Wazuh agent that has been shipping events to the manager over the normal agent channel for months.

So I stopped trying to make the cluster accept syslog and gave the router a relay instead:

```
router  --UDP 514-->  rsyslog on the Linux server  --file-->  Wazuh agent  --agent channel-->  Wazuh manager
```

rsyslog listens on 514, accepts traffic **only** from the router's IP, and writes it to its own log file. The Wazuh agent on that server watches that file. Nothing new has to cross the cluster boundary, because the agent channel was already proven.

I wrote it as one script: create the log folder, write the rsyslog rule, open the host firewall for the router only, add the file to the agent config (backing that up first), restart both services. Then repoint the router:

```
router(config)#no logging host <old cluster address>
router(config)#logging host <relay server> transport udp port 514
router#write memory
router#send log 4 relay test from cisco2911
```

## The bug in my own script

It did not work the first time, and this one was mine.

```
rsyslogd: error during parsing file /etc/rsyslog.d/10-cisco.conf, on or before line 9:
parameter 'port' not known -- typo in config file?
...
NOT LISTENING ON 514
```

My script checked whether the UDP input module was already loaded so it would not load it twice. It searched the main rsyslog config for `load="imudp"`, found it, and skipped loading the module.

The line it found was this:

```
#module(load="imudp")
```

Commented out. Ubuntu ships it that way. My check matched a comment, decided the module was loaded, and without the module rsyslog had no idea what `port` or `ruleset` meant. It threw the listener away and kept running like nothing happened.

The fix was one line at the top of my rule file. The lesson is bigger than the line: **when you grep a config to decide something, a comment matches just as well as a setting.**

## Proof

Second run:

```
UNCONN 0  0  0.0.0.0:514  0.0.0.0:*  users:(("rsyslogd",pid=206501,fd=6))
```

And the relay file:

```
%SEC_LOGIN-4-LOGIN_FAILED: Login failed [user: <redacted>] [localport: 22] [Reason: Login Authentication Failed]
%SEC_LOGIN-5-LOGIN_SUCCESS: Login Success [user: <redacted>] [localport: 22]
%SYS-4-USERLOG_WARNING: Message from tty389(user id: <redacted>): relay test two
%SYS-6-LOGOUT: User <redacted> has exited tty session 389
```

That failed login is real. I fat fingered my own password on the way in. Free test case.

Then the part that matters, what Wazuh did with it:

| Rule | Level | What it saw |
|---|---|---|
| 4724 | **9** | Cisco IOS: Failed login to the router |
| 4722 | 3 | Cisco IOS: Successful login to the router |
| 4714 | 3 | Cisco IOS warning message, USERLOG_WARNING |

Wazuh decoded the Cisco format on its own and tagged the failed login with PCI DSS 10.2.4 and 10.2.5, HIPAA 164.312.b, and NIST 800-53 AC.7 and AU.14. I did not write any of that. That is the value of getting logs into a SIEM instead of a text file nobody reads. Level 9 also crosses my Discord threshold, so a failed login on the router hits my phone.

Once it was confirmed, I deleted the Kubernetes service and pulled the unused listener out of the Wazuh config. Dead config is just future confusion.

## The health side: SNMPv3

For metrics I used SNMP, but not the way a lot of guides still show it. No `public` community string. SNMPv3 with authentication and encryption:

```
router#show snmp user
User name: <redacted>
Authentication Protocol: SHA
Privacy Protocol: AES128
Group-name: <redacted>
```

The SNMP group is tied to an access list that permits exactly one host, my monitoring server, and logs anything else that tries. Those denials go out over syslog with everything else, which means a stranger poking my router with SNMP lands in the same logs Wazuh collects. The two halves of this project cover each other.

On the monitoring side, `snmp_exporter` listens on localhost only. Prometheus scrapes the router through it every 60 seconds. I added the scrape job with a backup first and a `promtool` check that rolls the config back on its own if the check fails. Then I dropped a dashboard into Grafana as a provisioned file, so it lives in config and not only in a database.

First poll:

```
ifOperStatus{ifDescr="GigabitEthernet0/1",ifName="Gi0/1"} 2
ifOperStatus{ifDescr="Null0",ifName="Nu0"} 1
ifOperStatus{ifAlias="Clients",ifDescr="Loopback20",ifName="Lo20"} 1
```

`2` is down, `1` is up. Gi0/1 is down because nothing is plugged into it. That is correct, and it matters later.

## Uptime said no data

Everything on the dashboard filled in except **Router uptime**, which said "No data".

In the `snmp_exporter` version I installed, `sysUpTime` is not part of the interface module. It lives in a separate `system` module, and I was only asking for interfaces. One line in the scrape job, `module: [if_mib, system]`, and it came back:

```
value":[1792374995.143,"8616561"]
```

That number is hundredths of a second. 8,616,561 works out to about 23.9 hours, which matches the last reboot I did on the console the night before. Checking the number against something I already knew is how I trust it.

## The container that could not look anything up

My monitoring stack runs in an LXC container on my second Proxmox host. When the setup script tried to download the exporter:

```
curl: (6) Could not resolve host: github.com
```

The container could not resolve DNS at all. I got around it that night by downloading on the Proxmox host and pushing the file into the container, but I came back to fix it properly:

```
== DNS: before ==
nameserver 100.100.100.100
```

`100.100.100.100` is Tailscale's MagicDNS address. The Proxmox host runs Tailscale. When I built the container, it inherited the host's resolver settings, and that address only answers on a machine that is actually on the tailnet. The container is not. So every lookup went to an address that could never answer.

I set the container's DNS in its Proxmox config, pointing at my firewall's resolver with a public resolver as backup, so it survives restarts:

```
140.82.112.3    github.com
github https: 200
```

Nothing had broken yet because nothing in that container had needed the internet. It would have broken the first time Grafana tried to install a plugin.

## The test alert that found the real problem

With the data flowing, I added four alert rules for the router in Prometheus:

| Alert | Fires when |
|---|---|
| CiscoRouterDown | SNMP stops answering for 3 minutes |
| CiscoInterfaceDown | A port that was up in the last 24 hours goes down while still enabled |
| CiscoRouterRebooted | Uptime drops under 15 minutes |
| CiscoInterfaceErrors | More than 20 errors on a port in 10 minutes |

The interface rule is written so it does **not** fire for ports that were never up (like Gi0/1) or ports I shut down on purpose. An alert that is always firing teaches you to ignore alerts.

Every rule passed `promtool`. Then I sent a test alert, because a rule nobody has seen fire is a guess.

```
amtool: error: Post "http://127.0.0.1:9093/api/v2/alerts":
dial tcp 127.0.0.1:9093: connect: connection refused
```

Nothing was listening where Alertmanager should be. So I went looking:

```
prometheus-alertmanager.service   loaded   failed   failed   Alertmanager for prometheus
```

And the journal said exactly when and why:

```
Oct 16 15:46:51 level=ERROR msg="unable to initialize gossip mesh"
  err="create memberlist: Failed to get final advertise address: No private IP address found, and explicit IP not provided"
Oct 16 15:46:52 Scheduled restart job, restart counter is at 5.
Oct 16 15:46:52 Start request repeated too quickly.
Oct 16 15:46:52 Failed to start prometheus-alertmanager.service
```

October 16 was the day I powered the whole lab down to blow the dust out. Proper shutdown, everything came back up, nothing looked wrong.

Here is what happened. Alertmanager has a clustering feature for running several copies together, and it is on by default. At startup it looks for a private IP to advertise to its peers. On that boot, it started before the container's network finished coming up, found no IP, and crashed. systemd retried five times in about a second, hit its limit, and gave up for good.

From 15:46 on October 16 to 21:26 on October 18, every alert Prometheus fired went nowhere. **53 hours.** Node alerts, storage alerts, site alerts, all of it.

I run exactly one Alertmanager. It has no peers. So the fix was to turn clustering off with `--cluster.listen-address=` (empty on purpose), which removes the step that crashes:

```
config: ARGS="--cluster.listen-address= "
alertmanager: active
gossip mentions since restart: 0
```

Then I checked what was still firing, because two days of silence could be hiding something real. The list was empty. Prometheus resends active alerts every minute, so empty means nothing in the lab was actually broken. I got lucky. The point of alerting is that you are not supposed to need luck.

## While I was in there

My Wazuh feed had been posting alerts for a CIS check, "Ensure ip forwarding is disabled", on my Kubernetes nodes. Those nodes **have** to forward packets. That is how pod traffic moves. So that check will always fail there, and that is correct.

I had written a suppression rule for this back in July. I went to look at it, and it was gone from both Wazuh managers. I do not know when it disappeared.

I rewrote it tighter than the first time. It only applies to agents whose names match my cluster nodes, and only to checks with "ip forwarding" in the title:

```xml
<rule id="100100" level="0">
  <if_sid>19007,19008,19009,19010,19011</if_sid>
  <location type="pcre2">^\(cluster-node-\d+\)</location>
  <field name="sca.check.title" type="pcre2">(?i)ip forwarding</field>
  <description>Suppressed: IP forwarding is required on cluster nodes.</description>
</rule>
```

Every other CIS failure on those nodes still alerts. Any server that is **not** a cluster node and turns on forwarding still alerts. Silence the one thing you understand, not the whole category.

The script tested the config with `wazuh-analysisd -t` before restarting anything, with an automatic rollback if the test failed. It passed. Then `wazuh-control restart` inside the container hung for over five minutes and never returned. I killed the wait and checked state instead of trusting the command:

```
wazuh-clusterd is running...
wazuh-remoted is running...
wazuh-analysisd is running...
```

Rule present on the master, and the Wazuh cluster had already copied it to the worker on its own. Done.

## What I got wrong

- **I spent too long on Plan A.** Once a test pod inside the cluster could not reach the service, I had my answer that the problem was not the router. I kept poking at it anyway. I should have switched to the relay as soon as the test from inside the cluster failed.
- **My own script had the comment bug.** I wrote a check that looked smart and was not.
- **I asked SNMP for the wrong module** and briefly thought uptime was broken on the router.
- **I never tested my alerting after the October 16 power cycle.** Everything looked up, so I assumed it was. That assumption cost 53 hours of coverage.

## What is still open

- **Nothing watches the thing that sends the alerts.** If Alertmanager dies again, it still cannot tell me. The real fix is a dead man's switch: an alert that fires constantly on purpose, sent to an outside service that pages me when it **stops** arriving. That is the next thing I am building.
- **I never found the real reason UDP died inside the cluster.** The relay works and is arguably the better design, but an unexplained failure in my cluster's networking is still sitting there.
- **My suppression rule vanished once without me noticing.** Wazuh custom rules should live in git next to the rest of my config, not only inside a container.

## Things worth keeping

1. **Test the alert path, not just the alert rule.** A rule that passes validation and an alert that reaches your phone are two different claims.
2. **"Everything looks green" is not evidence.** A dead alerting system looks exactly like a healthy lab.
3. **After any planned shutdown, check for failed services.** Mine is now one line: `systemctl --failed` on the monitoring host and a check for any pod that is not Running.
4. **Use the pipeline you already proved.** I lost more time forcing a new path into the cluster than it took to build the relay on a path that already worked.
5. **Scope suppressions to exactly what you understand.** One check, on the hosts where it is expected, nothing wider.
