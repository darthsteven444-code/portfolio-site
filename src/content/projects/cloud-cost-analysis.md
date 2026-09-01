---
title: "What Cloud Actually Costs (I Ran Both)"
description: "I built the same Kubernetes workload twice, once on hardware I own, once in Oracle Cloud, and then did the math on what each one really costs. Spoiler: the free one isn't free, and the expensive one isn't expensive."
date: 2026-08-07
tags: ["cloud", "kubernetes", "cost", "oracle-cloud", "terraform"]
status: "Running, both clusters live"
duration: "3 days"
stack: ["Oracle Cloud (OKE)", "Terraform", "Kubernetes", "k3s", "Proxmox", "Cloudflare Tunnel", "Prometheus", "Velero"]
outcome: "A managed Kubernetes cluster running in Oracle Cloud at $0/month, serving the same site as my homelab, with a real cost comparison behind it."
skills: ["Cloud cost analysis", "Infrastructure as Code", "Terraform", "Managed Kubernetes", "Capacity planning", "Hybrid architecture", "TCO modeling"]
---

Everybody says "just use the cloud." Everybody else says "the cloud is a scam, self-host everything."

I got tired of the argument, so I built the same thing twice.

Same Kubernetes version. Same container image. Same site. One runs on a server in my house. The other runs on ARM instances in a Phoenix datacenter. Both are live right now, and if you're reading this, there's roughly a coin-flip chance it came from Oracle Cloud instead of my closet.

Then I sat down and did the math. It surprised me.

## The two-day-old cloud bill

Let's start with the number everybody wants.

<figure class="shot">
  <img src="/shots/oci-billing-zero.webp" alt="Oracle Cloud billing dashboard showing $0.00 of $300.00 trial credits used after 2 of 30 days" loading="lazy" decoding="async" />
  <figcaption><b>Two days in. Zero dollars spent.</b> Not because I'm being careful with trial credits, because everything I built sits inside Oracle's Always Free tier, which doesn't expire when the trial does.</figcaption>
</figure>

That $300 is trial credit I haven't touched. The cluster, the two worker nodes, the block storage, the object storage, the load balancer. All of it lands inside Always Free limits. When the 30-day trial ends, the meter stays at zero.

So the honest headline is: the cloud half of my infrastructure costs me nothing.

Now let me explain why that sentence is more complicated than it sounds.

## What "free" actually buys you

Here's the exact envelope I built inside:

| Resource | Always Free limit | What I used |
|---|---|---|
| OKE control plane | Free (Basic tier) | 1 cluster |
| ARM compute | 2 OCPUs / 12 GB **total** | 2 nodes × 1 OCPU / 6 GB |
| Block storage | 200 GB | 100 GB (2 × 50 GB boot) |
| Object storage | 20 GB | Velero backups |
| Load balancer | 1 flexible, 10 Mbps | 0 (used NodePort) |
| Outbound transfer | 10 TB/month | Nowhere close |

Read that ARM line again, because it's the whole game: 2 OCPUs and 12 GB across the entire tenancy. Not per instance. Oracle quietly halved that limit in June 2026. It used to be 4 and 24.

That constraint drove every design decision. Two nodes instead of three. One vCPU each. No NAT gateway, because NAT isn't free, which is why my worker nodes sit on a public subnet with firewall rules doing the work instead. No LoadBalancer service, because a misconfigured one provisions at a billable shape. Prometheus running in *agent* mode, shipping metrics home instead of storing them, because storage costs memory I don't have.

Designing inside a hard constraint is a skill. It's the same skill as designing inside a budget.

<figure class="shot">
  <img src="/shots/oci-instance-1.webp" alt="Oracle Cloud instance details showing VM.Standard.A1.Flex shape with 1 OCPU and 6 GB memory" loading="lazy" decoding="async" />
  <figcaption><b>One of the two ARM workers.</b> VM.Standard.A1.Flex, 1 OCPU, 6 GB, Oracle Linux 9.8 on aarch64. Two of these is exactly the Always Free ceiling. One more OCPU and the whole thing starts billing.</figcaption>
</figure>

## What the same cluster costs if you pay for it

This is the number that matters, because "free tier" isn't a business plan. If I built this for an employer, here's the monthly bill:

| Provider | Equivalent setup | Monthly |
|---|---|---|
| **Oracle OKE** | Basic control plane free + 2× A1.Flex (1 OCPU / 6 GB) | **~$18** |
| **DigitalOcean DOKS** | Free control plane + 2× 2vCPU/4GB | **~$48** |
| **Google GKE** | Free zonal control plane + 2× e2-medium | **~$50** |
| **Azure AKS** | Free control plane + 2× B2s | **~$60** |
| **AWS EKS** | $73 control plane + 2× t4g.medium | **~$122** |

Same workload, and the spread is nearly 7×. Most of that gap is a single line item: AWS charges $73/month just for the control plane. The part you never see and can't log into. Oracle, Google, Azure, and DigitalOcean all give it away and charge you for nodes.

If someone tells you "we're on Kubernetes in the cloud, it costs about $X," your first question should be which provider and whether that includes the control plane.

## And now the part nobody puts in the comparison

Here's where I have to be honest about my own side of the argument, because the homelab isn't free either.

My hypervisor is a Dell T7910, dual Xeon E5-2699 v4, 128 GB of RAM, running 17 VMs. I bought it used. But the real cost isn't the purchase price, it's the wall socket.

| Line item | Cost |
|---|---|
| Hardware (used, one-time) | ~$700 |
| Power at ~250W continuous, ~$0.14/kWh | **~$25/month** |
| Amortized hardware over 4 years | ~$15/month |
| **Effective monthly** | **~$40** |

My "free" homelab costs about $40/month to run. The Oracle cluster costs $0.

That was not the answer I expected when I started this.

## So why keep the homelab?

Because the comparison above measures the wrong thing.

That $40/month isn't buying me two ARM nodes. It's buying 17 virtual machines, 128 GB of RAM, 10 TB of storage, a Windows domain with its own certificate authority, a SIEM, a firewall with five VLANs, and. Most importantly. permission to break things.

Try building the equivalent in the cloud:

| What I run at home | Rough cloud equivalent |
|---|---|
| 17 VMs, 128 GB RAM | ~$800+/month in compute |
| 10 TB storage | ~$200+/month |
| Windows Server domain | licensing + instance |
| Full SIEM stack | ~$150+/month |
| **Total** | **north of $1,000/month** |

Forty dollars a month for a thousand dollars of learning environment is not a bad trade. And the cloud version bills you while you're asleep, whether or not you learned anything that day.

## Where each one actually wins

After running both, this is what I'd tell someone asking:

Self-hosting wins when the workload is steady, you already own the hardware, you need lots of RAM or storage cheaply, or you need to break things without a bill attached. Learning environments are the clearest case. Cloud pricing punishes experimentation, and experimentation is the entire point.

Cloud wins when the workload is spiky, when you need geographic distribution, when someone else patching the control plane is worth real money, or when the thing absolutely cannot go down with your house. My homelab has had two outages this month. Oracle's control plane has had zero, and I've never once thought about it.

The honest answer for most companies is both, which is the architecture I ended up with by accident. My site now serves from two clusters through one Cloudflare tunnel: my house and Phoenix, active-active.

<figure class="shot">
  <img src="/shots/cf-tunnel-two-replicas.webp" alt="Cloudflare tunnel dashboard showing two active replicas, one linux_amd64 from linux-lab and one linux_arm64 from the Oracle Cloud cluster" loading="lazy" decoding="async" />
  <figcaption><b>One tunnel, two origins, two architectures.</b> The top replica is my homelab on amd64 routing through Dallas and Houston. The bottom is Oracle Cloud on arm64 routing through Los Angeles. Cloudflare load-balances between them, so if my house loses power, this page keeps loading.</figcaption>
</figure>

The kicker: doing failover *properly* through Cloudflare's Load Balancing product costs about $5/month. Running a second tunnel replica gets me the same outcome for nothing, and it fails over faster because there's no health check to wait on.

Sometimes the cheap option is also the better one. Not always. But it's worth checking before you file the purchase request.

## What this cost me to learn

Three days, about a dozen failed `terraform apply` runs, and one genuinely useful discovery: an OCI tenancy won't create a Kubernetes cluster until you write a policy granting the OKE service permission to act on your behalf. Being the tenancy admin yourself isn't enough. The error message says `NotAuthorizedOrNotFound`, which sounds like your credentials are wrong. They aren't.

I also learned that Velero's S3 client sends checksum headers Oracle rejects, and that the resulting `SignatureDoesNotMatch` error has nothing to do with signatures.

Both of those cost me an hour each. Both are now written down.

---

*Everything here I built, broke, and fixed myself. I'm a CIS student finishing in May 2027 with no professional IT experience yet, so treat the numbers as researched and the architecture as real, because both are, but know that I learned this by doing it rather than by being paid for it.*
