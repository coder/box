# nixos/modules/screenconnect — optional ScreenConnect (ConnectWise Control) client
#
# Enable in the host's `hosts/<host>/local.nix`:
#   services.coder-nixos.screenconnect = {
#     enable = true;
#     installerUrl = "https://sc.example.com/Bin/ScreenConnect.ClientSetup.sh?e=Access&y=Guest&c=...";
#   };
#
# The installer URL is server-specific (contains embedded GUID and session params).
# This module downloads the installer script at activation time, extracts the
# embedded .deb, unpacks it, and installs the ScreenConnect client files to
# /opt/connectwisecontrol-<GUID>/ without requiring dpkg, pkexec, or /bin/bash
# from the host system.
#
# The GUID (e.g. "6069f55815889846") is discovered dynamically from the .deb
# package name — it is NOT hardcoded here.
#
# Re-installation is triggered whenever the installerUrl changes (stamp file
# tracks a hash of the URL). The service is managed by systemd.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.coder-nixos.screenconnect;

  # Tools used by the install script — resolved to Nix store paths so the
  # service's PATH doesn't need to contain them.
  bash = "${pkgs.bash}/bin/bash";
  curl = "${pkgs.curl}/bin/curl";
  dpkg = "${pkgs.dpkg}/bin/dpkg-deb";
  perl = "${pkgs.perl}/bin/perl";
  grep = "${pkgs.gnugrep}/bin/grep";
  tar = "${pkgs.gnutar}/bin/tar";

  installScript = pkgs.writeScript "screenconnect-install" ''
    #!${bash}
    set -euo pipefail

    INSTALLER_URL=${lib.escapeShellArg cfg.installerUrl}
    STAMP_DIR="/var/lib/screenconnect"
    STAMP="$STAMP_DIR/.installed"
    URL_HASH="${builtins.hashString "sha256" cfg.installerUrl}"

    mkdir -p "$STAMP_DIR"

    # Skip reinstall if already installed with same URL
    if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$URL_HASH" ]; then
      echo "screenconnect: already installed (url hash matches), skipping"
      exit 0
    fi

    echo "screenconnect: downloading installer..."
    TMPDIR=$(mktemp -d)
    trap 'rm -rf "$TMPDIR"' EXIT

    ${curl} -fsSL "$INSTALLER_URL" -o "$TMPDIR/sc-install.sh"

    echo "screenconnect: extracting embedded .deb..."
    # The installer shell script embeds the .deb between two marker lines.
    START=$(${grep} -anF -m1 "deb__commencement" "$TMPDIR/sc-install.sh" | ${grep} -o "^[0-9]*")
    END=$(${grep} -anF -m1 "deb__completion"    "$TMPDIR/sc-install.sh" | ${grep} -o "^[0-9]*")
    # tail exits non-zero on SIGPIPE when head closes the pipe early; suppress it
    { tail -n+$((START+1)) "$TMPDIR/sc-install.sh" || true; } | head -n$((END-START-1)) > "$TMPDIR/sc-package.deb"
    # Remove trailing newline that tail/head adds (matches installer logic)
    ${perl} -i -0pe 's/\n\Z//' "$TMPDIR/sc-package.deb"

    echo "screenconnect: extracting .deb contents..."
    mkdir -p "$TMPDIR/extracted"
    ${dpkg} -x "$TMPDIR/sc-package.deb" "$TMPDIR/extracted"

    echo "screenconnect: discovering package GUID..."
    PKG_NAME=$(${dpkg} -f "$TMPDIR/sc-package.deb" Package)
    GUID=$(echo "$PKG_NAME" | sed 's/connectwisecontrol-//')
    echo "screenconnect: GUID = $GUID, package = $PKG_NAME"

    OPT_SRC="$TMPDIR/extracted/opt/$PKG_NAME"
    OPT_DEST="/opt/$PKG_NAME"
    INIT_SRC="$TMPDIR/extracted/etc/init.d/$PKG_NAME"
    INIT_DEST="/etc/init.d/$PKG_NAME"

    if [ ! -d "$OPT_SRC" ]; then
      echo "screenconnect: ERROR: expected $OPT_SRC not found in .deb" >&2
      exit 1
    fi

    # Remove previous installation (different GUID or upgrade)
    for dir in /opt/connectwisecontrol-*/; do
      [ -d "$dir" ] && rm -rf "$dir" && echo "screenconnect: removed old $dir"
    done
    for f in /etc/init.d/connectwisecontrol-*; do
      [ -f "$f" ] && rm -f "$f" && echo "screenconnect: removed old $f"
    done

    echo "screenconnect: installing to $OPT_DEST ..."
    mkdir -p "$OPT_DEST"
    cp -r "$OPT_SRC/." "$OPT_DEST/"

    echo "screenconnect: installing init script to $INIT_DEST ..."
    mkdir -p /etc/init.d
    cp "$INIT_SRC" "$INIT_DEST"
    chmod +x "$INIT_DEST"

    # Patch the init script's PATH to include the Nix JRE so `java` is found.
    # The init script does: export PATH="/usr/local/sbin:..."
    # We prepend the JRE bin dir so it wins.
    JRE_BIN="${pkgs.temurin-bin-21}/bin"
    sed -i "s|export PATH=\"|export PATH=\"$JRE_BIN:|" "$INIT_DEST"

    # Run postinst to populate ClientLaunchParameters.txt with the real
    # connection params (relay host, port, encryption key, session ID).
    # The postinst embeds newClientLaunchParameters and addGeneratedSessionIdIfNecessary;
    # we extract and execute just that logic rather than running the whole postinst
    # (which tries to call dpkg, update-rc.d, systemctl, etc.).
    echo "screenconnect: populating ClientLaunchParameters.txt from postinst..."
    POSTINST_PARAMS=$(${dpkg} --ctrl-tarfile "$TMPDIR/sc-package.deb" | ${tar} -xOf - postinst 2>/dev/null \
      | grep "^newClientLaunchParameters=" | head -1 \
      | sed "s/^newClientLaunchParameters=//" | tr -d "'")
    if [ -z "$POSTINST_PARAMS" ]; then
      echo "screenconnect: ERROR: could not extract newClientLaunchParameters from postinst" >&2
      exit 1
    fi
    # Generate a random session ID (same logic as postinst addGeneratedSessionIdIfNecessary)
    SESSION_ID="$(dd if=/dev/urandom bs=1 count=16 2>/dev/null | od -A n -t x1 | tr -d ' \n' | head -c 32 | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/')"
    PARAMS_WITH_SESSION="''${POSTINST_PARAMS}&s=''${SESSION_ID}"
    echo "$PARAMS_WITH_SESSION" > "$OPT_DEST/ClientLaunchParameters.txt"
    echo "screenconnect: wrote ClientLaunchParameters.txt"

    # Write stamp
    echo "$URL_HASH" > "$STAMP"
    echo "screenconnect: installation complete (GUID=$GUID)"
  '';

in
{
  options.services.coder-nixos.screenconnect = {
    enable = lib.mkEnableOption "ScreenConnect (ConnectWise Control) remote access client";

    installerUrl = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        Full URL to the ScreenConnect client installer shell script.
        This is the "ScreenConnect.ClientSetup.sh" URL from your server's
        Access page, e.g.:
          https://sc.example.com/Bin/ScreenConnect.ClientSetup.sh?e=Access&y=Guest&c=MyOrg&c=&c=&c=&c=&c=&c=&c=
        The URL contains the server-specific GUID and session parameters.
        Set this in the host's local.nix (gitignored).
      '';
      example = "https://sc.example.com/Bin/ScreenConnect.ClientSetup.sh?e=Access&y=Guest&c=MyOrg&c=&c=&c=&c=&c=&c=&c=";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.installerUrl != "";
        message = "services.coder-nixos.screenconnect.installerUrl must be set when enable = true";
      }
    ];

    # Packages the install script and init script need at runtime
    environment.systemPackages = with pkgs; [ temurin-bin-21 ];

    # One-shot: downloads and installs the .deb contents at boot/rebuild.
    # Skips if already installed (stamp file matches URL hash).
    systemd.services.screenconnect-install = {
      description = "Install ScreenConnect client from installer URL";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      before = [ "screenconnect.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = installScript;
      };
    };

    # The actual ScreenConnect client service.
    # Calls the init script installed by screenconnect-install.
    # Type=forking because the init script daemonises the java process.
    systemd.services.screenconnect = {
      description = "ScreenConnect remote access client";
      after = [
        "network.target"
        "screenconnect-install.service"
        "display-manager.service"
      ];
      requires = [ "screenconnect-install.service" ];
      wantedBy = [ "multi-user.target" ];

      path = [
        pkgs.temurin-bin-21
        pkgs.coreutils
        pkgs.procps
        pkgs.gnugrep
      ];

      serviceConfig = {
        Type = "forking";
        # DISPLAY is set; XAUTHORITY is discovered dynamically in ExecStart
        # because the xauth filename changes on every boot.
        Environment = [ "DISPLAY=:0" ];
        # ExecStart is resolved dynamically — the GUID is not known at eval time.
        # We use a small wrapper that finds the installed init script.
        ExecStart = pkgs.writeShellScript "screenconnect-start" ''
          set -euo pipefail
          INIT=$(echo /etc/init.d/connectwisecontrol-*)
          if [ ! -f "$INIT" ]; then
            echo "screenconnect: init script not found at /etc/init.d/connectwisecontrol-*" >&2
            exit 1
          fi
          # Find the xauth cookie file for the running Xorg session.
          # The filename is randomised by SDDM on each boot.
          XAUTH=$(ls /run/sddm/xauth_* 2>/dev/null | head -1)
          if [ -n "$XAUTH" ]; then
            export XAUTHORITY="$XAUTH"
            echo "screenconnect: using XAUTHORITY=$XAUTH"
          else
            echo "screenconnect: warning: no xauth file found in /run/sddm/"
          fi
          exec "$INIT" start
        '';
        ExecStop = pkgs.writeShellScript "screenconnect-stop" ''
          set -euo pipefail
          INIT=$(echo /etc/init.d/connectwisecontrol-*)
          [ -f "$INIT" ] && exec "$INIT" stop || true
        '';
        ExecReload = pkgs.writeShellScript "screenconnect-reload" ''
          set -euo pipefail
          INIT=$(echo /etc/init.d/connectwisecontrol-*)
          if [ -f "$INIT" ]; then
            "$INIT" stop || true
            exec "$INIT" start
          fi
        '';
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = "10s";
      };
    };
  };
}
