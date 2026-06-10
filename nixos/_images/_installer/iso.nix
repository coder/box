# Installer ISO module — boots the Coder box to install it onto real hardware.
#
# For now this is intentionally identical to the appliance ISO (full GUI box +
# turn-key Coder bootstrap), differing ONLY in image identity (volume ID, boot
# menu label, file name). The eventual plan is a minimal, GUI-less environment
# whose job is to install the coder/box repo onto a target disk — that strip-
# down is deferred; the GUI is kept on for now.
#
# Build (hosts/_installer-iso => nixosConfigurations._installer-iso, see flake.nix):
#
#   make installer/iso
#   # or: nix build .#nixosConfigurations._installer-iso.config.system.build.isoImage
#   # → out/installer-iso/iso/coder-box-installer-*.iso  (flash with `dd`, Ventoy, etc.)
#
# Composition mirrors the appliance ISO: ../_base/iso.nix (ISO mechanics) +
# ../box-turnkey.nix (turn-key Coder box). Unlike the appliance, the installer
# is built ONLY as an ISO (no qcow2/raw disk images).

{ config, lib, pkgs, ... }:

{
  imports = [
    ../_base/iso.nix     # shared ISO mechanics
    ../box-turnkey.nix   # shared turn-key Coder box (login + Coder bootstrap)
  ];

  # ── Image identity ───────────────────────────────────────────────────────────
  isoImage.volumeID          = "CODER_BOX_INSTALLER";
  # Boot-menu label (BIOS/isolinux + EFI/grub). See _appliance/iso.nix for the
  # format; leading space is required.
  isoImage.appendToMenuLabel = " - Coder Box Installer";
  # ISO file name, with arch suffix (e.g. coder-box-installer-x86_64-linux.iso).
  # See _appliance/iso.nix for why this is mkForce + arch-suffixed.
  image.baseName             = lib.mkForce "coder-box-installer-${pkgs.stdenv.hostPlatform.system}";
}
