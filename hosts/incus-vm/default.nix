# Template host config for any Incus VM provisioned by the incus-vm Coder template.
#
# The provisioner writes this file (or a copy) to hosts/<hostname>/default.nix
# at workspace start. --impure is required because /etc/nixos/incus.nix and
# /etc/nixos/coder.nix are runtime files outside the flake tree.
#
# To enable k3s add one of these in your host's default.nix:
#   services.coder-nixos.k3s-sysbox.enable = true;  # sysbox-runc (Docker per workspace)
#   services.coder-nixos.k3s.enable = true;          # rootless Podman variant

{ lib, ... }:

{
  imports = [
    ./incus-vm.nix          # QEMU guest agents, networkd DHCP, no desktop stack
    /etc/nixos/incus.nix    # hostname — written by incus-virtual-machine init
    /etc/nixos/coder.nix    # coder-agent service + workspace user (token, URL)
  ];

  system.stateVersion = "25.11";
}
