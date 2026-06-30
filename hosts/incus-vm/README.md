# hosts/incus-vm — Running box on a headless host

## What box does

Box turns a NixOS machine into a **self-contained Coder deployment**. After
`nixos-rebuild switch`, the machine runs:

- **Coder server** — full control plane, accessible over a `*.try.coder.app`
  tunnel or a configured external URL
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
- `systemd-networkd` DHCP on `enp5s0` (the virtio NIC Incus assigns to VMs on
  both x86_64 and aarch64)
- Disables the KDE / PipeWire / printing / Avahi stack — a headless host only
  needs Coder + PostgreSQL

`default.nix` is the per-host entrypoint that imports `incus-vm.nix`, your
`local.nix` secrets file, and the runtime files from `/etc/nixos/` (see below).

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

# Stage the files — the flake's builtins.readDir only sees tracked files.
git -C /etc/nixos-repo add hosts/$HOSTNAME/
```

> **`/etc/nixos/coder.nix`:** The copied `default.nix` does **not** import this
> file. It only exists on VMs that are *also* running as a coder-agent workspace
> (i.e. the `incus-nixos` template writes it). On a pure box host it won't be
> present, and you don't need it.

### 3. Set architecture and enable k3s

Edit `hosts/$HOSTNAME/default.nix`.

**aarch64 VMs:** The flake defaults to `x86_64-linux`. If your VM is ARM
(e.g. running on Apple Silicon or an ARM server), add this or the build will
evaluate for the wrong architecture:

```nix
nixpkgs.hostPlatform = "aarch64-linux";
```

Then enable k3s (required for workspace provisioning):

```nix
# sysbox-runc — each workspace pod gets its own Docker daemon (no privileged mode)
services.coder-nixos.sysbox.enable = true;
```

Or for the lighter rootless-Podman variant:

```nix
services.coder-nixos.podman.enable = true;
```

> Only enable one. `sysbox` is required for the `k3s-sysbox` workspace
> template; `podman` works with `k3s-podman` and `k3s-dev`.

### 4. Create local.nix

`local.nix` holds per-host secrets (admin credentials, LAN IP, SSH keys). It is
gitignored and must be created manually:

```sh
cp /etc/nixos-repo/local.nix.example \
   /etc/nixos-repo/hosts/$HOSTNAME/local.nix

# Mark it so the flake's builtins.readDir can see it without committing it.
git -C /etc/nixos-repo add --intent-to-add -f hosts/$HOSTNAME/local.nix
```

Edit `hosts/$HOSTNAME/local.nix` and at minimum set:

```nix
services.coder-nixos.lanIp = "192.168.x.x";  # VM's primary IP

systemd.services.coder.environment = {
  CODER_ADMIN_EMAIL    = "you@example.com";
  CODER_ADMIN_USERNAME = "admin";
  CODER_ADMIN_PASSWORD = "changeme";
};
```

These credentials are read by `coder-init-admin.service` on first boot to
automatically create the admin user and mint a long-lived session token for
template-sync. **Without this, templates won't be pushed on the first
`nixos-rebuild switch`.**

### 5. Write the runtime hostname file

This file lives outside the flake so it doesn't need to be committed. On an
Incus VM provisioned by the `incus-nixos` template, `/etc/nixos/incus.nix` is
already written at first boot. For a fresh VM or bare-metal, create it manually:

```sh
cat > /etc/nixos/incus.nix << 'EOF'
{ lib, ... }:
{
  networking.hostName = lib.mkForce "your-hostname";
}
EOF
```

### 6. Apply

```sh
nixos-rebuild switch --flake /etc/nixos-repo#$(hostname -s) --impure
```

`--impure` is required because `/etc/nixos/incus.nix` lives outside the flake
tree. This will build and activate: Coder server, PostgreSQL, k3s, sysbox,
and all supporting services.

On first boot, `coder-init-admin.service` runs automatically after Coder starts:
creates the admin user, mints a long-lived session token to
`/etc/coder/session-token`, and pushes all workspace templates (`k3s-sysbox`,
`k3s-podman`, `k3s-dev`, `coder-cli`) via Terraform. Check progress with:

```sh
journalctl -u coder-init-admin -f
```

Once complete, the tunnel URL is in `/etc/motd`:

```sh
cat /etc/motd
```

**Fallback (no local.nix credentials):** If `CODER_ADMIN_EMAIL` was left empty,
`coder-init-admin` is skipped. Complete setup via the first-run wizard instead:

```sh
# Find the tunnel URL:
journalctl -u coder --no-pager | grep "View the Web UI"
```

Open that URL in a browser, create the admin user, then log in with the CLI:

```sh
CODER_URL=http://localhost:3000 coder login http://localhost:3000
```

Once logged in, run `sudo nixos-rebuild switch` again to push templates via
`template-sync`.
