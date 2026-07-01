# Claude Vitals - Hook-Hybrid Status Feedback (Design)

Date: 2026-07-01
Status: Approved (design), pending implementation plan

## Goal

Make agent status feedback in the Claude Vitals menu-bar app **accurate** and **instant**.
Today the app polls every 1.5-5s and reverse-engineers each session's state from transcript
mtime + the last conversational line. Two consequences:

- **Latency**: a state change surfaces up to 1.5-5s late, and every tick shells out to
  `pgrep`/`lsof`.
- **A blind spot**: a normal tool permission prompt (e.g. a Bash approval) is on disk
  indistinguishable from a running tool, so it shows as "running tool" instead of
  "waiting". Only `AskUserQuestion`/`ExitPlanMode` are special-cased today
  (`USER_PROMPT_TOOLS`).

The fix is a **hybrid**: a Claude Code plugin whose lifecycle hooks push precise state events
to the running app over a Unix domain socket, while the existing transcript parsing stays the
source of the numbers. Hooks become the fast, unambiguous trigger + state source; the
transcript stays the numbers source; polling drops to a safety net.

## Principle: hooks own state, transcripts own numbers, polling is the safety net

- **Hook events are authoritative for state (`Dot`) and liveness**, keyed by `session_id`.
  They arrive on every transition, instantly and unambiguously.
- **Transcript parsing stays the source for numbers** (context %, tokens, cost, turns,
  tool-calls) - hooks carry none of that. Each hook event **triggers an immediate targeted
  re-parse of that one session**, so numbers update in the same ~ms as state.
- **The poll loop remains but slows to a flat ~5s** and only fills sessions with no fresh
  hook data. Un-instrumented sessions behave exactly as today; instrumented ones go instant.

### Precedence rule (the crux)

For a given session: if its last hook event is newer than ~15s, hook-derived state wins;
otherwise fall back to the existing `deriveState` heuristic. If the plugin is disabled
mid-session, the app degrades gracefully after one window.

## Data flow

```
Claude Code session ──(8 hook events)──► emit.sh ──nc -U──► vitals.sock
                                                                 │
   ~/.claude/projects/*.jsonl ◄──targeted re-parse──┐           ▼
                                                     │      EventSocket (NWListener)
                                                     │           │ HookEvent{event, session_id,
                                                     │           │           transcript_path, tool_name, ts}
                                                     └───► Collector.ingest(e) ──► Snapshot ──► Store ──► UI
                                                                 ▲
                              poll loop (safety net, ~5s) ───────┘
```

## Event mapping

| Hook event                     | Effect on session state                             |
|--------------------------------|-----------------------------------------------------|
| `SessionStart`                 | liveness on; seed transcript_path as a candidate    |
| `SessionEnd`                   | liveness off (ended)                                |
| `UserPromptSubmit`             | `runningModel` (turn started)                       |
| `PreToolUse`                   | `runningTool` (+ exact tool_name)                   |
| `PostToolUse`                  | back to `runningModel`                              |
| `PermissionRequest`            | `waitingPermission` (new state - see below); authoritative permission signal |
| `Notification`                 | `waiting` (backstop: Claude is blocked on the user)  |
| `Stop`                         | `waiting` (waiting for prompt); fires the chime     |
| `SubagentStart` / `SubagentStop` | subagent liveness count                           |

## Component: the plugin (`plugin/claude-vitals/`)

- `plugin.json` - name/version metadata.
- `hooks/hooks.json` - wires all events above to one command, each marked **`async: true`**
  so monitoring never blocks or delays a tool/turn.
- `hooks/emit.sh` - dependency-free. Claude Code already puts everything needed on stdin
  (`hook_event_name`, `session_id`, `cwd`, `transcript_path`, `tool_name`), so the script
  forwards stdin straight to the socket:
  ```sh
  exec /usr/bin/nc -U -w1 "$HOME/.claude-vitals/vitals.sock"
  ```
  No `jq`, no shell parsing; the Swift side decodes. Fails fast and harmlessly if the app
  (socket) is not present.
- Install: `/plugin install ./plugin/claude-vitals` once at user scope → applies to every
  session in every repo. Disable via `/plugin`.

**Assumption to verify in implementation:** hook `session_id` equals the transcript filename
UUID (the app's existing `Block` key). If not, join via the `transcript_path` the hook carries.

## Component: Swift changes

- **New `EventSocket`** (owned by `Store`): creates `~/.claude-vitals/`, unlinks any stale
  socket, binds an `NWListener` on the AF_UNIX path; per received line decodes `HookEvent`
  and calls `await collector.ingest(e)`.
- **`Collector` actor gains** `var hooks: [String: HookStatus]` and
  `func ingest(_ e: HookEvent) -> Snapshot`: updates hook state for the session, seeds the
  transcript file as a candidate (via `transcript_path` - this also fixes the "pgrep misses
  VS Code processes" liveness gap), rebuilds the snapshot, returns it. All hook state funnels
  through the single actor, so no new locking.
- **`buildSnapshot` merge**: in the `deriveState` step, consult `hooks[sessionId]` first per
  the precedence rule; fall back to the current heuristic otherwise. Liveness for instrumented
  sessions comes from `SessionStart`..`SessionEnd` instead of `pgrep`.
- **Coalescing**: a burst (e.g. PreToolUse+PostToolUse) is debounced ~50ms before publishing
  to avoid rebuild storms.

## State model + alerts

Wiring `PermissionRequest` lets us distinguish the two previously-identical yellow states.

- Add **`Dot.waitingPermission`** (distinct glyph/color, e.g. 🔐) separate from `.waiting`
  (waiting for prompt). Update `Dot.glyph` and the views/label accordingly.
- **Alerts** (`TransitionTracker`): fire on `running → waitingPermission` **and**
  `running → waiting`, with distinct text ("needs permission" vs "finished"). Permission-
  waiting means Claude is blocked on the user, so it is treated as at least as urgent.
  Keep edge-triggering (no repeated dinging).

## Fallback & edge cases

- Plugin not installed / app not running → no events; existing poll drives everything
  (zero regression).
- Stale socket / app restart → listener rebinds on launch; full state rebuilt from
  transcripts immediately.
- Hook for an unknown/not-yet-seen session → `transcript_path` seeds it as a candidate.
- Precedence window (~15s) guarantees graceful fallback if hooks stop mid-session.

## Testing

- **Unit**: `HookEvent` decoding; the merge precedence rule (fresh hook state wins, stale
  falls back); `deriveState` fallback tests remain green (unchanged path).
- **Integration**: a `--emit <event>` debug subcommand pipes synthetic events into the socket;
  assert the snapshot state flips instantly.
- **Manual**: install the plugin, run a real session, observe permission/turn/tool latency.

## Out of scope (YAGNI)

- OTEL/telemetry ingestion (cost/token counters) - the transcript already yields these.
- In-app auto-writing of `~/.claude/settings.json` - the plugin is the only install path.
- Cross-machine / remote monitoring.
