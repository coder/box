# Live "Box" ISO host — "it's just The Box™", not an installer.
#
# Folder name = nixosConfigurations attribute (see flake.nix host
# auto-discovery), so this host is exposed as `nixosConfigurations.live`.
# Build the bootable ISO with:
#
#   nix build .#nixosConfigurations.live.config.system.build.isoImage
#   # → result/iso/coder-box-appliance-*.iso
#
# Unlike the install hosts (coder-thinkcentre, qemu-arm64), this host does NOT
# import nixos/disko-standard.nix, hardware-configuration.nix, or facter.json:
# the live root filesystem is the squashfs + tmpfs overlay provided by
# nixos/live-iso.nix. All of the live-specific wiring lives in that module.
#
# This host is independent of nixos/install.sh and never participates in the
# disk-install flow; adding it changes nothing for disko/nixos-install installs.

{ lib, ... }:

{
  imports = [ ../../nixos/live-iso.nix ]
    ++ lib.optional (builtins.pathExists ./local.nix) ./local.nix;
}
