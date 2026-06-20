#!/usr/bin/env bash
# seed-chats.sh — re-seed the Coder "Agents" (experimental chats) DB config after
# a fresh deploy or `coder-reset` (which wipes the database). Idempotent: skips
# anything that already exists.
#
# Seeds:
#   - Anthropic provider (centralized key from env)
#   - OpenAI provider (centralized key from env, when OPENAI_API_KEY is set)
#   - model-configs: opus-4-5, sonnet-4-5, sonnet-4-6 (sonnet-4-6 = default)
#   - workshop system prompt (from SYSTEM_PROMPT_FILE, include_default=true)
#   - virtual desktop experiment enabled
#
# Env:
#   CODER_URL            default http://localhost:3000
#   CODER_SESSION_TOKEN  admin token (else read TOKEN_FILE)
#   TOKEN_FILE           default /etc/coder/session-token
#   ANTHROPIC_API_KEY    centralized Anthropic provider key (optional)
#   OPENAI_API_KEY       centralized OpenAI provider key (optional)
#   SYSTEM_PROMPT_FILE   path to the workshop system prompt text
set -uo pipefail

URL="${CODER_URL:-http://localhost:3000}"
TOKEN_FILE="${TOKEN_FILE:-/etc/coder/session-token}"
TOK="${CODER_SESSION_TOKEN:-}"
[ -z "$TOK" ] && [ -r "$TOKEN_FILE" ] && TOK="$(cat "$TOKEN_FILE")"
KEY="${ANTHROPIC_API_KEY:-}"
OPENAI_KEY="${OPENAI_API_KEY:-}"
PROMPT_FILE="${SYSTEM_PROMPT_FILE:-}"
LICENSE_FILE="${LICENSE_FILE:-}"
B="$URL/api/experimental/chats"

log() { echo "[seed-chats] $*"; }
api() { curl -s -H "Coder-Session-Token: $TOK" "$@"; }

if [ -z "$TOK" ]; then log "no session token; skipping."; exit 0; fi

# Wait for the API to be reachable (server may still be starting).
for i in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "Coder-Session-Token: $TOK" "$B/providers" || true)
  [ "$code" = "200" ] && break
  sleep 2
done

# 1. Anthropic provider. The API lists all built-in "supported" providers even
# when none is configured, so only treat it as present when it actually has a
# key / source==database (a real configured provider) — not a placeholder.
have_provider=$(api "$B/providers" | jq '[.[] | select(.provider=="anthropic" and (.has_api_key==true or .source=="database"))] | length' 2>/dev/null || echo 0)
if [ "${have_provider:-0}" -ge 1 ]; then
  log "configured anthropic provider already present; skipping provider create."
elif [ -z "$KEY" ]; then
  log "no ANTHROPIC_API_KEY; cannot seed provider."
else
  log "creating anthropic provider"
  api -X POST -H 'content-type: application/json' \
    -d "$(jq -n --arg k "$KEY" '{provider:"anthropic", display_name:"Anthropic", enabled:true, api_key:$k, central_api_key_enabled:true, allow_user_api_key:false}')" \
    "$B/providers" >/dev/null
fi

# 1b. OpenAI provider — same shape as Anthropic, seeded only when OPENAI_API_KEY
# is set (so a host with no OpenAI key simply skips it). Idempotent.
have_openai=$(api "$B/providers" | jq '[.[] | select(.provider=="openai" and (.has_api_key==true or .source=="database"))] | length' 2>/dev/null || echo 0)
if [ "${have_openai:-0}" -ge 1 ]; then
  log "configured openai provider already present; skipping provider create."
elif [ -z "$OPENAI_KEY" ]; then
  log "no OPENAI_API_KEY; skipping openai provider."
else
  log "creating openai provider"
  api -X POST -H 'content-type: application/json' \
    -d "$(jq -n --arg k "$OPENAI_KEY" '{provider:"openai", display_name:"OpenAI", enabled:true, api_key:$k, central_api_key_enabled:true, allow_user_api_key:false}')" \
    "$B/providers" >/dev/null
fi

# 2. Model configs — created independently of the provider (decoupled, so a
# provider-without-models state still gets fixed). Only seed when none exist.
have_models=$(api "$B/model-configs" | jq 'length' 2>/dev/null || echo 0)
if [ "${have_models:-0}" -ge 1 ]; then
  log "model-configs already present ($have_models); skipping."
else
  for spec in \
    'claude-opus-4-5-20251101|Claude Opus 4.5|false' \
    'claude-sonnet-4-5-20250929|Claude Sonnet 4.5|false' \
    'claude-sonnet-4-6|Claude Sonnet 4.6|true'; do
    model="${spec%%|*}"; rest="${spec#*|}"; disp="${rest%%|*}"; def="${rest##*|}"
    log "creating model-config $model (default=$def)"
    api -X POST -H 'content-type: application/json' \
      -d "$(jq -n --arg m "$model" --arg d "$disp" --argjson def "$def" \
            '{provider:"anthropic", model:$m, display_name:$d, enabled:true, is_default:$def, context_limit:200000, compression_threshold:70}')" \
      "$B/model-configs" >/dev/null
  done
fi

# 3. Workshop system prompt.
if [ -n "$PROMPT_FILE" ] && [ -r "$PROMPT_FILE" ]; then
  log "setting system prompt from $PROMPT_FILE"
  api -X PUT -H 'content-type: application/json' \
    -d "$(jq -n --rawfile p "$PROMPT_FILE" '{system_prompt:$p, include_default_system_prompt:true}')" \
    "$B/config/system-prompt" >/dev/null
else
  log "no SYSTEM_PROMPT_FILE; leaving system prompt as-is."
fi

# 0. License (Premium features: prebuilds, etc.). Apply if a license file is set
# and no active license exists yet. The license is stored in the DB (wiped by
# coder-reset), so this restores it on every rebuild.
if [ -n "$LICENSE_FILE" ] && [ -r "$LICENSE_FILE" ]; then
  has_lic=$(curl -s -H "Coder-Session-Token: $TOK" "$URL/api/v2/entitlements" | jq -r '.has_license' 2>/dev/null)
  if [ "$has_lic" = "true" ]; then
    log "license already active; skipping."
  else
    log "applying license"
    curl -s -X POST -H "Coder-Session-Token: $TOK" -H 'content-type: application/json' \
      -d "$(jq -n --rawfile l "$LICENSE_FILE" '{license:($l|rtrimstr("\n"))}')" \
      "$URL/api/v2/licenses" >/dev/null && log "license applied."
  fi
fi

# 4. Virtual desktop experiment.
api -X PUT -H 'content-type: application/json' -d '{"enable_desktop":true}' \
  "$B/config/desktop-enabled" >/dev/null && log "virtual desktop enabled."

log "done."
