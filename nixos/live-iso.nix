# Live "Box" ISO module — "it's just The Box™", not an installer.
#
# Turns the shared Coder box configuration (configuration.nix) into a bootable
# live ISO that runs entirely from the USB/CD + RAM, with no disk install. When
# you boot this image you get the exact same system the on-disk install
# produces: KDE Plasma, the Coder server, k3s, rootless Podman, the bundled
# workspace templates, etc. — all started up automatically, just as if it were
# the disk you installed to.
#
# Build the ISO (folder name `live` => nixosConfigurations.live, see flake.nix):
#
#   nix build .#nixosConfigurations.live.config.system.build.isoImage
#   # → result/iso/coder-box-live-*.iso  (flash with `dd`, Ventoy, etc.)
#
# This module is imported only by hosts/live/default.nix and is completely
# independent of the regular disk-install flow (nixos/install.sh, disko,
# nixos-facter). It imports NO disko / hardware-configuration.nix / facter.json:
# the live root filesystem is the squashfs + tmpfs overlay that nixpkgs'
# iso-image.nix sets up, so there is no on-disk partition to format or mount.
#
# Why the boot-loader overrides below: configuration.nix targets installed UEFI
# machines (systemd-boot + writing EFI variables). A live ISO is booted via the
# GRUB-EFI / isolinux loader baked into the image by iso-image.nix instead, so
# we force the installed-machine boot settings off to avoid eval conflicts and
# pointless EFI-variable writes on the host.

{ config, lib, pkgs, modulesPath, self, inputs, ... }:

{
  imports = [
    # Core ISO builder: squashfs nix store, tmpfs overlay root, kernel/initrd,
    # and the EFI + BIOS ISO bootloader. Provides the `system.build.isoImage`
    # attribute and the `isoImage.*` options used below.
    (modulesPath + "/installer/cd-dvd/iso-image.nix")
    # Broad driver/firmware set so the ISO boots on arbitrary real hardware
    # (this replaces the per-host facter.json / hardware-configuration.nix that
    # installed hosts rely on).
    (modulesPath + "/profiles/all-hardware.nix")
  ];

  # ── ISO image settings ──────────────────────────────────────────────────────
  isoImage.makeEfiBootable  = true;  # boot on UEFI machines
  # Legacy BIOS boot uses syslinux, which is x86-only. Enable it just for x86
  # so the same module also evaluates/builds for an aarch64 live ISO (which
  # boots via EFI only). isx86 covers both i686 and x86_64.
  isoImage.makeBiosBootable = pkgs.stdenv.hostPlatform.isx86;
  isoImage.makeUsbBootable  = true;  # `dd` straight to a USB stick and boot
  isoImage.volumeID         = "BOX_LIVE";
  # Prefix of the generated file name (result/iso/<baseName>-<version>-<arch>.iso).
  # `image.baseName` is the post-25.05 replacement for `isoImage.isoBaseName`.
  # iso-image.nix already sets it ("nixos-<version>-<arch>"), so override with
  # mkForce to win over that definition.
  image.baseName            = lib.mkForce "coder-box-live";

  # ── Boot loader: let iso-image.nix own it ────────────────────────────────────
  # configuration.nix sets these for installed UEFI machines; force them off so
  # they don't conflict with the image's own bootloader or try to touch the
  # host's EFI variables when the live system activates.
  boot.loader.systemd-boot.enable      = lib.mkForce false;
  boot.loader.efi.canTouchEfiVariables = lib.mkForce false;

  # ── Bake the repo into the image at /etc/nixos-repo ──────────────────────────
  # The on-disk installer copies the working tree to /etc/nixos-repo; the Coder
  # bootstrap units (coder-init-admin.service, the coder-template-sync
  # activation script) read templates from /etc/nixos-repo/coderd and the
  # locally-packaged provider mirror. Point /etc/nixos-repo at the flake source
  # baked into the ISO so the live box deploys templates exactly like an
  # installed box. (The git-commit lookups in those scripts fall back to
  # "unknown" when no .git is present, which is fine.)
  environment.etc."nixos-repo".source = self.outPath;

  # Make the pinned nixpkgs resolvable on the live box so `nix` / flake commands
  # behave like an installed system, without shipping a channel.
  nix.registry.nixpkgs.flake = inputs.nixpkgs;

  # ── Login + Coder admin bootstrap ────────────────────────────────────────────
  # On installed hosts these come from the gitignored hosts/<host>/local.nix
  # that install.sh generates. The live image has no install step, so provide
  # turn-key defaults here (same defaults the installer uses). Autologin drops
  # straight into the Plasma desktop, mirroring a freshly-installed, configured
  # box. Change these before handing the ISO to anyone untrusted.
  services.displayManager.autoLogin = {
    enable = true;
    user   = "coderbox";
  };

  users.users.coderbox = {
    isNormalUser    = true;
    description     = "coderbox";
    extraGroups     = [ "networkmanager" "wheel" ];
    packages        = [ pkgs.kdePackages.kate ];
    initialPassword = "coderbox";
  };

  # coder-init-admin.service reads CODER_ADMIN_* from coder.service's
  # environment and creates a local admin on first boot, then mints a session
  # token and deploys the templates from /etc/nixos-repo/coderd. With these set
  # the live Coder instance is ready to use immediately.
  systemd.services.coder.environment = {
    CODER_ADMIN_EMAIL    = "admin@coder.com";
    CODER_ADMIN_USERNAME = "admin";
    CODER_ADMIN_PASSWORD = "PleaseChangeMe1234";
  };
}
