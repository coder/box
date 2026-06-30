# Installer ISO module — boots the Coder box to install it onto real hardware.
#
# For now this is intentionally identical to the appliance ISO (full GUI box +
# turn-key Coder bootstrap), differing in image identity, an auto-run installer
# console, and having the Coder runtime services switched off (the installer
# doesn't need a live Coder stack). The eventual minimal, GUI-less installer is
# deferred.
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
  # Short form for the boot-menu label (full 40-char hashes are unwieldy there).
  boxRevShort = if boxRev == "unknown" then "unknown" else builtins.substring 0 12 boxRev;

  # Launcher run inside the preopened terminal: cd into the baked repo, run the
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
    # the format; leading space is required. Include the short build revision so
    # the boot menu shows exactly which image you're booting. For a PR preview
    # build (coderBox.prMenuSuffix non-empty) the PR reference comes first and
    # the commit hash moves to the very end, so the label reads
    # " - Coder Box Installer - PR #46: <title> (<rev>)"; otherwise it's just
    # " - Coder Box Installer (<rev>)".
    isoImage.appendToMenuLabel =
      if config.coderBox.prMenuSuffix != "" then
        " - Coder Box Installer${config.coderBox.prMenuSuffix} (${boxRevShort})"
      else
        " - Coder Box Installer (${boxRevShort})";

    # Record the full build revision for install.sh to print (the baked repo
    # under /etc/nixos-repo has no .git, so the script can't get it from git).
    environment.etc."coder-box-rev".text = boxRev + "\n";

    # ISO file name, with arch suffix (e.g. coder-box-installer-x86_64-linux.iso).
    # See ../appliance/iso.nix for why this is mkForce + arch-suffixed. The
    # PR-slug suffix (coderBox.prFileSuffix) is empty unless this is a PR preview
    # build (e.g. coder-box-installer-x86_64-linux-pr-fix-the-thing.iso).
    image.baseName = lib.mkForce "coder-box-installer-${pkgs.stdenv.hostPlatform.system}${config.coderBox.prFileSuffix}";

    # ── Auto-launch a full-screen terminal that runs the installer ─────────────
    # box-turnkey.nix autologins straight into the GNOME (Wayland) desktop. For
    # the installer we want the install to start on its own: a system-wide XDG
    # autostart entry opens GNOME Terminal full-screen on session start and runs
    # the installer launcher (`gnome-terminal -- <launcher>`), which
    # `sudo ./install.sh`s and drops to an interactive bash shell if it fails.
    environment.systemPackages = [ pkgs.gnome-terminal ];
    environment.etc."xdg/autostart/coder-box-installer-terminal.desktop".text = ''
      [Desktop Entry]
      Type=Application
      Name=Coder Box Installer Console
      Comment=Run the coder/box installer in a full-screen terminal
      Exec=${pkgs.gnome-terminal}/bin/gnome-terminal --full-screen --working-directory=/etc/nixos-repo -- ${installerLauncher}
      Terminal=false
      X-GNOME-Autostart-enabled=true
      OnlyShowIn=GNOME;
    '';

    # ── Never prompt for a password to get in ──────────────────────────────────
    # Login is already passwordless (box-turnkey coderbox autologin + passwordless
    # sudo). Disable GNOME's screen lock / idle blanking (idle auto-lock and the
    # idle-delay screensaver) so the installer is never locked or blanked mid
    # install. Shipped as a system dconf default for the autologin user. (The
    # appliance keeps the default locker.)
    programs.dconf.profiles.user.databases = [
      {
        settings = {
          "org/gnome/desktop/screensaver".lock-enabled = false;
          "org/gnome/desktop/session".idle-delay = lib.gvariant.mkUint32 0;
          "org/gnome/settings-daemon/plugins/power".sleep-inactive-ac-type = "nothing";
        };
      }
    ];

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
