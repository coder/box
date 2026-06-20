# nixos/workshop-keycloak/keycloak.nix
#
# Optional module: Keycloak as Coder's OIDC identity provider for the workshop.
# Gives attendees ONE login that offers "Sign in with GitHub" (brokered, repo
# scope) OR a local throwaway account. A companion watcher (workshop-extauth-sync,
# see workshop-tunnel.nix / separate unit) copies the brokered GitHub token into
# Coder's external_auth_links so the agent can fork/push/PR.
#
# OFF by default. Enable + configure in hosts/<host>/local.nix:
#
#   services.workshop-keycloak = {
#     enable        = true;
#     publicUrl     = "https://dallas.cdr.dev";   # apex Coder+Keycloak are served on
#     httpRelativePath = "/auth";                  # Keycloak under <publicUrl>/auth
#     dbPassword    = "<keycloak db password>";    # for the local PG 'keycloak' role
#     adminPassword = "<kc admin password>";       # bootstrap admin
#   };
#
# Keycloak listens on 127.0.0.1:8089 (proxied via the apex by cloudflared/the
# middleware). It uses the EXISTING local Postgres (own 'keycloak' database).

{ config, lib, pkgs, ... }:

let
  cfg = config.services.workshop-keycloak;
in
{
  options.services.workshop-keycloak = {
    enable = lib.mkEnableOption "Keycloak OIDC IdP for the workshop";

    publicUrl = lib.mkOption {
      type = lib.types.str;
      example = "https://dallas.cdr.dev";
      description = "Public base URL Keycloak is reachable on (the apex).";
    };

    httpRelativePath = lib.mkOption {
      type = lib.types.str;
      default = "/auth";
      description = "URL path prefix Keycloak is served under (e.g. /auth).";
    };

    httpPort = lib.mkOption {
      type = lib.types.port;
      default = 8089;
      description = "Local port Keycloak's HTTP listener binds to (behind the proxy).";
    };

    dbName = lib.mkOption {
      type = lib.types.str;
      default = "keycloak";
      description = "Postgres database name for Keycloak (on the existing local PG).";
    };

    dbUser = lib.mkOption {
      type = lib.types.str;
      default = "keycloak";
      description = "Postgres role Keycloak connects as.";
    };

    dbPassword = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Password for the Keycloak Postgres role (set in local.nix, gitignored).";
    };

    adminUser = lib.mkOption {
      type = lib.types.str;
      default = "admin";
      description = "Bootstrap Keycloak admin username.";
    };

    adminPassword = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Bootstrap Keycloak admin password (set in local.nix, gitignored).";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.dbPassword != "";
        message = "services.workshop-keycloak.dbPassword must be set (in local.nix).";
      }
    ];

    # Keycloak's DB role + database on the existing local Postgres. The NixOS
    # postgresql.ensureUsers cannot set a password (peer-only), so we set it via
    # an activation snippet after PG is up.
    services.postgresql = {
      ensureDatabases = [ cfg.dbName ];
      ensureUsers = [{
        name = cfg.dbUser;
        ensureDBOwnership = true;
      }];
    };

    # Set the keycloak role's password from the (gitignored) option. Idempotent.
    systemd.services.workshop-keycloak-db-password = {
      description = "Set Keycloak Postgres role password";
      wantedBy = [ "multi-user.target" ];
      after = [ "postgresql.service" ];
      requires = [ "postgresql.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = "postgres";
        RemainAfterExit = true;
      };
      script = ''
        ${pkgs.postgresql}/bin/psql -v ON_ERROR_STOP=1 <<SQL
        ALTER ROLE ${cfg.dbUser} WITH LOGIN PASSWORD '${cfg.dbPassword}';
        SQL
      '';
    };

    # Write the Keycloak DB password to a /run file (NOT the world-readable nix
    # store) for services.keycloak.database.passwordFile to consume.
    systemd.services.workshop-keycloak-secrets = {
      description = "Materialize Keycloak DB password file";
      wantedBy = [ "multi-user.target" ];
      before = [ "keycloak.service" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        umask 077
        mkdir -p /run/workshop-keycloak
        printf '%s' '${cfg.dbPassword}' > /run/workshop-keycloak/db-password
        chmod 0400 /run/workshop-keycloak/db-password
      '';
    };

    services.keycloak = {
      enable = true;
      settings = {
        hostname = cfg.publicUrl;
        http-relative-path = cfg.httpRelativePath;
        http-host = "127.0.0.1";
        http-port = cfg.httpPort;
        http-enabled = true;
        # Behind cloudflared/middleware which terminates TLS and sets X-Forwarded-*.
        proxy-headers = "xforwarded";
        # The bootstrap admin is created on first start via env (below).
      };
      database = {
        type = "postgresql";
        host = "127.0.0.1";
        port = 5432;
        name = cfg.dbName;
        username = cfg.dbUser;
        # Use the EXISTING local Postgres; do not let the module provision PG.
        createLocally = false;
        passwordFile = "/run/workshop-keycloak/db-password";
      };
      # Bootstrap admin (first start only). Keycloak reads these env vars.
      # NOTE: KEYCLOAK_ADMIN(_PASSWORD) only seed on an empty realm.
    };

    # Provide the bootstrap admin creds to the keycloak service.
    systemd.services.keycloak.environment = {
      KEYCLOAK_ADMIN = cfg.adminUser;
      KEYCLOAK_ADMIN_PASSWORD = cfg.adminPassword;
    };

    # Order Keycloak after the role password is set + secret file is materialized.
    systemd.services.keycloak = {
      after = [ "workshop-keycloak-db-password.service" "workshop-keycloak-secrets.service" ];
      requires = [ "workshop-keycloak-db-password.service" "workshop-keycloak-secrets.service" ];
    };

    # ── external-auth sync watcher ──────────────────────────────────────────────
    # Copies each user's brokered GitHub token (Keycloak, repo scope) into Coder's
    # external_auth_links so the agent can fork/push/PR. Runs on a timer.
    systemd.services.workshop-extauth-sync = {
      description = "Sync Keycloak-brokered GitHub tokens into Coder external_auth_links";
      after = [ "keycloak.service" "coder.service" "postgresql.service" ];
      requires = [ "postgresql.service" ];
      environment = {
        CODER_PSQL_DSN = "dbname=coder host=/run/postgresql user=postgres";
        KC_PSQL_DSN = "dbname=${cfg.dbName} host=/run/postgresql user=postgres";
        KC_REALM = "workshop";
        KC_GITHUB_ALIAS = "github";
        PSQL_BIN = "${pkgs.postgresql}/bin/psql";
        EXTAUTH_PROVIDER_ID = "github";
        TOKEN_SOURCE = "kcdb";
      };
      serviceConfig = {
        Type = "oneshot";
        User = "postgres";  # peer auth to BOTH coder + keycloak DBs
        Group = "postgres";
        ExecStart = "${pkgs.python3}/bin/python3 ${./extauth-sync.py}";
      };
    };
    systemd.timers.workshop-extauth-sync = {
      description = "Periodic Keycloak->Coder external-auth sync";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "60s";
        OnUnitActiveSec = "30s";
        Unit = "workshop-extauth-sync.service";
      };
    };
  };
}
