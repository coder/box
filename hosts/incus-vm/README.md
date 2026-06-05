# hosts/incus-vm — Running box on a headless host

This directory holds the NixOS module and template `default.nix` for running box
on any **headless host** — Incus VM, a bare-metal machine like a ThinkStation, or
any other server that doesn't need the KDE desktop stack.

`incus-vm.nix` handles everything that differs from a normal bare-metal desktop host:

- QEMU guest agents and virtio drivers (via the upstream `incus-virtual-machine.nix`
  profile) — skip this import for a bare-metal host
- `systemd-networkd` DHCP on `enp5s0` (the virtio NIC Incus assigns to x86_64 VMs)
- Disables the KDE / PipeWire / printing / Avahi stack that `configuration.nix`
  enables by default — a headless host only needs Coder + PostgreSQL

`default.nix` is the per-host entrypoint. Copy it to `hosts/<hostname>/` and
import it from the flake (auto-discovered by hostname).

---

## Relationship to the incus-nixos registry template

[`registry.coder.com/templates/bpmct/incus-nixos`](https://registry.coder.com/templates/bpmct/incus-nixos)
is a separate, standalone Coder workspace template. It provisions a plain NixOS VM
as a Coder workspace using `nixos-rebuild switch` via `incus exec`. It does **not**
use this flake or any part of the box stack — it writes its own minimal
`configuration.nix` and `coder.nix` at first boot.

The two are complementary but independent:

| | `bpmct/incus-nixos` registry template | `hosts/incus-vm/` in this repo |
|---|---|---|
| Purpose | Provision any NixOS VM as a Coder workspace | Turn a host into a box provisioner |
| Uses box flake? | No | Yes — `nixos-rebuild switch --flake /etc/nixos-repo#<hostname>` |
| Sets up k3s / sysbox? | No | Optional — add to `hosts/<hostname>/default.nix` |
| Who runs it? | Coder Terraform provisioner | You, manually, on the host |

---

## Manual setup: fresh NixOS host → box

These steps work for an Incus VM **and** for a bare-metal machine (ThinkStation,
etc.). The only difference is which extra modules you import in `default.nix`.

### 1. Clone the repo

```sh
git clone https://github.com/coder/box /etc/nixos-repo
```

### 2. Create the host directory

The flake auto-discovers hosts by folder name. The folder name must match the
machine's hostname (`hostname -s`):

```sh
HOSTNAME=$(hostname -s)
mkdir -p /etc/nixos-repo/hosts/$HOSTNAME

# For an Incus VM — copy the incus-vm template:
cp /etc/nixos-repo/hosts/incus-vm/default.nix \
   /etc/nixos-repo/hosts/$HOSTNAME/default.nix
cp /etc/nixos-repo/hosts/incus-vm/incus-vm.nix \
   /etc/nixos-repo/hosts/$HOSTNAME/incus-vm.nix

# For a bare-metal host — start from a different base or write your own default.nix.
# See hosts/qemu-arm64/ for an example of the bare-metal layout.
```

### 3. Write the runtime config files

These files live outside the flake tree so they can carry secrets and
machine-specific values without being committed.

**`/etc/nixos/incus.nix`** — sets the hostname (Incus VMs get this written
automatically by `incus-virtual-machine.nix`; create it manually on bare metal):

```nix
{ lib, ... }:
{
  networking.hostName = lib.mkForce "your-hostname";
}
```

**`/etc/nixos/coder.nix`** — declares the workspace user and coder-agent service:

```nix
{ pkgs, ... }:
{
  users.users.coder = {
    isNormalUser = true;
    uid          = 1000;
    home         = "/home/coder";
    shell        = pkgs.bash;
    extraGroups  = [ "wheel" ];
  };
  security.sudo.wheelNeedsPassword = false;

  systemd.services.coder-agent = {
    description = "Coder Agent";
    after       = [ "network-online.target" ];
    wants       = [ "network-online.target" ];
    wantedBy    = [ "multi-user.target" ];
    serviceConfig = {
      User            = "coder";
      EnvironmentFile = "/opt/coder/init.env";
      ExecStart       = "/opt/coder/init";
      Restart         = "always";
      RestartSec      = 10;
    };
  };
}
```

### 4. Enable k3s (optional)

Edit `hosts/<hostname>/default.nix` and add one of:

```nix
# sysbox-runc — required for the k3s-sysbox workspace template (full Docker per workspace)
services.coder-nixos.k3s-sysbox.enable = true;
```

```nix
# rootless Podman — lighter option, works with k3s-podman and k3s-dev templates
services.coder-nixos.k3s.enable = true;
```

> `k3s-sysbox` and `k3s` use different option names to avoid conflicts — only
> enable one.

> **Note:** `k3s-sysbox` requires `rsync` on the host. `nixos/k3s-sysbox.nix`
> includes it in `environment.systemPackages` automatically. If rsync is absent,
> `sysbox-mgr` exits at startup with
> `preflight check failed: rsync is not installed on host` and pods stay stuck in
> `ContainerCreating`.

### 5. Apply

```sh
nixos-rebuild switch --flake /etc/nixos-repo#$(hostname -s) --impure
```

`--impure` is required because `/etc/nixos/incus.nix` and `/etc/nixos/coder.nix`
live outside the flake tree at absolute paths.
