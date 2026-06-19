# Workshop auth/tunnel plan (Keycloak single-click + Cloudflare apex)

This document lives with the box definition so the design + status travel with the
NixOS repo. It covers the optional workshop-auth stack:
  nixos/workshop-tunnel.nix     (Cloudflare Tunnel apex + single-click middleware, alt path)
  nixos/workshop-keycloak.nix   (Keycloak OIDC IdP + extauth-sync watcher)
  nixos/workshop-extauth-sync.py (copy brokered GitHub token -> Coder external_auth_links)
  nixos/workshop-realm.json      (Keycloak realm template)
All OFF by default; enable in hosts/<host>/local.nix.

## Goal (final, locked)
- ONE login click. Attendee picks "GitHub" OR a local throwaway account on Keycloak.
- GitHub users automatically get a repo-scoped external-auth token in Coder (so the
  agent can fork/push/PR) — no second consent.
- Throwaway users log in + use the agent UI but can't push (expected; no GitHub).

## Why Keycloak (recap of the dead ends)
- Coder GitHub LOGIN scopes are HARDCODED ["read:user","read:org","user:email"]
  (cli/server.go) — no `repo`, not configurable. So copying user_links ->
  external_auth_links yields a scope-less token. Dead end for the copy trick.
- Coder exposes oidc_access_token to templates ONLY for login_type=oidc
  (ObtainOIDCAccessToken filters LoginTypeOIDC). GitHub login != oidc. Dead end.
- => Need a flow that REQUESTS `repo`. Keycloak's GitHub broker can (Default
  Scopes=repo, Store Tokens=on) AND gives the throwaway-account option.

## Architecture
Cloudflare apex (stable): dallas.cdr.dev + *.dallas.cdr.dev  (required so Keycloak
  redirect URIs + the GitHub OAuth callback are stable across networks/restarts).

Keycloak (NixOS systemd services.keycloak; keycloak-26.5.7 in nixpkgs):
  - realm "workshop" (nixos/workshop-realm.json)
  - Identity Provider: GitHub broker
      clientId/secret = a GitHub OAuth App
        (callback = {kc}/realms/workshop/broker/github/endpoint)
      Default Scopes  = "repo read:org user:email"   (gets a repo token)
      Store Tokens    = ON                            (Keycloak keeps the gh token)
  - Local registration enabled (throwaway username/password accounts)
  - OIDC client "coder" (confidential) for Coder login
  - Hosted on the EXISTING local Postgres (own keycloak DB/role; createLocally=false)

Coder (env): switch login from CODER_OAUTH2_GITHUB_* to OIDC:
  CODER_OIDC_ISSUER_URL   = https://dallas.cdr.dev/auth/realms/workshop
  CODER_OIDC_CLIENT_ID    = coder
  CODER_OIDC_CLIENT_SECRET= <coder client secret>
  CODER_OIDC_SCOPES       = openid profile email
  CODER_OIDC_SIGN_IN_TEXT / allow-signups, etc.
  Keep an external-auth provider "github" defined so the access-token API works
  (CODER_EXTERNAL_AUTH_0_* or the default provider), even though the TOKEN itself
  is injected by the watcher rather than obtained via the external-auth flow.

extauth-sync watcher (the only glue; reuses the proven plaintext upsert):
  - systemd timer (every 30s). Reads Keycloak's federated_identity token store for
    realm "workshop", provider "github", parses the brokered access_token, and
    UPSERTs external_auth_links(provider_id=github, user_id) in Coder.
  - Maps Keycloak user -> Coder user by GitHub numeric id (users.github_com_user_id)
    then email. Throwaway users (no github identity) skipped.
  - Both DBs are local Postgres; external_auth_links tokens are PLAINTEXT (no
    dbcrypt), so the upsert is a direct DB write (validated end-to-end: inject ->
    `coder external-auth access-token github` returns it with repo scope).

## Hosting decision
- Keycloak via NixOS systemd (services.keycloak), DB on the EXISTING local Postgres.
  Cleaner than a k3s pod (no ingress, no container image); matches Coder+PG.

## Status (2026-06-18)
DONE (committed, all OFF by default — no live impact yet):
- nixos/workshop-tunnel.nix: cloudflared (token mode) + transparent/auth middleware.
  Middleware proxy validated against live Coder; injection upsert validated against
  the live DB; unit tests green. (Middleware is an ALT path; Keycloak is primary.)
- nixos/workshop-keycloak.nix: services.keycloak on local PG + extauth-sync timer.
- nixos/workshop-extauth-sync.py: watcher, unit-tested 17/17.
- nixos/workshop-realm.json: realm template (placeholders only, no secrets).
- keycloak-26.5.7 + python3 confirmed buildable in flake nixpkgs; flake evals clean.

REMAINING (need user secrets / CF access):
1. CF tunnel token -> bring up the apex (dallas.cdr.dev + wildcard).
2. GitHub OAuth App for the Keycloak broker
   (callback https://dallas.cdr.dev/auth/realms/workshop/broker/github/endpoint).
3. Realm import service (kcadm) that fills the realm-template placeholders from
   local.nix at activation.
4. Coder OIDC env switch; disable github-login default providers; keep external-auth
   provider "github" for the access-token API.
5. Bring up + verify: login choice (login_type=oidc), watcher populates
   external_auth_links, `coder external-auth access-token github` returns repo token.

## Prereqs from user
- CF tunnel token (pending CF access approval).
- GitHub OAuth App (Keycloak broker callback above) -> client id + secret.
- Passwords in local.nix (gitignored): Keycloak DB password, KC admin password,
  coder OIDC client secret.

## Reversibility
- Everything is gated by `services.workshop-keycloak.enable` /
  `services.workshop-tunnel.enable` in local.nix + the Coder env. Reverting local.nix
  + configuration.nix and `nixos-rebuild switch` restores the current GitHub-login
  (2-click) deployment.
