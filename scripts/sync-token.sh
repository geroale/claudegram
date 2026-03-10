#!/bin/bash
# Sync OAuth token from Claude Code credentials to claudegram .env
# Run via cron (e.g. every 5 min) to keep the bot authenticated
# Usage: */5 * * * * sudo /path/to/sync-token.sh

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CREDENTIALS_FILE="$HOME/.claude/.credentials.json"
ENV_FILE="$SCRIPT_DIR/.env"

if [ ! -f "$CREDENTIALS_FILE" ]; then
    exit 0
fi

NEW_TOKEN=$(python3 -c "import json; print(json.load(open('$CREDENTIALS_FILE'))['claudeAiOauth']['accessToken'])")
CURRENT_TOKEN=$(grep '^CLAUDE_CODE_OAUTH_TOKEN=' "$ENV_FILE" | cut -d= -f2)

if [ "$NEW_TOKEN" != "$CURRENT_TOKEN" ] && [ -n "$NEW_TOKEN" ]; then
    sed -i "s|^CLAUDE_CODE_OAUTH_TOKEN=.*|CLAUDE_CODE_OAUTH_TOKEN=${NEW_TOKEN}|" "$ENV_FILE"
    systemctl restart claudegram 2>/dev/null || true
    echo "$(date): Token refreshed and bot restarted" >> "$SCRIPT_DIR/token-sync.log"
fi
