#!/usr/bin/env bash
#
# Coder NixOS installer. Wipes a target disk, partitions it via disko,
# installs the NixOS config from this repo, copies the working tree to
# /etc/nixos-repo, and reboots.
#
# Usage from a NixOS live USB:
#
#   nix-shell -p git --run "git clone https://github.com/coder/box /tmp/box"
#   cd /tmp/box
#   sudo ./install.sh                  # interactive disk picker, defaults for the rest
#   sudo ./install.sh --disk /dev/sda --yes
#
# Flags (anything you don't pass uses the default shown):
#
#   --hostname NAME                  coder-nixos
#   --hardware-desc TEXT             auto (dmidecode)
#   --disk PATH                      interactive picker
#   --coder-admin-email EMAIL        admin@coder.com
#   --coder-admin-password PW        PleaseChangeMe1234
#   --coder-admin-password-file P    read first line as password
#   --nixos-username NAME            coderbox
#   --nixos-password PW              PleaseChangeMe1234
#   --nixos-password-file PATH       read first line as password
#   --lan-ip IP                      auto-detected
#   --no-reboot                      skip the final reboot
#   --yes                            skip the destructive-wipe confirmation
#   --help                           show this help

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Writable working copy ──────────────────────────────────────────────────
# install.sh writes generated host files into the repo (hosts/<host>/...), so
# REPO_DIR must be writable. On the normal live-USB flow it's a writable git
# clone. On the installer/appliance ISO the repo is baked at /etc/nixos-repo, a
# symlink into the read-only Nix store, so writing fails ("Read-only file
# system"). When REPO_DIR isn't writable, copy it to a writable tmpdir
# (tmpfs/RAM on a live ISO) and re-exec from there. The copy is a verbatim
# `cp -a`, so if the baked repo carries a .git the copy keeps it (with its
# origin) and the installed /etc/nixos-repo can still `git pull`.
if [[ ! -w "$REPO_DIR" ]]; then
  workdir="$(mktemp -d "${TMPDIR:-/tmp}/coder-box-install.XXXXXX")"
  echo "=== Repo at $REPO_DIR is read-only; copying to a writable dir at $workdir/box ===" >&2
  cp -a "$REPO_DIR/." "$workdir/box/"
  chmod -R u+w "$workdir/box"
  # Signal to the re-exec that we're installing FROM a baked Coder box image
  # (read-only repo in the Nix store) rather than a plain live-USB clone. The
  # install step uses this to copy the prebuilt closure into /mnt explicitly
  # (see "Install" below).
  export CODER_BOX_FROM_IMAGE=1
  exec "$workdir/box/install.sh" "$@"
fi

# ── Flag parsing ───────────────────────────────────────────────────────────
HOSTNAME_ARG=""
HARDWARE_DESC_ARG=""
DISK_ARG=""
ADMIN_EMAIL_ARG=""
ADMIN_PASSWORD_ARG=""
ADMIN_PASSWORD_FILE_ARG=""
NIXOS_USERNAME_ARG=""
NIXOS_PASSWORD_ARG=""
NIXOS_PASSWORD_FILE_ARG=""
LAN_IP_ARG=""
NO_REBOOT=0
ASSUME_YES=0

usage() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \?//; s/^set -euo.*//' | sed '/^$/N;/^\n$/D'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hostname)              HOSTNAME_ARG="$2";              shift 2 ;;
    --hardware-desc)         HARDWARE_DESC_ARG="$2";         shift 2 ;;
    --disk)                  DISK_ARG="$2";                  shift 2 ;;
    --coder-admin-email)           ADMIN_EMAIL_ARG="$2";           shift 2 ;;
    --coder-admin-password)        ADMIN_PASSWORD_ARG="$2";        shift 2 ;;
    --coder-admin-password-file)   ADMIN_PASSWORD_FILE_ARG="$2";   shift 2 ;;
    --nixos-username)        NIXOS_USERNAME_ARG="$2";        shift 2 ;;
    --nixos-password)        NIXOS_PASSWORD_ARG="$2";        shift 2 ;;
    --nixos-password-file)   NIXOS_PASSWORD_FILE_ARG="$2";   shift 2 ;;
    --lan-ip)                LAN_IP_ARG="$2";                shift 2 ;;
    --no-reboot)             NO_REBOOT=1;                    shift ;;
    --yes|-y)                ASSUME_YES=1;                   shift ;;
    --help|-h)               usage; exit 0 ;;
    *) echo "unknown flag: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -n "$ADMIN_PASSWORD_FILE_ARG" ]]; then
  [[ -r "$ADMIN_PASSWORD_FILE_ARG" ]] || { echo "cannot read $ADMIN_PASSWORD_FILE_ARG" >&2; exit 1; }
  ADMIN_PASSWORD_ARG="$(head -n1 "$ADMIN_PASSWORD_FILE_ARG" | tr -d '\r\n')"
fi
if [[ -n "$NIXOS_PASSWORD_FILE_ARG" ]]; then
  [[ -r "$NIXOS_PASSWORD_FILE_ARG" ]] || { echo "cannot read $NIXOS_PASSWORD_FILE_ARG" >&2; exit 1; }
  NIXOS_PASSWORD_ARG="$(head -n1 "$NIXOS_PASSWORD_FILE_ARG" | tr -d '\r\n')"
fi

# ── Sanity ─────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || { echo "must run as root (use sudo)" >&2; exit 1; }
[[ -f "$REPO_DIR/flake.nix" ]] || { echo "no flake.nix at $REPO_DIR" >&2; exit 1; }

command -v lsblk      >/dev/null || { echo "lsblk missing"      >&2; exit 1; }
command -v git        >/dev/null || { echo "git missing"        >&2; exit 1; }
command -v nix        >/dev/null || { echo "nix missing"        >&2; exit 1; }
command -v nixos-install >/dev/null || { echo "nixos-install missing (use the NixOS live USB)" >&2; exit 1; }

# Git complains about repo ownership when running under sudo. Whitelist this
# repo so subsequent git operations don't refuse to run.
git config --global --add safe.directory "$REPO_DIR"

# Pre-flight: live USB /nix/store is tmpfs; failed install attempts leave
# unreferenced paths until reboot, so the next nix command can hit ENOSPC.
check_nix_store_space() {
  local avail_kb
  avail_kb=$(df -Pk /nix/store 2>/dev/null | awk 'NR==2 {print $4}')
  if [[ -z "$avail_kb" ]]; then return 0; fi
  if [[ "$avail_kb" -lt 524288 ]]; then
    cat >&2 <<EOF

ERROR: /nix/store has less than 512 MiB free (\$(df -h /nix/store | awk 'NR==2 {print \$4}') available).

On a live USB, /nix/store is a tmpfs that doesn't get cleaned between
install attempts. Earlier failed runs likely filled it up.

Quickest fix: \`sudo reboot\` the VM and boot back into the live USB.
That wipes the tmpfs cleanly.

If you don't want to reboot:
  sudo nix-collect-garbage -d

Then re-run this installer.
EOF
    exit 1
  fi
}
check_nix_store_space

# ── Helpers ────────────────────────────────────────────────────────────────
detect_lan_ip() {
  local ip
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  if [[ -z "$ip" ]]; then return 1; fi
  case "$ip" in
    10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) echo "$ip"; return 0 ;;
    *) return 1 ;;
  esac
}

detect_hardware_desc() {
  local product manufacturer
  if command -v dmidecode >/dev/null 2>&1; then
    manufacturer=$(dmidecode -s system-manufacturer 2>/dev/null | tail -n1 || true)
    product=$(dmidecode -s system-product-name 2>/dev/null | tail -n1 || true)
    local combined="${manufacturer} ${product}"
    combined=$(echo "$combined" | sed 's/^ *//; s/ *$//; s/  */ /g')
    if [[ -n "$combined" && "$combined" != "To be filled by O.E.M." ]]; then
      echo "$combined"
      return 0
    fi
  fi
  echo "not detected"
}

validate_hostname() {
  [[ "$1" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || {
    echo "hostname must be DNS-safe (lowercase, digits, hyphens; no leading/trailing hyphen): $1" >&2
    return 1
  }
  [[ ${#1} -le 63 ]] || { echo "hostname too long (>63 chars): $1" >&2; return 1; }
}

validate_username() {
  # POSIX-portable: lowercase letter or _, then lowercase/digit/_/-, max 32.
  [[ "$1" =~ ^[a-z_][a-z0-9_-]*$ ]] || {
    echo "username must start with a letter or _ and contain only lowercase letters, digits, hyphens, or underscores: $1" >&2
    return 1
  }
  [[ ${#1} -le 32 ]] || { echo "username too long (>32 chars): $1" >&2; return 1; }
}

# Escape for a Nix "..." string literal.
nix_string_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\$/\\$/g'
}

# Escape for the REPLACEMENT in `sed s|...|REPL|`.
sed_replacement_escape() {
  printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}

list_disks() {
  # Whole-block-devices, non-removable, non-loop, non-rom. MODEL is last so an
  # empty model (e.g. virtio /dev/vda) can't shift the TYPE/RM columns.
  # Skip zram (compressed RAM swap, /dev/zramN) — it reports TYPE=disk RM=0 so
  # it would otherwise show up as an install target, which is never what we want
  # (installing onto RAM swap). Also skip device-mapper / md / loop just in case.
  lsblk -d -p -n -b -o NAME,SIZE,RM,TYPE,MODEL \
    | awk '$4=="disk" && $3=="0" && $1 !~ /\/(zram|dm-|md|loop)[0-9]+$/ { size_h=$2; cmd="numfmt --to=iec --suffix=B "$2; cmd|getline size_h; close(cmd); model=""; for(i=5;i<=NF;i++) model=model (model==""?"":" ") $i; print $1"\t"size_h"\t"model }'
}

# ── Gather inputs ──────────────────────────────────────────────────────────
# Resolve the build/commit revision for display: prefer git (the normal
# live-USB clone, or a fork checkout), else the baked /etc/coder-box-rev that
# the box image writes (its /etc/nixos-repo has no .git), else "unknown".
box_revision() {
  local rev
  rev="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null)" && { echo "$rev"; return; }
  rev="$(cat /etc/coder-box-rev 2>/dev/null)" && [[ -n "$rev" ]] && { echo "$rev"; return; }
  echo "unknown"
}
echo "=== Coder NixOS installer ==="
echo "  revision: $(box_revision)"
echo

# Defaults used when the corresponding flag is omitted.
DEFAULT_HOSTNAME="coder-nixos"
DEFAULT_ADMIN_EMAIL="admin@coder.com"
DEFAULT_ADMIN_PASSWORD="PleaseChangeMe1234"
DEFAULT_NIXOS_USERNAME="coderbox"
DEFAULT_NIXOS_PASSWORD="PleaseChangeMe1234"

# Track inputs that fell back to defaults so the summary can flag them.
HOSTNAME_IS_DEFAULT=0
EMAIL_IS_DEFAULT=0
PASSWORD_IS_DEFAULT=0
NIXOS_USERNAME_IS_DEFAULT=0
NIXOS_PASSWORD_IS_DEFAULT=0

if [[ -z "$HOSTNAME_ARG" ]]; then
  HOSTNAME_ARG="$DEFAULT_HOSTNAME"
  HOSTNAME_IS_DEFAULT=1
fi
validate_hostname "$HOSTNAME_ARG"

# Hardware description is a free-text comment header. Auto-detected if not
# given via --hardware-desc.
if [[ -z "$HARDWARE_DESC_ARG" ]]; then
  HARDWARE_DESC_ARG="$(detect_hardware_desc)"
fi

if [[ -z "$DISK_ARG" ]]; then
  echo
  echo "Available disks (non-removable):"
  mapfile -t DISKS < <(list_disks)
  if [[ ${#DISKS[@]} -eq 0 ]]; then
    echo "  no eligible disks found" >&2
    echo "  override with --disk if needed (use lsblk to inspect)" >&2
    exit 1
  fi
  i=1
  for d in "${DISKS[@]}"; do
    printf "  [%d] %s\n" "$i" "$d"
    i=$((i+1))
  done
  echo
  read -r -p "Install to which disk? [1]: " choice
  choice="${choice:-1}"
  [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le ${#DISKS[@]} ]] \
    || { echo "invalid selection: $choice" >&2; exit 1; }
  DISK_ARG=$(awk '{print $1}' <<<"${DISKS[$((choice-1))]}")
fi
[[ -b "$DISK_ARG" ]] || { echo "not a block device: $DISK_ARG" >&2; exit 1; }

if [[ -z "$ADMIN_EMAIL_ARG" ]]; then
  ADMIN_EMAIL_ARG="$DEFAULT_ADMIN_EMAIL"
  EMAIL_IS_DEFAULT=1
fi
if [[ -z "$ADMIN_PASSWORD_ARG" ]]; then
  ADMIN_PASSWORD_ARG="$DEFAULT_ADMIN_PASSWORD"
  PASSWORD_IS_DEFAULT=1
fi

if [[ -z "$NIXOS_USERNAME_ARG" ]]; then
  NIXOS_USERNAME_ARG="$DEFAULT_NIXOS_USERNAME"
  NIXOS_USERNAME_IS_DEFAULT=1
fi
validate_username "$NIXOS_USERNAME_ARG"
if [[ -z "$NIXOS_PASSWORD_ARG" ]]; then
  NIXOS_PASSWORD_ARG="$DEFAULT_NIXOS_PASSWORD"
  NIXOS_PASSWORD_IS_DEFAULT=1
fi

if [[ -z "$LAN_IP_ARG" ]]; then
  LAN_IP_ARG=$(detect_lan_ip || true)
fi

# Existing host folder?
HOST_DIR="$REPO_DIR/hosts/$HOSTNAME_ARG"
if [[ -d "$HOST_DIR" ]]; then
  echo
  echo "  hosts/$HOSTNAME_ARG already exists, using existing files." >&2
  echo "  Delete the folder first to regenerate." >&2
fi

# ── Summary + confirm ──────────────────────────────────────────────────────
echo
echo "Ready to install:"
printf "  Hostname:             %s%s\n" "$HOSTNAME_ARG" \
  "$( [[ $HOSTNAME_IS_DEFAULT -eq 1 ]] && echo '  (default)' )"
printf "  Hardware:             %s\n" "$HARDWARE_DESC_ARG"
printf "  Disk (will wipe):     %s\n" "$DISK_ARG"
printf "  Coder admin email:    %s%s\n" "$ADMIN_EMAIL_ARG" \
  "$( [[ $EMAIL_IS_DEFAULT -eq 1 ]] && echo '  (default)' )"
if [[ $PASSWORD_IS_DEFAULT -eq 1 ]]; then
  printf "  Coder admin password: %s  (default)\n" "$ADMIN_PASSWORD_ARG"
else
  printf "  Coder admin password: %s\n" "$(printf '%*s' "${#ADMIN_PASSWORD_ARG}" '' | tr ' ' '*')"
fi
printf "  NixOS login user:     %s%s\n" "$NIXOS_USERNAME_ARG" \
  "$( [[ $NIXOS_USERNAME_IS_DEFAULT -eq 1 ]] && echo '  (default)' )"
if [[ $NIXOS_PASSWORD_IS_DEFAULT -eq 1 ]]; then
  printf "  NixOS login password: %s  (default)\n" "$NIXOS_PASSWORD_ARG"
else
  printf "  NixOS login password: %s\n" "$(printf '%*s' "${#NIXOS_PASSWORD_ARG}" '' | tr ' ' '*')"
fi
printf "  LAN IP:               %s\n" "${LAN_IP_ARG:-(none detected)}"
if [[ $HOSTNAME_IS_DEFAULT -eq 1 || $EMAIL_IS_DEFAULT -eq 1 || $PASSWORD_IS_DEFAULT -eq 1 \
   || $NIXOS_USERNAME_IS_DEFAULT -eq 1 || $NIXOS_PASSWORD_IS_DEFAULT -eq 1 ]]; then
  echo
  echo "  Some values are defaults. Override with --hostname/--coder-admin-email/"
  echo "  --coder-admin-password/--nixos-username/--nixos-password, or change"
  echo "  inside Coder (admin) and via 'passwd' (NixOS user) after first login."
fi
echo

if [[ $ASSUME_YES -eq 0 ]]; then
  read -r -p "Wipe $DISK_ARG and install? [y/N]: " ans
  case "${ans,,}" in y|yes) ;; *) echo "aborted." >&2; exit 1 ;; esac
fi

# ── Generate host files ────────────────────────────────────────────────────
mkdir -p "$HOST_DIR"

# default.nix: disko-standard layout, target disk override, conditional
# local.nix, facter when present.
if [[ ! -f "$HOST_DIR/default.nix" ]]; then
  cat > "$HOST_DIR/default.nix" <<NIX
# Hardware: ${HARDWARE_DESC_ARG}.
#
# Generated by install.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ).
# Hand-edit freely; the installer won't overwrite an existing default.nix.

{ lib, ... }:

{
  imports = [ ../../nixos/disko-standard.nix ]
    ++ lib.optional (builtins.pathExists ./local.nix) ./local.nix;

  # Target disk for disko-standard.
  disko.devices.disk.main.device = lib.mkForce "${DISK_ARG}";

  # facter.json overrides hardware-detection bits of hardware-configuration.nix.
  hardware.facter.reportPath =
    lib.mkIf (builtins.pathExists ./facter.json) ./facter.json;
}
NIX
  echo "  wrote hosts/$HOSTNAME_ARG/default.nix"
fi

# local.nix: copy from example, splice creds + LAN IP.
if [[ ! -f "$HOST_DIR/local.nix" ]]; then
  cp "$REPO_DIR/local.nix.example" "$HOST_DIR/local.nix"
  # Two-stage escape: Nix string literal, then sed replacement.
  esc_email=$(sed_replacement_escape "$(nix_string_escape "$ADMIN_EMAIL_ARG")")
  esc_pw=$(sed_replacement_escape "$(nix_string_escape "$ADMIN_PASSWORD_ARG")")
  esc_username=$(sed_replacement_escape "$(nix_string_escape "$NIXOS_USERNAME_ARG")")
  esc_nixos_pw=$(sed_replacement_escape "$(nix_string_escape "$NIXOS_PASSWORD_ARG")")
  sed -i \
    -e "s|CODER_ADMIN_EMAIL    = \"you@example.com\";|CODER_ADMIN_EMAIL    = \"${esc_email}\";|" \
    -e "s|CODER_ADMIN_PASSWORD = \"changeme\";|CODER_ADMIN_PASSWORD = \"${esc_pw}\";|" \
    -e "s|nixosUsername = \"coderbox\";|nixosUsername = \"${esc_username}\";|" \
    -e "s|initialPassword = \"changeme\";|initialPassword = \"${esc_nixos_pw}\";|" \
    "$HOST_DIR/local.nix"
  if [[ -n "$LAN_IP_ARG" ]]; then
    esc_ip=$(sed_replacement_escape "$(nix_string_escape "$LAN_IP_ARG")")
    sed -i \
      -e "s|# services.coder-nixos.lanIp = \"192.168.x.x\";|services.coder-nixos.lanIp = \"${esc_ip}\";|" \
      "$HOST_DIR/local.nix"
  fi
  echo "  wrote hosts/$HOSTNAME_ARG/local.nix"
fi

# facter.json: hardware report. Use the flake's pinned nixos-facter so it
# shares one nixpkgs source with the rest of the install (avoids parallel
# tmpfs allocations of disko's and nixpkgs#'s own nixpkgs trees).
if [[ ! -f "$HOST_DIR/facter.json" ]]; then
  echo "  running nixos-facter ..."
  nix --extra-experimental-features 'nix-command flakes' \
    run "$REPO_DIR#nixos-facter" -- -o "$HOST_DIR/facter.json"
  echo "  wrote hosts/$HOSTNAME_ARG/facter.json"
fi

# A git path flake ignores untracked files, so the freshly written host files
# must be intent-to-added for the flake to see them (local.nix is gitignored, so
# force-add it). Only meaningful when REPO_DIR is a git repo; the ISO writable
# copy may have no .git (a non-git path flake already sees every file), so skip.
if git -C "$REPO_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "$REPO_DIR" add --intent-to-add -f \
    "hosts/$HOSTNAME_ARG/default.nix" \
    "hosts/$HOSTNAME_ARG/facter.json" \
    "hosts/$HOSTNAME_ARG/local.nix" >/dev/null
fi

# ── Validate ───────────────────────────────────────────────────────────────
echo "  validating flake ..."
nix --extra-experimental-features 'nix-command flakes' \
  eval "$REPO_DIR#nixosConfigurations.${HOSTNAME_ARG}.config.system.build.toplevel.drvPath" \
  >/dev/null

# ── Partition + format + mount ─────────────────────────────────────────────
echo
echo "=== Partitioning $DISK_ARG via disko ==="
# Use the flake's pinned disko (one nixpkgs source for the whole install).
nix --extra-experimental-features 'nix-command flakes' \
  run "$REPO_DIR#disko" -- \
  --mode disko --flake "$REPO_DIR#${HOSTNAME_ARG}"

mountpoint -q /mnt || { echo "disko did not mount /mnt" >&2; exit 1; }

# Activate any swap partitions disko just formatted on the target. nixos-install
# can spike past available RAM (notably Coder's vite frontend bundle); on a
# small-RAM live USB the OOM killer fires without swap.
mapfile -t SWAP_PARTS < <(blkid -t TYPE=swap -o device 2>/dev/null \
  | awk -v disk="$DISK_ARG" 'index($0, disk) == 1')
for sp in "${SWAP_PARTS[@]}"; do
  echo "=== Activating swap on $sp ==="
  swapon "$sp" 2>/dev/null \
    || echo "  (swapon $sp failed, continuing without it)"
done

# ── Bake the repo into the installed system at /etc/nixos-repo ─────────────
echo "=== Copying repo into /mnt/etc/nixos-repo ==="
# Copy the working tree to the target. Keep .git so the installed system
# can git pull / git status against the repo.
mkdir -p /mnt/etc/nixos-repo
cp -a "$REPO_DIR/." /mnt/etc/nixos-repo/

# Symlink /etc/nixos/flake.nix so plain `nixos-rebuild switch` finds the
# config after reboot.
mkdir -p /mnt/etc/nixos
ln -sf /etc/nixos-repo/flake.nix /mnt/etc/nixos/flake.nix

# ── Install ────────────────────────────────────────────────────────────────
# Two cases:
#
# (A) Installing FROM a Coder box image (installer/appliance ISO;
#     CODER_BOX_FROM_IMAGE=1). The live /nix/store already contains almost the
#     entire closure for the target system — but in the read-only squashfs lower
#     layer of the overlay. nixos-install builds the flake with
#     `nix build --store /mnt --extra-substituters <host-store>`, i.e. it
#     *substitutes* paths into /mnt from the host store; squashfs paths lack the
#     signatures/narinfo substitution needs, so the copy silently yields
#     nothing. /mnt is left empty (no bash; the `system` profile points at the
#     wrong path) and the chroot `activate` fails: "No such file or directory".
#     (NOTE: the target host is `coder-nixos`, a *different* system than the
#     image's own host, so its toplevel isn't pre-realised — it must be built.
#     The build is cheap: every heavy dependency (KDE, Coder, k3s, …) is reused
#     from the squashfs; only the few host-specific derivations are new.)
#
#     So: build the toplevel, copy its full closure into /mnt with
#     `nix copy --no-check-sigs` (bypassing the signature/substituter machinery
#     that was the actual failure), then `nixos-install --system <path>` just
#     activates it. This mirrors the working manual workaround ("copy the repo
#     somewhere writable and run install.sh").
#
# (B) Plain live-USB clone (stock NixOS ISO). The closure is NOT present, so
#     building it in the host store first would balloon tmpfs/RAM. Keep the
#     original `nixos-install --flake` which builds/downloads straight into
#     /mnt.
if [[ "${CODER_BOX_FROM_IMAGE:-0}" == "1" ]]; then
  echo "=== Building system closure (reusing the baked store) ==="
  SYSTEM_TOPLEVEL=$(nix --extra-experimental-features 'nix-command flakes' \
    build --no-link --print-out-paths \
    --option download-buffer-size 268435456 \
    "/mnt/etc/nixos-repo#nixosConfigurations.${HOSTNAME_ARG}.config.system.build.toplevel")
  [[ -n "$SYSTEM_TOPLEVEL" ]] || { echo "failed to build system closure" >&2; exit 1; }

  echo "=== Copying system closure into /mnt ==="
  nix --extra-experimental-features 'nix-command flakes' \
    copy --no-check-sigs --to "local?root=/mnt" "$SYSTEM_TOPLEVEL"

  echo "=== Running nixos-install (from prebuilt system) ==="
  nixos-install \
    --system "$SYSTEM_TOPLEVEL" \
    --no-channel-copy \
    --no-root-passwd \
    --option download-buffer-size 268435456
else
  echo "=== Running nixos-install ==="
  echo "    (closure builds into /mnt/nix/store; no tmpfs OOM risk)"
  nixos-install \
    --flake "/mnt/etc/nixos-repo#${HOSTNAME_ARG}" \
    --no-channel-copy \
    --no-root-passwd \
    --option download-buffer-size 268435456
fi

echo
echo "✓ Installation complete."
echo
echo "Installed:"
printf "  Hostname:             %s\n" "$HOSTNAME_ARG"
printf "  Disk:                 %s\n" "$DISK_ARG"
printf "  Coder admin email:    %s\n" "$ADMIN_EMAIL_ARG"
if [[ $PASSWORD_IS_DEFAULT -eq 1 ]]; then
  printf "  Coder admin password: %s  (default)\n" "$ADMIN_PASSWORD_ARG"
else
  printf "  Coder admin password: %s\n" "$(printf '%*s' "${#ADMIN_PASSWORD_ARG}" '' | tr ' ' '*')"
fi
printf "  NixOS login user:     %s\n" "$NIXOS_USERNAME_ARG"
if [[ $NIXOS_PASSWORD_IS_DEFAULT -eq 1 ]]; then
  printf "  NixOS login password: %s  (default)\n" "$NIXOS_PASSWORD_ARG"
else
  printf "  NixOS login password: %s\n" "$(printf '%*s' "${#NIXOS_PASSWORD_ARG}" '' | tr ' ' '*')"
fi
printf "  LAN IP:               %s\n" "${LAN_IP_ARG:-(none detected)}"
echo
echo "Coder web UI after reboot:"
echo "  http://${HOSTNAME_ARG}.local        (port 80 redirects to the *.try.coder.app tunnel URL)"
echo "  http://${HOSTNAME_ARG}.local:3000   (direct LAN access)"
echo "  the *.try.coder.app URL itself is written to /etc/motd on first boot once coder.service is up"
echo
echo "Optional after first login:"
echo "  - Update the box:  cd /etc/nixos-repo && sudo git pull && sudo nixos-rebuild switch"
echo

if [[ $NO_REBOOT -eq 0 ]]; then
  if [[ $ASSUME_YES -eq 1 ]]; then
    echo "Rebooting in 5s. Ctrl+C to skip."
    sleep 5
    reboot
  else
    read -r -p "Reboot now? [Y/n]: " ans
    case "${ans,,}" in n|no) echo "skip reboot." ;; *) reboot ;; esac
  fi
fi
