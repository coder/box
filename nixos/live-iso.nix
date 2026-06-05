# Live "Box" ISO module — "it's just The Box™", not an installer.
#
# Turns the shared Coder box configuration into a bootable *ephemeral* live ISO
# that runs entirely from the USB/CD + RAM, with no disk install. Booting it
# gives the same system the on-disk install produces (KDE, Coder server, k3s,
# Podman, the bundled templates, all started automatically) — but the root
# filesystem is a squashfs + tmpfs overlay, so all state is discarded on
# reboot. For a *persistent* image (state survives reboots) build the
# persistent-disk host instead (qcow2 / raw); see the Makefile / README.
#
# Build (folder name `live` => nixosConfigurations.live, see flake.nix):
#
#   make live-ephemeral-iso
#   # or: nix build .#nixosConfigurations.live.config.system.build.isoImage
#   # → result/iso/coder-box-appliance-*.iso  (flash with `dd`, Ventoy, etc.)
#
# This module is imported only by hosts/live/default.nix and is independent of
# the regular disk-install flow (nixos/install.sh, disko, nixos-facter). It
# imports NO disko / hardware-configuration.nix / facter.json: the live root is
# the squashfs + tmpfs overlay that nixpkgs' iso-image.nix sets up.
#
# The turn-key login + Coder admin bootstrap (shared with the persistent-disk
# image) live in nixos/box-turnkey.nix.

{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    # Core ISO builder: squashfs nix store, tmpfs overlay root, kernel/initrd,
    # and the EFI + BIOS ISO bootloader. Provides `system.build.isoImage` and
    # the `isoImage.*` options used below.
    (modulesPath + "/installer/cd-dvd/iso-image.nix")
    # Shared turn-key config (all-hardware, baked /etc/nixos-repo, autologin,
    # Coder admin bootstrap).
    ./box-turnkey.nix
  ];

  # ── ISO image settings ──────────────────────────────────────────────────────
  isoImage.makeEfiBootable  = true;  # boot on UEFI machines
  # Legacy BIOS boot uses syslinux, which is x86-only. Enable it just for x86
  # so the same module also evaluates/builds for an aarch64 live ISO (which
  # boots via EFI only). isx86 covers both i686 and x86_64.
  isoImage.makeBiosBootable = pkgs.stdenv.hostPlatform.isx86;
  isoImage.makeUsbBootable  = true;  # `dd` straight to a USB stick and boot
  isoImage.volumeID         = "BOX_LIVE";
  # ISO file name. iso-image.nix derives isoName from image.baseName as
  # "<baseName>.iso", and defaults baseName to "nixos-<version>-<arch>". We
  # override baseName (mkForce, to win over that default) but keep the arch
  # suffix so the file is e.g. coder-box-appliance-aarch64-linux.iso — the arch
  # is visible in the name and x86_64/aarch64 ISOs don't collide in ./out.
  image.baseName            = lib.mkForce "coder-box-appliance-${pkgs.stdenv.hostPlatform.system}";

  # ── Boot loader: let iso-image.nix own it ────────────────────────────────────
  # configuration.nix sets these for installed UEFI machines; force them off so
  # they don't conflict with the image's own bootloader or try to touch the
  # host's EFI variables when the live system activates.
  boot.loader.systemd-boot.enable      = lib.mkForce false;
  boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
}
