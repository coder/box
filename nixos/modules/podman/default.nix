# nixos/modules/podman — expose the rootless Podman socket to workspace pods.
#
# Layers on top of the k3s base (nixos/modules/k3s): k3s schedules pods with its
# built-in containerd runtime, and the host's rootless Podman socket
# (/run/user/991/podman/podman.sock) is bind-mounted into workspace pods via a
# hostPath volume in the Terraform template, so `docker` commands work inside
# workspaces without a privileged container or a custom CRI.
#
# Usage in configuration.nix (or the host's hosts/<host>/local.nix):
#   services.coder-nixos.podman.enable = true;
#
# Enabling this enables the k3s base automatically. Do NOT enable the sysbox
# module at the same time — both expect to own pod scheduling.
#
# Apply: sudo nixos-rebuild switch

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.coder-nixos.podman;
  coderUid = 991;
in
{
  options.services.coder-nixos.podman = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Expose the host's rootless Podman socket inside k3s workspace pods so
        that `docker` works in workspaces without a privileged container or a
        custom CRI. Enables the base k3s server (nixos/modules/k3s).

        Do NOT enable services.coder-nixos.sysbox at the same time — both
        expect to own pod scheduling.
      '';
    };
  };

  config = lib.mkIf cfg.enable {

    # Pull in the base single-node k3s server.
    services.coder-nixos.k3s.enable = lib.mkDefault true;

    # ── Podman socket world-accessible ────────────────────────────────────────
    # The rootless Podman socket /run/user/991/podman/podman.sock is 0600 by
    # default. k3s/containerd (root) can traverse /run/user/991 to bind-mount the
    # socket path, but processes *inside* the pod (UID 1000, mapped to host UID
    # ~100999 via subuid) need write access to the socket fd. chmod 0666 makes it
    # accessible to anyone who can reach the path.
    systemd.services.coder-podman-socket-fix = {
      description = "Ensure rootless Podman socket is accessible for workspace pods";
      wantedBy = [ "multi-user.target" ];
      after = [ "user@${toString coderUid}.service" ];
      wants = [ "user@${toString coderUid}.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;

        ExecStart = pkgs.writeShellScript "coder-podman-socket-fix" ''
          set -euo pipefail
          SOCKET="/run/user/${toString coderUid}/podman/podman.sock"

          # Wait up to 30 s for the user session to create the socket.
          for i in $(seq 1 30); do
            [ -S "$SOCKET" ] && break
            echo "Waiting for Podman socket ($i/30)..."
            sleep 1
          done

          if [ ! -S "$SOCKET" ]; then
            echo "WARNING: Podman socket not found at $SOCKET — skipping chmod."
            exit 0
          fi

          chmod 0666 "$SOCKET"
          echo "Podman socket chmod'd to 0666: $SOCKET"
        '';
      };
    };

    # ── Podman events-backend: override to "file" to avoid cross-UID journald hang
    #
    # Root cause: Podman defaults to the "journald" events backend. When a Docker
    # client inside a workspace pod (UID 1000, mapped to host ~100999 via subuid)
    # calls POST /containers/{id}/wait?condition=next-exit, Podman waits for a
    # journal event from the container. Cross-UID journal reads are either delayed
    # or never delivered, causing `docker run` (without --rm) to hang indefinitely
    # inside workspace pods.
    #
    # Fix: pass --events-backend=file to `podman system service` so Podman uses a
    # plain file-based event log instead of journald. A systemd user drop-in placed
    # at /etc/systemd/user/podman.service.d/events-backend.conf overrides ExecStart
    # for UID 991 (coder) without touching the read-only nix-store unit.
    environment.etc."systemd/user/podman.service.d/events-backend.conf".text = ''
      [Service]
      ExecStart=
      ExecStart=${pkgs.podman}/bin/podman $LOGGING --events-backend=file system service
    '';
  };
}
