# AGENTS.system.md — operating this box (making the sausage)

Admin-facing notes for whoever (human or agent) runs **coderbox** — the NixOS
demo box and its Coder deployment, the Wall of Names workshop, and the AI
agents. This is the hard-won "how it actually works" doc; read it before poking
at the live system.

> Companion docs: the repo-root `agents.md` (general box guide) and
> `coder-contrib/name-wall/AGENTS.md` (attendee-facing wall mechanics). This
> file is the *operator* layer.

---

## The box at a glance

- Host: **coderbox** (NixOS). Reach it: `ssh coderbox@coderbox.local`
  (password auth). `.local` is mDNS and can drop — if it stops resolving, the
  box likely **suspended** (see below) or rebooted.
- Coder server: OSS **v2.33.1**, on `:3000`, behind a `*.try.coder.app`
  tunnel. Dashboard URL is in `coder/box` motd and the deployment config.
- Repo baked at **`/etc/nixos-repo`** (a Nix flake). Apply changes with
  `sudo nixos-rebuild switch --flake /etc/nixos-repo`.
  - **Gotcha:** do NOT use `--flake /etc/nixos` — that dir holds only a
    `flake.nix` symlink and Nix can't find the sibling files. Always
    `--flake /etc/nixos-repo`.
- Admin token: `/etc/coder/session-token` (root-readable). Most admin API/CLI
  calls below use `TOK=$(sudo cat /etc/coder/session-token)`.
- Secrets live in **`hosts/coderbox/local.nix`** (gitignored): Coder admin
  creds, GitHub OAuth client id/secret, and the **Anthropic API key**. Never
  commit these.

## Hard-won gotchas (read these first)

- **Suspend/hibernate takes the box off the network.** A desktop "Sleep",
  power key, or `systemctl suspend` drops the NIC → no mDNS/SSH/tunnel until
  someone wakes it. We have a PR to mask suspend/hibernate; if the box vanishes
  mid-demo, this is the first suspect. Don't let it idle-sleep on stage.
- **`coder-reset` wipes the database.** It re-bootstraps admin + templates, but
  it also drops anything stored only in the DB — **the AI provider key, models,
  and chat system prompt** (see "AI agents" below) are DB state and get wiped.
  Re-seed them after a reset (there is no NixOS oneshot for this yet — TODO).
- **`/api/v2/...` vs `/api/experimental/...`.** The AI/chat/models feature is
  under **`/api/experimental/chats/...`**, NOT `/api/v2`. Guessing `v2` paths
  wastes time (everything 404s). AI Bridge (`/api/v2/aibridge/...`) is a
  **Premium** feature and returns "Contact sales!" on this OSS box — don't use
  it. The experimental chats API is the working path.
- **Workspace pods reach Coder at `http://10.42.0.1:3000`, not localhost.**
  Anything running inside a workspace pod (serve.js activity/queue polling,
  curl to the API) must use the in-pod address `10.42.0.1:3000`. `localhost`
  in a pod is the pod itself.
- **The agent's tool cwd is `/root`, not the workspace `$HOME`.** Chat-agent
  file tools default to `/root`; the repo is at `/home/node/name-wall`. Always
  use absolute `/home/node/...` paths in agent instructions or tools hit
  "permission denied". This is baked into the workshop system prompt.
- **`kubectl exec` + backgrounding kills the exec.** Starting `node serve.js &`
  inside `kubectl exec` often SIGTERMs the whole exec (RC 143). Start detached
  in its own exec: `nohup env ... node serve.js >log 2>&1 & disown; sleep 2`,
  then verify from a *separate* exec. And `pkill -f serve.js` can kill the exec
  shell too — match more narrowly or kill by pid.
- **No `python3` on the box host** (there is in workspace pods). For host-side
  text munging, edit files on thinkstation and `scp`, or use `node`.
- **Template version names must be unique.** `coderd` template-sync fails with
  409 if you reuse a `version_name`. Use a timestamp (`ws-$(date +%H%M%S)`).
- **`coder external-auth` only works inside a workspace** (needs
  `CODER_AGENT_URL`); it errors on the host CLI. The agent's `coder` binary in
  a pod is at `/tmp/coder.*/coder` but is NOT logged in as a CLI, so
  `coder tokens create` fails there — generate tokens from the dashboard or use
  `/etc/coder/session-token` on the host.

## Templates (coderbox-specific)

Demo templates live under **`hosts/coderbox/templates/`** and are host-gated in
`coderd/main.tf` with `count = local.is_coderbox ? 1 : 0` (mirrors how
`nook-android` is gated to `coder-thinkcentre`). Current set:

- `workshop` — **Workshop: Wall of Names** (the live demo; forks
  `coder-contrib/name-wall`, agent-driven).
- `data-science` — JupyterLab + Python via the `coder/jupyterlab` registry module.
- `kindleframe-onboard` — onboard to the private `bpmct/kindleframe-server`
  (uses GitHub external-auth to clone a private repo).

Shared templates (`coder-cli`, `k3s-podman`, `k3s-sysbox`, `k3s-dev`) live in
`coderd/templates/` and got audience-facing display names ("Universal Golden
Path", "Isolated Docker Path", etc.).

**Deploy a template change** (template-sync, what `nixos-rebuild` runs):
```sh
sudo bash -c '
  TOK=$(cat /etc/coder/session-token); VER=ws-$(date +%H%M%S)
  export TF_CLI_CONFIG_FILE=$(find /nix/store -maxdepth 1 -name "*terraformrc-coderd" | head -1)
  cd /etc/nixos-repo/coderd; export TF_DATA_DIR=/var/lib/coder/template-sync/.terraform
  terraform apply -auto-approve -no-color \
    -var=coder_url=http://localhost:3000 -var=coder_session_token=$TOK \
    -var=hostname=coderbox -var=version_name=$VER -var=coder_lan_ip=
'
```
Validate a single template before deploying: copy its `main.tf` into a temp dir
and `terraform init -backend=false && terraform validate`. HCL gotcha:
single-line blocks can't have two args (`option { name=.. value=.. }` must be
multi-line); and `%{...}` in a heredoc is a Terraform template directive —
escape literal `%` as `%%`.

## Auth wiring

- **GitHub login (any user):** `CODER_OAUTH2_GITHUB_*` in `local.nix`
  (`ALLOW_EVERYONE=true`, `DEFAULT_PROVIDER_ENABLE=true`). The OAuth app's
  callback is pinned to the **current tunnel URL** — a `coder-reset`/tunnel
  change breaks login until the callback is updated in the GitHub OAuth app.
- **GitHub external-auth (private clones, fork+push):** device-flow via the
  built-in default provider. Each user authorizes once at
  `<tunnel>/external-auth/github`. Needed for the workshop fork flow and the
  `kindleframe-onboard` private clone.
- **"Coder Agents User" role:** new GitHub logins land with no org role. The
  custom org role **`agents-access`** grants agent/CLI use. The role bot
  (below) auto-assigns it.

## AI agents (the chats/models setup)

Configured via the **experimental chats API** (no AI Bridge, no per-user keys):

- **Provider:** Anthropic, enabled, key from `local.nix`. Created via
  `POST /api/experimental/chats/providers`
  `{provider:"anthropic", api_key, enabled:true, central_api_key_enabled:true}`.
- **Model:** `claude-sonnet-4-6` (default). Created via
  `POST /api/experimental/chats/model-configs`
  `{provider:"anthropic", model:"claude-sonnet-4-6", display_name, enabled:true, is_default:true, context_limit:200000}`.
  Verify real model ids against `curl https://api.anthropic.com/v1/models`
  with the key — don't guess dated identifiers.
- **System prompt (deployment-wide):**
  `PUT /api/experimental/chats/config/system-prompt`
  `{include_default_system_prompt:true, system_prompt:"..."}`. Ours is the
  workshop "promoter": guides "make my name X" → fork → edit
  `/home/node/name-wall/names/<handle>.json` (rich html+css) → preview → PR.
- Sanity check a turn: `POST /api/experimental/chats`
  `{organization_id, content:[{type:"text",text:"reply OK"}], client_type:"api"}`,
  wait ~12s, read `/api/experimental/chats/{id}/messages`.
- **All of this is DB state → wiped by `coder-reset`.** Re-seed after a reset.
- Tasks UI is hidden via `CODER_HIDE_AI_TASKS=true` (in `configuration.nix`).

## The Wall of Names workshop (full loop)

Repo: **`coder-contrib/name-wall`** (public). One file per attendee:
`names/<handle>.json`. Each name renders as a **sandboxed `<iframe srcdoc>`**
card — a full HTML/CSS canvas (animations/movement/components), **CSS only, no
scripts/external loads** (the sandbox enforces it; this is the safety model for
a projected shared screen). Legacy `{name, color}` still works.

The loop: attendee logs in (any GitHub) → role bot grants `agents-access` →
they tell the agent "make my name a cookie" → agent forks the repo, writes
their JSON, shows the preview, opens a PR from their fork → admin merge bot
auto-approves + squash-merges → name lights up on the projected wall.

**Admin side — one command** (run in the admin workspace, e.g. `olive-locust-63`):
```sh
cd ~/name-wall && ./bot/wall-of-fame.sh
# open http://localhost:8080/?admin full-screen and screen-share it
```
`wall-of-fame.sh` runs: `serve.js` (the wall + `/api/active` + `/api/pending`),
the **merge bot** (auto-approve+merge `names/*.json` PRs, queue order), and a
`git pull` loop pinning the display to merged `main`. It exports a Coder token
(active-now pill) and `gh auth token` (PR queue + merges).

Other bot scripts in `name-wall/bot/`:
- `role-bot.sh` — poll members, grant `agents-access` to new logins (needs an
  owner/org-admin token; `CODER_URL=http://10.42.0.1:3000` in a pod).
- `merge-bot.sh` — standalone auto-merge (also launched by wall-of-fame).

**Wall display details:**
- Admin mode + the green "active now" pill auto-enable when the server has a
  Coder token (`/api/active` available) — not via a URL flag (the app-proxy URL
  drops query params). Hover the pill → "Admin · Wall of Fame".
- **Scales to many names:** `#wall` is an auto-fit grid with density tiers
  (cozy→medium→dense→packed→huge) set from the live count, and each iframe is a
  320×200 canvas scaled to its card via ResizeObserver. 100+ names stay on one
  screen, no scroll. serve.js reads the dir per request (~2ms at 80 names).
- **Rendering uses DOM diffing** (names and the PR queue) — never `innerHTML=""`
  + rebuild, or you get flicker (learned this twice). New items animate once;
  existing ones stay put; gone ones are removed.

## Editing the wall app

Live checkout is in the admin workspace at `/home/node/name-wall`. Edit on
GitHub or in the workspace, push to `coder-contrib/name-wall:main`,
`git pull` on the admin checkout (the wall-of-fame loop does this automatically
within seconds). The Coder **brand design system** is applied (Lay Grotesk +
FT System Mono fonts bundled as woff2, logo, ink/electric-purple palette);
serve.js needs the `.svg`/`.woff2` MIME types (already added) or assets 404.

## TODO / known gaps

- **NixOS oneshot to re-seed AI config** (provider key + model + system prompt)
  and the wall templates after `coder-reset`/reboot — currently manual.
- Rotate the Anthropic key + GitHub OAuth secret after the workshop (they've
  passed through chat history).
- At the `huge` density tier intricate name art is tiny on a projector;
  consider a spotlight/rotation if counts get very large.
