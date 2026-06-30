# agents.md — Coder agent guide for the coder-nixos repo

Reference for AI coding agents and humans working on this repo.

## Quick Reference

| Item | Value |
|---|---|
| SSH | `ssh -i ~/.ssh/id_ed25519 coderbox@<TAILSCALE_IP>` |
| Repo path | `/etc/nixos-repo/` (a Nix flake; `nixosConfigurations.<hostname>`) |
| Git ops | `sudo git -C /etc/nixos-repo <command>` |
| Coder URL | `http://coder-thinkcentre.local:3000` |
| Coder token | stored in `/etc/coder/session-token` |
| Coder binary | `coder` (in PATH via NixOS; resolves from nix store) |
| kubectl | `sudo k3s kubectl` — in PATH via NixOS |
| Tailscale IP | set in `hosts/<host>/local.nix` — see `tailscale status` |
| LAN IP | set via `services.coder-nixos.lanIp` in `hosts/<host>/local.nix` |

**kubectl alias (on the box):**
```sh
alias k='sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml k3s kubectl'
# or just:
sudo k3s kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml ...
```

## Applying NixOS Changes

```sh
# Service, package, or config changes — safe, non-destructive:
cd /etc/nixos-repo && sudo nixos-rebuild switch --flake /etc/nixos-repo

# Desktop stack (KDE, SDDM, Xorg, Wayland) — must reboot:
cd /etc/nixos-repo && sudo nixos-rebuild boot --flake /etc/nixos-repo && sudo reboot
```

The repo is baked onto the box at **`/etc/nixos-repo`** (the canonical flake;
`nixosConfigurations.<hostname>`, auto-selected by the running hostname). Edit
files there, then rebuild. Always pass `--flake /etc/nixos-repo` (or `cd` into
it and use `--flake .`) — see the `/etc/nixos` pitfall below.

`nixos-rebuild switch` triggers the `coder-template-sync` activation script, which runs `terraform apply` in `coderd/` and pushes any template changes to Coder. The `/etc/coder/session-token` it needs is populated automatically by `coder-init-admin.service` on first boot, so this just works post-install.

> **Note:** Earlier versions of this file said "never use `nixos-rebuild switch`". That was written when this box ran a KDE desktop as the primary interface and switch could corrupt an active Plasma session. For backend service/package changes — which is most of what we do — `switch` is fine. Only use `boot + reboot` if you're changing KDE, SDDM, Xorg, or display stack config.

## Tailscale

Tailscale is managed by `nixos/modules/tailscale`. Auth key is set as `authKey` in `hosts/<host>/local.nix` (gitignored). Get a reusable key from https://login.tailscale.com/admin/settings/keys.

**IMPORTANT:** Do NOT add `--ssh` to `extraUpFlags` in `hosts/<host>/local.nix`. Tailscale SSH takes over port 22 with browser-based auth, which will lock you out of the machine. Standard OpenSSH on port 22 is used instead.

`tailscale-autoauth.service` has `RemainAfterExit = true` — it won't re-run on `nixos-rebuild switch` if Tailscale is already authenticated. Check status with `tailscale status`.

## Git Workflow

All files in `/etc/nixos-repo/` are root-owned. Use `sudo git`:

```sh
cd /etc/nixos-repo
sudo git status
sudo git add -p
sudo git commit -m "feat: describe your change"
# Don't push unless explicitly asked
```

Commit regularly. Don't push to remote unless the user explicitly asks.

The `gh` CLI is installed as a helper for working with this repo (opening PRs,
checking CI, etc.). It is not authenticated out of the box — run `gh auth login`
once as the login user. Still don't push or open PRs unless explicitly asked.

`.gitignore` ignores the whole `hosts/` directory (so users can drop their own
hosts in without git noise), then un-ignores each centrally-managed host with a
`!hosts/<host>/` line. **When you add a new centrally-managed host, add a
matching `!hosts/<host>/` line to `.gitignore`** — otherwise its files stay
ignored and `git add` rejects them (per-host `local.nix`/`facter.json` remain
ignored via the `hosts/*/local.nix` rule).

## Template Management

Templates live in two places:
- `coderd/templates/` — general templates (k3s-podman, k3s-sysbox, k3s-dev); managed by `coderd/main.tf`
- `hosts/coder-thinkcentre/templates/` — machine-specific templates (nook-android)

`coderd/main.tf` uses `var.hostname` to conditionally deploy machine-specific templates:
```hcl
# nook-android is only deployed when hostname == "coder-thinkcentre"
count = var.hostname == "coder-thinkcentre" ? 1 : 0
```

**To push a template change manually** (without nixos-rebuild):
```sh
export CODER_URL=http://localhost:3000
export CODER_SESSION_TOKEN=$(sudo cat /etc/coder/session-token)
coder templates push <template-name> --directory hosts/coder-thinkcentre/templates/nook-android/
```

**To apply the coderd Terraform (same as activation script does):**
```sh
cd /etc/nixos-repo/coderd
sudo terraform apply \
  -var="coder_url=http://localhost:3000" \
  -var="coder_session_token=$(sudo cat /etc/coder/session-token)" \
  -var="hostname=coder-thinkcentre" \
  -var="version_name=$(sudo git -C /etc/nixos-repo rev-parse --short HEAD)"
```

## nook-android Template

Workspace for building the `trmnl-nook-simple-touch` APK on the Barnes & Noble Nook Simple Touch e-reader.

**Image:** `localhost/nook-android:latest` — pre-built by `nook-android-image-build.service` and imported into k3s containerd. Pod uses `imagePullPolicy: Never`.

**Rebuild the image** (e.g. after Dockerfile changes):
```sh
sudo systemctl restart nook-android-image-build
sudo journalctl -fu nook-android-image-build
```
Or force rebuild by deleting the stamp file:
```sh
sudo rm /var/lib/coder/nook-android-image.stamp
sudo systemctl start nook-android-image-build
```

**Key facts:**
- `boot.binfmt.emulatedSystems = [ "i686-linux" ]` — qemu-i386 binfmt registered so 32-bit ADT binaries run transparently in pods
- Coder user in the pod: `coder` (uid/gid 1000), passwordless sudo
- Home dir: `/home/coder` (on PVC — image layers shadowed by PVC mount, so `mkdir -p ~/.local/bin` in startup script)
- Build command: `$ANT -Dbuild.compiler=modern clean debug`

## Checking Service Status

```sh
# Coder server
sudo systemctl status coder
sudo journalctl -fu coder

# k3s
sudo systemctl status k3s
sudo k3s kubectl get pods -n coder-workspaces

# Tailscale
tailscale status
sudo systemctl status tailscaled

# nook-android image build
sudo systemctl status nook-android-image-build
sudo journalctl -u nook-android-image-build --no-pager

# ScreenConnect
sudo systemctl status screenconnect
sudo journalctl -fu screenconnect
sudo journalctl -u screenconnect-install --no-pager
```

## Workspace Debugging

```sh
# List all workspace pods
sudo k3s kubectl get pods -n coder-workspaces

# Exec into a running pod
sudo k3s kubectl exec -it -n coder-workspaces <pod-name> -- bash

# View pod logs (agent output)
sudo k3s kubectl logs -n coder-workspaces <pod-name>

# Describe pod (events, image pull errors, etc.)
sudo k3s kubectl describe pod -n coder-workspaces <pod-name>
```

## Common Pitfalls

- **SSH to LAN IP fails** — the LAN IP is routed via Tailscale subnet router. Always SSH to the Tailscale IP (check `tailscale status`).
- **Coder agent URL inside pods** — pods reach Coder via `http://coder-thinkcentre.local:3000` using a `hostAliases` entry. The IP is set via `services.coder-nixos.lanIp` in the host's `local.nix` and injected at template sync time.
- **PVC shadows image home dir** — the PVC mounts over `/home/coder`, so any files created in the image at `/home/coder` are invisible at runtime. Always create needed dirs/files in the startup script.
- **Tailscale auth doesn't re-run** — `tailscale-autoauth` has `RemainAfterExit = true`. If you change auth key config, run `sudo systemctl restart tailscale-autoauth`.
- **Template sync skips**, if `/etc/coder/session-token` is empty, the activation script exits cleanly. The token is auto-populated by `coder-init-admin.service`; if it's missing, check `journalctl -u coder-init-admin`.
- **`coder` binary path** — the binary is in PATH via NixOS environment; don't hardcode nix store paths in scripts (they change with every package update).
- **`--flake /etc/nixos` fails** — `/etc/nixos` is a plain dir holding only a `flake.nix` *symlink* into `/etc/nixos-repo`. Nix follows the symlink into the store but can't find the sibling files (configuration.nix, hosts/, nixos/), dying with `path '/nix/store/...-source/etc/nixos-repo/flake.nix' does not exist`. Always rebuild against the real tree: `--flake /etc/nixos-repo` (or `cd /etc/nixos-repo && nixos-rebuild switch --flake .`).
- **`Git tree '/etc/nixos-repo' is dirty` warning** — harmless. `hosts/<host>/{local.nix,facter.json}` are gitignored and intent-to-added by the installer, so the tree always reads "dirty". After editing them, re-mark intent-to-add so the flake sees them: `sudo git -C /etc/nixos-repo add --intent-to-add -f hosts/<host>/local.nix hosts/<host>/facter.json`.
- **ScreenConnect blank screen** — if SC shows a black/blank view, SDDM may have fallen back to Wayland. Ensure `services.displayManager.sddm.wayland.enable = false` and `services.displayManager.defaultSession = "plasmax11"` in `configuration.nix`, then `nixos-rebuild boot && reboot`.

## Wildcard App Access (TODO)

`CODER_WILDCARD_ACCESS_URL` is currently empty — Coder app proxying via subdomains is not configured. To enable:
1. Choose a domain and set DNS (or split-DNS for LAN vs Tailscale).
2. Configure HTTPS (likely via Caddy reverse proxy).
3. Update `CODER_ACCESS_URL` and `CODER_WILDCARD_ACCESS_URL` in `configuration.nix`.
4. Run `sudo nixos-rebuild switch`.

## File Layout (agent-relevant paths)

```
/etc/nixos-repo/                # repo root (a Nix flake; sudo git required)
  flake.nix                     # entry point: nixosConfigurations.<host> per machine
  flake.lock                    # pinned nixpkgs / disko / nixos-facter-modules
  configuration.nix             # shared NixOS config (edit here for services/packages)
  local.nix.example             # template for hosts/<host>/local.nix
  nixos/
    disko-standard.nix          # shared disko config: UEFI + single-disk layout for new hosts
    modules/                    # NixOS service modules (services.coder-nixos.*)
      k3s/                      # base single-node k3s server
      podman/                   # k3s + rootless Podman socket runtime
      sysbox/                   # k3s + sysbox-runc runtime
      tailscale/                # Tailscale module
      screenconnect/            # ScreenConnect remote access client
    _images/                    # prebuilt-image modules (appliance + installer)
      box-turnkey.nix           # shared turn-key Coder box (login + Coder bootstrap); all image hosts
      base/hardware.nix         # all-hardware (boot on arbitrary hardware)
      base/iso.nix              # shared ISO mechanics (iso-image.nix, EFI/BIOS/USB bootable, bootloader)
      appliance/iso.nix         # appliance ISO module (imported by hosts/_appliance-iso)
      installer/iso.nix         # installer ISO module (imported by hosts/_installer-iso)
  packages/                     # one folder per package, each with a default.nix
    coder/                      # Coder server package (binary or from-source selector)
    coder-binary/               # prebuilt Coder release binary
    coder-from-source/          # Coder built from source
    coderd-provider/            # terraform-provider-coderd derivation
    terraform-binary/           # prebuilt Terraform release binary
    sysbox-runc/                # sysbox-runc 0.7.0 from source (+ vendored deps tarball)
    sysbox-ce/                  # sysbox-mgr / sysbox-fs from the CE .deb
  hosts/                        # ONLY hosts we manage centrally (see .gitignore)
    _appliance-iso/         # `_appliance-iso` host: ephemeral appliance ISO; no disko/facter/hardware-config
                            #   build: make appliance/iso (or appliance/iso/<arch>)
    _appliance-disk/        # `_appliance-disk` host: persistent qcow2/raw disk image (disko image builder)
                            #   build: make appliance/qcow2  |  make appliance/raw  (or .../<arch>)
    _installer-iso/         # `_installer-iso` host: installer ISO (ISO only; full GUI box for now)
                            #   build: make installer/iso (or installer/iso/<arch>)
    coder-thinkcentre/      # folder name = hostname; default.nix has a hardware-model header comment
      default.nix               # host module: imports facter/legacy + local.nix + thinkcentre-only services
      hardware-configuration.nix   # legacy fallback (used until facter.json exists)
      facter.json               # OPTIONAL nixos-facter report; supersedes hardware-configuration.nix
      local.nix                 # gitignored: admin creds, secrets, SSH keys
      templates/
        nook-android/           # Dockerfile + main.tf; machine-specific
  coderd/
    main.tf                   # Coder template management (Terraform)
    templates/
      k3s-podman/             # main.tf + README.md
      k3s-sysbox/             # main.tf + README.md
      k3s-dev/                # main.tf + README.md
/etc/coder/session-token      # Coder API token for template sync (mode 600)
# Tailscale auth key lives in hosts/<host>/local.nix as authKey = "tskey-auth-…" (gitignored)
/var/lib/coder/               # Coder data dir (templates, workspaces, PVCs)
/var/lib/coder/template-sync/ # Terraform state for coderd/ templates
/var/lib/coder/nook-android-image.stamp  # Dockerfile hash — controls image rebuild
```
