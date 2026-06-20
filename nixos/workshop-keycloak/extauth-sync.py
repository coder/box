#!/usr/bin/env python3
"""
workshop-extauth-sync — copy each user's brokered GitHub token from Keycloak into
Coder's external_auth_links, so the workspace agent can fork/push/PR after a single
Keycloak login (GitHub broker, repo scope).

Runs on a timer on the box. Both Keycloak and Coder use the LOCAL Postgres, and
Coder's external_auth_links tokens are PLAINTEXT (no dbcrypt), so the copy is a
direct DB upsert — the same upsert validated end-to-end earlier.

Flow per Coder user (login_type=oidc):
  1. Find the Coder user's GitHub identity. We match Coder<->Keycloak<->GitHub by
     GitHub numeric id where possible, else by email.
  2. Get the brokered GitHub access token Keycloak stored for that user
     (Store Tokens=ON on the GitHub IdP).
  3. Upsert external_auth_links(provider_id='github', user_id=<coder user>) with it.
Throwaway (no GitHub identity) users are skipped.

Token source (TOKEN_SOURCE env):
  - "kcdb" (default): read Keycloak's own DB (federated_identity.token JSON) directly
    via psql. Most reliable server-side; no Keycloak session needed.
  - "rest": use Keycloak admin REST to enumerate federated identities (token still
    read from kcdb, since the broker/<p>/token endpoint needs a user session).

Env:
  CODER_PSQL_DSN     libpq DSN for the Coder DB   (default "dbname=coder host=/run/postgresql user=postgres")
  KC_PSQL_DSN        libpq DSN for the Keycloak DB(default "dbname=keycloak host=/run/postgresql user=postgres")
  KC_REALM           Keycloak realm               (default "workshop")
  KC_GITHUB_ALIAS    GitHub IdP alias in Keycloak (default "github")
  PSQL_BIN           path to psql                 (default "psql")
  EXTAUTH_PROVIDER_ID Coder external-auth id      (default "github")
  TOKEN_SOURCE       "kcdb" | "rest"              (default "kcdb")
  DRY_RUN            "1" = log only, no writes
  DEBUG              "1" = verbose
"""

import os
import sys
import json
import subprocess

CODER_DSN = os.environ.get("CODER_PSQL_DSN", "dbname=coder host=/run/postgresql user=postgres")
KC_DSN = os.environ.get("KC_PSQL_DSN", "dbname=keycloak host=/run/postgresql user=postgres")
KC_REALM = os.environ.get("KC_REALM", "workshop")
KC_GITHUB_ALIAS = os.environ.get("KC_GITHUB_ALIAS", "github")
PSQL_BIN = os.environ.get("PSQL_BIN", "psql")
EXTAUTH_PROVIDER_ID = os.environ.get("EXTAUTH_PROVIDER_ID", "github")
TOKEN_SOURCE = os.environ.get("TOKEN_SOURCE", "kcdb")
DRY_RUN = os.environ.get("DRY_RUN", "0") == "1"
DEBUG = os.environ.get("DEBUG", "0") == "1"


def log(*a):
    print("[extauth-sync]", *a, file=sys.stderr, flush=True)


def dbg(*a):
    if DEBUG:
        log("DEBUG", *a)


def psql(dsn, sql):
    """Run SQL via psql against the given DSN. Returns (rc, stdout, stderr)."""
    args = [PSQL_BIN, dsn, "-v", "ON_ERROR_STOP=1", "-Atq"]
    p = subprocess.run(args, input=sql, capture_output=True, text=True)
    return p.returncode, p.stdout.strip(), p.stderr.strip()


def psql_rows(dsn, sql, sep="\x1f"):
    """Run SQL and return rows as lists of columns, using a field separator."""
    args = [PSQL_BIN, dsn, "-v", "ON_ERROR_STOP=1", "-At", "-F", sep]
    p = subprocess.run(args, input=sql, capture_output=True, text=True)
    if p.returncode != 0:
        log("psql error:", p.stderr.strip())
        return None
    rows = []
    for line in p.stdout.splitlines():
        if line == "":
            continue
        rows.append(line.split(sep))
    return rows


def sql_lit(s):
    return "'" + str(s).replace("'", "''") + "'"


# ── Keycloak side: brokered GitHub identities + tokens ──────────────────────────
def keycloak_github_identities():
    """
    Return list of dicts: {kc_user_id, github_user_id, github_login, email, token}
    for users in KC_REALM who have a federated GitHub identity with a stored token.

    Keycloak schema (v2x): federated_identity(identity_provider, user_id, realm_id,
    federated_user_id, federated_username, token TEXT). token is the broker token
    JSON ({"access_token":...,"token_type":...,"scope":...}) when Store Tokens=ON.
    user_entity(id, email, realm_id). The github numeric id == federated_user_id.
    """
    sql = f"""
SELECT fi.federated_user_id,
       coalesce(fi.federated_username,''),
       coalesce(ue.email,''),
       coalesce(fi.token,'')
FROM federated_identity fi
JOIN user_entity ue ON ue.id = fi.user_id
JOIN realm r ON r.id = ue.realm_id
WHERE r.name = {sql_lit(KC_REALM)}
  AND fi.identity_provider = {sql_lit(KC_GITHUB_ALIAS)};
"""
    rows = psql_rows(KC_DSN, sql)
    if rows is None:
        return []
    out = []
    for r in rows:
        fed_id, fed_user, email, tokraw = (r + ["", "", "", ""])[:4]
        access_token = ""
        if tokraw:
            try:
                access_token = json.loads(tokraw).get("access_token", "")
            except Exception:
                # Some KC versions store the raw token string, not JSON.
                access_token = tokraw if tokraw.startswith(("gho_", "ghu_", "ghp_")) else ""
        out.append({
            "github_user_id": fed_id,
            "github_login": fed_user,
            "email": email.lower(),
            "token": access_token,
        })
    return out


# ── Coder side: resolve user_id + upsert external_auth_links ────────────────────
def coder_user_id_by_github_id(github_user_id):
    if not github_user_id:
        return ""
    try:
        gid = int(github_user_id)
    except ValueError:
        return ""
    rc, out, err = psql(CODER_DSN,
        f"SELECT id::text FROM users WHERE github_com_user_id = {gid} AND deleted = false LIMIT 1;")
    return out.strip() if rc == 0 else ""


def coder_user_id_by_email(email):
    if not email:
        return ""
    rc, out, err = psql(CODER_DSN,
        f"SELECT id::text FROM users WHERE lower(email) = {sql_lit(email)} AND deleted = false LIMIT 1;")
    return out.strip() if rc == 0 else ""


def upsert_external_auth(user_id, access_token):
    prov = sql_lit(EXTAUTH_PROVIDER_ID)
    uid = sql_lit(user_id)
    at = sql_lit(access_token)
    sql = f"""
INSERT INTO external_auth_links
  (provider_id, user_id, created_at, updated_at,
   oauth_access_token, oauth_refresh_token, oauth_expiry,
   oauth_refresh_failure_reason)
VALUES
  ({prov}, {uid}, now(), now(), {at}, '', (now() + interval '100 years'), '')
ON CONFLICT (provider_id, user_id) DO UPDATE SET
  updated_at = now(),
  oauth_access_token = EXCLUDED.oauth_access_token,
  oauth_access_token_key_id = NULL,
  oauth_refresh_token_key_id = NULL,
  oauth_refresh_failure_reason = '';
"""
    rc, out, err = psql(CODER_DSN, sql)
    if rc != 0:
        log("upsert error:", err)
        return False
    return True


def main():
    identities = keycloak_github_identities()
    log(f"found {len(identities)} GitHub-brokered Keycloak identities in realm {KC_REALM}")
    synced = skipped = failed = 0
    for ident in identities:
        if not ident["token"]:
            dbg("no stored token for", ident["github_login"], "- skip (Store Tokens off or no login yet)")
            skipped += 1
            continue
        uid = coder_user_id_by_github_id(ident["github_user_id"]) or coder_user_id_by_email(ident["email"])
        if not uid:
            dbg("no Coder user for", ident["github_login"], ident["email"], "- skip")
            skipped += 1
            continue
        if DRY_RUN:
            log(f"DRY_RUN would set external-auth for {ident['github_login']} -> coder {uid}")
            synced += 1
            continue
        if upsert_external_auth(uid, ident["token"]):
            log(f"synced external-auth for {ident['github_login']} -> coder {uid}")
            synced += 1
        else:
            failed += 1
    log(f"done: synced={synced} skipped={skipped} failed={failed}")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
