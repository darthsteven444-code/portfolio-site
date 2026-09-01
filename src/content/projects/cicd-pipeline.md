---
title: "building the pipeline that ships this site"
description: "going from hand-built container images at 2am to a real CI/CD pipeline, hardened, non-root, and pushed to a registry automatically on every version tag."
date: 2026-07-24
tags: ["ci-cd", "github-actions", "docker", "ghcr", "devops"]
---

## Building Images by Hand Is a Liability

For a while, deploying an update to this very website meant SSHing into a box, running `docker build`, running `docker push`, and hoping I typed the tag right. It worked. It was also a trap, and I found out exactly how much of a trap when I went looking one night.

The deployment was pointed at an image tag, `v2`, that had never actually been pushed to the registry. The site was only running because the image happened to be *cached* on the nodes from an earlier build. One pod reschedule, one node reboot, and my portfolio would've gone dark with no image to pull. It looked perfectly healthy right up until the moment it wouldn't have been.

That's the whole problem with manual builds: they hide latent failures behind currently-running pods. So I fixed it the right way, twice over. First the image, then the pipeline that builds it.

## Fixing the Image: Non-Root by Default

The original container ran nginx as root, on port 80, with a full set of Linux capabilities it never used. That's how the default nginx image ships, and it's how most people leave it. My own cluster's Pod Security policy was flagging it on every deploy. A warning I'd been walking past.

So I rebuilt it properly:

- Switched the base image to the unprivileged nginx build, which runs as a non-root user (UID 101) on a high port
- Added a full security context to the deployment: `runAsNonRoot`, dropped all Linux capabilities, blocked privilege escalation, enforced a seccomp profile
- Rewired the service and ingress so the port change was invisible to the outside world, the site never blipped

The payoff: the container now meets Kubernetes' strictest `restricted` security standard, and that nagging PodSecurity warning is gone. This is the kind of hardening you can actually *do* on an image you own. Unlike upstream vendor images where you're stuck accepting their choices.

## Building the Pipeline: Ship on a Tag

Then the real fix, killing the manual build entirely. I wrote a GitHub Actions workflow so that pushing a version tag does everything automatically:

```
git tag v5
git push origin v5
```

That's it. The pipeline wakes up, checks out the code, logs into the container registry using a token GitHub injects automatically (no secrets for me to manage or leak), builds the hardened image from the Dockerfile, and pushes it to GitHub Container Registry tagged to match. A git tag goes in; a published, hardened, versioned image comes out. Zero manual steps.

## The Snags Were the Education

Here's the honest part, it didn't work on the first try, and the failures taught me more than a clean run would have.

First wall: the push got rejected because my Git access token was missing the `workflow` scope, GitHub refuses to let a token create or modify pipeline files without it, as a guard against a leaked token injecting malicious CI. A sensible protection, and a good thing to learn by hitting it.

Second wall: the first pipeline run built the image perfectly, then *failed on the push*. `permission_denied: write_package`. The build was flawless; the registry just wouldn't accept it. The fix was linking the container package to the repository with write access, because a package originally created by a manual push doesn't automatically trust an automated one.

Neither of those is in the tutorials. Both of them are exactly what shipping real CI/CD actually feels like, the workflow logic is the easy part, and the last mile is permissions and trust between systems. Now I've solved them once, and I'll recognize them instantly next time.

## The Full Circle

The satisfying part: the pipeline I built is what ships the page you're reading right now. I write a project page, commit it, push a tag, and GitHub builds and publishes the new site image on its own. The tool describes its own creation and then deploys itself. That's the loop I was chasing.

## What I Learned

- *Manual builds hide latent failures*, a deployment pointing at a tag that doesn't exist looks fine until the exact worst moment
- *Harden the images you own*, non-root, dropped capabilities, seccomp, meeting the `restricted` bar instead of walking past the warning
- *GitHub Actions build-on-tag*, a clean, reproducible `git tag` → build → push to a registry, using the built-in token with no secrets to manage
- *The last mile of CI/CD is trust and permissions*, token scopes and package access are where real pipelines break, not the YAML
- The point of the whole thing: a pipeline turns "I hope I pushed that image" into "the system pushed it, correctly, every time"
