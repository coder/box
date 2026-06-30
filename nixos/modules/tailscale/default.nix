# nixos/modules/tailscale — optional Tailscale integration
#
# Enable in the host's `hosts/<host>/local.nix`:
#   services.coder-nixos.tailscale = {
#     enable  = true;
#     authKey = "tskey-auth-…";  # reusable/ephemeral key from tailscale.com/admin
#   };
#
# If enable = false (default) no tailscale packages or services are installed.
#
# WARNING: do NOT add "--ssh" to extraUpFlags.
# Tailscale SSH takes over port 22 on the tailscale0 interface and requires
# a browser-based check-session auth that will lock you out of SSH until
# you visit a Tailscale URL. Use regular OpenSSH (coderbox user + key) instead.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.coder-nixos.tailscale;
in
{
  options.services.coder-nixos.tailscale = {
    enable = lib.mkEnableOption "Tailscale VPN";

    authKey = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Tailscale auth key (tskey-auth-…) as a string.
        Set this in the host's local.nix (gitignored).
        If set, tailscaled will authenticate automatically on first boot.
        Leave null to authenticate manually with `tailscale up`.
      '';
    };

    authKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to a file containing a Tailscale auth key.
        Prefer authKey (inline string in the host's local.nix) unless you have a
        specific reason to keep the key in a separate file.
      '';
    };

    extraUpFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Extra flags passed to `tailscale up`.
        Do NOT include --ssh here (see module header warning).
      '';
      example = [ "--advertise-exit-node" ];
    };
  };

  config = lib.mkIf cfg.enable {
    services.tailscale.enable = true;

    # Open the Tailscale UDP port in the firewall.
    networking.firewall = {
      allowedUDPPorts = [ 41641 ];
      trustedInterfaces = [ "tailscale0" ];
    };

    # Auto-authenticate if an auth key is provided (inline string or file).
    systemd.services.tailscale-autoauth = lib.mkIf (cfg.authKey != null || cfg.authKeyFile != null) {
      description = "Tailscale one-shot authentication";
      after = [
        "tailscaled.service"
        "network-online.target"
      ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      # RemainAfterExit = true means this won't re-run on nixos-rebuild
      # if already authenticated — so a bad extraUpFlags change is safe.
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "tailscale-autoauth" ''
          set -euo pipefail
          STATUS=$(${pkgs.tailscale}/bin/tailscale status --json 2>/dev/null || echo '{}')
          BACKEND=$(echo "$STATUS" | ${pkgs.jq}/bin/jq -r '.BackendState // "NoState"')
          if [ "$BACKEND" = "Running" ]; then
            echo "tailscale: already authenticated, skipping"
            exit 0
          fi
          ${
            if cfg.authKey != null then
              ''
                KEY=${lib.escapeShellArg cfg.authKey}
              ''
            else
              ''
                KEY=$(cat ${lib.escapeShellArg cfg.authKeyFile})
              ''
          }
          ${pkgs.tailscale}/bin/tailscale up \
            --authkey "$KEY" \
            --accept-routes \
            ${lib.escapeShellArgs cfg.extraUpFlags}
          echo "tailscale: authenticated successfully"
        '';
      };
    };
  };
}
