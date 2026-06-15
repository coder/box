# Installer ISO host — boots the Coder box to install it onto real hardware.
#
# Folder name = nixosConfigurations attribute (see flake.nix host
# auto-discovery), so this host is exposed as `nixosConfigurations._installer-iso`.
# It's normally built via the Makefile rather than by attribute:
#
#   make installer/iso          # → out/installer-iso/iso/coder-box-installer-*.iso
#   # equivalently:
#   nix build .#nixosConfigurations._installer-iso.config.system.build.isoImage
#
# For now the installer is identical to the appliance ISO (full GUI box +
# turn-key Coder bootstrap) and differs only in image identity; the eventual
# minimal, GUI-less installer environment is deferred. Unlike the appliance, the
# installer ships ONLY as an ISO (no qcow2/raw disk images). All of the
# installer-ISO wiring lives in nixos/_images/installer/iso.nix.
#
# This host is independent of install.sh and never participates in the
# disk-install flow; adding it changes nothing for disko/nixos-install installs.

{ lib, ... }:

{
  imports = [ ../../nixos/_images/installer/iso.nix ]
    ++ lib.optional (builtins.pathExists ./local.nix) ./local.nix;

  # No networking.hostName here on purpose: underscore-prefixed image hosts get
  # no folder-name injection from flake.nix and inherit the central default
  # "coder-box" (configuration.nix). Override in local.nix if you need another.
}
