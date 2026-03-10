#!/bin/bash
# Refresh Claude OAuth token and keep claudegram authenticated.
# Run via cron every 5 min:  */5 * * * * /home/ubuntu/claudegram/scripts/sync-token.sh
#
# The Claude Agent SDK reads credentials from ~/.claude/.credentials.json.
# This script refreshes the access token BEFORE it expires using the refresh token.

set -euo pipefail

# ── Paths (hardcoded — no sudo $HOME issues) ──────────────────
CREDENTIALS_FILE="/home/ubuntu/.claude/.credentials.json"
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_FILE="$SCRIPT_DIR/token-sync.log"

# ── OAuth config (from Claude Code SDK) ───────────────────────
TOKEN_ENDPOINT="https://platform.claude.com/v1/oauth/token"
CLIENT_ID="9d1c250a-e61b-44d9-88ed-5944d1962f5e"

# Refresh when less than this many seconds remain (2 hours)
REFRESH_THRESHOLD=7200

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $*" >> "$LOG_FILE"
}

if [ ! -f "$CREDENTIALS_FILE" ]; then
    log "ERROR: Credentials file not found: $CREDENTIALS_FILE"
    exit 1
fi

# ── Read current token data ───────────────────────────────────
TOKEN_DATA=$(python3 -c "
import json, time, sys
try:
    d = json.load(open('$CREDENTIALS_FILE'))
    oauth = d['claudeAiOauth']
    expires_at = oauth['expiresAt'] / 1000  # ms -> s
    remaining = expires_at - time.time()
    print(f\"{oauth['refreshToken']}|{oauth['accessToken']}|{int(remaining)}\")
except Exception as e:
    print(f'ERROR|{e}', file=sys.stderr)
    sys.exit(1)
")

REFRESH_TOKEN=$(echo "$TOKEN_DATA" | cut -d'|' -f1)
CURRENT_ACCESS_TOKEN=$(echo "$TOKEN_DATA" | cut -d'|' -f2)
REMAINING_SECONDS=$(echo "$TOKEN_DATA" | cut -d'|' -f3)

# ── Check if refresh is needed ────────────────────────────────
if [ "$REMAINING_SECONDS" -gt "$REFRESH_THRESHOLD" ]; then
    # Token still valid, no refresh needed
    exit 0
fi

log "Token expires in ${REMAINING_SECONDS}s (threshold: ${REFRESH_THRESHOLD}s) — refreshing..."

# ── Refresh the token ─────────────────────────────────────────
RESPONSE=$(curl -sf --max-time 30 \
    -X POST "$TOKEN_ENDPOINT" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=refresh_token" \
    -d "client_id=$CLIENT_ID" \
    -d "refresh_token=$REFRESH_TOKEN" \
    2>&1) || {
    log "ERROR: Token refresh request failed: $RESPONSE"
    exit 1
}

# ── Parse response ────────────────────────────────────────────
NEW_TOKEN_DATA=$(python3 -c "
import json, sys, time
try:
    r = json.loads('''$RESPONSE''')
    if 'error' in r:
        print(f\"ERROR: {r.get('error_description', r['error'])}\", file=sys.stderr)
        sys.exit(1)
    access_token = r['access_token']
    refresh_token = r.get('refresh_token', '')
    expires_in = r.get('expires_in', 43200)  # default 12h
    expires_at_ms = int((time.time() + expires_in) * 1000)
    print(f'{access_token}|{refresh_token}|{expires_at_ms}')
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)
") || {
    log "ERROR: Failed to parse refresh response"
    exit 1
}

NEW_ACCESS_TOKEN=$(echo "$NEW_TOKEN_DATA" | cut -d'|' -f1)
NEW_REFRESH_TOKEN=$(echo "$NEW_TOKEN_DATA" | cut -d'|' -f2)
NEW_EXPIRES_AT=$(echo "$NEW_TOKEN_DATA" | cut -d'|' -f3)

if [ -z "$NEW_ACCESS_TOKEN" ]; then
    log "ERROR: Empty access token in refresh response"
    exit 1
fi

# ── Update credentials file ──────────────────────────────────
python3 -c "
import json
creds = json.load(open('$CREDENTIALS_FILE'))
creds['claudeAiOauth']['accessToken'] = '$NEW_ACCESS_TOKEN'
creds['claudeAiOauth']['expiresAt'] = $NEW_EXPIRES_AT
refresh = '$NEW_REFRESH_TOKEN'
if refresh:
    creds['claudeAiOauth']['refreshToken'] = refresh
with open('$CREDENTIALS_FILE', 'w') as f:
    json.dump(creds, f, indent=2)
"

log "SUCCESS: Token refreshed. New expiry: $(python3 -c "import time; print(time.ctime($NEW_EXPIRES_AT/1000))")"

# NOTE: Do NOT set CLAUDE_CODE_OAUTH_TOKEN in .env — when present as an
# env var, the SDK uses it WITHOUT a refresh token, breaking auto-refresh.
# The SDK reads ~/.claude/.credentials.json directly (which has both tokens).
