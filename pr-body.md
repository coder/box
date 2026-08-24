Closes #61.

## What

Surface the live Coder access URL (`*.try.coder.app` tunnel) in **any terminal on login**, not just PAM sessions.

Previously `coder-redirect.service` wrote the URL to `/etc/motd`, which only shows on SSH/console logins via `pam_motd` — a local desktop terminal never saw it.

## How

- `coder-redirect.service` now caches the discovered tunnel URL to `/tmp/coder-access-url` (`chmod 0644`) instead of writing `/etc/motd`. It `rm -f`s the file at the top of `ExecStart`, so the stale URL is cleared on every boot and on every service restart until the live URL is rediscovered. Both the cleanup and the write are best-effort (`|| true`) so a `/tmp` hiccup can't trip `set -euo pipefail` and restart-loop the redirect.
- New `environment.interactiveShellInit` prints an `Access URL` / `Local` / `Redirect` banner by reading that file — no network access. An exported `CODER_ACCESS_URL_SHOWN` guard keeps nested shells from reprinting it within a session. This covers local GNOME terminals, console TTYs, and SSH from one place.
- Docs updated (`README.md`, `hosts/incus-vm/README.md`, `install.sh`) to point at the terminal banner / `/tmp/coder-access-url` instead of `/etc/motd`.

The large `configuration.nix` diff is mostly `nixfmt` renormalizing the `coder-redirect` script: removing the heredoc left the block uniformly indented, so the formatter re-based it to the canonical column.

## Verification

Ran in a workspace with the repo's own toolchain (`nix fmt` = treefmt: nixfmt/statix/deadnix/shfmt/shellcheck):

- `nix fmt` idempotent (0 changed)
- `shellcheck install.sh` clean
- `nixosConfigurations._appliance-iso` evaluates; built `coder-redirect` script and rendered `interactiveShellInit` inspected — escaping and `|| true` guards land correctly
- Ran the banner snippet: prints once, guard suppresses the repeat

Not build/boot-tested on real hardware (needs a box).

<details>
<summary>Implementation notes / decisions</summary>

- **Dropped `/etc/motd` entirely** rather than keeping it alongside the banner. Keeping both would double-print on SSH/console (pam_motd + shell banner); consolidating on the shell banner gives one source of truth that also works in desktop terminals. Console TTY and SSH still get the URL because their login shell sources the init.
- **`interactiveShellInit` vs `loginShellInit`**: GNOME Terminal opens a non-login interactive shell by default, so `loginShellInit`/`profile.d` wouldn't fire there. `interactiveShellInit` covers it; the exported guard prevents subshell spam.
- **Hostname** read at display time from `/proc/sys/kernel/hostname` (always present) to match the previous runtime `hostname` behavior rather than baking `networking.hostName` at eval time.
- **`/tmp` wipe**: relying on tmpfs-on-boot isn't guaranteed here, so the explicit `rm -f` in `ExecStart` (which runs on every boot and restart) is what satisfies "wipes on boot or restart of coder-redirect".

</details>

---
🤖 Opened by Coder Agents on behalf of @phorcys420.
