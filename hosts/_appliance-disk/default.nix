# Persistent "Box" disk image host — "it's just The Box™" on a real disk.
#
# Folder name = nixosConfigurations attribute (see flake.nix host
# auto-discovery), so this host is exposed as `nixosConfigurations._appliance-disk`.
# Unlike the appliance ISO (hosts/_appliance-iso), this builds a *persistent* disk
# image (qcow2 or raw) using disko's image builder: it carries the real on-disk
# GPT layout (1 GB ESP + ZFS root pool from nixos/disko-standard.nix) and state
# survives reboots, exactly like a machine you ran install.sh on.
#
# Build (the format is chosen at build time, see Makefile / README):
#
#   make appliance/qcow2                 # qcow2 for this machine's arch
#   make appliance/raw                   # raw  (dd-able straight to a drive)
#   make appliance/qcow2/aarch64-linux   # cross-arch (needs a matching builder)
#
#   # without make, e.g. a raw image (diskoImagesDir bundles the image with its
#   # .sha256 sidecar, see nixos/_images/base/disk.nix; use .diskoImages for the
#   # bare image without a checksum):
#   nix build .#nixosConfigurations._appliance-disk.config.system.build.diskoImagesDir
#   # (override disko.imageBuilder.imageFormat = "qcow2" for qcow2)
#
# This host is independent of install.sh; it shares the disk LAYOUT with
# real installs (disko-standard.nix) but is never itself part of the install
# flow. The turn-key login + Coder admin bootstrap (shared with the appliance ISO)
# live in nixos/_images/box-turnkey.nix.

{ lib, pkgs, ... }:

{
  imports = [
    ../../nixos/disko-standard.nix       # 1 GB ESP + ZFS root pool single-disk layout
    ../../nixos/_images/box-turnkey.nix  # shared turn-key config (login + Coder bootstrap)
    ../../nixos/_images/base/disk.nix    # bundles each disk image with its .sha256 (diskoImagesDir)
  ] ++ lib.optional (builtins.pathExists ./local.nix) ./local.nix;

  # No networking.hostName here on purpose: underscore-prefixed image hosts get
  # no folder-name injection from flake.nix and inherit the central default
  # "coder-box" (configuration.nix). Override in local.nix if you need another.

  # disko writes the image for this device node; /dev/vda is the virtio disk a
  # built image is partitioned against. The on-disk filesystems mount by LABEL
  # (see disko-standard.nix), so the image still boots if the runtime device
  # node differs (sda/nvme0n1/etc.).
  disko.devices.disk.main.device = lib.mkForce "/dev/vda";

  # Output file name: disko defaults imageName to the disk attr name ("main"),
  # which would produce main.raw / main.qcow2. Name it after the appliance and
  # include the arch (like the ISO's image.baseName) so the built image is
  # coder-box-appliance-<arch>.raw / .qcow2 — arch visible, and x86_64/aarch64
  # images don't collide in ./out.
  disko.devices.disk.main.imageName =
    lib.mkForce "coder-box-appliance-${pkgs.stdenv.hostPlatform.system}";

  # The image is built offline in a VM with no EFI variable store, so install
  # the bootloader without touching EFI variables. systemd-boot (enabled by
  # default in configuration.nix) also writes the removable EFI fallback path
  # (EFI/BOOT/BOOTX64.EFI), so the image still boots on firmware that has no
  # pre-existing boot entry.
  boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
}
