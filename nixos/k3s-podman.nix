# k3s-podman.nix — NixOS module: single-node k3s + rootless Podman socket
#
# Design:
#   k3s uses its built-in containerd runtime for pod scheduling.
#   The existing rootless Podman socket at /run/user/991/podman/podman.sock is
#   bind-mounted into workspace pods via a hostPath volume in the Terraform template.
#   No custom CRI is needed; Podman is purely a docker-in-workspace mechanism.
#
# Usage in configuration.nix (or the host's `hosts/<host>/local.nix`):
#   imports = [ ./k3s-podman.nix ];
#   services.coder-nixos.k3s.enable = true;
#
# After enabling and rebuilding:
#   1. k3s starts and writes /etc/rancher/k3s/k3s.yaml (kubeconfig)
#   2. coder-k3s-kubeconfig-fix sets it to root:coder 0640
#   3. Coder's Terraform runner picks up KUBECONFIG automatically
#   4. Workspace pods see /var/run/docker.sock → rootless Podman socket from the host

{ config, lib, pkgs, ... }:

let
  cfg      = config.services.coder-nixos.k3s;
  coderUid = 991;
in

{
  # ── Option declaration ──────────────────────────────────────────────────────
  options.services.coder-nixos.k3s = {
    enable = lib.mkOption {
      type        = lib.types.bool;
      default     = false;
      description = ''
        Enable a single-node k3s server on this host.

        k3s uses its built-in containerd runtime for scheduling workspace pods.
        The host's rootless Podman socket is exposed inside pods via a hostPath
        volume so that `docker` commands work inside workspaces without requiring
        a privileged container or a custom CRI.

        After enabling, Coder's Terraform provisioner can reach the cluster via
        /etc/rancher/k3s/k3s.yaml, which is made group-readable for the coder
        group by a systemd service.
      '';
    };
  };

  # ── Implementation ──────────────────────────────────────────────────────────
  config = lib.mkIf cfg.enable {

    # ── k3s server ────────────────────────────────────────────────────────────
    services.k3s = {
      enable = true;
      role   = "server";

      extraFlags = lib.concatStringsSep " " [
        # Make kubeconfig readable by coder group after ownership fix below.
        "--write-kubeconfig-mode=640"

        # Disable components we don't need on a single demo box.
        "--disable=traefik"
        "--disable=servicelb"

        # Ensure the node registers with the machine's hostname.
        "--node-name=${config.networking.hostName}"

        # Single-node: bind API server on all interfaces so Terraform can
        # reach 127.0.0.1:6443 from within the coder service.
        "--bind-address=0.0.0.0"

        # Allow pods to use host user namespaces (needed for rootless podman
        # socket bind-mounts when userns=keep-id is set in the workspace image).
        "--kube-apiserver-arg=--allow-privileged=true"
      ];
    };

    # ── Kernel: user namespaces for rootless containers ───────────────────────
    # Already set in configuration.nix; lib.mkDefault lets the outer config win.
    boot.kernel.sysctl."user.max_user_namespaces" = lib.mkDefault 65536;

    # ── kubectl in PATH ────────────────────────────────────────────────────────
    environment.systemPackages = [ pkgs.kubectl ];

    # ── KUBECONFIG system-wide ────────────────────────────────────────────────
    environment.variables.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";

    # ── tmpfiles: ensure /etc/rancher/k3s exists early ───────────────────────
    systemd.tmpfiles.rules = [
      "d /etc/rancher       0755 root root  -"
      "d /etc/rancher/k3s   0750 root coder -"
    ];

    # ── Pre-create the coder-workspaces namespace ────────────────────────────
    # Templates deploy workloads into this namespace; they should not own it.
    # Declared as a k3s auto-deploy manifest (rather than a kubectl one-shot
    # service): k3s applies files in /var/lib/rancher/k3s/server/manifests/ via
    # its addon controller as soon as the API server is up, so the namespace is
    # created declaratively with no systemd unit for anything to order against.
    services.k3s.manifests."coder-workspaces-namespace".content = {
      apiVersion = "v1";
      kind       = "Namespace";
      metadata.name = "coder-workspaces";
    };

    # ── API readiness gate ───────────────────────────────────────────────────
    # Polls /readyz until the API accepts requests. Consumers that need a live
    # API (e.g. coder-logstream-kube) order after this instead of k3s.service,
    # which reaches "active" before the API finishes coming up on a cold boot.
    systemd.services.k3s-api-ready = {
      description = "Wait for k3s API server /readyz";
      wantedBy    = [ "multi-user.target" ];
      after       = [ "k3s.service" ];
      requires    = [ "k3s.service" ];

      serviceConfig = {
        Type            = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "k3s-wait-api-ready" ''
          echo "k3s-wait-api-ready: waiting for API server /readyz..."
          for i in $(seq 1 120); do
            if ${pkgs.curl}/bin/curl -sf -o /dev/null \
                --cacert /var/lib/rancher/k3s/server/tls/server-ca.crt \
                https://127.0.0.1:6443/readyz 2>/dev/null; then
              echo "k3s-wait-api-ready: API ready after ''${i}s"
              exit 0
            fi
            sleep 1
          done
          echo "k3s-wait-api-ready: timed out after 120s — continuing anyway"
          exit 0
        '';
      };
    };

    # ── Kubeconfig ownership fix ──────────────────────────────────────────────
    # k3s writes /etc/rancher/k3s/k3s.yaml as 0640 root:root when
    # --write-kubeconfig-mode=640 is set.  We need it root:coder 0640 so
    # UID 991 can read it without sudo.
    systemd.services.coder-k3s-kubeconfig-fix = {
      description = "Fix k3s kubeconfig ownership (root:coder 0640)";
      wantedBy    = [ "multi-user.target" ];
      after       = [ "k3s.service" ];
      requires    = [ "k3s.service" ];

      serviceConfig = {
        Type            = "oneshot";
        RemainAfterExit = true;

        ExecStart = pkgs.writeShellScript "coder-k3s-kubeconfig-fix" ''
          set -euo pipefail
          KUBECONFIG="/etc/rancher/k3s/k3s.yaml"

          # Wait up to 60 s for k3s to write the file.
          for i in $(seq 1 60); do
            [ -f "$KUBECONFIG" ] && break
            echo "Waiting for $KUBECONFIG ... ($i/60)"
            sleep 1
          done

          if [ ! -f "$KUBECONFIG" ]; then
            echo "ERROR: $KUBECONFIG was not written by k3s after 60 seconds"
            exit 1
          fi

          chown root:coder "$KUBECONFIG"
          chmod 640        "$KUBECONFIG"
          echo "kubeconfig permissions fixed: $(stat -c '%a %U:%G' "$KUBECONFIG")"
        '';
      };
    };

    # ── Podman socket world-accessible ───────────────────────────────────────
    # The rootless Podman socket /run/user/991/podman/podman.sock is 0600
    # by default.  k3s/containerd (root) can traverse /run/user/991 to
    # bind-mount the socket path.  But processes *inside* the pod (UID 1000,
    # mapped to host UID ~100999 via subuid) need write access to the socket fd.
    # chmod 0666 makes it accessible to anyone who can reach the path.
    systemd.services.coder-podman-socket-fix = {
      description = "Ensure rootless Podman socket is accessible for workspace pods";
      wantedBy    = [ "multi-user.target" ];
      after       = [ "user@${toString coderUid}.service" ];
      wants       = [ "user@${toString coderUid}.service" ];

      serviceConfig = {
        Type            = "oneshot";
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

    # ── Inject KUBECONFIG into coder.service ──────────────────────────────────
    # Inject KUBECONFIG for Terraform's kubernetes provider.
    #
    # coder.service is intentionally NOT ordered after k3s. The Coder server
    # only needs Postgres to start and serve; gating it behind k3s (which can
    # take a while to be ready on a cold boot) delayed the server, its tunnel
    # URL and web UI for no reason.
    #
    # The coder-workspaces namespace is only needed for the *first workspace
    # build*, not for the server to start. It is now created declaratively by
    # k3s's addon controller from a manifest (see services.k3s.manifests
    # above), so there is no systemd unit to order against.
    systemd.services.coder = {
      environment = {
        KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
      };
    };

    # ── Podman events-backend: override to "file" to avoid cross-UID journald hang
    #
    # Root cause: Podman defaults to the "journald" events backend.  When a
    # Docker client inside a workspace pod (UID 1000, mapped to host ~100999 via
    # subuid) calls POST /containers/{id}/wait?condition=next-exit, Podman waits
    # for a journal event from the container.  Cross-UID journal reads are either
    # delayed or never delivered, causing `docker run` (without --rm) to hang
    # indefinitely inside workspace pods.
    #
    # Fix: pass --events-backend=file to `podman system service` so Podman uses a
    # plain file-based event log instead of journald.  A systemd user drop-in
    # placed at /etc/systemd/user/podman.service.d/events-backend.conf overrides
    # ExecStart for UID 991 (coder) without touching the read-only nix-store unit.
    environment.etc."systemd/user/podman.service.d/events-backend.conf".text = ''
      [Service]
      ExecStart=
      ExecStart=${pkgs.podman}/bin/podman $LOGGING --events-backend=file system service
    '';

    # ── Ensure coder group exists ──────────────────────────────────────────────
    users.groups.coder = lib.mkDefault {};

  }; # end config
}
