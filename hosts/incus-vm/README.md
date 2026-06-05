# hosts/incus-vm — Running box on a headless host

## What box does

Box turns a NixOS machine into a **self-contained Coder deployment**. After
`nixos-rebuild switch`, the machine runs:

- **Coder server** — full control plane, accessible over a Tailscale tunnel or
  a configured external URL
- **PostgreSQL** — Coder's database, managed by the box flake
- **k3s + sysbox** (optional) — single-node Kubernetes cluster where Coder
  provisions workspaces as pods; sysbox-runc gives each pod its own Docker daemon
  without privileged mode
- **template-sync** — an activation hook that runs `terraform apply` on
  `coderd/` at every `nixos-rebuild switch`, keeping Coder templates in sync with
  the repo automatically

The result: SSH or `coder ssh` into the machine, and you have a working Coder
instance. Workspace pods run on the same node via k3s. No separate infrastructure
required.

---

## What this directory provides

`incus-vm.nix` adapts the base box config for a headless VM or server:

- Imports the upstream `incus-virtual-machine.nix` profile (QEMU guest agents,
  virtio drivers) — skip this for bare-metal
- `systemd-networkd` DHCP on `enp5s0` (the virtio NIC Incus assigns to x86_64 VMs)
- Disables the KDE / PipeWire / printing / Avahi stack — a headless host only
  needs Coder + PostgreSQL

`default.nix` is the per-host entrypoint that imports `incus-vm.nix` plus the
two runtime files from `/etc/nixos/` (see below).

The same pattern works for bare-metal machines (ThinkStation, etc.) — just skip
`incus-vm.nix` or replace it with your own hardware module.

---

## Relationship to the incus-nixos registry template

[`registry.coder.com/templates/bpmct/incus-nixos`](https://registry.coder.com/templates/bpmct/incus-nixos)
is a **separate, unrelated** Coder workspace template. It provisions a plain NixOS
VM as a Coder *workspace* (something you SSH into to do work), using
`nixos-rebuild switch` via `incus exec`. It writes its own minimal
`configuration.nix` at first boot and has nothing to do with this flake.

| | `bpmct/incus-nixos` registry template | `hosts/incus-vm/` in this repo |
|---|---|---|
| What is it? | A Coder workspace template | A box host config |
| End result | A NixOS VM you work inside | A NixOS machine that *runs* Coder |
| Uses box flake? | No | Yes |
| Runs Coder server? | No — runs coder-agent | Yes — full Coder + PostgreSQL + k3s |
| Who runs it? | Coder Terraform provisioner | You, manually, on the host |

You can use both together: run the `incus-nixos` template from a box host to spin
up NixOS workspaces, while the host itself is set up with this flake.

---

## Manual setup: fresh NixOS host → box

These steps work for an Incus VM provisioned by the `incus-nixos` template (or
any other NixOS VM) **and** for bare-metal machines.

> **Note:** A stock NixOS image does not have `git` installed. Use
> `nix-shell -p git` to get it temporarily for the clone step, or add it to the
> system environment first.

### 1. Clone the repo

```sh
nix-shell -p git --run "git clone https://github.com/coder/box /etc/nixos-repo"
```

### 2. Create the host directory

The flake auto-discovers hosts by folder name — the folder name must match
`hostname -s`:

```sh
HOSTNAME=$(hostname -s)
mkdir -p /etc/nixos-repo/hosts/$HOSTNAME

# For an Incus VM:
cp /etc/nixos-repo/hosts/incus-vm/default.nix \
   /etc/nixos-repo/hosts/$HOSTNAME/default.nix
cp /etc/nixos-repo/hosts/incus-vm/incus-vm.nix \
   /etc/nixos-repo/hosts/$HOSTNAME/incus-vm.nix

# For bare-metal — write your own default.nix or copy from another host.
# See hosts/qemu-arm64/ for an example layout.

# Stage the files — the flake's builtins.readDir only sees tracked files.
git -C /etc/nixos-repo add hosts/$HOSTNAME/
```

### 3. Enable k3s (required for workspace provisioning)

Edit `hosts/$HOSTNAME/default.nix` and add:

```nix
# sysbox-runc — each workspace pod gets its own Docker daemon (no privileged mode)
services.coder-nixos.k3s-sysbox.enable = true;
```

Or for the lighter rootless-Podman variant:

```nix
services.coder-nixos.k3s.enable = true;
```

> Only enable one. `k3s-sysbox` is required for the `k3s-sysbox` workspace
> template; `k3s` works with `k3s-podman` and `k3s-dev`.

### 4. Write the runtime hostname file

This file lives outside the flake so it doesn't need to be committed. On an
Incus VM provisioned by the `incus-nixos` template, `/etc/nixos/incus.nix` is
already written by `incus-virtual-machine.nix`. For bare-metal or a fresh VM,
create it manually:

```sh
cat > /etc/nixos/incus.nix << 'EOF'
{ lib, ... }:
{
  networking.hostName = lib.mkForce "your-hostname";
}
EOF
```

> `/etc/nixos/coder.nix` is **not** needed here. That file is for the
> `coder-agent` service on workspace VMs. The box host runs the Coder *server*,
> not an agent.

### 5. Apply

```sh
nixos-rebuild switch --flake /etc/nixos-repo#$(hostname -s) --impure
```

`--impure` is required because `/etc/nixos/incus.nix` lives outside the flake
tree. This will build and activate: Coder server, PostgreSQL, k3s, sysbox,
template-sync, and all supporting services.

### 6. Bootstrap the admin user

After the first `nixos-rebuild switch`, the Coder server is up but has no users.
Complete setup via the first-run wizard:

```sh
# The tunnel URL is printed in the Coder server logs:
journalctl -u coder --no-pager | grep "View the Web UI"
```

Open that URL in a browser and create the admin user. Or use the CLI:

```sh
CODER_URL=http://localhost:3000 coder login http://localhost:3000
```

Once logged in, `template-sync` will succeed on the next `nixos-rebuild switch`
and push the workspace templates (`k3s-sysbox`, `k3s-podman`, `k3s-dev`,
`coder-cli`) automatically.

To automate first-run on future machines, set these in the host's NixOS config
(e.g. via a secret manager or environment file):

```
CODER_ADMIN_EMAIL=admin@example.com
CODER_ADMIN_USERNAME=admin
CODER_ADMIN_PASSWORD=...
```

The `coder-init-admin` service reads these at boot and creates the user + mints
a long-lived session token for template-sync automatically.
