# Live "Box" ISO appliance host — "it's just The Box™", not an installer.
#
# Folder name = nixosConfigurations attribute (see flake.nix host
# auto-discovery), so this host is exposed as `nixosConfigurations._appliance-iso`.
# It's normally built via the Makefile rather than by attribute:
#
#   make appliance/iso          # → out/appliance-iso/iso/coder-box-appliance-*.iso
#   # equivalently:
#   nix build .#nixosConfigurations._appliance-iso.config.system.build.isoImage
#
# Unlike normal install hosts (hosts/<hostname>/), this host does NOT
# import nixos/disko-standard.nix, hardware-configuration.nix, or facter.json:
# the appliance root filesystem is the squashfs + tmpfs overlay provided by
# nixos/_images/appliance/iso.nix. All of the appliance-ISO wiring lives there.
#
# This host is independent of install.sh and never participates in the
# disk-install flow; adding it changes nothing for disko/nixos-install installs.

{ lib, ... }:

{
  imports = [
    ../../nixos/_images/appliance/iso.nix
  ]
  ++ lib.optional (builtins.pathExists ./local.nix) ./local.nix;

  # No networking.hostName here on purpose: underscore-prefixed image hosts get
  # no folder-name injection from flake.nix and inherit the central default
  # "coder-box" (configuration.nix). Override in local.nix if you need another.
}
