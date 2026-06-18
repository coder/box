#!/usr/bin/env bash
# seed-chats.sh — re-seed the Coder "Agents" (experimental chats) DB config after
# a fresh deploy or `coder-reset` (which wipes the database). Idempotent: skips
# anything that already exists.
#
# Seeds:
#   - Anthropic provider (centralized key from env)
#   - model-configs: opus-4-5, sonnet-4-5, sonnet-4-6 (sonnet-4-6 = default)
#   - workshop system prompt (from SYSTEM_PROMPT_FILE, include_default=true)
#   - virtual desktop experiment enabled
#
# Env:
#   CODER_URL            default http://localhost:3000
#   CODER_SESSION_TOKEN  admin token (else read TOKEN_FILE)
#   TOKEN_FILE           default /etc/coder/session-token
#   ANTHROPIC_API_KEY    centralized provider key (required to seed the provider)
#   SYSTEM_PROMPT_FILE   path to the workshop system prompt text
set -uo pipefail

URL="${CODER_URL:-http://localhost:3000}"
TOKEN_FILE="${TOKEN_FILE:-/etc/coder/session-token}"
TOK="${CODER_SESSION_TOKEN:-}"
[ -z "$TOK" ] && [ -r "$TOKEN_FILE" ] && TOK="$(cat "$TOKEN_FILE")"
KEY="${ANTHROPIC_API_KEY:-}"
PROMPT_FILE="${SYSTEM_PROMPT_FILE:-}"
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

# 1. Anthropic provider (only if none present).
have_provider=$(api "$B/providers" | grep -c '"provider": *"anthropic"' || true)
if [ "${have_provider:-0}" -ge 1 ]; then
  log "anthropic provider already present; skipping provider+models."
else
  if [ -z "$KEY" ]; then
    log "no ANTHROPIC_API_KEY; cannot seed provider. Skipping."
  else
    log "creating anthropic provider"
    api -X POST -H 'content-type: application/json' \
      -d "$(jq -n --arg k "$KEY" '{provider:"anthropic", display_name:"Anthropic", enabled:true, api_key:$k, central_api_key_enabled:true, allow_user_api_key:false}')" \
      "$B/providers" >/dev/null
    # 2. Model configs. Last one created stays default via is_default.
    for spec in \
      'claude-opus-4-5-20251101|Claude Opus 4.5|false' \
      'claude-sonnet-4-5-20250929|Claude Sonnet 4.5|false' \
      'claude-sonnet-4-6|Claude Sonnet 4.6|true'; do
      IFS='|' read -r model disp def <<< "$spec"
      log "creating model-config $model (default=$def)"
      api -X POST -H 'content-type: application/json' \
        -d "$(jq -n --arg m "$model" --arg d "$disp" --argjson def "$def" \
              '{provider:"anthropic", model:$m, display_name:$d, enabled:true, is_default:$def, context_limit:200000, compression_threshold:70}')" \
        "$B/model-configs" >/dev/null
    done
  fi
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

# 4. Virtual desktop experiment.
api -X PUT -H 'content-type: application/json' -d '{"enable_desktop":true}' \
  "$B/config/desktop-enabled" >/dev/null && log "virtual desktop enabled."

log "done."
