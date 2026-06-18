#!/usr/bin/env python3
"""
workshop-middleware — single-click GitHub auth front for Coder.

Sits in front of Coder (apex host only; wildcard app host goes straight to Coder).
By default it is a TRANSPARENT reverse proxy to Coder. It intercepts ONLY the
GitHub auth flow so that one GitHub consent satisfies BOTH:
  - Coder SSO login, and
  - Coder external-auth (a repo-scoped token written into external_auth_links).

Design (Variant 2a):
  * The GitHub OAuth App's single callback is THIS service: ${MW_PUBLIC_URL}/wm/cb
  * We rewrite Coder's login authorize-start so redirect_uri -> us and scope gains
    `repo`. The user consents ONCE.
  * On /wm/cb we receive the GitHub `code`. GitHub, having just been consented,
    will silently re-issue codes for the same app, so we:
       1. Exchange the received code -> a repo-scoped access token + gh user id.
       2. Upsert external_auth_links(provider_id='github', user_id) with that token.
       3. Kick a fresh (silent) GitHub authorize whose redirect_uri is Coder's REAL
          login callback, so Coder completes login with its own code as usual.
  * Everything else is proxied verbatim to Coder.

Dependencies: Python stdlib only. DB writes shell out to `psql` (PSQL_BIN), which
authenticates via peer auth as the `coder`/`postgres` role over the unix socket.

Env (all required unless noted):
  MW_LISTEN_ADDR        host:port to listen on            (default 127.0.0.1:8088)
  MW_PUBLIC_URL         public apex URL                   (e.g. https://dallas.cdr.dev)
  CODER_UPSTREAM        Coder base URL                    (default http://127.0.0.1:3000)
  GH_CLIENT_ID          OAuth App client id
  GH_CLIENT_SECRET      OAuth App client secret
  GH_SCOPES             space-separated scopes            (default "repo read:user user:email")
  EXTAUTH_PROVIDER_ID   external-auth provider id         (default "github")
  PSQL_BIN              path to psql                      (default "psql")
  PSQL_DSN              libpq DSN/conninfo for the coder db
                        (default "dbname=coder host=/run/postgresql user=coder")
  MW_DISABLE_INTERCEPT  if "1", pure transparent proxy (Step 2 testing)
  MW_DEBUG              if "1", verbose logging
"""

import os
import sys
import json
import time
import socket
import threading
import subprocess
import urllib.parse
import urllib.request
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ── config ────────────────────────────────────────────────────────────────────
LISTEN_ADDR = os.environ.get("MW_LISTEN_ADDR", "127.0.0.1:8088")
PUBLIC_URL = os.environ.get("MW_PUBLIC_URL", "").rstrip("/")
UPSTREAM = os.environ.get("CODER_UPSTREAM", "http://127.0.0.1:3000").rstrip("/")
GH_CLIENT_ID = os.environ.get("GH_CLIENT_ID", "")
GH_CLIENT_SECRET = os.environ.get("GH_CLIENT_SECRET", "")
GH_SCOPES = os.environ.get("GH_SCOPES", "repo read:user user:email")
EXTAUTH_PROVIDER_ID = os.environ.get("EXTAUTH_PROVIDER_ID", "github")
PSQL_BIN = os.environ.get("PSQL_BIN", "psql")
PSQL_DSN = os.environ.get("PSQL_DSN", "dbname=coder host=/run/postgresql user=coder")
DISABLE_INTERCEPT = os.environ.get("MW_DISABLE_INTERCEPT", "0") == "1"
DEBUG = os.environ.get("MW_DEBUG", "0") == "1"

# Coder's real OAuth endpoints (paths are stable in Coder v2).
CODER_LOGIN_CALLBACK = "/api/v2/users/oauth2/github/callback"
CODER_LOGIN_START = "/api/v2/users/oauth2/github/callback"  # GET here begins login
# The path GitHub will redirect back to on OUR side:
MW_CALLBACK_PATH = "/wm/cb"

GITHUB_AUTHORIZE = "https://github.com/login/oauth/authorize"
GITHUB_TOKEN = "https://github.com/login/oauth/access_token"
GITHUB_API_USER = "https://api.github.com/user"

HOP_BY_HOP = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailers", "transfer-encoding", "upgrade",
}


def log(*a):
    print("[workshop-mw]", *a, file=sys.stderr, flush=True)


def dbg(*a):
    if DEBUG:
        log("DEBUG", *a)


# ── Postgres helpers (shell out to psql; no python deps) ───────────────────────
def psql(sql, params=None):
    """
    Run a SQL statement via psql. Uses a here-doc with parameters bound as psql
    variables to avoid quoting issues. `params` is a dict of name->str.
    Returns (rc, stdout, stderr).
    """
    args = [PSQL_BIN, PSQL_DSN, "-v", "ON_ERROR_STOP=1", "-Atq"]
    if params:
        for k, v in params.items():
            args += ["-v", f"{k}={v}"]
    dbg("psql", sql)
    p = subprocess.run(args, input=sql, capture_output=True, text=True)
    return p.returncode, p.stdout.strip(), p.stderr.strip()


def sql_lit(s):
    """Single-quote a SQL string literal safely."""
    return "'" + str(s).replace("'", "''") + "'"


def resolve_user_id_by_github_id(gh_user_id):
    """Map a GitHub numeric user id -> Coder users.id (uuid), or '' if not found."""
    sql = f"SELECT id::text FROM users WHERE github_com_user_id = {int(gh_user_id)} AND deleted = false LIMIT 1;"
    rc, out, err = psql(sql)
    if rc != 0:
        log("resolve_user_id error:", err)
        return ""
    return out.strip()


def upsert_external_auth(user_id, access_token, refresh_token, expiry_epoch):
    """
    Upsert external_auth_links for (provider_id, user_id) with a plaintext token.
    expiry_epoch: unix seconds (int). 0 -> far future (GitHub OAuth App tokens
    don't expire).
    """
    if expiry_epoch and expiry_epoch > 0:
        expiry_sql = f"to_timestamp({int(expiry_epoch)})"
    else:
        expiry_sql = "(now() + interval '100 years')"
    prov = sql_lit(EXTAUTH_PROVIDER_ID)
    uid = sql_lit(user_id)
    at = sql_lit(access_token)
    rt = sql_lit(refresh_token or "")
    sql = f"""
INSERT INTO external_auth_links
  (provider_id, user_id, created_at, updated_at,
   oauth_access_token, oauth_refresh_token, oauth_expiry,
   oauth_refresh_failure_reason)
VALUES
  ({prov}, {uid}, now(), now(), {at}, {rt}, {expiry_sql}, '')
ON CONFLICT (provider_id, user_id) DO UPDATE SET
  updated_at = now(),
  oauth_access_token = EXCLUDED.oauth_access_token,
  oauth_refresh_token = EXCLUDED.oauth_refresh_token,
  oauth_expiry = EXCLUDED.oauth_expiry,
  oauth_access_token_key_id = NULL,
  oauth_refresh_token_key_id = NULL,
  oauth_refresh_failure_reason = '';
"""
    rc, out, err = psql(sql)
    if rc != 0:
        log("upsert_external_auth error:", err)
        return False
    return True


# ── GitHub OAuth helpers ───────────────────────────────────────────────────────
def github_exchange_code(code):
    """Exchange an authorization code for an access token. Returns dict or None."""
    data = urllib.parse.urlencode({
        "client_id": GH_CLIENT_ID,
        "client_secret": GH_CLIENT_SECRET,
        "code": code,
        "redirect_uri": PUBLIC_URL + MW_CALLBACK_PATH,
    }).encode()
    req = urllib.request.Request(
        GITHUB_TOKEN, data=data,
        headers={"Accept": "application/json", "User-Agent": "workshop-mw"},
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.loads(r.read().decode())
    except Exception as e:
        log("github_exchange_code error:", e)
        return None


def github_user_id(access_token):
    """Fetch the GitHub numeric user id for a token. Returns int or None."""
    req = urllib.request.Request(
        GITHUB_API_USER,
        headers={
            "Authorization": "Bearer " + access_token,
            "Accept": "application/vnd.github+json",
            "User-Agent": "workshop-mw",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return int(json.loads(r.read().decode())["id"])
    except Exception as e:
        log("github_user_id error:", e)
        return None


# ── reverse proxy ──────────────────────────────────────────────────────────────
def parse_addr(addr):
    host, _, port = addr.partition(":")
    return host or "127.0.0.1", int(port or "8088")


UP_HOST, UP_PORT, UP_HTTPS = (lambda u: (
    urllib.parse.urlparse(u).hostname,
    urllib.parse.urlparse(u).port or (443 if urllib.parse.urlparse(u).scheme == "https" else 80),
    urllib.parse.urlparse(u).scheme == "https",
))(UPSTREAM)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        if DEBUG:
            log("req", self.command, self.path, "->", fmt % args)

    # All verbs route through one dispatcher.
    def do_GET(self):    self.dispatch()
    def do_POST(self):   self.dispatch()
    def do_PUT(self):    self.dispatch()
    def do_DELETE(self): self.dispatch()
    def do_PATCH(self):  self.dispatch()
    def do_HEAD(self):   self.dispatch()
    def do_OPTIONS(self):self.dispatch()

    def dispatch(self):
        path = urllib.parse.urlparse(self.path).path
        if not DISABLE_INTERCEPT and path == MW_CALLBACK_PATH:
            return self.handle_callback()
        # (Step 3 will also intercept the login authorize-start here.)
        return self.proxy()

    # ---- transparent proxy to Coder --------------------------------------------
    def proxy(self):
        body = b""
        cl = self.headers.get("Content-Length")
        if cl:
            try:
                body = self.rfile.read(int(cl))
            except Exception:
                body = b""
        conn_cls = http.client.HTTPSConnection if UP_HTTPS else http.client.HTTPConnection
        try:
            conn = conn_cls(UP_HOST, UP_PORT, timeout=60)
            fwd_headers = {}
            for k, v in self.headers.items():
                if k.lower() in HOP_BY_HOP:
                    continue
                fwd_headers[k] = v
            # Preserve original client info for Coder.
            fwd_headers["X-Forwarded-Host"] = self.headers.get("Host", "")
            fwd_headers["X-Forwarded-Proto"] = "https"
            xff = self.headers.get("X-Forwarded-For")
            client_ip = self.client_address[0]
            fwd_headers["X-Forwarded-For"] = (xff + ", " + client_ip) if xff else client_ip
            conn.request(self.command, self.path, body=body or None, headers=fwd_headers)
            resp = conn.getresponse()
            data = resp.read()
            self.send_response_only(resp.status, resp.reason)
            for k, v in resp.getheaders():
                if k.lower() in HOP_BY_HOP or k.lower() == "content-length":
                    continue
                self.send_header(k, v)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(data)
            conn.close()
        except Exception as e:
            log("proxy error:", e)
            self.send_error(502, "upstream error")

    # ---- single-click callback (Step 3 wires the full chain) -------------------
    def handle_callback(self):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        code = (q.get("code") or [""])[0]
        state = (q.get("state") or [""])[0]
        if not code:
            return self.send_error(400, "missing code")
        # 1) exchange for a repo-scoped token
        tok = github_exchange_code(code)
        if not tok or "access_token" not in tok:
            log("callback: token exchange failed", tok)
            return self.send_error(502, "github token exchange failed")
        access_token = tok["access_token"]
        refresh_token = tok.get("refresh_token", "")
        # GitHub OAuth App tokens normally have no expiry; honor if present.
        expiry_epoch = 0
        if tok.get("expires_in"):
            try:
                expiry_epoch = int(time.time()) + int(tok["expires_in"])
            except Exception:
                expiry_epoch = 0
        # 2) resolve the Coder user via GitHub numeric id
        gh_id = github_user_id(access_token)
        user_id = resolve_user_id_by_github_id(gh_id) if gh_id else ""
        if user_id:
            ok = upsert_external_auth(user_id, access_token, refresh_token, expiry_epoch)
            log(f"callback: external-auth {'set' if ok else 'FAILED'} for user {user_id} (gh {gh_id})")
        else:
            # User may not exist yet (first login). Step 3 handles ordering so login
            # creates the user first; for now we just log and continue.
            log(f"callback: no Coder user for gh id {gh_id}; external-auth deferred")
        # 3) complete Coder login by handing a fresh silent code to Coder's real
        #    callback. Implemented in Step 3; for now redirect to dashboard.
        self.send_response(302)
        self.send_header("Location", PUBLIC_URL + "/")
        self.end_headers()


def main():
    missing = [n for n in ("MW_PUBLIC_URL",) if not os.environ.get(n)]
    if missing and not DISABLE_INTERCEPT:
        log("WARNING missing env:", missing, "(ok for pure-proxy testing)")
    host, port = parse_addr(LISTEN_ADDR)
    srv = ThreadingHTTPServer((host, port), Handler)
    log(f"listening on {host}:{port} -> upstream {UPSTREAM} "
        f"(intercept={'off' if DISABLE_INTERCEPT else 'on'})")
    srv.serve_forever()


if __name__ == "__main__":
    main()
