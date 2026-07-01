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

  # ── Show the build identity on the boot screen as a footer ───────────────────
  # The boot-menu ENTRY can't carry the build identity: it's a single,
  # non-wrapping line in a fixed-width GRUB/isolinux menu, so a long PR title
  # overflows and gets clipped (and widening the menu makes it span the whole
  # screen). Instead, render the identity as standalone GRUB *labels*
  # (boot-screen chrome, not selectable entries) shown as a footer UNDER the
  # menu, on up to two lines so a long PR title doesn't overflow the width:
  #   line 1 (always):  "Coder Box - <short-sha>@<branch>"
  #   line 2 (PR only): "(PR #46: <title>)"
  # Line 1 is always present (every build has a commit/branch), so the footer
  # shows on local/non-PR builds too, not just CI PR previews.
  #
  # Key gotcha: the stock theme's boot_menu fills almost the whole height with an
  # opaque white pixmap (boot_menu_*.png), and GRUB paints that box OVER any
  # label that overlaps it — so a footer placed inside the box is invisible. The
  # menu only has a handful of entries, so we shrink boot_menu's height to free
  # the lower area of the screen, then place the labels there on the plain
  # background (dark text, good contrast). The menu WIDTH is untouched (still the
  # stock 800px), so the menu doesn't blow up horizontally. EFI/GRUB only; the
  # BIOS/isolinux text menu has no theme, so there the identity is available
  # off-menu via /etc/coder-box-pr + the installer console banner.
  #
  # substituteInPlace uses --replace-fail so a future nixpkgs theme reflow fails
  # the build loudly instead of silently dropping the footer.
  isoImage.grubTheme =
    let
      inherit (config.coderBox) bootLabelLine1 bootLabelLine2;
      # theme.txt wraps the text in double quotes; neutralise quotes/backslashes
      # so an arbitrary title can't break the theme parser.
      themeSafe = builtins.replaceStrings [ "\"" "\\" ] [ "'" "" ];
      line1 = themeSafe bootLabelLine1;
      line2 = themeSafe bootLabelLine2;
      # A GRUB `+ label` is a single line, so line 2 (the PR title) is a second
      # label stacked ~1 line-height (font is 20px) below line 1. Only emitted
      # for PR builds (bootLabelLine2 is empty otherwise).
      line2Label = lib.optionalString (bootLabelLine2 != "") ''

        + label {
        	top = 50%+28
        	left = 50%-400
        	width = 800
        	align = "center"
        	color = "#232627"
        	font = "DejaVu Regular"
        	text = "${line2}"
        }
      '';
    in
    pkgs.runCommand "coder-box-grub2-theme" { } ''
      cp -r ${pkgs.nixos-grub2-theme} "$out"
      chmod -R u+w "$out"

      # 1) Shrink the menu box so its opaque pixmap stops at ~46% of the screen
      #    (~1/3 shorter than the stock full height), leaving the lower area free
      #    for the footer (stock fills to the progress bar and would cover it).
      substituteInPlace "$out/theme.txt" \
        --replace-fail 'height = 100%-3%-100-3%-3%-32-3%' 'height = 46%-100-6%'

      # 2) Footer label(s) just BELOW the shrunk box (top ~50%), so they sit close
      #    to the menu. left/width match the menu box (left = 50%-400, width =
      #    800) so the centred text lines up with the rectangle. Quoted heredoc so
      #    the build shell does no expansion; the text is already substituted by
      #    Nix (and quote/backslash-sanitised). line2Label is empty on non-PR
      #    builds.
      cat >> "$out/theme.txt" <<'EOF'

      + label {
      	top = 50%
      	left = 50%-400
      	width = 800
      	align = "center"
      	color = "#232627"
      	font = "DejaVu Regular"
      	text = "${line1}"
      }${line2Label}
      EOF
    '';

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
