---
display_name: Coder CLI / Dogfood
description: Full-featured dev workspace running the Coder oss-dogfood image — docker CLI, terraform, gh, go, node, and more pre-installed.
icon: /icon/coder.svg
maintainer_github: coder
verified: false
tags: [docker, cli, dogfood]
---

# Coder CLI / Dogfood

A general-purpose developer workspace built on the `codercom/oss-dogfood` image. Everything you'd reach for in a demo or workshop is already installed — no setup required.

## What's included

- **Coder CLI** — `coder` binary matching the server version
- **Docker CLI** — talks to the host Docker/Podman socket via `DOCKER_HOST`
- **Terraform** + **OpenTofu**
- **GitHub CLI** (`gh`)
- **Go**, **Node.js**, **Python 3**
- **git**, **curl**, **jq**, **make**, and the usual UNIX toolkit
- **code-server** — VS Code in the browser, pre-installed
- **Cursor** desktop app link

## Images

| Option | Image | Base OS |
|---|---|---|
| Ubuntu 22.04 (default) | `codercom/oss-dogfood:latest` | Ubuntu 22.04 |
| Ubuntu 26.04 | `codercom/oss-dogfood:26.04` | Ubuntu 26.04 |
| Nix (experimental) | `codercom/oss-dogfood-nix:latest` | NixOS |

The image is immutable — rebuild the workspace to switch.

## Parameters

| Parameter | Description |
|---|---|
| Workspace image | Base image (immutable — rebuild to change) |
| CPU cores | 1–16 |
| Memory (GiB) | Configurable |
| Home disk (GiB) | 10–200 GiB, immutable |

## How it works

This template runs workspaces as Docker containers directly on the host (not via k3s). The container gets:

- The host Docker/Podman socket bind-mounted as `/var/run/docker.sock`
- A persistent named volume for `/home/coder`
- `CODER_AGENT_TOKEN` and `CODER_AGENT_URL` injected via environment

The Coder agent starts inside the container via the `init_script` entrypoint and reports back to the server.

## Requirements

Docker or rootless Podman must be running on the host. No k3s or sysbox needed — this template is the lightest option and works on any host in this repo.
