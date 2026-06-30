# Shared "turn-key" Box™ config — the bits that make an image boot straight
# into a fully-configured, ready-to-use Coder box with no install step.
#
# Shared by every Coder box image flavour:
#   - nixos/_images/appliance/iso.nix   (ephemeral appliance ISO: hosts/_appliance-iso)
#   - nixos/_images/installer/iso.nix   (installer ISO: hosts/_installer-iso)
#   - hosts/_appliance-disk/             (persistent disk image: qcow2 / raw)
#
# On real installs these settings come from install.sh + the gitignored
# hosts/<host>/local.nix it generates. The image flavours have no install step,
# so this module supplies the same turn-key defaults (same values the installer
# defaults to). Change them before handing an image to anyone untrusted, or
# override per-image via hosts/<host>/local.nix.

{
  config,
  lib,
  pkgs,
  self,
  inputs,
  ...
}:

let
  # ── PR-preview identity helpers ──────────────────────────────────────────────
  # For a PR-preview build CI injects the PR title + number (coderBox.prTitle /
  # coderBox.prNumber) so reviewers can tell which PR an image came from. This is
  # deliberately kept OFF the boot menu and OUT of the ISO file name:
  #   * The boot-menu entry is a single, non-wrapping line in a fixed-width
  #     GRUB/isolinux menu — a long title overflows and gets clipped, and
  #     widening the menu makes it span the whole screen, which looks broken.
  #   * The ISO file name stays constant per flavour/arch regardless of build,
  #     so it's predictable and downloads/links never change.
  # The PR identity is surfaced off-menu instead: recorded at /etc/coder-box-pr
  # and printed by the installer console banner (see prFull / ../installer/iso.nix).
  # Empty for tag/main/local builds.
  inherit (config.coderBox) prTitle prNumber;

  # Flatten newlines so the identity stays a single line in the file / banner.
  prTitleClean = builtins.replaceStrings [ "\n" ] [ " " ] prTitle;
  prNumMenu = lib.optionalString (prNumber != "") " #${prNumber}";

  # Full PR identity for off-menu surfaces (baked image record + installer
  # console banner): "PR #46: <full title>". Empty for non-PR builds.
  prFull = lib.optionalString (prTitle != "") "PR${prNumMenu}: ${prTitleClean}";
in
{
  imports = [
    # Broad driver/firmware set so the image boots on arbitrary hardware /
    # virtual machines (single source for the _images tree). Replaces the
    # per-host facter.json / hardware-configuration.nix that installed hosts
    # rely on (image hosts ship neither). The ISO flavours also pull this in
    # via base/iso.nix; importing the same module twice is a harmless no-op
    # (NixOS dedups identical module paths), and the _appliance-disk host —
    # which imports box-turnkey but NOT iso.nix — needs it from here.
    ./base/hardware.nix
  ];

  # Build revision baked into the image (used by the installer's boot-menu label
  # and /etc/coder-box-rev). Default works for `.#` (git+file) builds where
  # `self` carries git metadata; the Makefile builds through a *path* flakeref
  # (getFlake (toString ./.)) which has NO git metadata, so it overrides this
  # with `coderBox.rev = "<git rev>"` (see Makefile box_build). Defined here (in
  # the shared module) so it exists for every image host the Makefile builds.
  # (Because this module declares `options`, all its config must live under the
  # `config = { … }` block below.)
  options.coderBox.rev = lib.mkOption {
    type = lib.types.str;
    default = self.rev or self.dirtyRev or "unknown";
    description = "Git revision this Coder box image was built from.";
  };

  # PR title for a pull-request preview build. CI sets it via the
  # CODER_BOX_PR_TITLE environment variable (read here under `--impure`, which
  # every image build already uses), so an arbitrary title never has to be
  # shell-escaped into a Nix expression. getEnv returns "" in pure eval / when
  # unset, so non-PR builds (tags, main, local `nix build`) leave the pretty
  # version name untouched.
  options.coderBox.prTitle = lib.mkOption {
    type = lib.types.str;
    default = builtins.getEnv "CODER_BOX_PR_TITLE";
    description = "Pull-request title this image was built for. Surfaced off the boot menu (recorded at /etc/coder-box-pr and printed by the installer console) when non-empty; never woven into the menu label or ISO file name, which carry only the PR number.";
  };

  # PR number (GitHub PR "ID") for a pull-request preview build. CI sets it via
  # CODER_BOX_PR_NUMBER (read under `--impure` like prTitle); empty otherwise.
  options.coderBox.prNumber = lib.mkOption {
    type = lib.types.str;
    default = builtins.getEnv "CODER_BOX_PR_NUMBER";
    description = "Pull-request number (ID) this image was built for, woven into the pretty version name when non-empty.";
  };

  # Full, untruncated PR identity ("PR #46: <title>") for surfaces that AREN'T
  # the boot menu — recorded at /etc/coder-box-pr (below) and printed by the
  # installer console banner (../installer/iso.nix). The boot-menu label and the
  # ISO file name deliberately carry NO PR identity (neither title nor number):
  # the menu entry stays a clean "Coder Box <flavour> (<rev>)" and the file name
  # is constant per flavour/arch. Empty for non-PR builds.
  options.coderBox.prFull = lib.mkOption {
    type = lib.types.str;
    internal = true;
    readOnly = true;
    default = prFull;
    description = "Full PR identity (number + untruncated title) for off-menu surfaces (empty for non-PR builds).";
  };

  config = {

    # ── Bake the repo into the image at /etc/nixos-repo ──────────────────────────
    # The on-disk installer copies the working tree to /etc/nixos-repo; the Coder
    # bootstrap units (coder-init-admin.service, the coder-template-sync
    # activation script) read templates from /etc/nixos-repo/coderd and the
    # locally-packaged provider mirror. Point /etc/nixos-repo at the flake source
    # baked into the image so it deploys templates exactly like an installed box.
    # (The git-commit lookups in those scripts fall back to "unknown" when no
    # .git is present, which is fine.)
    #
    # IMPORTANT: filter out build artifacts before baking. `self.outPath` is the
    # flake source, but on a DIRTY working tree `getFlake`/`nix build .#…` copies
    # untracked files into it *even if they're gitignored* — including the
    # Makefile's ./out (where built images land) and any stray *.iso/*.qcow2/*.raw
    # in the repo. Baking that unfiltered means each build's image gets embedded
    # into /etc/nixos-repo → into the squashfs → into the *next* image, so the ISO
    # grows on every rebuild (a feedback loop). cleanSourceWith strips those paths
    # so the baked repo is stable regardless of build artifacts, while still
    # shipping the full tree (coderd/ etc.) for nixos-rebuild / coder-reset.
    environment.etc."nixos-repo".source = lib.cleanSourceWith {
      name = "nixos-repo-src";
      src = self.outPath;
      filter =
        path: _type:
        let
          base = baseNameOf (toString path);
        in
        base != "out"
        && base != "result"
        && !(lib.hasPrefix "result-" base)
        && !(lib.hasSuffix ".iso" base)
        && !(lib.hasSuffix ".qcow2" base)
        && !(lib.hasSuffix ".raw" base);
    };

    # Record the full PR identity (number + untruncated title) in the image so
    # it's available off the boot menu, where the title can't fit. The installer
    # console prints it (../installer/iso.nix); on any flavour it can also be
    # read with `cat /etc/coder-box-pr`. Only created for PR-preview builds.
    environment.etc."coder-box-pr" = lib.mkIf (prFull != "") {
      text = prFull + "\n";
    };

    # Make the pinned nixpkgs resolvable on the box so `nix` / flake commands
    # behave like an installed system, without shipping a channel.
    nix.registry.nixpkgs.flake = inputs.nixpkgs;

    # ── Login + Coder admin bootstrap ────────────────────────────────────────────
    # Autologin drops straight into the Plasma desktop, mirroring a
    # freshly-installed, configured box.
    services.displayManager.autoLogin = {
      enable = true;
      user = "coderbox";
    };

    users.users.coderbox = {
      isNormalUser = true;
      description = "coderbox";
      extraGroups = [
        "networkmanager"
        "wheel"
      ];
      packages = [ pkgs.kdePackages.kate ];
      initialPassword = "PleaseChangeMe1234";
    };

    # coder-init-admin.service reads CODER_ADMIN_* from coder.service's
    # environment and creates a local admin on first boot, then mints a session
    # token and deploys the templates from /etc/nixos-repo/coderd. With these set
    # the Coder instance is ready to use immediately.
    systemd.services.coder.environment = {
      CODER_ADMIN_EMAIL = "admin@coder.com";
      CODER_ADMIN_USERNAME = "admin";
      CODER_ADMIN_PASSWORD = "PleaseChangeMe1234";
    };

  }; # end config
}
