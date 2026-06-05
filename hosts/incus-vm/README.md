# hosts/incus-vm — Running box on an Incus VM

This directory contains the NixOS configuration for running box inside
an Incus virtual machine, instead of on bare metal.

`incus-vm.nix` handles everything that differs from a bare-metal host:

- QEMU guest agents and virtio drivers (via the upstream `incus-virtual-machine.nix` profile)
- `systemd-networkd` DHCP on `enp5s0` (the virtio NIC Incus assigns to x86_64 VMs)
- Disables the KDE/PipeWire/printing/Avahi stack that `configuration.nix` enables
  by default — a headless VM only needs Coder + PostgreSQL

`default.nix` is the template that gets copied to `hosts/<hostname>/` when a new
VM is provisioned (see [How the provisioner works](#how-the-provisioner-works)).

---

## Manual setup: fresh NixOS Incus VM → box

If you have a NixOS Incus VM and want to turn it into a box host
without using the Coder workspace template, follow these steps inside the VM.

### 1. Clone the repo

```sh
git clone https://github.com/coder/box /etc/nixos-repo
ln -sf /etc/nixos-repo/flake.nix /etc/nixos/flake.nix
```

### 2. Write the runtime config files

Incus writes these automatically when using the `incus-vm` Coder template, but
for a manual setup you create them yourself.

**`/etc/nixos/incus.nix`** — sets the hostname to match the Incus instance name:

```nix
{ lib, ... }:
{
  networking.hostName = lib.mkForce "your-vm-name";
}
```

**`/etc/nixos/coder.nix`** — declares the workspace user and coder-agent service.
Copy and adapt from the example in `hosts/incus-vm/default.nix`, or use the
minimal form below:

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

### 3. Create the host directory

The flake auto-discovers hosts by folder name. The folder name must match the
hostname you set in `/etc/nixos/incus.nix`:

```sh
mkdir -p /etc/nixos-repo/hosts/your-vm-name
cp /etc/nixos-repo/hosts/incus-vm/default.nix \
   /etc/nixos-repo/hosts/your-vm-name/default.nix
cp /etc/nixos-repo/hosts/incus-vm/incus-vm.nix \
   /etc/nixos-repo/hosts/your-vm-name/incus-vm.nix
```

### 4. Enable k3s (optional)

Edit `hosts/your-vm-name/default.nix` and add one of:

```nix
# sysbox-runc — required for the k3s-sysbox workspace template (full Docker per workspace)
services.coder-nixos.k3s-sysbox.enable = true;
```

```nix
# rootless Podman — lighter option, works with k3s-podman and k3s-dev templates
services.coder-nixos.k3s.enable = true;
```

> `k3s-sysbox.nix` and `k3s-podman.nix` use different option names to avoid
> conflicts — only enable one.

> **Note:** `k3s-sysbox` requires `rsync` on the host. `nixos/k3s-sysbox.nix`
> includes it in `environment.systemPackages` automatically. If rsync is absent,
> `sysbox-mgr` exits at startup with
> `preflight check failed: rsync is not installed on host` and pods stay stuck in
> `ContainerCreating`.

### 5. Apply

```sh
nixos-rebuild switch --flake /etc/nixos-repo#your-vm-name --impure
```

`--impure` is required because `/etc/nixos/incus.nix` and `/etc/nixos/coder.nix`
live outside the flake tree at absolute paths.

---

## How the provisioner works

When using the [incus-vm Coder template](https://registry.coder.com/templates/coder/incus),
the provisioner does the above automatically on every workspace start:

1. Clones this repo to `/etc/nixos-repo` (or pulls if already present)
2. Symlinks `/etc/nixos/flake.nix` → `/etc/nixos-repo/flake.nix`
3. Writes `/etc/nixos/incus.nix` (hostname) and `/etc/nixos/coder.nix`
   (coder-agent service + workspace user) — runtime files that live outside the flake
4. Creates `hosts/<hostname>/` and copies `incus-vm.nix` + a `default.nix`
   that imports `./incus-vm.nix`, `/etc/nixos/incus.nix`, `/etc/nixos/coder.nix`
5. Runs `nixos-rebuild switch --flake /etc/nixos-repo#<hostname> --impure`
6. Restarts `coder-agent.service` to pick up the fresh token

This runs on every workspace start, so token rotation is handled automatically.
