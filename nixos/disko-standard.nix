# Standard UEFI + GPT single-disk layout for the Coder demo boxes.
#
# 1 GB EFI System Partition and an ext4 root taking the rest of the disk.
# No on-disk swap partition; swap is provided at runtime via zram (see
# configuration.nix: zramSwap.enable). Works on any single block device
# (NVMe, SATA SSD/HDD, USB, virtio).
# Partitions are labelled so the running NixOS mounts by label, not UUID,
# which makes the layout portable across machines that follow it.
#
# Hosts that follow this layout import the module and override the disk
# device path if needed (the default is /dev/nvme0n1, the current demo box
# is NVMe-only):
#
#   imports = [ ../../nixos/disko-standard.nix ];
#   disko.devices.disk.main.device = "/dev/sda";   # SATA example
#
# install.sh handles the format + install on a fresh box by running
# `disko --mode disko` followed by `nixos-install`, so the per-host module
# only needs the device override above.

{ lib, ... }:

{
  disko.devices.disk.main = {
    type = "disk";
    # Override per-host. /dev/nvme0n1 is the default since the current
    # demo box is NVMe; SATA hosts override to /dev/sda etc. install.sh
    # writes the override into hosts/<host>/default.nix based on the disk
    # picked at install time.
    device = lib.mkDefault "/dev/nvme0n1";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          priority = 1;
          name = "ESP";
          size = "1G";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "fmask=0077" "dmask=0077" ];
          };
        };
        root = {
          priority = 2;
          name = "root";
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
}
