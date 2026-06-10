# Shared ISO mechanics for every Coder box image that ships as an ISO
# (appliance ISO, installer ISO). This is a _base primitive: it wires up the
# nixpkgs ISO builder and the boot-loader overrides, but carries NO image
# identity (volumeID / menu label / file name) — each image module under
# _images/appliance or _images/installer sets those.
#
# Provides `config.system.build.isoImage` and the `isoImage.*` options.
{ config, lib, pkgs, modulesPath, ... }:
{
  imports = [
    # Core ISO builder: squashfs nix store, tmpfs overlay root, kernel/initrd,
    # and the EFI + BIOS ISO bootloader.
    (modulesPath + "/installer/cd-dvd/iso-image.nix")
    # Broad driver/firmware set (see hardware.nix).
    ./hardware.nix
  ];

  isoImage.makeEfiBootable  = true;  # boot on UEFI machines
  # Legacy BIOS boot uses syslinux, which is x86-only. Enable it just for x86 so
  # the same module also evaluates/builds for an aarch64 ISO (which boots via
  # EFI only). isx86 covers both i686 and x86_64.
  isoImage.makeBiosBootable = pkgs.stdenv.hostPlatform.isx86;
  isoImage.makeUsbBootable  = true;  # `dd` straight to a USB stick and boot

  # Boot loader: let iso-image.nix own it. configuration.nix sets these for
  # installed UEFI machines; force them off so they don't conflict with the
  # image's own bootloader or try to touch the host's EFI variables when the
  # live system activates.
  boot.loader.systemd-boot.enable      = lib.mkForce false;
  boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
}
