---
title: "the detection rule that disappeared"
description: "a custom SIEM rule I wrote months ago was gone and nothing told me. so I stopped hand editing rules on a running box and built a pipeline that will not let that happen again, then sent one of the rules upstream."
date: 2026-10-21
category: detection engineering
tags: [Wazuh, Detection as Code, Sigma, GitHub Actions, Kubernetes, Cisco IOS, MITRE ATT&CK, CI/CD]
status: "Complete, upstream pull request open"
duration: "Two evenings"
stack: [Wazuh 4.14 on k3s, Git, GitHub Actions, Python, Bash, wazuh-logtest, Sigma, sigma-cli]
outcome: "Custom detections live in version control with two gates in front of them, a CI check that needs no SIEM and a live test that fires real log lines at the real manager. Three of three test cases pass and the deploy script writes to both managers and verifies them. One of the rules is now an open pull request at SigmaHQ."
skills: [Detection engineering, CI/CD pipeline design, Test design, Debugging, Kubernetes operations, Open source contribution, MITRE ATT&CK mapping]
---

## Start with what I found

I went looking for a rule I wrote months ago. It suppressed a specific piece of Kubernetes noise that was filling my alert feed, rule 100100. I remembered writing it. I remembered it working.

It was not there.

Not disabled, not broken, not throwing errors. Gone. No alert fired when it left. No dashboard changed color. The SIEM carried on exactly as if that rule had never existed, which from its point of view was true.

I never found the exact moment it died. A restart, a redeploy, a config regeneration, any one of those would do it. That is the honest answer and it is also the point. The rule was only ever stored in one place, which was the running system, and the running system is the one thing in my lab I cannot promise will survive the week.

So the real problem was never rule 100100. The real problem was that my detections had no source of truth.

## What I was actually doing wrong

Every custom rule I had written went in the same way. Open a shell on the manager, edit the file in place, restart, eyeball an alert, move on.

That workflow has no answer to any of the questions that matter:

- what rules am I supposed to have right now
- did this edit break the ones that already worked
- if this box burns down, what do I put on the new one
- did the rule I just wrote actually catch anything, or did I just believe it would

I was writing detections the way you write a sticky note. The fix is to write them the way you write software.

## The shape of the fix

![the pipeline, edit through to deploy](/shots/dac-pipeline.webp)

A repo holds the rules, the decoders, and a plain text file of test cases. Nothing reaches the SIEM without passing two gates, and the gates test different things on purpose.

Gate one runs in CI on a cold runner with no SIEM anywhere near it. Gate two runs against the real manager with real log lines. The first one catches the mistakes that are obvious once a machine looks at them. The second one catches the mistakes that only show up when a rules engine actually reads your work.

Then a deploy script puts the rules on both managers, checks the config before restarting anything, and verifies afterward.

## Gate one, and the detour I took to get there

My first idea was to run the whole thing in CI. Stand up a Wazuh manager container on the GitHub runner, fire the test log lines at it, assert on the rule ids. Full fidelity, no cluster needed.

It failed twice. The manager container came up, but the analysis daemon never got to a ready state on the runner. I gave it ninety seconds. Then I gave it a hundred and eighty seconds. It just sat there, and I sat there with it, watching a red X on a job that was testing the test harness instead of the rules.

That is the kind of problem where you have to ask what the gate is for. I wanted CI to tell me quickly and reliably that I had not broken anything. Booting a full SIEM to find that out is a lot of machinery for a question that mostly comes down to whether the XML parses and whether I reused a rule id.

So gate one became a Python script that reads the files and checks them directly:

- does every file parse as well formed XML
- is any rule id used twice
- does every rule have a description and a level

The first two fail the build. The last two only warn, because a missing description is sloppy, not dangerous.

![the CI gate passing on a runner with no SIEM on it](/shots/dac-validate.webp)

One wrinkle worth writing down. Wazuh rule and decoder files are not valid standalone XML documents. They have multiple root elements, and my decoder file at the time was nothing but comments, which parses as no document at all. A plain parser rejects both. The script wraps the file contents in a synthetic root element before parsing, which lets a normal XML parser check the thing Wazuh actually cares about without me pretending the file is something it is not.

Gate one now runs in a few seconds and does not need anything running. That is what made it worth keeping.

## Gate two, and the bug that cost me the most time

Gate two fires real log lines at the real manager through the Wazuh log testing tool and asserts on what comes back. Three cases: a Cisco failed login should hit my rule, a Cisco lockout should hit the other one, and the Kubernetes noise should be dropped.

First run said this:

```
cisco failed login      expect 100210  got id=none   FAIL
FAIL  1 ran, 2 never ran, 0 passed
```

One of three cases ran. The other two never executed at all, and the one that did ran against nothing. My first read was that the rules were broken, which is the wrong read and cost me a while.

The test loop reads the case file line by line on standard input. Inside that loop it calls into the cluster to run the log test. The call into the cluster was passing a flag that attaches standard input to the remote process, and standard input at that moment was the case file. So the first iteration handed the entire remaining test file to the remote command, which ignored it, and the loop had nothing left to read.

The rules engine got an empty line and said what it should say. No rule matched nothing. `id=none`.

Two changes fixed it. Drop the flag that attaches standard input, explicitly give the remote command nothing to read, and move the loop onto its own file descriptor so no child process can ever eat it again.

```
done 3< "$ROOT/tests/tests.txt"
```

That last part is the lesson. The loop was correct and the rules were correct. The pipe between them was the bug, and it presented as a detection failure. If I had trusted the error message I would have rewritten two perfectly good rules.

![three of three, with the probe detail underneath](/shots/dac-logtest.webp)

Addresses in that output are placeholders. The real one is a router on my own network.

The probe detail at the bottom is the part I care about. Rule 4724, level 9, tagged for PCI DSS, HIPAA and NIST 800-53. That is not something I wrote, it is Wazuh's own Cisco coverage firing correctly because the log actually arrives and actually decodes. My custom rules sit on top of a pipeline that works, which is the order you want.

## Deploy, and the fact that there are two managers

My SIEM runs a master and a worker. A rule on one and not the other is worse than a rule on neither, because it looks fine from whichever one you happen to check.

So the deploy script does the boring things in the boring order. Copy the files to both. Run the configuration test on both before touching a service, because a bad rule file will take the analysis daemon down and then you have no SIEM at all. Restart with a timeout so a hung restart does not hang the whole script. Then go back and confirm the rule is actually present on both.

It is not clever. It is the same five steps every time, which is the entire reason it is in a script instead of in my head.

## Sending one upstream

The second rule in the repo detects a Cisco device going into quiet mode, which is what happens when the login lockout I configured actually trips. It is a brute force signal and it has a clean, unambiguous string in the log.

That is general. It is not specific to my lab at all. Anyone running a Cisco device with login blocking would want it.

So I wrote it as a Sigma rule and opened a pull request at SigmaHQ.

![the rule in Sigma format](/shots/dac-sigma.webp)

Their standards are tighter than mine were, which was the useful part. Title casing, a UUID, status, references, false positives, and MITRE ATT&CK tags that have to be the right technique and not just the right neighborhood. This maps to T1110.001, password guessing, because that is what a lockout means happened.

It passes all three of their local test suites. It is pull request 6488 and it is waiting on a maintainer, which is normal and not something I can speed up.

Writing a rule for someone else's repo changed how I write them for mine. False positives became a field I have to fill in rather than something I think about later and forget.

## What I got wrong

I spent an evening trying to run a full SIEM inside a CI runner before asking what the CI gate was supposed to prove. The answer was a lot smaller than what I was building, and the smaller answer is the one that runs in seconds and has never flaked since.

I trusted an error message that was describing a symptom. `id=none` reads like a detection problem. It was a plumbing problem two layers away, and I nearly rewrote working rules because of it.

I also went back and reconstructed rule 100100 from memory rather than from anything written down, because there was nothing written down. It is in the repo now. That it took losing it to get it there is not a great look, and it is why this write up exists.

## What is still open

The pipeline prevents the next disappearance. It does not detect one. If a rule vanishes off a manager tomorrow, git still has it and deploy will put it back, but nothing is going to tell me it left. Comparing what is deployed against what is in the repo on a schedule is the obvious next piece and I have not built it.

The repo has two custom rules in it. Two rules is not a detection library, it is a pattern with proof. The point was the pipeline, and now that it exists the cost of adding the third rule is small, which is the whole return on this.

The Sigma pull request is open and out of my hands.

## Things worth keeping

Anything that only exists on a running machine is not something you have. It is something you are currently borrowing.

Make your tests test different things. A fast gate that needs nothing catches a different class of mistake than a slow gate that needs everything. Running both is cheap. Collapsing them into one means picking which kind of mistake you are willing to ship.

When a test harness fails, suspect the harness. A detection that reports no match looks exactly like a detection that never got a line to look at.

Write one rule for a stranger. The things a public repo makes you fill in are the same things that make a rule reviewable in six months, and you will not discover which ones you were skipping until someone else's template asks.
