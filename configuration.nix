# NixOS configuration. Shared by all coder-nixos hosts.
# Per-host modules (hardware-configuration.nix or facter.json, optional disko,
# local.nix) live under ./hosts/<host>/; everything else lives here.
#
# Apply: sudo nixos-rebuild switch (packages/services only)
#        sudo nixos-rebuild boot + sudo reboot (anything touching desktop/display stack)
#
# First-time setup and the live-USB install walkthrough are in ./README.md.
# This file expects a flake (./flake.nix) to assemble the configuration via
# nixosConfigurations.<hostname>, so `nixos-rebuild switch` should resolve
# through /etc/nixos/flake.nix (symlinked to /etc/nixos-repo/flake.nix).
#
# Per-host local.nix lives at hosts/<host>/local.nix and is gitignored.

{ config, pkgs, lib, ... }:

let
  coder          = pkgs.callPackage ./pkgs/coder.nix {
    channel = "mainline";
  };
  coderdProvider = pkgs.callPackage ./pkgs/coderd-provider.nix {};

  # UID 991 is pinned so the DOCKER_HOST socket path is deterministic.
  # NixOS won't change an existing user's UID live, so this must stay 991.
  coderUid = 991;

  # .terraformrc pointing terraform at the locally-packaged coderd provider.
  # No network access needed during `terraform init`.
  terraformrc = pkgs.writeText "terraformrc-coderd" ''
    provider_installation {
      filesystem_mirror {
        path    = "${coderdProvider}"
        include = ["registry.terraform.io/coder/coderd"]
      }
      direct {
        exclude = ["registry.terraform.io/coder/coderd"]
      }
    }
  '';
in
{
  # Per-host modules (hardware detection via facter, disk layout via disko,
  # the host's local.nix, and any host-specific overrides) live in
  # ./hosts/<host>/ and are auto-discovered by flake.nix from the directory
  # listing. This shared config covers what every box has in common.
  imports = [
    ./nixos/k3s-sysbox.nix     # single-node k3s + sysbox-runc (isolated Docker per workspace)
    ./nixos/tailscale.nix      # optional Tailscale (enable in hosts/<host>/local.nix)
    ./nixos/screenconnect.nix  # optional ScreenConnect client (enable in hosts/<host>/local.nix)
  ];

  # ── NixOS option: SSH key sync ─────────────────────────────────────────────
  # Set in hosts/<host>/local.nix: services.coder-sync-ssh-keys.githubUsers = [ "user1" ];
  options.services.coder-nixos.lanIp = lib.mkOption {
    type        = lib.types.str;
    default     = "";
    description = "LAN IP of this box, used for CODER_AGENT_URL and k8s hostAliases so pods resolve the hostname without relying on mDNS. Set in the host's local.nix. Leave empty to fall back to hostname-based mDNS URL.";
  };

  options.services.coder-sync-ssh-keys.githubUsers = lib.mkOption {
    type        = lib.types.listOf lib.types.str;
    default     = [];
    description = "GitHub usernames whose SSH keys are fetched and written to /etc/ssh/authorized_keys.d/ on each boot.";
  };

  config = {

    # ── Platform ──────────────────────────────────────────────────────────────
    # Fallback architecture. Since flake.nix no longer hardcodes `system` in
    # lib.nixosSystem, something must set nixpkgs.hostPlatform. The facter
    # module (nixos/modules/hardware/facter/system.nix) and any host's
    # hardware-configuration.nix set it from detected hardware at mkDefault
    # priority. This must therefore sit at a WEAKER priority than mkDefault
    # (mkOptionDefault = 1500 vs mkDefault = 1000) so those hardware-derived
    # values win — otherwise two differing mkDefaults (e.g. this x86_64 vs an
    # aarch64 facter report) collide with a "conflicting definition values"
    # error. It only applies when nothing else sets the platform.
    # arm64 boxes without facter can set `nixpkgs.hostPlatform = "aarch64-linux";`
    # in hosts/<host>/default.nix (or local.nix).
    nixpkgs.hostPlatform = lib.mkOptionDefault "x86_64-linux";

    # ── Terraform: prebuilt binary, not from source ───────────────────────────
    # Terraform is BSL-licensed, so cache.nixos.org does not distribute it and
    # `pkgs.terraform` would compile the multi-GB Go project from source during
    # `nixos-install`. On the small live-USB build environment that exhausts the
    # build tmpdir ("no space left on device" while compiling terraform). Swap in
    # the official statically-linked release binary (same 1.14.0 version) via an
    # overlay so every pkgs.terraform consumer (coder's PATH wrapper,
    # systemPackages, the template-deploy scripts) picks it up. Works on arm64 too.
    nixpkgs.overlays = [
      (final: prev: {
        terraform = final.callPackage ./pkgs/terraform-binary.nix {};
      })
    ];

    # ── Boot ──────────────────────────────────────────────────────────────────
    # Defaults assume a modern UEFI machine; host modules under ./hosts/<host>/
    # can override these (e.g. set systemd-boot.enable = false and configure
    # boot.loader.grub on BIOS hardware).
    boot.loader.systemd-boot.enable = lib.mkDefault true;
    boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;

    # ── Swap ──────────────────────────────────────────────────────────────────
    # No on-disk swap partition (see nixos/disko-standard.nix). Use a
    # compressed in-RAM swap device instead, sized to half of RAM.
    zramSwap.enable = lib.mkDefault true;

    # ── Never suspend or hibernate ──────────────────────────────────────
    # The box is an always-on appliance (Coder server + k3s) reached over the
    # LAN and a *.try.coder.app tunnel. Suspending or hibernating drops the
    # NIC, so the machine silently falls off the network (no mDNS, no SSH,
    # tunnel dies) until someone physically wakes it. The shipped image runs a
    # KDE desktop, which exposes Sleep/Hibernate actions, and a stray
    # `systemctl suspend` / `systemctl hibernate` (or the matching D-Bus call)
    # would do the same. Mask the suspend, hibernate, and hybrid-sleep targets
    # so all of those paths become a no-op.
    #
    # Scope is deliberately narrow: only the "drop off the network" sleep
    # states are blocked. Idle/lid/power-key handling is left at NixOS
    # defaults — the single concern is the box not putting itself to sleep.
    systemd.targets.suspend.enable      = false;
    systemd.targets.hibernate.enable    = false;
    systemd.targets.hybrid-sleep.enable = false;
    services.logind.settings.Login = {
      HandleSuspendKey   = "ignore";
      HandleHibernateKey = "ignore";
    };

    # ── Networking ────────────────────────────────────────────────────────────
    # Central default hostname. Install hosts override this: flake.nix's mkHost
    # injects `networking.hostName = lib.mkDefault <folder-name>` for every
    # non-underscore host (so coder-thinkcentre stays coder-thinkcentre, etc.).
    # Underscore-prefixed image/appliance hosts (_appliance_iso, _appliance-disk)
    # get no injection and so inherit "coder-box".
    #
    # Priority 1250 (mkOverride) is deliberately BETWEEN mkDefault (1000) and
    # mkOptionDefault (1500): it beats the option's own built-in default
    # ("nixos", which nixpkgs sets at mkOptionDefault and would otherwise tie
    # and error), while still losing to flake.nix's mkDefault folder-name
    # injection on install hosts. A host's local.nix/default.nix can override at
    # normal (100) priority or mkForce.
    networking.hostName = lib.mkOverride 1250 "coder-box";
    networking.networkmanager.enable = true;

    # mDNS: every box reachable as <hostname>.local on the LAN
    services.avahi = {
      enable   = true;
      nssmdns4 = true;
      publish  = { enable = true; addresses = true; workstation = true; };
    };

    # ── Locale / time ─────────────────────────────────────────────────────────
    time.timeZone = "America/Chicago";
    i18n.defaultLocale = "en_US.UTF-8";
    i18n.extraLocaleSettings = {
      LC_ADDRESS        = "en_US.UTF-8";
      LC_IDENTIFICATION = "en_US.UTF-8";
      LC_MEASUREMENT    = "en_US.UTF-8";
      LC_MONETARY       = "en_US.UTF-8";
      LC_NAME           = "en_US.UTF-8";
      LC_NUMERIC        = "en_US.UTF-8";
      LC_PAPER          = "en_US.UTF-8";
      LC_TELEPHONE      = "en_US.UTF-8";
      LC_TIME           = "en_US.UTF-8";
    };

    # ── Desktop: KDE Plasma 6 ─────────────────────────────────────────────────
    services.xserver.enable = true;
    services.displayManager.sddm.enable = true;
    services.displayManager.sddm.wayland.enable = false;
    services.displayManager.defaultSession = "plasmax11";
    services.desktopManager.plasma6.enable = true;
    services.xserver.xkb = { layout = "us"; variant = ""; };

    # ── Audio ─────────────────────────────────────────────────────────────────
    services.pulseaudio.enable = false;
    security.rtkit.enable = true;
    services.pipewire = {
      enable            = true;
      alsa.enable       = true;
      alsa.support32Bit = true;
      pulse.enable      = true;
    };

    services.printing.enable = true;

    # ── Users ─────────────────────────────────────────────────────────────────
    # Desktop / SSH login user is declared per-host in local.nix (template
    # in local.nix.example); username and password are install-time flags.
    # The `coder` system user (uid 991) is shared and declared further down.

    security.sudo.wheelNeedsPassword = false;

    # ── SSH ───────────────────────────────────────────────────────────────────
    services.openssh = {
      enable = true;
      settings.PasswordAuthentication = true;
      # Allow per-user files written by coder-sync-ssh-keys
      extraConfig = ''
        AuthorizedKeysFile .ssh/authorized_keys .ssh/authorized_keys2 /etc/ssh/authorized_keys.d/%u
      '';
    };

    # ── SSH key sync from GitHub usernames ────────────────────────────────────
    # Fetches https://github.com/<user>.keys for each username in
    # services.coder-sync-ssh-keys.githubUsers (set in hosts/<host>/local.nix).
    # Writes keys to /etc/ssh/authorized_keys.d/<user>. Runs at boot.
    systemd.services.coder-sync-ssh-keys = {
      description = "Sync SSH authorized keys from GitHub user profiles";
      wantedBy    = [ "multi-user.target" ];
      after       = [ "network-online.target" ];
      wants       = [ "network-online.target" ];

      serviceConfig = {
        Type            = "oneshot";
        RemainAfterExit = true;
        ExecStart       = pkgs.writeShellScript "coder-sync-ssh-keys" ''
          set -euo pipefail
          KEYS_DIR="/etc/ssh/authorized_keys.d"

          # User list is baked in at eval time from local.nix
          USERS_CSV="${lib.concatStringsSep "," config.services.coder-sync-ssh-keys.githubUsers}"

          if [ -z "$USERS_CSV" ]; then
            echo "No GitHub users configured, skipping SSH key sync."
            exit 0
          fi

          mkdir -p "$KEYS_DIR"
          IFS=',' read -ra USERS <<< "$USERS_CSV"

          for user in "''${USERS[@]}"; do
            user="$(echo "$user" | tr -d '[:space:]')"
            [ -z "$user" ] && continue
            echo "Fetching SSH keys for GitHub user: $user"
            keys="$(${pkgs.curl}/bin/curl -sf "https://github.com/$user.keys" || true)"
            if [ -z "$keys" ]; then
              echo "  Warning: no keys found or fetch failed for $user"
              continue
            fi
            echo "$keys" > "$KEYS_DIR/$user"
            chmod 0644 "$KEYS_DIR/$user"
            echo "  Written $(echo "$keys" | wc -l) key(s) to $KEYS_DIR/$user"
          done
        '';
      };
    };

    # ── Packages ──────────────────────────────────────────────────────────────
    programs.firefox.enable = true;
    nixpkgs.config.allowUnfree = true;

    environment.systemPackages = with pkgs; [
      git vim curl wget htop jq pciutils usbutils coder terraform vlc
    ];

    nix.settings.experimental-features = [ "nix-command" "flakes" ];
    nix.settings.download-buffer-size = 268435456;  # 256 MiB; quiets the "buffer full" warning on big closure pulls
    networking.firewall.enable = false;

    # ── PostgreSQL ────────────────────────────────────────────────────────────
    services.postgresql = {
      enable  = true;
      package = pkgs.postgresql;
      ensureDatabases = [ "coder" ];
      ensureUsers = [{ name = "coder"; ensureDBOwnership = true; }];
      authentication = pkgs.lib.mkOverride 10 ''
        local all postgres              peer
        local all all                   peer
        host  all all  127.0.0.1/32    scram-sha-256
        host  all all  ::1/128         scram-sha-256
      '';
    };

    # ── Rootless Podman ───────────────────────────────────────────────────────
    # Used by Coder workspace templates via the Docker-compatible socket API.
    # dockerCompat installs a `docker` shim that redirects to podman so
    # workspace tooling that hard-codes `docker` (the coder-cli template, host
    # debugging, ad hoc commands) still works without a real Docker daemon.
    virtualisation.podman = {
      enable        = true;
      dockerCompat  = true;
      extraPackages = [ pkgs.crun ]; # workaround nixpkgs#226849
    };
    boot.kernel.sysctl."user.max_user_namespaces" = 65536;

    # k3s-sysbox is the workspace runtime for every shipped template (k3s-*
    # pods and the docker-CLI sandbox). Enable by default so a fresh install
    # actually has k3s running; hosts can opt out from their local.nix.
    services.coder-nixos.k3s-sysbox.enable = lib.mkDefault true;

    # ── Coder user ────────────────────────────────────────────────────────────
    # UID 991 is below 1000 so isSystemUser is required (isNormalUser rejects it).
    # linger = true ensures the user session (and Podman socket) starts at boot.
    users.users.coder = {
      isSystemUser = true;
      uid          = coderUid;
      group        = "coder";
      home         = "/var/lib/coder";
      createHome   = true;
      homeMode     = "700";
      shell        = pkgs.bash;  # needed for systemd user session
      linger       = true;
      subUidRanges = [{ startUid = 100000; count = 65536; }];
      subGidRanges = [{ startGid = 100000; count = 65536; }];
    };
    users.groups.coder = {};
    # podman.socket uses SocketGroup=podman; the NixOS podman module does not
    # create this group automatically so we declare it explicitly.
    users.groups.podman = {};

    # /etc/coder dir + empty session-token file (populated on first boot by
    # coder-init-admin.service, which runs as the coder user and needs to
    # own the file to write it). The trailing `z` line re-applies the
    # ownership on existing installs where the file was created under a
    # previous rule that owned it root:root.
    systemd.tmpfiles.rules = [
      "d /etc/coder 0750 root coder -"
      "f /etc/coder/session-token 0600 coder coder -"
      "z /etc/coder/session-token 0600 coder coder -"
    ];

    # ── Coder server ──────────────────────────────────────────────────────────
    # Base env vars live here. Secrets (admin creds, OAuth, etc.) are merged in
    # via systemd.services.coder.environment in hosts/<host>/local.nix; no EnvironmentFile.
    systemd.services.coder = {
      description = "Coder Server";
      wantedBy    = [ "multi-user.target" ];
      after       = [ "network.target" "postgresql.service" "user@${toString coderUid}.service" ];
      requires    = [ "postgresql.service" ];
      wants       = [ "user@${toString coderUid}.service" ]; # non-fatal if user session is delayed

      environment = {
        CODER_HTTP_ADDRESS             = "0.0.0.0:3000";
        CODER_MAX_TOKEN_LIFETIME       = "8760h"; # allow year-long tokens (e.g. nixos-sync)
        CODER_MAX_ADMIN_TOKEN_LIFETIME = "8760h";
        # CODER_ACCESS_URL not set → Coder auto-creates a *.try.coder.app tunnel URL
        # Wildcard access URL is set automatically by the tunnel (not needed here)

        # Agents (k3s pods) reach the server directly over LAN for low latency.
        # This is independent of the public tunnel URL used by browsers.
        CODER_AGENT_URL = let lanIp = config.services.coder-nixos.lanIp; in
          if lanIp != "" then "http://${lanIp}:3000"
          else "http://${config.networking.hostName}.local:3000";
        CODER_PG_CONNECTION_URL        = "postgres:///coder?host=/run/postgresql&user=coder&sslmode=disable";
        CODER_DATA_DIR                 = "/var/lib/coder";
        # Point the Terraform Docker provider at the rootless Podman socket.
        DOCKER_HOST                    = "unix:///run/user/${toString coderUid}/podman/podman.sock";
        # Enable all experiments: Coder AI agents, MCP, etc.
        CODER_EXPERIMENTS              = "*";
      };

      serviceConfig = {
        ExecStart    = "${coder}/bin/coder server";
        User         = "coder";
        Group        = "coder";
        Restart      = "on-failure";
        RestartSec   = "5s";
        ExecStartPre = "+${pkgs.coreutils}/bin/chown -R coder:coder /var/lib/coder";
      };
    };

    # ── Admin user bootstrap ──────────────────────────────────────────────────
    # Reads CODER_ADMIN_* from coder.service environment (set via local.nix).
    # Creates a local admin account once; sentinel prevents re-running.
    # If CODER_ADMIN_EMAIL is unset, skips and directs user to the browser wizard.
    systemd.services.coder-init-admin = {
      description = "Coder bootstrap: create admin, mint session token, deploy templates";
      wantedBy    = [ "multi-user.target" ];
      after       = [ "coder.service" ];
      requires    = [ "coder.service" ];

      # Inherit the full coder.service environment so CODER_ADMIN_* and
      # CODER_PG_CONNECTION_URL are available without duplication.
      environment = config.systemd.services.coder.environment;

      serviceConfig = {
        Type            = "oneshot";
        RemainAfterExit = true;
        # Runs as the coder user so peer auth against the local PG socket
        # matches the 'coder' role in CODER_PG_CONNECTION_URL. The token
        # file is owned by coder:coder (see tmpfiles.rules above), so this
        # service can still write it.
        User            = "coder";
        ExecStart       = pkgs.writeShellScript "coder-init-admin" ''
          set -euo pipefail

          admin_sentinel=/var/lib/coder/.admin-created
          templates_sentinel=/var/lib/coder/.templates-deployed
          token_file=/etc/coder/session-token

          if [ -z "''${CODER_ADMIN_EMAIL:-}" ]; then
            echo "CODER_ADMIN_EMAIL not set, skipping bootstrap."
            echo "Complete the first-run wizard at http://$(hostname -s).local:3000"
            exit 0
          fi

          # systemd's `after = [ "coder.service" ]` only orders start, it doesn't
          # wait for coder.service to be READY. coder server runs PG migrations
          # before it opens its HTTP listener, so a 200 from /api/v2/buildinfo
          # means the DB schema and coder role exist.
          echo "Waiting for coder API..."
          for i in $(seq 1 60); do
            if ${pkgs.curl}/bin/curl -sf http://localhost:3000/api/v2/buildinfo > /dev/null 2>&1; then
              echo "coder API ready after $((i * 2))s."
              break
            fi
            if [ "$i" = 60 ]; then
              echo "coder API still not responding after 120s; aborting." >&2
              exit 1
            fi
            sleep 2
          done

          # 1. Create the admin user.
          if [ -f "$admin_sentinel" ]; then
            echo "Admin user already created."
          else
            echo "Creating admin user $CODER_ADMIN_EMAIL..."
            ${coder}/bin/coder server create-admin-user \
              --postgres-url "$CODER_PG_CONNECTION_URL" \
              --username     "$CODER_ADMIN_USERNAME" \
              --email        "$CODER_ADMIN_EMAIL" \
              --password     "$CODER_ADMIN_PASSWORD"
            touch "$admin_sentinel"
          fi

          # 2. Mint a long-lived session token for coder-template-sync.
          mkdir -p /etc/coder
          if [ -s "$token_file" ]; then
            echo "Session token already exists."
          else
            echo "Logging in as admin to mint a long-lived token..."
            SESSION=$(${pkgs.curl}/bin/curl -sf -X POST http://localhost:3000/api/v2/users/login \
              -H 'Content-Type: application/json' \
              -d "{\"email\":\"$CODER_ADMIN_EMAIL\",\"password\":\"$CODER_ADMIN_PASSWORD\"}" \
              | ${pkgs.jq}/bin/jq -r '.session_token')
            [ -n "$SESSION" ] && [ "$SESSION" != "null" ] \
              || { echo "Admin login failed." >&2; exit 1; }
            LONG_TOKEN=$(CODER_URL=http://localhost:3000 CODER_SESSION_TOKEN="$SESSION" \
              ${coder}/bin/coder tokens create --name nixos-sync --lifetime 8760h)
            [ -n "$LONG_TOKEN" ] \
              || { echo "Token mint failed." >&2; exit 1; }
            echo "$LONG_TOKEN" > "$token_file"
            chmod 600 "$token_file"
            echo "Wrote session token to $token_file."
          fi

          # 3. Deploy templates via terraform. coder-template-sync (activation
          #    script) handles subsequent updates on every nixos-rebuild switch;
          #    this branch covers the first boot before any rebuild has run.
          if [ -f "$templates_sentinel" ]; then
            echo "Templates already deployed by this service."
          else
            echo "Deploying Coder templates..."
            CODERD_SRC="/etc/nixos-repo/coderd"
            STATE_DIR="/var/lib/coder/template-sync"
            CODERD_DIR="$STATE_DIR/coderd-workdir"
            mkdir -p "$STATE_DIR"
            # /etc/nixos-repo is root-owned; this service runs as 'coder' so
            # it can't write the .terraform.lock.hcl that terraform init
            # creates in the working directory. Copy coderd/ into a workdir
            # we own and run terraform there.
            #
            # On the appliance images /etc/nixos-repo is a read-only Nix store
            # path (dirs 0555, files 0444), so `cp -r` reproduces those
            # read-only perms and `terraform init` then fails writing
            # .terraform.lock.hcl into the workdir (Permission denied) — which,
            # under `set -o pipefail`, aborts this service *after* the admin
            # user + token were already created, so templates silently never
            # deploy. chmod -R u+w makes the copy writable. (On normal installs
            # the source is already writable, so this is a harmless no-op.)
            rm -rf "$CODERD_DIR"
            cp -r "$CODERD_SRC" "$CODERD_DIR"
            chmod -R u+w "$CODERD_DIR"
            COMMIT=$(GIT_DIR=/etc/nixos-repo/.git ${pkgs.git}/bin/git -c safe.directory=/etc/nixos-repo -C /etc/nixos-repo rev-parse --short HEAD 2>/dev/null || echo "unknown")
            export TF_CLI_CONFIG_FILE="${terraformrc}"
            export TF_DATA_DIR="$STATE_DIR/.terraform"
            ${pkgs.terraform}/bin/terraform -chdir="$CODERD_DIR" init -no-color 2>&1 \
              | ${pkgs.gnused}/bin/sed 's/^/[template-deploy] /'
            ${pkgs.terraform}/bin/terraform -chdir="$CODERD_DIR" apply -auto-approve -no-color \
              -var="coder_url=http://localhost:3000" \
              -var="coder_session_token=$(cat "$token_file")" \
              -var="hostname=${config.networking.hostName}" \
              -var="version_name=$COMMIT" \
              -var="coder_lan_ip=${config.services.coder-nixos.lanIp}" 2>&1 \
              | ${pkgs.gnused}/bin/sed 's/^/[template-deploy] /'
            touch "$templates_sentinel"
            echo "Templates deployed."
          fi

          echo "Bootstrap complete."
        '';
      };
    };


    # ── Coder reset (on-demand) ───────────────────────────────────────────────
    # Tears down all workspace pods/PVCs, wipes the Coder DB and data dir,
    # re-bootstraps the admin user, mints a fresh session token, and runs
    # nixos-rebuild switch to push templates back to Coder — fully automated.
    #
    # Usage:  sudo systemctl start coder-reset
    systemd.services.coder-reset = {
      description = "Coder – full wipe and re-bootstrap (run manually)";
      # NOT in wantedBy — must be triggered explicitly with `systemctl start coder-reset`
      after       = [ "coder.service" "k3s.service" "postgresql.service" ];
      requires    = [ "postgresql.service" ];

      environment = config.systemd.services.coder.environment;

      serviceConfig = {
        Type = "oneshot";
        # Run as root (needs kubectl, psql, rm -rf /var/lib/coder)
        ExecStart = pkgs.writeShellScript "coder-reset" ''
          set -euo pipefail
          echo "=== coder-reset: starting full wipe ==="

          # 1. Stop Coder + redirect so nothing re-creates state mid-wipe
          echo "--- stopping coder, coder-init-admin, coder-redirect"
          ${pkgs.systemd}/bin/systemctl stop coder.service coder-init-admin.service coder-redirect.service || true

          # 2. Delete all workspace pods and PVCs from k3s
          echo "--- wiping k3s workspace pods and PVCs"
          ${pkgs.k3s}/bin/k3s kubectl delete pods --all -n coder-workspaces \
            --force --grace-period=0 2>/dev/null || true
          ${pkgs.k3s}/bin/k3s kubectl delete pvc  --all -n coder-workspaces \
            2>/dev/null || true

          # 3. Drop and recreate the Coder PostgreSQL database
          echo "--- resetting PostgreSQL database"
          ${pkgs.sudo}/bin/sudo -u postgres ${pkgs.postgresql}/bin/psql \
            -c 'DROP DATABASE IF EXISTS coder;'
          ${pkgs.sudo}/bin/sudo -u postgres ${pkgs.postgresql}/bin/psql \
            -c 'CREATE DATABASE coder OWNER coder;'

          # 4. Wipe Coder data dir (clears sentinel, tokens, provisioner state, Podman volumes)
          echo "--- wiping /var/lib/coder"
          ${pkgs.coreutils}/bin/rm -rf /var/lib/coder/*
          ${pkgs.coreutils}/bin/chown -R coder:coder /var/lib/coder

          # 5. Clear the session token so coder-redirect doesn't use a stale one
          echo "" | ${pkgs.coreutils}/bin/tee /etc/coder/session-token > /dev/null

          # 6. Restart Coder and wait for the API to become ready
          echo "--- starting coder.service"
          ${pkgs.systemd}/bin/systemctl start coder.service
          echo "--- waiting for Coder API..."
          until ${pkgs.curl}/bin/curl -sf http://localhost:3000/api/v2/buildinfo > /dev/null 2>&1; do
            sleep 3
          done

          # 7. Re-run admin bootstrap (sentinel was cleared in step 4)
          echo "--- bootstrapping admin user"
          ${pkgs.systemd}/bin/systemctl start coder-init-admin.service

          # 8. Mint a fresh long-lived session token using the admin creds from local.nix
          echo "--- minting session token"
          SESSION=$(${pkgs.curl}/bin/curl -sf             -X POST http://localhost:3000/api/v2/users/login             -H 'Content-Type: application/json'             -d "{"email":"''${CODER_ADMIN_EMAIL}","password":"''${CODER_ADMIN_PASSWORD}"}"             | ${pkgs.jq}/bin/jq -r '.session_token')
          LONG_TOKEN=$(CODER_URL=http://localhost:3000 CODER_SESSION_TOKEN="$SESSION"             ${coder}/bin/coder tokens create --name nixos-sync --lifetime 8760h)
          echo "$LONG_TOKEN" | ${pkgs.coreutils}/bin/tee /etc/coder/session-token > /dev/null
          echo "--- session token written"

          # 9. Restart coder-redirect so it picks up the new token
          echo "--- restarting coder-redirect"
          ${pkgs.systemd}/bin/systemctl restart coder-redirect.service

          # 10. Re-run nixos-rebuild switch to push templates via coder-template-sync
          echo "--- running nixos-rebuild switch (template sync)"
          /run/current-system/sw/bin/nixos-rebuild switch \
            --flake /etc/nixos-repo 2>&1 \
            | ${pkgs.gnused}/bin/sed 's/^/[coder-reset] /'

          echo ""
          echo "=== coder-reset: complete — Coder is clean with templates restored ==="
        '';
      };
    };

    # ── Template sync activation script ──────────────────────────────────────
    # Runs on every `nixos-rebuild switch`. Uses terraform-provider-coderd to
    # apply templates from /etc/nixos-repo/coderd/.
    # /etc/coder/session-token is populated automatically by
    # coder-init-admin.service on first boot, so the skip branch below only
    # triggers between nixos-install and first boot completing, or after
    # coder-reset has cleared state.
    system.activationScripts.coder-template-sync = {
      text = ''
        TOKEN_FILE="/etc/coder/session-token"
        CODERD_DIR="/etc/nixos-repo/coderd"
        STATE_DIR="/var/lib/coder/template-sync"

        if [ ! -s "$TOKEN_FILE" ]; then
          echo "[coder-template-sync] /etc/coder/session-token is empty; skipping."
          echo "  This file is auto-populated by coder-init-admin.service on first boot."
        else
          mkdir -p "$STATE_DIR"

          COMMIT=$(GIT_DIR=/etc/nixos-repo/.git ${pkgs.git}/bin/git -c safe.directory=/etc/nixos-repo -C /etc/nixos-repo rev-parse --short HEAD 2>/dev/null || echo "unknown")

          export TF_CLI_CONFIG_FILE="${terraformrc}"
          export TF_DATA_DIR="$STATE_DIR/.terraform"

          ${pkgs.terraform}/bin/terraform -chdir="$CODERD_DIR" init -no-color 2>&1 \
            | ${pkgs.gnused}/bin/sed 's/^/[template-sync] /' || true
          ${pkgs.terraform}/bin/terraform -chdir="$CODERD_DIR" apply -auto-approve -no-color \
            -var="coder_url=http://localhost:3000" \
            -var="coder_session_token=$(cat "$TOKEN_FILE")" \
            -var="hostname=${config.networking.hostName}" \
            -var="version_name=$COMMIT" \
            -var="coder_lan_ip=${config.services.coder-nixos.lanIp}" 2>&1 \
            | ${pkgs.gnused}/bin/sed 's/^/[template-sync] /'
        fi
      '';
      deps = [];
    };


    # The nook-android image build service is host-specific and lives in
    # ./hosts/coder-thinkcentre/default.nix.


    # ── Coder tunnel redirect ─────────────────────────────────────────────────
    # Listens on port 80 (http://coder-thinkcentre.local) and issues a 302
    # redirect to the live *.try.coder.app tunnel URL, which Coder sets when
    # CODER_ACCESS_URL is left unset.  The shell wrapper discovers the URL and
    # execs a Python HTTP server that serves the redirect.
    systemd.services.coder-redirect =
      let
        redirectPy = pkgs.writeText "coder-redirect.py" ''
          import http.server, os, sys
          TUNNEL = os.environ["CODER_TUNNEL_URL"]
          class R(http.server.BaseHTTPRequestHandler):
              def do_GET(self):
                  self.send_response(302)
                  self.send_header("Location", TUNNEL)
                  self.end_headers()
              do_HEAD = do_GET
              def log_message(self, fmt, *args): pass
          print(f"coder-redirect: serving redirects to {TUNNEL} on :80", flush=True)
          http.server.HTTPServer(("", 80), R).serve_forever()
        '';
      in {
      description = "HTTP redirect: port 80 → Coder tunnel URL";
      wantedBy    = [ "multi-user.target" ];
      after       = [ "coder.service" ];
      requires    = [ "coder.service" ];

      serviceConfig = {
        Type       = "simple";
        Restart    = "on-failure";
        RestartSec = "10s";
        ExecStart  = pkgs.writeShellScript "coder-redirect" ''
          set -euo pipefail
          CODER_LOCAL="http://localhost:3000"

          # Wait until the Coder API is up
          echo "coder-redirect: waiting for Coder API..."
          until ${pkgs.curl}/bin/curl -sf "$CODER_LOCAL/api/v2/buildinfo" > /dev/null 2>&1; do
            sleep 5
          done

          # Fetch the tunnel URL (may take a moment to establish after startup)
          TUNNEL_URL=""
          for i in $(seq 1 20); do
            TUNNEL_URL=$(${pkgs.curl}/bin/curl -sf \
                -H "Coder-Session-Token: $(cat /etc/coder/session-token)" \
                "$CODER_LOCAL/api/v2/deployment/config" \
              | ${pkgs.jq}/bin/jq -r '.config.access_url // empty' 2>/dev/null || true)
            if echo "$TUNNEL_URL" | grep -q "try.coder.app"; then
              echo "coder-redirect: tunnel URL is $TUNNEL_URL"
              break
            fi
            echo "coder-redirect: tunnel not ready yet (attempt $i), retrying in 5s..."
            sleep 5
          done

          if ! echo "$TUNNEL_URL" | grep -q "try.coder.app"; then
            echo "coder-redirect: could not detect tunnel URL; will retry in 30s"
            sleep 30
            exit 1
          fi

          export CODER_TUNNEL_URL="$TUNNEL_URL"

          # Surface the tunnel URL on every console / SSH login.
          HOSTNAME="$(${pkgs.nettools}/bin/hostname)"
          ${pkgs.coreutils}/bin/cat > /etc/motd <<EOF

  Coder is running on this box.

    Tunnel URL:  $TUNNEL_URL
    Local:       http://$HOSTNAME.local:3000
    Redirect:    http://$HOSTNAME.local        (302 → tunnel)

EOF

          exec ${pkgs.python3}/bin/python3 ${redirectPy}
        '';
      };
    };


    # ── Workspace reaper ──────────────────────────────────────────────────────────
    # Deletes workspaces that have been stopped for >= 72 h.
    # time_til_dormant_autodelete_ms is Enterprise-only so we implement this
    # ourselves: an hourly timer calls the API, finds stopped workspaces whose
    # last_used_at is older than 72 h, and issues DELETE requests.
    systemd.services.coder-workspace-reaper = {
      description = "Delete Coder workspaces stopped for >= 72 h";
      after       = [ "coder.service" ];
      serviceConfig = {
        Type            = "oneshot";
        User            = "root";
        ExecStart       = pkgs.writeShellScript "coder-workspace-reaper" ''
          set -euo pipefail
          CODER_LOCAL="http://localhost:3000"
          TOKEN_FILE="/etc/coder/session-token"
          DELETE_AFTER_HOURS=72

          if [ ! -s "$TOKEN_FILE" ]; then
            echo "coder-workspace-reaper: no session token, skipping"
            exit 0
          fi
          TOKEN=$(cat "$TOKEN_FILE")

          NOW=$(${pkgs.coreutils}/bin/date +%s)
          CUTOFF=$(( NOW - DELETE_AFTER_HOURS * 3600 ))

          echo "coder-workspace-reaper: checking for workspaces stopped before $(${pkgs.coreutils}/bin/date -d @$CUTOFF --iso-8601=seconds)"

          WORKSPACES=$(${pkgs.curl}/bin/curl -sf             -H "Coder-Session-Token: $TOKEN"             "$CODER_LOCAL/api/v2/workspaces?limit=100&filterQuery=status:stopped"             | ${pkgs.jq}/bin/jq -r '.workspaces[] | .id + " " + .name + " " + .last_used_at')

          if [ -z "$WORKSPACES" ]; then
            echo "coder-workspace-reaper: no stopped workspaces found"
            exit 0
          fi

          echo "$WORKSPACES" | while IFS=" " read -r id name last_used; do
            # Parse ISO8601 to epoch
            LAST_EPOCH=$(${pkgs.coreutils}/bin/date -d "$last_used" +%s 2>/dev/null || echo 0)
            if [ "$LAST_EPOCH" -lt "$CUTOFF" ]; then
              echo "coder-workspace-reaper: deleting $name ($id) — last used $last_used"
              ${pkgs.curl}/bin/curl -sf -X DELETE                 -H "Coder-Session-Token: $TOKEN"                 "$CODER_LOCAL/api/v2/workspaces/$id" ||                 echo "coder-workspace-reaper: WARNING — delete failed for $name"
            else
              echo "coder-workspace-reaper: keeping $name — stopped recently"
            fi
          done
          echo "coder-workspace-reaper: done"
        '';
      };
    };

    systemd.timers.coder-workspace-reaper = {
      description = "Hourly trigger for coder-workspace-reaper";
      wantedBy    = [ "timers.target" ];
      timerConfig = {
        OnBootSec   = "10min";
        OnUnitActiveSec = "1h";
        Unit        = "coder-workspace-reaper.service";
      };
    };


    # ── coder-logstream-kube Helm install ─────────────────────────────────────
    # Streams k3s pod events (scheduling, image pull, OOMKill, etc.) into
    # Coder workspace startup logs. Runs helm upgrade --install on every boot
    # so the chart is kept up to date after NixOS rebuilds.
    systemd.services.coder-logstream-kube = {
      description = "Install/upgrade coder-logstream-kube Helm chart";
      wantedBy    = [ "multi-user.target" ];
      after       = [ "k3s.service" "network-online.target" ];
      wants       = [ "network-online.target" ];
      requires    = [ "k3s.service" ];
      serviceConfig = {
        Type            = "oneshot";
        RemainAfterExit = true;
        User            = "root";
        ExecStart       = pkgs.writeShellScript "coder-logstream-kube-install" ''
          set -euo pipefail
          export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

          # Add repo if not already present
          ${pkgs.kubernetes-helm}/bin/helm repo add coder-logstream-kube \
            https://helm.coder.com/logstream-kube 2>/dev/null || true
          ${pkgs.kubernetes-helm}/bin/helm repo update coder-logstream-kube

          ${pkgs.kubernetes-helm}/bin/helm upgrade --install coder-logstream-kube \
            coder-logstream-kube/coder-logstream-kube \
            --namespace coder-workspaces \
            --set url=http://10.42.0.1:3000 \
            --set namespaces={coder-workspaces} \
            --atomic --timeout 120s

          echo "coder-logstream-kube: installed/upgraded successfully"
        '';
      };
    };

    system.stateVersion = "25.11";

  }; # end config
}
