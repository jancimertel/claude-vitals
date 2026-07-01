#!/bin/sh
# Forward the hook's stdin JSON (already contains hook_event_name, session_id, cwd,
# transcript_path, tool_name) straight to the Claude Vitals app socket. No jq, no parsing.
# Fails fast and harmlessly if the app is not running.
SOCK="${CLAUDE_VITALS_SOCK:-$HOME/.claude-vitals/vitals.sock}"
exec /usr/bin/nc -U -w1 "$SOCK"
