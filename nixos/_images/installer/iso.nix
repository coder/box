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

{ config, lib, pkgs, ... }:

{
  imports = [
    ../base/iso.nix     # shared ISO mechanics
    ../box-turnkey.nix   # shared turn-key Coder box (login + Coder bootstrap)
  ];

  # ── Image identity ───────────────────────────────────────────────────────────
  isoImage.volumeID          = "CODER_BOX_INSTALLER";
  # Boot-menu label (BIOS/isolinux + EFI/grub). See _appliance/iso.nix for the
  # format; leading space is required.
  isoImage.appendToMenuLabel = " - Coder Box Installer";
  # ISO file name, with arch suffix (e.g. coder-box-installer-x86_64-linux.iso).
  # See ../appliance/iso.nix for why this is mkForce + arch-suffixed.
  image.baseName             = lib.mkForce "coder-box-installer-${pkgs.stdenv.hostPlatform.system}";

  # ── Auto-launch a full-screen Konsole on login ───────────────────────────────
  # box-turnkey.nix autologins straight into the Plasma (X11) desktop. For the
  # installer we want a terminal front-and-centre, so drop a system-wide XDG
  # autostart entry that opens Konsole full-screen as soon as the session starts,
  # with its working directory set to /etc/nixos-repo (the baked coder/box repo)
  # so the install commands are right there. This is the GUI-on stepping stone
  # toward the eventual terminal-driven install flow. (--fullscreen and
  # --workdir are Konsole CLI flags.)
  environment.systemPackages = [ pkgs.kdePackages.konsole ];
  environment.etc."xdg/autostart/coder-box-installer-konsole.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Coder Box Installer Console
    Comment=Open a full-screen terminal for installing coder/box
    Exec=${pkgs.kdePackages.konsole}/bin/konsole --fullscreen --workdir /etc/nixos-repo
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
}
