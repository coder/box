# Installer ISO module — boots the Coder box to install it onto real hardware.
#
# Unlike the appliance ISO, the installer runs GUI-LESS: it boots straight to a
# text console on tty1 that auto-runs the installer, with the GNOME/Wayland
# desktop (and the Coder runtime stack) switched off. It shares the turn-key
# module only for the baked /etc/nixos-repo + build identity; it deliberately
# does NOT bring up GNOME.
#
# Why no desktop here (this matters — it used to run the full GNOME session):
# install.sh has to `nix build` the target host's closure, which realises a few
# host-specific derivations that aren't in the baked store (e.g.
# nixos-generate-config's perl env — it depends on the installed host's
# facter/hardware inputs, so it can't be pre-baked into any image). Building
# those reads the rest of the store from the squashfs on the (slow, often
# emulated) live medium. When GNOME Shell + Mutter were also running on software
# rendering (llvmpipe), the combined load overwhelmed the medium and store reads
# failed with EIO ("Input/output error" reading glibc headers), aborting the
# build. A bare console removes GNOME entirely: the install build is the only
# load, reads stay reliable, and the installer starts deterministically instead
# of racing gnome-terminal's D-Bus server.
#
# Build (hosts/_installer-iso => nixosConfigurations._installer-iso, see flake.nix):
#
#   make installer/iso
#   # or: nix build .#nixosConfigurations._installer-iso.config.system.build.isoImage
#   # → out/installer-iso/iso/coder-box-installer-*.iso  (flash with `dd`, Ventoy, etc.)
#
# Composition mirrors the appliance ISO: ../base/iso.nix (ISO mechanics) +
# ../box-turnkey.nix (turn-key Coder box). Unlike the appliance, the installer
# is built ONLY as an ISO (no qcow2/raw disk images).

{
  config,
  lib,
  pkgs,
  ...
}:

let
  boxRev = config.coderBox.rev;

  # Launcher run on the tty1 installer console: cd into the baked repo, run the
  # installer as root (passwordless sudo is configured in configuration.nix),
  # and — whatever happens — drop the user into an interactive bash shell so a
  # failed install leaves them at a prompt to inspect/retry instead of a dead
  # terminal. (On success install.sh reboots, so the shell is only reached on
  # failure or --no-reboot.)
  installerLauncher = pkgs.writeShellScript "coder-box-installer-launch" ''
    cd /etc/nixos-repo 2>/dev/null || cd /
    # The installer ISO is meant to be driven interactively from this console,
    # so default to --interactive (gum prompts for everything not preset). Any
    # extra args forwarded to the launcher are appended after it; --yes still
    # wins (install.sh ignores --interactive when --yes is given).
    set -- --interactive "$@"
    echo "=== Coder Box installer ==="
    # For PR-preview builds, print the full PR identity (number + untruncated
    # title) here, off the boot menu, where it can't be clipped. The file only
    # exists on PR builds (see ../box-turnkey.nix), so non-PR images print nothing.
    if [ -s /etc/coder-box-pr ]; then
      echo "Image: $(cat /etc/coder-box-pr)"
    fi
    echo "Running: sudo ./install.sh $*"
    echo
    if sudo ./install.sh "$@"; then
      echo
      echo "=== install.sh finished ==="
    else
      rc=$?
      echo
      echo "=== install.sh FAILED (exit $rc) — dropping you into a shell ==="
      echo "    You are in /etc/nixos-repo. Re-run with: sudo ./install.sh"
    fi
    echo
    # Interactive login-ish shell so the user can debug/retry. exec so closing
    # the shell closes the terminal window.
    exec ${pkgs.bashInteractive}/bin/bash -i
  '';
in
{
  imports = [
    ../base/iso.nix # shared ISO mechanics
    ../box-turnkey.nix # shared turn-key Coder box (login + Coder bootstrap)
  ];

  # config.coderBox.rev is defined in ../box-turnkey.nix (shared by all image
  # hosts so the Makefile can inject the rev for every target). It defaults to
  # self.rev/dirtyRev for `.#` builds and is overridden by the Makefile.
  config = {
    # ── Image identity ─────────────────────────────────────────────────────────
    isoImage.volumeID = "CODER_BOX_INSTALLER";
    # Boot-menu label (BIOS/isolinux + EFI/grub). See ../appliance/iso.nix for
    # the format; leading space is required. The label is the same for every
    # build — " - Coder Box Installer" — with NO build identity: the commit
    # short-sha (and, for PR previews, the PR number + title) live in the
    # boot-screen footer label instead (coderBox.bootLabel, see ../base/iso.nix),
    # so the menu entry stays clean. The full "PR #N: <title>" is also printed by
    # the installer console banner and recorded at /etc/coder-box-pr.
    isoImage.appendToMenuLabel = " - Coder Box Installer";

    # Record the full build revision for install.sh to print (the baked repo
    # under /etc/nixos-repo has no .git, so the script can't get it from git).
    environment.etc."coder-box-rev".text = boxRev + "\n";

    # ISO file name, with arch suffix (e.g. coder-box-installer-x86_64-linux.iso).
    # See ../appliance/iso.nix for why this is mkForce + arch-suffixed. The name
    # is constant for a given flavour/arch — it carries NO PR identity, so a PR
    # preview ISO has the exact same file name as a release build.
    image.baseName = lib.mkForce "coder-box-installer-${pkgs.stdenv.hostPlatform.system}";

    # ── Boot to a text console, not the GNOME desktop ──────────────────────────
    # The appliance and the installed box run GNOME on Wayland (configuration.nix
    # + box-turnkey.nix). The installer does NOT: force the whole desktop stack
    # off so tty1 comes up as a plain text console. This is what keeps the
    # install-time `nix build` from failing with EIO on the live medium (see the
    # header comment) and also drops GNOME from the installer's closure, shrinking
    # the image. mkForce beats the mkDefault/normal values set in the shared
    # modules.
    services.xserver.enable = lib.mkForce false;
    services.displayManager.gdm.enable = lib.mkForce false;
    services.desktopManager.gnome.enable = lib.mkForce false;
    services.displayManager.autoLogin.enable = lib.mkForce false;

    # ── Auto-run the installer on tty1 ─────────────────────────────────────────
    # Replace getty on tty1 with a service that runs the installer launcher
    # directly, with a real controlling terminal (StandardInput=tty + TTYPath) so
    # install.sh's gum TUI prompts work. Type=idle waits for boot output to
    # settle first. On failure the launcher drops to an interactive shell on the
    # same tty; on success install.sh reboots.
    systemd.services."getty@tty1".enable = false;
    systemd.services.coder-box-installer = {
      description = "Coder Box installer console (tty1)";
      wantedBy = [ "multi-user.target" ];
      after = [
        "multi-user.target"
        "systemd-user-sessions.service"
      ];
      conflicts = [ "getty@tty1.service" ];
      serviceConfig = {
        Type = "idle";
        ExecStart = installerLauncher;
        StandardInput = "tty";
        StandardOutput = "tty";
        TTYPath = "/dev/tty1";
        TTYReset = true;
        TTYVHangup = true;
        Restart = "no";
      };
    };

    # ── Installer ergonomics ───────────────────────────────────────────────────
    # `sudo ./install.sh` from the baked /etc/nixos-repo works because the script
    # detects its repo dir is read-only (a symlink into the read-only Nix store)
    # and copies it to a writable tmpdir (tmpfs/RAM here) to re-exec from. The
    # copy keeps the baked .git (if any) so the installed /etc/nixos-repo can
    # `git pull`. Mirror nixpkgs' installation-device.nix low-memory tweak so the
    # kernel's overcommit heuristics don't spuriously block forks during install.
    boot.kernel.sysctl."vm.overcommit_memory" = "1";

    # ── Don't run the Coder box services in the installer ──────────────────────
    # The installer's only job is to install coder/box onto a disk; it inherits
    # the full box config but the running Coder server, k3s, PostgreSQL, Podman,
    # the bootstrap/redirect/reaper units, and template-sync are dead weight here
    # (slow startup, wasted RAM/CPU during install). Disable them — the INSTALLED
    # system still gets everything; this only affects the live installer.
    services.coder-nixos.sysbox.enable = lib.mkForce false;
    services.coder-nixos.k3s.enable = lib.mkForce false;
    services.postgresql.enable = lib.mkForce false;
    virtualisation.podman.enable = lib.mkForce false;

    systemd.services.coder.enable = false;
    systemd.services.coder-init-admin.enable = false;
    systemd.services.coder-redirect.enable = false;
    systemd.services.coder-logstream-kube.enable = false;
    systemd.services.coder-workspace-reaper.enable = false;
    systemd.timers.coder-workspace-reaper.enable = false;
    systemd.services.coder-sync-ssh-keys.enable = false;

    # Template-sync activation script — pointless in the live installer (no
    # running Coder, empty session token).
    system.activationScripts.coder-template-sync = lib.mkForce "";
  };
}
