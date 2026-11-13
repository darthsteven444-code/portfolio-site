---
title: "the keys I didn't know I was handing out"
description: "three systems in my lab, a kubernetes cluster, a bot I built, and a cloud ticketing integration, all ended up holding more access than they used. this is me walking each one back to the least it could get away with."
date: 2026-11-13
category: "security and monitoring"
tags: ["least privilege", "RBAC", "Kubernetes", "ServiceNow", "IAM", "service accounts", "threat modeling"]
status: "Done, and now a habit"
duration: "Spread across a few projects"
stack: ["Kubernetes (k3s)", "Wazuh", "ServiceNow", "Windmill", "Discord"]
outcome: "Six workloads lost API tokens they never called, two dead god-mode credentials got deleted, the bot that can touch my cluster can only do three things and read no secrets, and the cloud integration was proven to be a one way door with the audit output to show it."
skills: ["Least privilege design", "Kubernetes RBAC", "IAM", "Service account scoping", "Threat modeling", "Cloud integration security"]
---

## the pattern I kept noticing

Three separate projects, three different systems, same problem every time. I would build something, get it working, and then go back and find it was holding way more access than it actually used. A pod sitting on a cluster token it never called. A bot I wrote that could delete anything it wanted. A cloud account one setting away from reaching back into my network.

None of it was on fire. That is the thing about too much privilege, it does not show up as a problem until the day something gets popped, and then the extra access is the difference between a bad hour and a bad month.

So this one is not a single project. It is the same question asked three times. What is the least this thing needs to do its job, and why does it have more than that.

## one: the cluster was handing out tokens nobody used

I went looking at who could do what in my k3s cluster and found two things worth fixing.

The first was service account tokens. Six workloads, my portfolio site and every Wazuh component, were mounting a Kubernetes API token by default. Not one of them makes an API call. They did not need the credential, they were just handed one because that is what Kubernetes does unless you tell it not to. If any of those containers got popped, the attacker would find a working cluster credential already sitting in the pod, ready to start mapping the place. So I turned off the automatic token mount on the default service accounts in those namespaces. The pods kept working, because they were never using it.

The second was leftover god mode. Two `cluster-admin` bindings from install jobs that had finished twelve days earlier were still there. Dead credentials with full control of the cluster, bound to nothing that was still running. I deleted them.

What is left with `cluster-admin` after that is two things, and both are supposed to have it. The built in masters group, and my backup tool, which genuinely needs cluster wide read to back the cluster up. That is the point of the audit. You are not trying to get the count to zero, you are trying to get it down to the things that can explain why they are on the list.

## two: I built a bot, so I had to decide what it is allowed to break

Later I built a bot that watches my alerts, works out what broke, and, after I approve it in Discord, restarts the thing that is wedged. A bot that can restart pods is a bot that can take your cluster down if it goes wrong, or if the part of it that decides what to do is a language model, which mine is.

So before it touched anything I gave it its own account with a role that lists exactly what it may do. It can read pods, logs and events. It can delete a pod. It can read and restart a deployment. That is the whole list. It cannot read secrets. It cannot create anything. It cannot touch a namespace it has no business in.

The reason that list is short is the same reason the approval step exists. I do not fully trust the thing deciding what to do, so I made sure the worst decision it could make is still something I can live with. A bot that can only delete a pod and restart a deployment, even on its worst day, is doing something Kubernetes already does on its own ten times a week. That is the bar. Give the automation the smallest blast radius that still lets it do the job.

## three: the cloud integration that could have been a back door

The same bot opens a ticket in ServiceNow for every alert and closes it when a fix is approved. ServiceNow is a cloud service. My lab is not. So the question changes from what can this account do to could this connection be used to reach into my network, because that is the one that actually matters when you wire your lab to something you do not control.

The account the bot uses has one role, the basic ITIL role, and nothing else. It is set as an integration user, which means it cannot log into the website at all, it can only talk through the API. The connection goes one way, my lab calls out to ServiceNow, ServiceNow never calls in, and the only thing the bot keeps from a reply is the ticket number. Lab details get scrubbed out of the text before anything leaves, so IPs, hostnames and anything key shaped never make the trip.

Then I tested it instead of trusting it. I had the account try the things that would actually be dangerous and watched them all get refused.

```
incident (make tickets):      ok
server scripts:               blocked (http 403)
scheduled scripts:            blocked
outbound REST messages:       blocked
MID servers:                  blocked
```

That MID server line is the one I cared about most. A MID server is an agent you install inside your own network so ServiceNow can reach in. It is the one feature that would turn this integration into a real door into my lab. The account cannot make one, and I am never going to install one by hand, so the door does not exist. The rest of the list is the account being unable to run code or make the instance call out somewhere, which is exactly what you want a ticket bot to be unable to do.

## the why, said plainly

Least privilege is not a tool you install. It is a question you make yourself answer every single time you hand something a key. What is the least this needs. The three systems above had nothing in common technically, a container platform, a bot, a SaaS account, but the mistake was identical in all three, and so was the fix.

The reason it is worth doing when nothing is wrong is that the whole value is sitting there for the day something is. On a normal day, a pod with an unused token and a pod without one look exactly the same. The difference only shows up the day one of them gets compromised, and by then it is too late to go take the key back.

## what is still open

Two accounts still hold `cluster-admin` and both have a reason, but "has a reason today" is a thing worth re-checking, so a scheduled review of who holds broad access is on the list rather than me remembering to look.

The ServiceNow account is locked down on the things that matter, but its credentials still live in my automation platform, so the next move there is rotating them on a schedule instead of when I happen to think about it. Locking down what an account can do and making sure its password does not go stale are two different jobs, and I have only finished the first one.

## things worth keeping

Access you are not using is not a convenience, it is a liability sitting quietly until someone else finds a use for it.

When you automate something, scope it to its worst day, not its normal one. The question is not what does this need to work, it is what is the most damage it can do if the thing driving it is wrong, and are you okay with that number.

When you wire your own stuff to something in the cloud, the real question is never what the integration can do for you, it is whether it can be turned around and used to reach back. Test that it cannot, do not assume it.

And test the lockdown instead of trusting it. The difference between "I set it to blocked" and "I watched it get a 403" is the difference between hoping and knowing.
