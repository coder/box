# Shared "turn-key" Box™ config — the bits that make an image boot straight
# into a fully-configured, ready-to-use Coder box with no install step.
#
# Shared by every Coder box image flavour:
#   - nixos/_images/appliance/iso.nix   (ephemeral appliance ISO: hosts/_appliance_iso)
#   - nixos/_images/installer/iso.nix   (installer ISO: hosts/_installer-iso)
#   - hosts/_appliance-disk/             (persistent disk image: qcow2 / raw)
#
# On real installs these settings come from install.sh + the gitignored
# hosts/<host>/local.nix it generates. The image flavours have no install step,
# so this module supplies the same turn-key defaults (same values the installer
# defaults to). Change them before handing an image to anyone untrusted, or
# override per-image via hosts/<host>/local.nix.

{ config, lib, pkgs, self, inputs, ... }:

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
    filter = path: type:
      let base = baseNameOf (toString path); in
      base != "out"
      && base != "result"
      && !(lib.hasPrefix "result-" base)
      && !(lib.hasSuffix ".iso" base)
      && !(lib.hasSuffix ".qcow2" base)
      && !(lib.hasSuffix ".raw" base);
  };

  # Make the pinned nixpkgs resolvable on the box so `nix` / flake commands
  # behave like an installed system, without shipping a channel.
  nix.registry.nixpkgs.flake = inputs.nixpkgs;

  # ── Login + Coder admin bootstrap ────────────────────────────────────────────
  # Autologin drops straight into the Plasma desktop, mirroring a
  # freshly-installed, configured box.
  services.displayManager.autoLogin = {
    enable = true;
    user   = "coderbox";
  };

  users.users.coderbox = {
    isNormalUser    = true;
    description     = "coderbox";
    extraGroups     = [ "networkmanager" "wheel" ];
    packages        = [ pkgs.kdePackages.kate ];
    initialPassword = "PleaseChangeMe1234";
  };

  # coder-init-admin.service reads CODER_ADMIN_* from coder.service's
  # environment and creates a local admin on first boot, then mints a session
  # token and deploys the templates from /etc/nixos-repo/coderd. With these set
  # the Coder instance is ready to use immediately.
  systemd.services.coder.environment = {
    CODER_ADMIN_EMAIL    = "admin@coder.com";
    CODER_ADMIN_USERNAME = "admin";
    CODER_ADMIN_PASSWORD = "PleaseChangeMe1234";
  };
}
