#!/usr/bin/env bash
# Fallback installer for Claude Code environments WITHOUT the /plugin command.
# Registers the claude-vitals hooks in ~/.claude/settings.json (user scope) so every
# session emits lifecycle events to the running Claude Vitals app. Idempotent and
# non-destructive (preserves any other hooks you already have).
#
# Preferred path is the marketplace install (see INSTALL.md); use this only if /plugin
# is unavailable.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_EMIT="$REPO_DIR/plugin/claude-vitals/hooks/emit.sh"
DEST_DIR="$HOME/.claude-vitals"
DEST_EMIT="$DEST_DIR/emit.sh"
SETTINGS="$HOME/.claude/settings.json"

[ -f "$SRC_EMIT" ] || { echo "error: emit.sh not found at $SRC_EMIT" >&2; exit 1; }
command -v python3 >/dev/null || { echo "error: python3 required" >&2; exit 1; }

# 1. Stage the hook script in a stable, repo-independent location.
mkdir -p "$DEST_DIR"
cp "$SRC_EMIT" "$DEST_EMIT"
chmod +x "$DEST_EMIT"

# 2. Merge our hooks into settings.json (create it if missing, back it up first).
mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak-vitals"

python3 - "$SETTINGS" "$DEST_EMIT" <<'PY'
import json, sys
settings_path, emit = sys.argv[1], sys.argv[2]
with open(settings_path) as f:
    cfg = json.load(f)

cmd = {"type": "command", "command": emit, "async": True}
TOOL_EVENTS  = ["PreToolUse", "PostToolUse", "PermissionRequest"]
PLAIN_EVENTS = ["SessionStart", "SessionEnd", "UserPromptSubmit",
                "Notification", "Stop", "SubagentStart", "SubagentStop"]

hooks = cfg.setdefault("hooks", {})
def add(event, entry):
    arr = hooks.setdefault(event, [])
    # drop any prior claude-vitals entry so re-running is idempotent, keep others
    arr[:] = [e for e in arr if not any(h.get("command") == emit for h in e.get("hooks", []))]
    arr.append(entry)

for ev in TOOL_EVENTS:
    add(ev, {"matcher": "*", "hooks": [cmd]})
for ev in PLAIN_EVENTS:
    add(ev, {"hooks": [cmd]})

with open(settings_path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PY

echo "Installed claude-vitals hooks."
echo "  hook script : $DEST_EMIT"
echo "  settings    : $SETTINGS  (backup: $SETTINGS.bak-vitals)"
echo "Verify in a Claude Code session with /hooks. No restart needed."
echo "Make sure the app is running: (cd $REPO_DIR && ./make_app.sh && open ClaudeVitals.app)"
