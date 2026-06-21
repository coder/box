# Template host config for a box host running inside an Incus VM.
#
# Copy this to hosts/<hostname>/default.nix and incus-vm.nix to the same
# folder, then follow hosts/incus-vm/README.md.
#
# --impure is required because /etc/nixos/incus.nix is a runtime file
# outside the flake tree.
#
# To enable k3s add one of these below:
#   services.coder-nixos.k3s-sysbox.enable = true;  # sysbox-runc (Docker per workspace)
#   services.coder-nixos.k3s.enable = true;          # rootless Podman variant

{ lib, ... }:

{
  imports = [
    ./incus-vm.nix          # QEMU guest agents, networkd DHCP, no desktop stack
    ./local.nix             # per-host secrets: admin creds, LAN IP, SSH keys
    /etc/nixos/incus.nix    # hostname — written by incus-virtual-machine init
    # /etc/nixos/coder.nix  # only needed if this VM is also a coder-agent workspace
  ];

  # Uncomment for aarch64 VMs (Apple Silicon, ARM servers, etc.).
  # The flake defaults to x86_64-linux; without this the build evaluates
  # for the wrong architecture and will fail or produce a broken system.
  # nixpkgs.hostPlatform = "aarch64-linux";

  services.coder-nixos.k3s-sysbox.enable = true;

  system.stateVersion = "25.11";
}
