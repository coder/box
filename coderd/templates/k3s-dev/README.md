# k3s-dev — Language Demo Workspaces

A demo-focused workspace template that auto-starts a real web application per language. Pick a language when creating the workspace and a demo app will be cloned/scaffolded and started automatically.

## Languages & Demo Apps

| Language | Demo App | Port | Notes |
|---|---|---|---|
| **Python** | FastAPI hello world | 8000 | Inline scaffold, no clone needed |
| **Node.js** | Next.js (create-next-app) | 3000 | Scaffolded on first start |
| **Go** | [Pagoda](https://github.com/mikestefanello/pagoda) web framework | 8000 | SQLite embedded, CSS pre-compiled |
| **Java** | [Spring PetClinic](https://github.com/spring-projects/spring-petclinic) | 8080 | H2 in-memory DB, Maven wrapper included |
| **Rust** | [rustypaste](https://github.com/orhun/rustypaste) file-paste server | 8000 | Compiles on first start (~5 min) |

## How It Works

1. Choose a language at workspace creation — this selects the container image and configures the demo app.
2. The `startup_script` runs on every workspace start:
   - First run: clones/scaffolds the project into `~/demo-app`
   - Subsequent runs: starts the server directly (no re-clone)
3. The **Demo App** button in the Coder UI opens a proxy to the running web server.

## Container Images

Each language maps to a Microsoft devcontainers image:

| Language | Image |
|---|---|
| Python | `mcr.microsoft.com/devcontainers/python:3.12` |
| Node.js | `mcr.microsoft.com/devcontainers/javascript-node:20` |
| Go | `mcr.microsoft.com/devcontainers/go:1.22` |
| Java | `mcr.microsoft.com/devcontainers/java:21` |
| Rust | `mcr.microsoft.com/devcontainers/rust:latest` |

## Home Directory

All devcontainer images use UID 1000. Node.js uses `/home/node`; all others use `/home/vscode`. The PVC mount path is set dynamically to match the image's home directory.

## First-Start Times

- **Python**: ~30 s (pip install fastapi)
- **Node.js**: ~2–3 min (npx create-next-app + npm install)
- **Go**: ~1–2 min (go mod download)
- **Java**: ~3–5 min (Maven downloads dependencies)
- **Rust**: ~5–10 min (cargo build --release compiles everything)

Subsequent starts are fast because `~/demo-app` is persisted on the PVC and dependencies are already installed.

## Infrastructure

Built on k3s + rootless Podman (same as `k3s-podman`):
- k3s schedules workspace pods on the local node
- Host Podman socket bind-mounted as `/var/run/docker.sock`
- No privileged mode required
