# Hardware: Lenovo ThinkCentre M70q Gen 2.
#
# Hardware detection: hardware-configuration.nix provides fileSystems (UUID
# mounts) since this host pre-dates disko. When facter.json is present, the
# facter module also runs and supersedes the hardware-detection bits of
# hardware-configuration.nix (kernel modules, microcode, etc.). To migrate:
# run `sudo nix run nixpkgs#nixos-facter -- -o facter.json` on this host and
# commit the result.
#
# Disk layout: this host stays on UUID-based mounts from hardware-configuration.nix.
# It does NOT import nixos/disko-standard.nix because doing so would conflict
# with the existing fileSystems entries. Fresh installs of new hosts use
# disko-standard.nix and skip hardware-configuration.nix entirely.

{ config, pkgs, lib, inputs, ... }:

{
  imports = [ ./hardware-configuration.nix ]
    ++ lib.optional (builtins.pathExists ./local.nix) ./local.nix;

  # Activate nixos-facter only when facter.json has been generated for this
  # host. Until then, hardware-configuration.nix alone handles detection.
  hardware.facter.reportPath =
    lib.mkIf (builtins.pathExists ./facter.json) ./facter.json;

  # qemu-i386 binfmt: required for 32-bit ADT tools in the nook-android
  # workspace template (32-bit Android build tools run transparently in pods).
  boot.binfmt.emulatedSystems = [ "i686-linux" ];

  # ── Nook Android image build ───────────────────────────────────────────────
  # Builds the nook-android devcontainer image with Podman (needs qemu-i386
  # binfmt for the linux/386 stage) and imports it into k3s containerd so
  # workspace pods can reference localhost/nook-android:latest with Never pull.
  # Re-runs if the Dockerfile changes (stamp file tracks the content hash).
  systemd.services.nook-android-image-build = {
    description = "Build nook-android container image for Coder workspaces";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "network-online.target" "k3s.service" ];
    wants       = [ "network-online.target" ];
    # Don't block boot if the build fails; workspaces just can't start until fixed.
    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "nook-android-image-build" ''
        set -euo pipefail
        DOCKERFILE="/etc/nixos-repo/hosts/coder-thinkcentre/templates/nook-android/Dockerfile"
        STAMP="/var/lib/coder/nook-android-image.stamp"
        TAG="localhost/nook-android:latest"

        # Compute hash of the Dockerfile to detect changes
        HASH="$(${pkgs.coreutils}/bin/sha256sum "$DOCKERFILE" | ${pkgs.coreutils}/bin/cut -d' ' -f1)"

        if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$HASH" ]; then
          echo "nook-android image is up to date (hash: $HASH)"; exit 0
        fi

        echo "Building nook-android image (hash: $HASH)..."
        # Build the multi-stage image; qemu-i386 binfmt handles linux/386 stage
        ${pkgs.podman}/bin/podman build \
          --tag "$TAG" \
          --file "$DOCKERFILE" \
          --platform linux/amd64 \
          /etc/nixos-repo/hosts/coder-thinkcentre/templates/nook-android/

        echo "Exporting image to k3s containerd..."
        ${pkgs.podman}/bin/podman save "$TAG" \
          | ${pkgs.k3s}/bin/k3s ctr images import --platform linux/amd64 -

        echo "$HASH" > "$STAMP"
        echo "nook-android image built and imported successfully."
      '';
    };
  };
}
