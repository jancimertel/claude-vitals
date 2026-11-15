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
SRC_HOOKS="$REPO_DIR/plugin/claude-vitals/hooks/hooks.json"
DEST_DIR="$HOME/.claude-vitals"
DEST_EMIT="$DEST_DIR/emit.sh"
SETTINGS="$HOME/.claude/settings.json"

[ -f "$SRC_EMIT" ] || { echo "error: emit.sh not found at $SRC_EMIT" >&2; exit 1; }
[ -f "$SRC_HOOKS" ] || { echo "error: hooks.json not found at $SRC_HOOKS" >&2; exit 1; }
command -v python3 >/dev/null || { echo "error: python3 required" >&2; exit 1; }

# 1. Stage the hook script in a stable, repo-independent location.
mkdir -p "$DEST_DIR"
cp "$SRC_EMIT" "$DEST_EMIT"
chmod +x "$DEST_EMIT"

# 2. Merge our hooks into settings.json (create it if missing, back it up first).
mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak-vitals"

python3 - "$SETTINGS" "$DEST_EMIT" "$SRC_HOOKS" <<'PY'
import json, sys
settings_path, emit, src_hooks = sys.argv[1], sys.argv[2], sys.argv[3]
with open(settings_path) as f:
    cfg = json.load(f)

cmd = {"type": "command", "command": emit, "async": True}
# hooks.json is the single event list (plugin and installer stay in sync)
with open(src_hooks) as f:
    events = json.load(f)["hooks"]

hooks = cfg.setdefault("hooks", {})
def add(event, entry):
    arr = hooks.setdefault(event, [])
    # drop any prior claude-vitals entry so re-running is idempotent, keep others
    arr[:] = [e for e in arr if not any(h.get("command") == emit for h in e.get("hooks", []))]
    arr.append(entry)

for ev, entries in events.items():
    m = entries[0].get("matcher")
    add(ev, {"matcher": m, "hooks": [cmd]} if m else {"hooks": [cmd]})

with open(settings_path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PY

echo "Installed claude-vitals hooks."
echo "  hook script : $DEST_EMIT"
echo "  settings    : $SETTINGS  (backup: $SETTINGS.bak-vitals)"
echo "Verify in a Claude Code session with /hooks. No restart needed."
echo "Make sure the app is running: (cd $REPO_DIR && ./make_app.sh && open \"Claude Vitals.app\")"
