---
display_name: Kubernetes + Sysbox (Docker-in-Workspace)
description: Full Docker-in-workspace via sysbox-runc — no privileged mode required.
icon: /icon/docker.svg
maintainer_github: bpmct
verified: false
tags: [kubernetes, docker, sysbox, k3s]
---

# Kubernetes + Sysbox (Docker-in-Workspace)

Workspaces run as Kubernetes pods using the **sysbox-runc** runtime, which provides a secure inner Linux environment. Each workspace gets a full Docker daemon (`dockerd`) running as root inside sysbox's isolated user namespace — unprivileged on the host.

## Features

- **Full Docker** — `docker build`, `docker run`, `docker-compose`, etc. all work out of the box
- **Image selector** — choose from Universal, Python, Go, Java, Node.js, or Rust base images
- **Git clone** — optionally clone a repo on first start
- **Persistent home** — `/home/coder` survives restarts via a PVC
- **code-server** — VS Code in the browser, pre-installed

## How it works

1. k3s schedules the workspace pod with `runtimeClassName: sysbox-runc` and `hostUsers: false`
2. The startup script launches `sudo dockerd` inside the pod
3. sysbox intercepts syscalls so the inner root is fully isolated from the host

## Parameters

| Parameter | Description |
|-----------|-------------|
| Container image | Base image (immutable — rebuild to change) |
| Git repository URL | Optional repo to clone on first start |
| CPU cores | 1 / 2 / 4 / 8 |
| Memory (GiB) | 2 / 4 / 8 / 12 |
| Home disk (GiB) | 5–200 GiB, immutable |

## Requirements

Host must have sysbox-runc installed and registered as a k3s runtime class. Enable via `nixos/k3s-sysbox.nix` in the NixOS configuration.
