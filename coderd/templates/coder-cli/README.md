---
display_name: Universal Golden Path
description: The standard paved road for any developer — full toolchain, browser IDE, and an AI agent, ready in seconds.
icon: /icon/coder.svg
maintainer_github: coder
verified: false
tags: [docker, golden-path, universal, ai]
---

# Universal Golden Path

The default paved road every developer gets. A Docker workspace on the
`codercom/oss-dogfood` image — a batteries-included environment with the common
toolchain preinstalled, a browser IDE, and an optional AI agent — so anyone can
start coding in seconds without assembling their own setup.

## Features

- **Full toolchain** — `docker` CLI, `terraform`, `gh`, `go`, `node`, `git`, and the kitchen sink
- **Browser IDE** — VS Code in the browser, no local install
- **AI agent** — optional Claude Code, authenticated against the Coder AI Gateway
- **Git clone** — optionally clone a repo into `~/projects` on first start
- **Persistent home** — your home directory survives restarts

## How it works

1. The workspace runs as a Docker container on the host's runtime (no inner daemon)
2. The Coder agent connects and starts the IDE + any enabled modules
3. The dogfood image already ships the toolchain, so first start is fast

## Parameters

| Parameter | Description |
|-----------|-------------|
| Workspace image | Ubuntu (oss-dogfood) variant |
| Install Claude Code | Enable the AI agent module |
| Git repository URL | Optional repo to clone on first start |

## When to use

This is the general-purpose golden path. For specialized work, use the
**Data Science Path** (JupyterLab + Python) or a project-specific template.
