# Shared ISO mechanics for every Coder box image that ships as an ISO
# (appliance ISO, installer ISO). This is a _base primitive: it wires up the
# nixpkgs ISO builder and the boot-loader overrides, but carries NO image
# identity (volumeID / menu label / file name) — each image module under
# _images/appliance or _images/installer sets those.
#
# Provides `config.system.build.isoImage` and the `isoImage.*` options.
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:
{
  imports = [
    # Core ISO builder: squashfs nix store, tmpfs overlay root, kernel/initrd,
    # and the EFI + BIOS ISO bootloader.
    (modulesPath + "/installer/cd-dvd/iso-image.nix")
    # Broad driver/firmware set (see hardware.nix).
    ./hardware.nix
  ];

  isoImage.makeEfiBootable = true; # boot on UEFI machines
  # Legacy BIOS boot uses syslinux, which is x86-only. Enable it just for x86 so
  # the same module also evaluates/builds for an aarch64 ISO (which boots via
  # EFI only). isx86 covers both i686 and x86_64.
  isoImage.makeBiosBootable = pkgs.stdenv.hostPlatform.isx86;
  isoImage.makeUsbBootable = true; # `dd` straight to a USB stick and boot

  # Boot loader: let iso-image.nix own it. configuration.nix sets these for
  # installed UEFI machines; force them off so they don't conflict with the
  # image's own bootloader or try to touch the host's EFI variables when the
  # live system activates.
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.efi.canTouchEfiVariables = lib.mkForce false;

  # Tools install.sh expects at runtime, shipped in the base layer so every ISO
  # flavour (installer + appliance) has them:
  #   - dmidecode: read SMBIOS/DMI (board model, BIOS, serial) for the
  #     hardware-description auto-detection; also handy for inspecting the target
  #     machine from the live ISO.
  #   - gum: the interactive TUI (charmbracelet) install.sh drives for its
  #     --interactive prompts. install.sh hard-requires it (no fallback), so it
  #     must be present in the live environment.
  #   - openssl: install.sh uses `openssl rand` to generate the random default
  #     hostname suffix (coder-box-<random>); it's in the preflight tool checks.
  environment.systemPackages = [
    pkgs.dmidecode
    pkgs.gum
    pkgs.openssl
  ];

  # A store output that bundles the ISO together with its SHA-256 checksum, so
  # the checksum lives in the (immutable) /nix/store right beside the image. A
  # plain `nix build --out-link out/<target>` then surfaces both — no need to
  # write the sidecar into the read-only store path after the fact. The ISO is
  # symlinked (not copied) to avoid duplicating the multi-GB image; the
  # interpolation registers it as a runtime dependency so it is GC-rooted along
  # with this output. The checksum is written with the bare basename so
  # `sha256sum -c <name>.iso.sha256` verifies the ISO sitting next to it, and a
  # single `cp -L out/<target>/iso/*` copies image + sidecar together.
  system.build.isoImageDir = pkgs.runCommand "coder-box-iso-with-checksum" { } ''
    mkdir -p "$out/iso"
    for iso in ${config.system.build.isoImage}/iso/*.iso; do
      base=$(basename "$iso")
      ln -s "$iso" "$out/iso/$base"
      ( cd "$out/iso" && sha256sum "$base" > "$base.sha256" )
    done
  '';
}
