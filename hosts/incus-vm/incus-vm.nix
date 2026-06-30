# NixOS module for Incus VM guests.
#
# Import this in hosts/<hostname>/default.nix for any machine that lives
# inside an Incus virtual machine (as opposed to bare-metal or LXC).
#
# What it does:
#   - Imports the upstream incus-virtual-machine.nix profile (QEMU guest
#     agents, virtio drivers, auto-resize, systemd-boot).
#   - Switches networking to systemd-networkd + DHCP on enp5s0 (the
#     virtio NIC Incus assigns to VMs on both x86_64 and aarch64).
#   - Disables the full desktop stack (KDE, PipeWire, printing, Avahi)
#     that configuration.nix enables by default — a headless VM only needs
#     the Coder server + PostgreSQL.
#
# k3s / sysbox are NOT enabled here. Set:
#   services.coder-nixos.sysbox.enable = true;
# in hosts/<hostname>/default.nix to enable the full box stack (Coder +
# PostgreSQL + k3s + sysbox) inside the VM.

{ lib, modulesPath, ... }:

{
  imports = [
    # Use path concatenation (not string interpolation) so this works in
    # pure eval mode when building from a flake.
    (modulesPath + "/virtualisation/incus-virtual-machine.nix")
  ];

  # Incus VMs get a virtio NIC named enp5s0 on both x86_64 and aarch64.
  # Use systemd-networkd instead of dhcpcd (already disabled by
  # incus-virtual-machine.nix, but be explicit).
  networking = {
    dhcpcd.enable = false;
    useDHCP = false;
    useHostResolvConf = false;
  };

  systemd.network = {
    enable = true;
    networks."50-enp5s0" = {
      matchConfig.Name = "enp5s0";
      networkConfig = {
        DHCP = "ipv4";
        IPv6AcceptRA = true;
      };
      linkConfig.RequiredForOnline = "routable";
    };
  };

  # The full desktop stack from configuration.nix is not needed in a VM.
  # Use lib.mkForce to win against the lib.mkDefault values set there.
  services.xserver.enable = lib.mkForce false;
  services.displayManager.sddm.enable = lib.mkForce false;
  services.desktopManager.plasma6.enable = lib.mkForce false;
  services.pipewire.enable = lib.mkForce false;
  services.pulseaudio.enable = lib.mkForce false;
  security.rtkit.enable = lib.mkForce false;
  services.printing.enable = lib.mkForce false;
  services.avahi.enable = lib.mkForce false;
}
