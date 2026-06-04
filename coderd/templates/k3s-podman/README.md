---
display_name: Kubernetes + Podman (Docker-compatible socket)
description: Workspace pods share the host's rootless Podman socket — no privileged mode, no daemon.
icon: /icon/docker.svg
maintainer_github: coder
verified: false
tags: [kubernetes, docker, podman, k3s]
---

# Kubernetes + Podman (Docker-compatible socket)

Workspaces run as Kubernetes pods on k3s. The host's **rootless Podman socket** is bind-mounted into each pod as `/var/run/docker.sock`, so the standard `docker` CLI works without running a daemon inside the workspace and without any privileged mode.

## Features

- **Docker-compatible** — `docker build`, `docker run`, `docker-compose` work via `DOCKER_HOST`
- **Image selector** — choose from Universal, Python, Go, Java, Node.js, or Rust base images
- **Git clone** — optionally clone a repo on first start
- **Persistent home** — `/home/coder` survives restarts via a PVC
- **code-server** — VS Code in the browser, pre-installed
- **No daemon overhead** — Podman runs on the host; workspaces just use the socket

## How it works

1. k3s schedules the workspace pod using the default containerd runtime
2. `/run/user/991/podman/podman.sock` (host) is bind-mounted to `/var/run/docker.sock` (pod)
3. `DOCKER_HOST=unix:///var/run/docker.sock` is set automatically

## Parameters

| Parameter | Description |
|-----------|-------------|
| Container image | Base image (immutable — rebuild to change) |
| Git repository URL | Optional repo to clone on first start |
| CPU cores | 1 / 2 / 4 / 8 |
| Memory (GiB) | 2 / 4 / 8 / 12 |
| Home disk (GiB) | 5–200 GiB, immutable |

## Requirements

Host must have rootless Podman running as the `coder` user and the socket exposed. Enable via `nixos/k3s-podman.nix` in the NixOS configuration.
