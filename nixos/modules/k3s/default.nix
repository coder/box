# nixos/modules/k3s — base single-node k3s server.
#
# Generic k3s server shared by the podman and sysbox add-on modules. Enabling
# either of those pulls this in automatically (via mkDefault), but it can also
# be enabled on its own:
#
#   services.coder-nixos.k3s.enable = true;
#
# This module owns everything generic: the k3s service + flags, the kubeconfig
# ownership fix (root:coder 0640 so UID 991 can read it), the coder-workspaces
# namespace, the KUBECONFIG injection into coder.service, and kubectl/helm.
#
# The podman (nixos/modules/podman) and sysbox (nixos/modules/sysbox) modules
# layer their runtime-specific pieces on top. They are mutually exclusive in
# practice (both expect to own pod scheduling), so enable at most one.
#
# Apply: sudo nixos-rebuild switch

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.coder-nixos.k3s;
in
{
  options.services.coder-nixos.k3s = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable a single-node k3s server on this host.

        This is the base layer. The podman and sysbox modules enable it
        automatically; enable it directly only if you want a plain k3s server
        with no extra container runtime wiring.

        After enabling, Coder's Terraform provisioner can reach the cluster via
        /etc/rancher/k3s/k3s.yaml, which is made group-readable for the coder
        group by a systemd service.
      '';
    };
  };

  config = lib.mkIf cfg.enable {

    # ── Kernel: user namespaces for rootless containers ───────────────────────
    # configuration.nix sets a non-default value too; mkDefault lets that win.
    boot.kernel.sysctl."user.max_user_namespaces" = lib.mkDefault 65536;

    # ── k3s server ────────────────────────────────────────────────────────────
    # extraFlags is the union of every flag the podman/sysbox layers need; the
    # sets are additive (none contradict), so a single base config serves both.
    services.k3s = {
      enable = true;
      role = "server";

      extraFlags = lib.concatStringsSep " " [
        # Make kubeconfig readable by coder group after the ownership fix below.
        "--write-kubeconfig-mode=0640"

        # Disable components we don't need on a single demo box.
        "--disable=traefik"
        "--disable=servicelb"

        # Register the node with the machine's hostname.
        "--node-name=${config.networking.hostName}"

        # Single-node: bind the API server on all interfaces so Terraform can
        # reach 127.0.0.1:6443 from within the coder service.
        "--bind-address=0.0.0.0"

        # Allow privileged pods (needed by some workspace runtimes).
        "--kube-apiserver-arg=--allow-privileged=true"

        # systemd cgroup driver to match the host.
        "--kubelet-arg=cgroup-driver=systemd"

        # TLS SAN for the .local mDNS name.
        "--tls-san=${config.networking.hostName}.local"
      ];
    };

    # ── kubeconfig ownership fix ──────────────────────────────────────────────
    # k3s writes /etc/rancher/k3s/k3s.yaml as 0640 root:root. We need it
    # root:coder 0640 so UID 991 can read it without sudo. A standalone service
    # (rather than a k3s ExecStartPost) so both add-on modules share one fix and
    # so it does not hold k3s.service in "activating" (see k3s-api-ready below).
    systemd.services.coder-k3s-kubeconfig-fix = {
      description = "Fix k3s kubeconfig ownership (root:coder 0640)";
      wantedBy = [ "multi-user.target" ];
      after = [ "k3s.service" ];
      requires = [ "k3s.service" ];

      serviceConfig = {
        Type = "oneshot";
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
          chmod 0640       "$KUBECONFIG"
          echo "kubeconfig permissions fixed: $(stat -c '%a %U:%G' "$KUBECONFIG")"
        '';
      };
    };

    # ── API readiness gate ────────────────────────────────────────────────────
    # Polls /readyz until the API accepts requests so in-cluster pods
    # (local-path-provisioner, etc.) and API consumers don't race the API before
    # it is up on cold boots. Kept OUT of k3s.service's ExecStartPost: an
    # ExecStartPost holds the unit in "activating" until it returns, so polling
    # /readyz (up to ~2 min on a cold boot) inline made k3s.service itself appear
    # to take ~2 min to start and stalled everything ordered after it. A separate
    # gate lets k3s.service go active fast while readiness-sensitive consumers
    # order after THIS unit instead.
    systemd.services.k3s-api-ready = {
      description = "Wait for k3s API server /readyz";
      wantedBy = [ "multi-user.target" ];
      after = [ "k3s.service" ];
      requires = [ "k3s.service" ];

      serviceConfig = {
        Type = "oneshot";
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

    # ── tmpfiles: ensure /etc/rancher/k3s exists early ───────────────────────
    systemd.tmpfiles.rules = [
      "d /etc/rancher       0755 root root  -"
      "d /etc/rancher/k3s   0750 root coder -"
    ];

    # ── Pre-create the coder-workspaces namespace ─────────────────────────────
    # Templates deploy workloads into this namespace; they should not own it.
    # Declared as a k3s auto-deploy manifest (rather than a kubectl one-shot
    # service): k3s applies files in /var/lib/rancher/k3s/server/manifests/ via
    # its addon controller as soon as the API server is up, so the namespace is
    # created declaratively with no systemd unit for anything to order against.
    services.k3s.manifests."coder-workspaces-namespace".content = {
      apiVersion = "v1";
      kind = "Namespace";
      metadata.name = "coder-workspaces";
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
    # k3s's addon controller from a manifest (see services.k3s.manifests above),
    # so there is no systemd unit to order against — by the time a user
    # provisions a workspace the namespace exists.
    systemd.services.coder = {
      environment = {
        KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
      };
    };

    # ── KUBECONFIG system-wide ────────────────────────────────────────────────
    environment.variables.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";

    # ── Ensure coder group exists ─────────────────────────────────────────────
    users.groups.coder = lib.mkDefault { };

    # ── kubectl + helm in PATH ────────────────────────────────────────────────
    environment.systemPackages = with pkgs; [
      kubectl
      kubernetes-helm
    ];

    # ── Firewall ──────────────────────────────────────────────────────────────
    networking.firewall.allowedTCPPorts = lib.mkIf config.networking.firewall.enable [ 6443 ];
  };
}
