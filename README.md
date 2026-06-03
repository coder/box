# coder-nixos

NixOS configuration for Coder demo and workshop boxes.

> **Demo box setup**. This repo configures one or more single-purpose physical machines running Coder + k3s as self-contained workshop and demo environments. It is intentionally simple: no HA, no remote state, no cloud provider. Each machine's secrets (IPs, auth keys, passwords) live in a per-host gitignored `hosts/<host>/local.nix` file. Each box runs a Coder server, k3s (single-node), and a set of workspace templates managed by Terraform via the `coderd` provider.

## Machines

| Hostname | Hardware | LAN IP | Tailscale IP | Status |
|---|---|---|---|---|
| `coder-thinkcentre` | Lenovo ThinkCentre M70q Gen 2 | n/a | n/a | active |

## Repo Structure

```
flake.nix                  # entry point: nixosConfigurations.<host> per machine
flake.lock                 # pinned nixpkgs / disko / nixos-facter-modules
configuration.nix          # shared NixOS config (all machines)
local.nix.example          # template copied to hosts/<host>/local.nix by install.sh
.gitignore                 # ignores hosts/*/local.nix
nixos/
  install.sh               # one-shot installer: disko + nixos-install + bake /etc/nixos-repo
  disko-standard.nix       # shared disko config: 1 GB EFI + 16 GB swap + ext4 root on a single disk
  tailscale.nix            # Tailscale module (auth key, no --ssh flag)
  k3s-sysbox.nix           # k3s + sysbox-runc runtime class
  k3s-podman.nix           # k3s + rootless Podman socket
  screenconnect.nix        # optional ScreenConnect remote access client
pkgs/
  coder.nix                # custom Coder server package
  coderd-provider.nix      # terraform-provider-coderd package
hosts/
  coder-thinkcentre/       # folder name = hostname; default.nix has a header comment with hardware model
    default.nix            # host module: imports facter/legacy hardware-config + local.nix
    hardware-configuration.nix  # legacy nixos-generate-config output (fallback)
    facter.json            # OPTIONAL: nixos-facter hardware report; supersedes hardware-configuration.nix
    local.nix              # gitignored: admin creds, secrets, SSH users
    templates/
      nook-android/        # Workspace: build trmnl-nook-simple-touch APK
coderd/
  main.tf                  # manages all Coder templates via coderd Terraform provider
  templates/
    coder-cli/             # Workspace: oss-dogfood image (docker CLI, terraform, gh, go, node, etc.)
    k3s-podman/            # Workspace: k3s + rootless Podman Docker socket
    k3s-sysbox/            # Workspace: k3s + sysbox-runc, full Docker-in-workspace
    k3s-dev/               # Workspace: language demo (python, node, go, java, rust)
```

This repo is a Nix flake. `flake.nix` auto-discovers every subdirectory of
`./hosts/` that contains a `default.nix` and exposes it as
`nixosConfigurations.<folder-name>`. The folder name is the hostname, so
`nixos-rebuild switch --flake .` auto-selects the right config on the
running box. Adding a new host means creating a host folder, no flake.nix
edit. The installer does this for you.

Two community tools do the heavy lifting:

- [`disko`](https://github.com/nix-community/disko) declares partition layouts in Nix. `nixos/disko-standard.nix` is a single-disk UEFI layout (1 GB EFI / 16 GB swap / ext4 root). `install.sh` picks the device at install time.
- [`nixos-facter`](https://github.com/nix-community/nixos-facter) writes a JSON hardware report (`facter.json`) that replaces `hardware-configuration.nix` on new hosts. The `nixos-facter-modules` module reads it to set kernel modules, microcode, GPU drivers, and so on.

## Installing on a new machine

From a NixOS live USB on the target box, with network access (any reasonably recent ISO from [nixos.org](https://nixos.org/download/) works; the installed system pins its own nixpkgs in `flake.lock` independent of what the USB is running):

```sh
nix-shell -p git --run "git clone https://github.com/bpmct/coder-nixos /tmp/coder-nixos"
cd /tmp/coder-nixos
sudo ./nixos/install.sh
```

The installer prompts for a target disk. Anything else not passed as a flag falls back to a default: hostname `coder-nixos`, Coder admin `admin@coder.com` / `PleaseChangeMe1234`, OS login `coderbox` / `PleaseChangeMe1234`. Passwords in the summary are obfuscated, unless they are left as defaults.

For a fully unattended install, pass every value as a flag:

```sh
sudo ./nixos/install.sh \
  --hostname coder-demo \
  --disk /dev/nvme0n1 \
  --coder-admin-email you@example.com \
  --coder-admin-password 'changeme' \
  --nixos-username coderbox \
  --nixos-password 'changeme' \
  --yes
```

`./nixos/install.sh --help` lists everything. `--coder-admin-password-file PATH` and `--nixos-password-file PATH` read passwords from a file so they don't end up in shell history. `--no-reboot` skips the automatic reboot at the end.

The installer generates `hosts/<hostname>/{default.nix,local.nix,facter.json}`, copies the repo into `/etc/nixos-repo` on the target, and symlinks `/etc/nixos/flake.nix`. After reboot, `nixos-rebuild switch` Just Works. Continue with [After install](#after-install).

> **Different partition layout?** Don't import `nixos/disko-standard.nix`; drop your own disko config into the host folder instead. See [disko examples](https://github.com/nix-community/disko/tree/master/example).

> **BIOS hardware?** The shared config defaults to `systemd-boot` (UEFI). In your host's `default.nix`:
> ```nix
> boot.loader.systemd-boot.enable = false;
> boot.loader.grub = { enable = true; device = "/dev/sda"; };
> ```
> And use a BIOS-compatible disko layout instead of `disko-standard.nix`.

## After install

The installer auto-creates the admin user, mints a long-lived API token to
`/etc/coder/session-token`, and deploys the workspace templates on first
boot via `coder-init-admin.service`. After the reboot:

1. Find the box at `http://<your-hostname>.local:3000`, or look up the
   `*.try.coder.app` tunnel URL in `/etc/motd` on the box (also tailed to
   the console on each SSH login).
2. Log in with the Coder admin email and password set at install time
   (defaults: `admin@coder.com` / `PleaseChangeMe1234`).
3. Change the admin password from the user settings page if you used the
   defaults.

Subsequent edits to `coderd/` templates go out via `coder-template-sync`
on every `sudo nixos-rebuild switch`.

## Applying changes

```sh
sudo nixos-rebuild switch                    # most changes
sudo nixos-rebuild boot && sudo reboot       # changes that touch the desktop stack

# Edited hosts/<host>/local.nix or facter.json? Re-mark intent-to-add:
sudo git -C /etc/nixos-repo add --intent-to-add -f \
  hosts/<host>/local.nix \
  hosts/<host>/facter.json
```

## Updating nixpkgs / disko / facter

```sh
sudo nix flake update --flake /etc/nixos-repo
sudo nixos-rebuild switch
```

This bumps `flake.lock` to the latest of each input.

## Workspace Templates

### coder-cli
Full-featured CLI/dev workspace running the `codercom/oss-dogfood` image (Ubuntu + docker CLI, terraform, gh, go, node, etc.). No sysbox or inner Docker daemon; uses the host's runtime.

### k3s-sysbox
Full Docker-in-workspace via sysbox-runc. Each workspace gets an isolated Docker daemon. No privileged mode on the host.

### k3s-podman
Docker-compatible socket via host rootless Podman. Simpler than sysbox; no inner daemon. `docker` CLI works via `DOCKER_HOST`.

### k3s-dev
Language demo workspaces. Pick Python/Node.js/Go/Java/Rust at creation; a real demo app auto-starts (FastAPI, Next.js, Pagoda, Spring PetClinic, rustypaste).

### nook-android *(thinkcentre only)*
Dev environment for building the [trmnl-nook-simple-touch](https://github.com/usetrmnl/trmnl-nook-simple-touch) APK for the Barnes & Noble Nook Simple Touch. Uses a pre-built image (`localhost/nook-android:latest`) loaded into k3s by the `nook-android-image-build` NixOS service. 32-bit ADT tools run transparently via qemu-i386 binfmt.

## Key Services

| Service | Description |
|---|---|
| `coder.service` | Coder server on port 3000 |
| `postgresql.service` | Local PostgreSQL for Coder |
| `k3s.service` | Single-node k3s (sysbox-runc runtime) |
| `tailscaled` + `tailscale-autoauth` | Tailscale (auth key in `hosts/<host>/local.nix`) |
| `nook-android-image-build` | Builds/imports nook-android image into k3s containerd |
| `coder-sync-ssh-keys` | Fetches SSH keys from GitHub on boot |
| `screenconnect-install` | Downloads and installs ScreenConnect client (oneshot) |
| `screenconnect` | ScreenConnect remote access daemon |
| `coder-redirect.service` | HTTP 302 redirect: port 80 → live `*.try.coder.app` tunnel URL |

## Reset / Full Wipe

Encoded as a NixOS systemd service. No manual steps needed.

```sh
sudo systemctl start coder-reset
```

Fully automated, no follow-up steps needed. The service:

1. Stops Coder, coder-redirect
2. Force-deletes all workspace pods and PVCs from k3s
3. Drops and recreates the PostgreSQL database
4. Wipes `/var/lib/coder` (data dir, sentinel, tokens, Podman volumes)
5. Starts Coder and waits for the API
6. Re-bootstraps the admin user from credentials in the host's `local.nix`
7. Mints a fresh long-lived session token → writes to `/etc/coder/session-token`
8. Restarts `coder-redirect`
9. Runs `nixos-rebuild switch` to push templates back via `coder-template-sync`

### Changing the admin password

1. Edit `hosts/<host>/local.nix`, update `CODER_ADMIN_PASSWORD`.
2. Run `sudo nixos-rebuild switch` to bake the new password into the service.
3. Run `sudo systemctl start coder-reset` to wipe and re-bootstrap with the new password.

> If you need to change the password on a **live** deployment without a full wipe:
> ```sh
> TOKEN=$(curl -sf -X POST http://localhost:3000/api/v2/users/login \
>   -H 'Content-Type: application/json' \
>   -d '{"email":"admin@coder.com","password":"<OLD>"}' | jq -r '.session_token')
> curl -sf -X PUT http://localhost:3000/api/v2/users/me/password \
>   -H "Coder-Session-Token: $TOKEN" \
>   -H 'Content-Type: application/json' \
>   -d '{"old_password":"<OLD>","password":"<NEW>"}'
> ```

## Notes

- Steps 1 to 4 run while Coder is stopped so the provisioner can't re-create pods mid-wipe; the systemd service handles the stop and restart.
- If the admin password changed before a reset and the user already exists in Postgres (rare; the wipe drops the DB), update via the API instead of `coder-reset`:
  ```sh
  TOKEN=$(curl -sf -X POST http://localhost:3000/api/v2/users/login \
    -H 'Content-Type: application/json' \
    -d '{"email":"admin@coder.com","password":"<OLD_PASSWORD>"}' \
    | jq -r '.session_token')
  curl -sf -X PUT http://localhost:3000/api/v2/users/me/password \
    -H "Coder-Session-Token: $TOKEN" \
    -H 'Content-Type: application/json' \
    -d '{"old_password":"<OLD_PASSWORD>","password":"<NEW_PASSWORD>"}'
  ```
- Rootless Podman volumes live under `/var/lib/coder/.local/...`; `rm -rf /var/lib/coder/*` in step 4 clears these too.
- k3s PVs backed by `local-path-provisioner` live under `/var/lib/rancher/k3s/storage/`; `kubectl delete pvc` in step 2 triggers their cleanup.

## Repo notes

- `hosts/<host>/local.nix` is gitignored. Never commit secrets or machine-specific overrides.
- The `coderd/` Terraform state is stored in `/var/lib/coder/template-sync/` on the box, not in the repo.
- `CODER_ACCESS_URL` is intentionally unset; Coder auto-creates a `*.try.coder.app` tunnel on startup. `http://<hostname>.local` (port 80) redirects to the live tunnel URL via `coder-redirect.service`, which also writes the URL to `/etc/motd` so it shows on every console and SSH login.
- The `coder` user (uid 991) runs Coder server and rootless Podman. UID is pinned; do not change.
- Workspace pods resolve `<hostname>.local` via a `hostAliases` entry pointing to the LAN IP (set via `services.coder-nixos.lanIp` in the host's `local.nix`).
