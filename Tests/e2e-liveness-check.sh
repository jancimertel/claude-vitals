#!/bin/bash
# End-to-end liveness check: runs the real binary against fake session-registry directories.
# XCTest needs Xcode; this runs with Command Line Tools only. Usage, from the repo root:
#   swift build && bash Tests/e2e-liveness-check.sh
# Writes only into fresh mktemp dirs. Each --dump makes one tiny usage call, so allow a few seconds per line.
BIN=.build/debug/ClaudeVitals
FAKE="$(mktemp -d)/sessions";  mkdir -p "$FAKE"
EMPTY="$(mktemp -d)/sessions"; mkdir -p "$EMPTY"
OLD=$(ls -tr "$HOME"/.claude/projects/*/*.jsonl | head -1)   # oldest transcript: far outside the grace window
SID=$(basename "$OLD" .jsonl)
NOW_MS=$(( $(date +%s) * 1000 ))

# A card for OLD ends its row with the file age in seconds; no other session is that old to the second.
# Prints "<blocks> <old_card>". BSD seq switches to scientific notation on large numbers without -f.
run() {
  local a=$(( $(date +%s) - $(stat -f %m "$OLD") ))
  local out; out=$(CLAUDE_VITALS_SESSIONS_DIR="$1" "$BIN" --dump)
  local ages; ages=$(seq -f '%.0f' $((a - 2)) $((a + 10)) | paste -sd'|' -)
  echo "$(printf '%s\n' "$out" | head -1 | grep -o 'blocks=[0-9]*' | cut -d= -f2) $(printf '%s\n' "$out" | grep -cE "  (${ages})s(  |\$)")"
}

fail=0
check() { if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1 (got $2, want $3)"; fail=1; fi; }

printf '{"pid":999999,"sessionId":"%s","cwd":"/nonexistent","startedAt":%s}' "$SID" "$NOW_MS" > "$FAKE/999999.json"
printf '{"pid":%s,"sessionId":"%s","cwd":"/nonexistent","startedAt":1000}' "$$" "$SID" > "$FAKE/$$.json"
read -r _ a_old <<< "$(run "$FAKE")"
check "dead pid and reused pid are not live" "$a_old" 0

printf '{"pid":%s,"sessionId":"%s","cwd":"/nonexistent","startedAt":%s}' "$$" "$SID" "$NOW_MS" > "$FAKE/$$.json"
read -r _ b_old <<< "$(run "$FAKE")"
check "running pid with a plausible startedAt is live" "$b_old" 1

read -r c_blocks _ <<< "$(run "$FAKE/absent")"
read -r d_blocks _ <<< "$(run "$EMPTY")"
check "empty registry falls back like a missing one" "$d_blocks" "$c_blocks"

read -r r_blocks _ <<< "$(run "$HOME/.claude/sessions")"
live=$(ls "$HOME"/.claude/sessions/*.json 2>/dev/null | wc -l | tr -d ' ')
if [ "$r_blocks" -ge "$live" ]; then echo "ok    real registry: $r_blocks cards for $live registry entries"
else echo "FAIL  real registry: $r_blocks cards for $live registry entries"; fail=1; fi
exit $fail
