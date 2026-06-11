# Installer ISO module — boots the Coder box to install it onto real hardware.
#
# For now this is intentionally identical to the appliance ISO (full GUI box +
# turn-key Coder bootstrap), differing ONLY in image identity (volume ID, boot
# menu label, file name). The eventual plan is a minimal, GUI-less environment
# whose job is to install the coder/box repo onto a target disk — that strip-
# down is deferred; the GUI is kept on for now.
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

{ config, lib, pkgs, self, ... }:

let
  # Revision this image was built from. self.rev is the clean git commit;
  # dirtyRev (…-dirty) when built from an uncommitted tree; "unknown" otherwise.
  boxRev = self.rev or self.dirtyRev or "unknown";
  # Short form for the boot-menu label (full 40-char hashes are unwieldy there).
  boxRevShort = if boxRev == "unknown" then "unknown" else builtins.substring 0 12 boxRev;

  # Launcher run inside the preopened Konsole: cd into the baked repo, run the
  # installer as root (passwordless sudo is configured in configuration.nix),
  # and — whatever happens — drop the user into an interactive bash shell so a
  # failed install leaves them at a prompt to inspect/retry instead of a dead
  # terminal. (On success install.sh reboots, so the shell is only reached on
  # failure or --no-reboot.)
  installerLauncher = pkgs.writeShellScript "coder-box-installer-launch" ''
    cd /etc/nixos-repo 2>/dev/null || cd /
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
    # the shell closes Konsole.
    exec ${pkgs.bashInteractive}/bin/bash -i
  '';
in
{
  imports = [
    ../base/iso.nix     # shared ISO mechanics
    ../box-turnkey.nix   # shared turn-key Coder box (login + Coder bootstrap)
  ];

  # ── Image identity ───────────────────────────────────────────────────────────
  isoImage.volumeID          = "CODER_BOX_INSTALLER";
  # Boot-menu label (BIOS/isolinux + EFI/grub). See ../appliance/iso.nix for the
  # format; leading space is required. Include the short build revision so the
  # boot menu shows exactly which image you're booting.
  isoImage.appendToMenuLabel = " - Coder Box Installer (${boxRevShort})";

  # Record the full build revision for install.sh to print (the baked repo under
  # /etc/nixos-repo has no .git, so the script can't derive it from git there).
  environment.etc."coder-box-rev".text = boxRev + "\n";
  # ISO file name, with arch suffix (e.g. coder-box-installer-x86_64-linux.iso).
  # See ../appliance/iso.nix for why this is mkForce + arch-suffixed.
  image.baseName             = lib.mkForce "coder-box-installer-${pkgs.stdenv.hostPlatform.system}";

  # ── Auto-launch a full-screen Konsole that runs the installer ────────────────
  # box-turnkey.nix autologins straight into the Plasma (X11) desktop. For the
  # installer we want the install to start on its own: a system-wide XDG
  # autostart entry opens Konsole full-screen on session start and runs the
  # installer launcher (`konsole -e <launcher>`), which `sudo ./install.sh`s and
  # drops to an interactive bash shell if it fails. This is the GUI-on stepping
  # stone toward the eventual terminal-driven install flow.
  environment.systemPackages = [ pkgs.kdePackages.konsole ];
  environment.etc."xdg/autostart/coder-box-installer-konsole.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Coder Box Installer Console
    Comment=Run the coder/box installer in a full-screen terminal
    Exec=${pkgs.kdePackages.konsole}/bin/konsole --fullscreen --workdir /etc/nixos-repo -e ${installerLauncher}
    Terminal=false
    X-GNOME-Autostart-enabled=true
    OnlyShowIn=KDE;
  '';

  # ── Never prompt for a password to get in ────────────────────────────────────
  # Login itself is already passwordless: box-turnkey.nix autologins the
  # `coderbox` user, and configuration.nix sets passwordless sudo. The only
  # remaining password gate is KDE's screen locker (idle auto-lock or
  # lock-on-resume), which would force a password to get back into the session.
  # Disable it system-wide for the installer so the box is never locked. (The
  # appliance keeps the default locker.)
  environment.etc."xdg/kscreenlockerrc".text = ''
    [Daemon]
    Autolock=false
    LockOnResume=false
  '';

  # ── Installer ergonomics ─────────────────────────────────────────────────────
  # Running `sudo ./install.sh` from the baked /etc/nixos-repo works because the
  # script detects its repo dir is read-only (a symlink into the read-only Nix
  # store) and copies it to a writable tmpdir (tmpfs/RAM here) to re-exec from.
  # The copy keeps the baked .git (if any), so the installed /etc/nixos-repo can
  # `git pull` to update. install.sh builds the system closure straight into the
  # target disk's /mnt/nix/store.
  #
  # Mirror nixpkgs' installation-device.nix low-memory tweak so the kernel's
  # overcommit heuristics don't spuriously block forks during the install on
  # low-RAM machines.
  boot.kernel.sysctl."vm.overcommit_memory" = "1";

  # ── Don't run the Coder box services in the installer ────────────────────────
  # The installer's only job is to install coder/box onto a disk; it inherits
  # the full box config (configuration.nix + box-turnkey) but the running Coder
  # server, k3s, PostgreSQL, Podman, the bootstrap/redirect/reaper units, and
  # template-sync are all dead weight here (they'd boot a whole Coder stack we
  # never use, slow startup, and eat RAM/CPU during the install). Disable them.
  # The INSTALLED system still gets them — this only affects the live installer.
  services.coder-nixos.k3s-sysbox.enable = lib.mkForce false;
  services.postgresql.enable             = lib.mkForce false;
  virtualisation.podman.enable           = lib.mkForce false;

  systemd.services.coder.enable                  = false;
  systemd.services.coder-init-admin.enable       = false;
  systemd.services.coder-redirect.enable         = false;
  systemd.services.coder-logstream-kube.enable   = false;
  systemd.services.coder-workspace-reaper.enable = false;
  systemd.timers.coder-workspace-reaper.enable   = false;
  systemd.services.coder-sync-ssh-keys.enable    = false;

  # Activation script that pushes templates via terraform on every switch —
  # pointless in the live installer (no running Coder, empty session token).
  system.activationScripts.coder-template-sync = lib.mkForce "";
}
