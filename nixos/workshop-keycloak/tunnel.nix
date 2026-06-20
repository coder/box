# nixos/workshop-keycloak/tunnel.nix
#
# Optional module: stable public domain via Cloudflare Tunnel + a single-click
# GitHub auth middleware in front of Coder.
#
# OFF by default. Enable + configure in hosts/<host>/local.nix, e.g.:
#
#   services.workshop-tunnel = {
#     enable        = true;
#     publicUrl     = "https://dallas.cdr.dev";
#     wildcardUrl   = "*.dallas.cdr.dev";
#     cloudflared.tunnelToken = "<CF tunnel token>";   # from the CF dashboard
#     middleware = {
#       githubClientId     = "<oauth app client id>";
#       githubClientSecret = "<oauth app client secret>";
#     };
#   };
#
# The middleware listens on 127.0.0.1:8088 and reverse-proxies to Coder
# (127.0.0.1:3000), intercepting only the GitHub auth flow. cloudflared routes:
#   apex      (publicUrl host)   -> middleware :8088
#   wildcard  (*.publicUrl host) -> Coder       :3000
#
# Coder's CODER_ACCESS_URL / CODER_WILDCARD_ACCESS_URL must be set to match
# (done in local.nix coder env or via the helper option below).

{ config, lib, pkgs, ... }:

let
  cfg = config.services.workshop-tunnel;

  middlewarePy = pkgs.writeText "workshop-middleware.py" (builtins.readFile ./middleware.py);

  # Ingress config for cloudflared. Apex -> middleware, wildcard -> Coder direct.
  cfTunnelConfig = pkgs.writeText "cloudflared-config.yml" ''
    ingress:
      - hostname: ${cfg.apexHost}
        service: http://127.0.0.1:${toString cfg.middleware.port}
      - hostname: "*.${cfg.apexHost}"
        service: http://127.0.0.1:3000
      - service: http_status:404
  '';
in
{
  options.services.workshop-tunnel = {
    enable = lib.mkEnableOption "Cloudflare Tunnel + single-click GitHub auth middleware";

    publicUrl = lib.mkOption {
      type = lib.types.str;
      example = "https://dallas.cdr.dev";
      description = "Public apex URL (scheme + host) that Coder is served on.";
    };

    apexHost = lib.mkOption {
      type = lib.types.str;
      default = lib.removePrefix "https://" (lib.removePrefix "http://" cfg.publicUrl);
      description = "Bare apex host derived from publicUrl (e.g. dallas.cdr.dev).";
    };

    wildcardUrl = lib.mkOption {
      type = lib.types.str;
      default = "*.${cfg.apexHost}";
      description = "Wildcard access URL for Coder workspace apps.";
    };

    cloudflared = {
      tunnelToken = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Cloudflare named-tunnel token (from the CF dashboard). If empty, cloudflared is not started.";
      };
    };

    middleware = {
      port = lib.mkOption {
        type = lib.types.port;
        default = 8088;
        description = "Local port the middleware listens on.";
      };
      githubClientId = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "GitHub OAuth App client id (callback = publicUrl/wm/cb).";
      };
      githubClientSecret = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "GitHub OAuth App client secret.";
      };
      scopes = lib.mkOption {
        type = lib.types.str;
        default = "repo read:user user:email";
        description = "Space-separated OAuth scopes the middleware requests.";
      };
      disableIntercept = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "If true, the middleware is a pure transparent proxy (Step 2 testing).";
      };
      debug = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Verbose middleware logging.";
      };
    };
  };

  config = lib.mkIf cfg.enable {

    # ── single-click GitHub auth middleware ─────────────────────────────────────
    systemd.services.workshop-middleware = {
      description = "Workshop single-click GitHub auth middleware (front of Coder)";
      wantedBy = [ "multi-user.target" ];
      after = [ "coder.service" "postgresql.service" ];
      requires = [ "postgresql.service" ];

      environment = {
        MW_LISTEN_ADDR = "127.0.0.1:${toString cfg.middleware.port}";
        MW_PUBLIC_URL = cfg.publicUrl;
        CODER_UPSTREAM = "http://127.0.0.1:3000";
        GH_CLIENT_ID = cfg.middleware.githubClientId;
        GH_CLIENT_SECRET = cfg.middleware.githubClientSecret;
        GH_SCOPES = cfg.middleware.scopes;
        EXTAUTH_PROVIDER_ID = "github";
        PSQL_BIN = "${pkgs.postgresql}/bin/psql";
        # Connect to the local Coder DB. Peer auth as the postgres superuser via
        # the unix socket (the service runs as postgres for DB write access).
        PSQL_DSN = "dbname=coder host=/run/postgresql user=postgres";
        MW_DISABLE_INTERCEPT = if cfg.middleware.disableIntercept then "1" else "0";
        MW_DEBUG = if cfg.middleware.debug then "1" else "0";
      };

      serviceConfig = {
        Type = "simple";
        # Run as postgres so peer auth grants DB write access to external_auth_links.
        User = "postgres";
        Group = "postgres";
        Restart = "on-failure";
        RestartSec = "5s";
        ExecStart = "${pkgs.python3}/bin/python3 ${middlewarePy}";
      };
    };

    # ── Cloudflare Tunnel ───────────────────────────────────────────────────────
    # Outbound-only; works on any network (NAT/captive-portal friendly). Only
    # started when a tunnelToken is provided.
    systemd.services.cloudflared-workshop = lib.mkIf (cfg.cloudflared.tunnelToken != "") {
      description = "Cloudflare Tunnel for the Coder workshop";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" "coder.service" "workshop-middleware.service" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        RestartSec = "10s";
        # Token-based tunnels carry their ingress config from the CF dashboard;
        # we ALSO ship a local config for ingress in case the tunnel is run
        # config-file style. Token mode ignores the local file but it documents
        # intent and supports `cloudflared tunnel run` fallback.
        ExecStart = "${pkgs.cloudflared}/bin/cloudflared --no-autoupdate tunnel run --token ${cfg.cloudflared.tunnelToken}";
        DynamicUser = true;
      };
    };

    # Expose the resolved config file path for debugging / config-file fallback.
    environment.etc."workshop-tunnel/cloudflared-config.yml".source = cfTunnelConfig;
  };
}
