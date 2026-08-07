# steven-garcia.dev

Personal portfolio and engineering notebook — an Astro static site that runs on **two Kubernetes clusters in two states**, built and shipped by CI as a multi-architecture container.

**Live:** [steven-garcia.dev](https://steven-garcia.dev)

Roughly half the traffic to this site is served from a homelab in Texas. The other half comes from ARM instances in an Oracle Cloud datacenter in Phoenix. Both are behind a single Cloudflare Tunnel, so if one goes down the other keeps serving.

---

## Architecture

```
                      Cloudflare (TLS, WAF, CDN)
                               |
                    ┌──────────┴──────────┐
                    │   one tunnel, two   │
                    │   active replicas   │
                    └──────────┬──────────┘
              ┌────────────────┴────────────────┐
              │                                 │
    cloudflared @ homelab              cloudflared @ Oracle Cloud
    (linux/amd64, DFW + IAH)           (linux/arm64, LAX)
              │                                 │
        k3s cluster                        OKE cluster
        3 nodes, Ubuntu 24.04              2 nodes, Oracle Linux 9
        containerd                         cri-o
        Proxmox VMs, my house              VM.Standard.A1.Flex, Phoenix
              │                                 │
              └────────► same container ◄───────┘
                    ghcr.io/…/portfolio:vN
                    linux/amd64 + linux/arm64
```

No inbound ports are open on the home network. The tunnel dials outward.

---

## Stack

**Site**
- Astro 5 — static generation, zero JavaScript shipped by default
- Tailwind CSS v4
- Markdown content via Astro Content Collections
- ~15 lines of vanilla JS for the screenshot lightbox. No framework.

**Container**
- Multi-stage build: Node builder → `nginxinc/nginx-unprivileged:alpine`
- Runs as **non-root** (uid 101) on port 8080, no privilege escalation
- Multi-arch: `linux/amd64` and `linux/arm64` from one manifest
- Builder stage pinned to `$BUILDPLATFORM` so the site compiles once natively instead of twice under QEMU

**CI/CD**
- GitHub Actions on `v*` tags → buildx → GHCR
- QEMU + Buildx for cross-architecture builds, GHA layer cache
- Deploy is a `kubectl set image` against both clusters

**Where it runs**
- **Homelab:** k3s on Proxmox VMs, behind OPNsense with five VLANs
- **Cloud:** Oracle Kubernetes Engine, provisioned entirely with **Terraform**, sized to the Always Free tier at $0/month
- **Edge:** Cloudflare Tunnel — two replicas, active-active

**Operations**
- Prometheus + Grafana + Alertmanager, with a blackbox exporter probing this site every 15 seconds
- Loki + Alloy for centralized logs from both clusters
- Prometheus agent on the cloud cluster remote-writing metrics home over Tailscale
- Wazuh SIEM monitoring every node, cloud included
- Velero backups nightly, with a second offsite copy in Oracle Object Storage
- Trivy scanning every image, default-deny NetworkPolicy across namespaces

---

## Local development

```bash
npm install
npm run dev -- --host 0.0.0.0    # http://localhost:4321
npm run build                     # static output in ./dist/
```

The build output is plain static files — deploy `./dist/` anywhere.

## Container build

```bash
docker buildx build --platform linux/amd64,linux/arm64 -t portfolio:local .
```

## Release

```bash
git tag v15 && git push origin v15    # CI builds and pushes to GHCR
```

---

## Project structure

```
.github/workflows/build.yml    multi-arch buildx pipeline
src/
├── assets/                    network topology diagram (SVG)
├── components/
│   └── ProjectSummary.astro   per-project summary + skills box
├── content/projects/          write-ups in markdown
├── layouts/Base.astro         shared shell, nav, hiring footer, lightbox
├── pages/
│   ├── index.astro            hero, live metrics, project grid
│   ├── infrastructure.astro   architecture overview + evidence gallery
│   └── projects/[...slug]     dynamic project routes
└── styles/global.css          design system (navy + gold, design tokens)
public/
├── shots/                     screenshots from the live environment
└── resume.pdf
Dockerfile                     multi-stage, non-root, multi-arch
```

---

## Why it's built this way

I'm a U.S. Navy veteran finishing an A.A.S. in Computer Information Systems in May 2027, working toward a first role in IT and infrastructure. I don't have professional IT experience yet — so instead of waiting for someone to hand me a production environment, I built one.

Everything above I designed, deployed, broke, repaired, and documented myself. The write-ups on the site cover the failures as carefully as the successes, because the failures are where the actual learning happened.

If it loads, the pipeline works.
