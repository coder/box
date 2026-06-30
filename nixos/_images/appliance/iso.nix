# Appliance ISO module — "it's just The Box™", not an installer.
#
# Turns the shared Coder box configuration into a bootable *ephemeral* appliance
# ISO that runs entirely from the USB/CD + RAM, with no disk install. Booting it
# gives the same system the on-disk install produces (KDE, Coder server, k3s,
# Podman, the bundled templates, all started automatically) — but the root
# filesystem is a squashfs + tmpfs overlay, so all state is discarded on
# reboot. For a *persistent* appliance (state survives reboots) build the
# _appliance-disk host instead (qcow2 / raw); see the Makefile / README.
#
# Build (hosts/_appliance-iso => nixosConfigurations._appliance-iso, see flake.nix):
#
#   make appliance/iso
#   # or: nix build .#nixosConfigurations._appliance-iso.config.system.build.isoImage
#   # → out/appliance-iso/iso/coder-box-appliance-*.iso  (flash with `dd`, Ventoy, etc.)
#
# Composition: the ISO mechanics (iso-image.nix, EFI/BIOS/USB bootable,
# bootloader overrides, all-hardware) live in ../base/iso.nix; the turn-key
# Coder box (baked /etc/nixos-repo, nixpkgs registry, coderbox autologin, Coder
# admin bootstrap) lives in ../box-turnkey.nix. This module only sets the
# appliance's image identity.

{ config, lib, pkgs, ... }:

{
  imports = [
    ../base/iso.nix # shared ISO mechanics
    ../box-turnkey.nix # shared turn-key Coder box (login + Coder bootstrap)
  ];

  # ── Image identity ───────────────────────────────────────────────────────────
  isoImage.volumeID = "CODER_BOX_APPLIANCE";
  # Boot-menu label (both the BIOS/isolinux and EFI/grub entries). The label is
  # "<distroName> <version><appendToMenuLabel>"; the default append is
  # " Installer", which is misleading here since this is the appliance, not the
  # installer. Leading space is required (it's concatenated directly). The
  # PR-title suffix (coderBox.prMenuSuffix, set in box-turnkey.nix) is empty
  # unless this is a PR preview build.
  isoImage.appendToMenuLabel = " - Coder Box Appliance${config.coderBox.prMenuSuffix}";
  # ISO file name. iso-image.nix derives isoName from image.baseName as
  # "<baseName>.iso", and defaults baseName to "nixos-<version>-<arch>". We
  # override baseName (mkForce, to win over that default) but keep the arch
  # suffix so the file is e.g. coder-box-appliance-aarch64-linux.iso — the arch
  # is visible in the name and x86_64/aarch64 ISOs don't collide in ./out. The
  # PR-slug suffix (coderBox.prFileSuffix) is empty unless this is a PR preview
  # build (e.g. coder-box-appliance-x86_64-linux-pr-fix-the-thing.iso).
  image.baseName = lib.mkForce "coder-box-appliance-${pkgs.stdenv.hostPlatform.system}${config.coderBox.prFileSuffix}";
}
