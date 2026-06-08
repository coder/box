# Live "Box" ISO appliance host — "it's just The Box™", not an installer.
#
# Folder name = nixosConfigurations attribute (see flake.nix host
# auto-discovery), so this host is exposed as `nixosConfigurations._appliance_iso`.
# It's normally built via the Makefile rather than by attribute:
#
#   make appliance/iso          # → out/appliance-iso/iso/coder-box-appliance-*.iso
#   # equivalently:
#   nix build .#nixosConfigurations._appliance_iso.config.system.build.isoImage
#
# Unlike the install hosts (coder-thinkcentre, qemu-arm64), this host does NOT
# import nixos/disko-standard.nix, hardware-configuration.nix, or facter.json:
# the appliance root filesystem is the squashfs + tmpfs overlay provided by
# nixos/_appliance/live-iso.nix. All of the appliance-ISO wiring lives there.
#
# This host is independent of nixos/install.sh and never participates in the
# disk-install flow; adding it changes nothing for disko/nixos-install installs.

{ lib, ... }:

{
  imports = [ ../../nixos/_appliance/live-iso.nix ]
    ++ lib.optional (builtins.pathExists ./local.nix) ./local.nix;

  # No networking.hostName here on purpose: underscore-prefixed image hosts get
  # no folder-name injection from flake.nix and inherit the central default
  # "coder-box" (configuration.nix). Override in local.nix if you need another.
}
