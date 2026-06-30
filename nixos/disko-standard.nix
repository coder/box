# Standard UEFI + GPT single-disk layout for the Coder demo boxes.
#
# 1 GB EFI System Partition and a ZFS pool ("rpool") taking the rest of the
# disk. No on-disk swap partition; swap is provided at runtime via zram (see
# configuration.nix: zramSwap.enable). Works on any single block device
# (NVMe, SATA SSD/HDD, USB, virtio).
#
# Why ZFS instead of ext4: cheap, instant on-demand snapshots (take one before
# a risky nixos-rebuild and roll back in seconds), transparent zstd
# compression, and on-disk checksums/scrubbing. The pool is imported by name ("rpool"),
# not by device node, so the layout stays portable across machines that
# follow it (NVMe/SATA/USB/virtio) — the same property the old ext4 layout
# got from filesystem labels.
#
# ZFS requires a unique networking.hostId per machine. configuration.nix
# derives it in Nix from the hostname (first 8 hex digits of its sha256), so
# every host with a distinct hostName gets a distinct id automatically.
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
  disko.devices = {
    disk.main = {
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
              mountOptions = [
                "fmask=0077"
                "dmask=0077"
              ];
            };
          };
          zfs = {
            priority = 2;
            name = "zfs";
            size = "100%";
            content = {
              type = "zfs";
              pool = "rpool";
            };
          };
        };
      };
    };

    # Single-disk pool ("rpool", mode = "" → no redundancy). Datasets are
    # mounted by the disko-generated fileSystems entries (legacy mountpoints),
    # so there is no separate import/mount unit ordering to worry about.
    zpool.rpool = {
      type = "zpool";

      rootFsOptions = {
        # zstd: good ratio, negligible CPU cost; helps the Nix store especially.
        compression = "zstd";
        # POSIX ACLs + xattrs stored in the inode (sa) — needed by systemd and
        # avoids the slow on-disk xattr dir layout.
        acltype = "posixacl";
        xattr = "sa";
        # The pool itself isn't a mountpoint; datasets carry the mounts.
        mountpoint = "none";
      };

      datasets = {
        # Root filesystem.
        root = {
          type = "zfs_fs";
          mountpoint = "/";
        };

        # The Nix store is fully reproducible from the flake and churns
        # constantly; atime off avoids needless write amplification.
        nix = {
          type = "zfs_fs";
          mountpoint = "/nix";
          options.atime = "off";
        };
      };
    };
  };
}
