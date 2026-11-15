# Newer Hook Events Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Consume the Claude Code hook events and payload fields added since July so a turn that dies on an API error shows "failed" with an alert, compaction shows its own state, and the context ring and cost stop being corrupted by API-error placeholder lines.

**Architecture:** Registration lives in one list (`hooks.json`, which `install.sh` now reads). `HookEvent` decodes the new fields tolerantly, `applyHookEvent` maps the new events onto two new `Dot` cases (`failed`, `compacting`), `resolveState` keeps `failed` sticky the way it already keeps `waitingPermission`, and `TransitionTracker` raises a new `failed` alert. On the transcript side, `deriveContext` and `TranscriptParser` skip `<synthetic>` API-error lines, and the ring reads `compactMetadata.postTokens` right after a compaction. `deriveState` (the plugin-less heuristic) is deliberately untouched.

**Tech Stack:** Swift 6 (SwiftPM executable target), Foundation, SwiftUI; bash + python3 for `install.sh`.

**Spec:** GitHub issue #3, https://github.com/jancimertel/claude-vitals/issues/3 (`gh issue view 3`), plus the triage decisions under Global Constraints.

## Global Constraints

- Platform floor macOS 14, swift-tools-version 6.0, no new dependencies.
- Spec, verbatim: "`StopFailure` fires when a turn ends on an API error such as a rate limit. It maps to a new failed state with its own alert." / "`PreCompact` / `PostCompact` map to a "compacting" state, and the context ring re-reads the transcript after `PostCompact`." / "`PostToolUseFailure` returns the card to "running model" the same way `PostToolUse` does." / "`PermissionDenied` clears "needs permission" when auto mode rejects a tool." / "`permission_prompt` sets "needs permission" when `PermissionRequest` was missed, and `idle_prompt` confirms "waiting prompt". Other types stay timestamp-only." / "Payloads carry `permission_mode`, `effort.level`, `agent_id` and `agent_type`. `HookEvent` decodes them so later issues can use them." / "`install.sh` registers the same event list as `hooks.json`."
- Payload shapes, verified in the installed Claude Code 2.1.210 binary:
  - every event: `session_id`, `transcript_path`, `cwd`, `permission_mode`, `agent_id` (set only inside a subagent; `session_id` stays the parent's), `agent_type`, `effort` = OBJECT `{"level": "..."}`, not a string.
  - `SessionStart`: `source` ("startup" | "resume" | "clear" | "compact"). It fires with `source: "compact"` after a compaction.
  - `StopFailure`: `error` (kind string such as "rate_limit", "server_error", default "unknown"), `error_details`, `last_assistant_message`. It returns before the Stop hooks run, so no `Stop` follows it. It carries `agent_id` when it comes from a subagent.
  - `PreCompact` / `PostCompact`: `trigger` ("manual" | "auto"). They carry no `agent_id`.
  - `PostToolUseFailure`: `tool_name`, `error`, `is_interrupt`. `PermissionDenied`: `tool_name`, `reason` (auto-mode denials only; the turn continues).
  - `Notification`: `notification_type` ("permission_prompt", "idle_prompt", others).
- Transcript shapes, verified in local transcripts:
  - API error: `{"type":"assistant","isApiErrorMessage":true,"error":"server_error","message":{"model":"<synthetic>","stop_reason":"stop_sequence","usage":{all zeros}}}`. These lines are NOT always terminal (Claude Code often continues after them), so they must never be used as a failure signal.
  - Compaction: `{"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"manual","preTokens":479298,"postTokens":23336}}`.
- Triage decisions (approved): no transcript-based "failed" heuristic; `failed` is exempt from supersession like `waitingPermission`; `compacting` counts as running (pulses, no alert on auto-compaction, a manual `/compact` finishing chimes "finished"); palette unchanged (`failed` uses `danger`, `compacting` uses `accent`); plugin version bumps to 0.2.0.
- Follow existing style: top-level free functions for pure logic, comments explain WHY. No em-dash characters anywhere (code, comments, docs, commits); use a plain hyphen.
- Commits: conventional-commit subject, no `Co-Authored-By` or "Generated with" trailer. Stage ONLY the files the task names with explicit `git add <path>`. `.gitignore` carries an unrelated pending edit that must stay uncommitted; never `git add -A` or `git add .`.
- TEST EXECUTION: this machine has Command Line Tools only, so XCTest and `swift test` are unavailable. The runnable check is `runSelfCheck()` in `Sources/ClaudeVitals/Entry.swift` (prints `ok <name>` per check, `FAIL <name>` and exit 1 on failure). Add new checks there, before the final `exit(0)`. Verify with `swift build 2>&1 | tail -1 && .build/debug/ClaudeVitals --selfcheck; echo "exit=$?"` and expect `Build complete!`, every new `ok <name>` line, and `exit=0`. Do not edit the XCTest files; the existing ones must still compile against the new `HookEvent` init (they pass all five original arguments).

## Review Focus

- Hooks are async and each runs its own `nc`, so events can arrive out of order: a late `PostCompact` or `permission_prompt` after the next tool hook must not stick a false state. Pinned by `latePostCompactIgnored` and `permissionPromptOnlyWhileRunning` (Task 2).
- Older Claude Code that sends none of the new events or fields must behave exactly as today. Pinned by `oldPayloadDecodes` and `untypedNotificationStillNoop` (Task 2).
- A new field with an unexpected shape (`effort` as a string, `error` as an object) must not drop the whole event, because `EventSocket` silently discards undecodable payloads. Pinned by `oddFieldShapesStillDecode` (Task 2).
- A failed session whose terminal is closed must not show "failed" forever. Pinned by `failedFallsBackWhenLivenessUnconfirmed` (Task 3).
- A subagent hitting an API error while the parent continues must not mark the parent failed. Pinned by `subagentStopFailureIgnored` (Task 2).

---

### Task 1: Register the new events in one place

**Files:**
- Modify: `plugin/claude-vitals/hooks/hooks.json`
- Modify: `plugin/claude-vitals/.claude-plugin/plugin.json`
- Modify: `install.sh:30-56`
- Modify: `README.md` (section "Fast triggers")

**Interfaces:**
- Produces: `hooks.json` is the single event list; `install.sh` derives its registrations from it.

- [ ] **Step 1: Write the check** (run from the repo root; it uses a throwaway `HOME`, so the real `~/.claude/settings.json` is never touched)

```bash
T=$(mktemp -d); HOME=$T bash install.sh >/dev/null && HOME=$T bash install.sh >/dev/null
python3 -I - "$T/.claude/settings.json" plugin/claude-vitals/hooks/hooks.json <<'PY'
import json, sys
got = json.load(open(sys.argv[1]))["hooks"]; want = json.load(open(sys.argv[2]))["hooks"]
assert set(got) == set(want), set(got) ^ set(want)
for ev, entries in want.items():
    assert len(got[ev]) == 1, (ev, got[ev])                 # second run replaced, did not append
    assert got[ev][0].get("matcher") == entries[0].get("matcher"), ev
print("ok", len(got), "events")
PY
```

- [ ] **Step 2: Run it before the change.** Expected: `ok 10 events` (the current lists happen to match).

- [ ] **Step 3: Register the events.** In `hooks.json`, add, in the same one-line style and alignment as the existing entries: `PostToolUseFailure` and `PermissionDenied` with `"matcher": "*"`; `StopFailure`, `PreCompact`, `PostCompact` without a matcher. In `plugin.json` set `"version": "0.2.0"` so `/plugin update` picks up the new hooks.json.

- [ ] **Step 4: Make `install.sh` read `hooks.json`.** Pass `"$REPO_DIR/plugin/claude-vitals/hooks/hooks.json"` as a third argument to the python heredoc and fail early (like the `SRC_EMIT` check) if it is missing. Replace `TOOL_EVENTS` / `PLAIN_EVENTS` and their two loops with one loop over the source file's `hooks` object: each event gets `{"matcher": <m>, "hooks": [cmd]}` when its first entry has a `matcher`, else `{"hooks": [cmd]}`. Keep `add()` and its idempotent cleanup unchanged.

- [ ] **Step 5: Run the check again.** Expected: `ok 15 events`.

- [ ] **Step 6: README.** In "Fast triggers", extend the parenthesised list to mention API failures and compaction, and add one sentence: existing plugin installs pick the new events up with `/plugin update` (plugin 0.2.0); `install.sh` users re-run it.

- [ ] **Step 7: Commit**

```bash
git add plugin/claude-vitals/hooks/hooks.json plugin/claude-vitals/.claude-plugin/plugin.json install.sh README.md
git commit -m "feat(plugin): register StopFailure, compaction, tool-failure and denial hooks"
```

---

### Task 2: Decode the new fields and map the new events

**Files:**
- Modify: `Sources/ClaudeVitals/HookEvent.swift` (struct `HookEvent`, `applyHookEvent`)
- Modify: `Sources/ClaudeVitals/Models.swift:58-72` (`enum Dot`)
- Modify: `Sources/ClaudeVitals/Theme.swift:101-110` (`Theme.state`)
- Modify: `Sources/ClaudeVitals/Entry.swift` (`runSelfCheck`)
- Modify: `README.md` (State badge line)

**Interfaces:**
- Produces:
  - `HookEvent` gains `let source, trigger, error, notification_type, agent_id, agent_type, permission_mode, effortLevel: String?`.
  - `init(event: String, session_id: String, cwd: String? = nil, transcript_path: String? = nil, tool_name: String? = nil, source: String? = nil, trigger: String? = nil, error: String? = nil, notification_type: String? = nil, agent_id: String? = nil, agent_type: String? = nil, permission_mode: String? = nil, effortLevel: String? = nil)`
  - `enum Dot { case runningModel, runningTool, compacting, waiting, waitingPermission, failed, idle, ended }`; `isRunning` is true for `runningModel`, `runningTool`, `compacting`.

- [ ] **Step 1: Write the checks** in `runSelfCheck()`, before the menu-bar ring block. Helpers: `func st(_ d: Dot) -> HookStatus` (state string "x", `alive: true`, `at: now`) and `func ev(_ name: String, ...) -> HookEvent` as you see fit; `dec(_ json: String) -> HookEvent?` via `try? JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))`.

| check name | input | assertion |
|---|---|---|
| `decodesNewFields` | `{"hook_event_name":"StopFailure","session_id":"s","error":"rate_limit","agent_type":"general-purpose","permission_mode":"auto","effort":{"level":"high"},"source":"startup","trigger":"auto","notification_type":"idle_prompt","agent_id":"a1"}` | every field decoded: `error == "rate_limit"`, `effortLevel == "high"`, `permission_mode == "auto"`, `agent_type == "general-purpose"`, `agent_id == "a1"`, `source == "startup"`, `trigger == "auto"`, `notification_type == "idle_prompt"` |
| `oldPayloadDecodes` | `{"hook_event_name":"Stop","session_id":"s"}` | non-nil, all eight new fields nil |
| `oddFieldShapesStillDecode` | `{"hook_event_name":"StopFailure","session_id":"s","effort":"high","error":{"type":"x"}}` | non-nil, `effortLevel == nil`, `error == nil`, and `applyHookEvent(st(.runningModel), e, at: now)?.state == "failed: unknown"` |
| `stopFailureGoesFailed` | prev `.runningModel`, `StopFailure` error "rate_limit" | dot `.failed`, state `"failed: rate limit"` (underscores shown as spaces), toolName nil |
| `subagentStopFailureIgnored` | prev `.runningModel`, `StopFailure` with `agent_id: "a1"` | dot `.runningModel` |
| `sessionStartCompactKeepsState` | prev `.runningModel`, `SessionStart` source "compact" | dot `.runningModel` |
| `sessionStartStartupGoesWaiting` | prev `.runningModel`, `SessionStart` source "startup" | dot `.waiting` |
| `autoPreCompactWhileRunning` | prev `.runningTool`, `PreCompact` trigger "auto" | dot `.compacting`, state `"compacting"` |
| `autoPreCompactWhileWaitingIgnored` | prev `.waiting`, `PreCompact` trigger "auto" | dot `.waiting` |
| `manualPreCompactFromWaiting` | prev `.waiting`, `PreCompact` trigger "manual" | dot `.compacting` |
| `postCompactAutoResumesRunning` | prev `.compacting`, `PostCompact` trigger "auto" | dot `.runningModel` |
| `postCompactManualGoesWaiting` | prev `.compacting`, `PostCompact` trigger "manual" | dot `.waiting` |
| `latePostCompactIgnored` | prev `.runningModel`, `PostCompact` trigger "manual" | dot `.runningModel` |
| `toolFailureAndDenialGoRunningModel` | prev `.runningTool` / prev `.waitingPermission`; `PostToolUseFailure` / `PermissionDenied` | both dot `.runningModel` |
| `idlePromptOnlyWhileRunning` | `Notification` idle_prompt on prev `.runningTool`, then on prev `.failed` | `.waiting`, then stays `.failed` |
| `permissionPromptOnlyWhileRunning` | `Notification` permission_prompt on prev `.runningTool`, then on prev `.waiting` | `.waitingPermission` with state `"needs permission"`, then stays `.waiting` |
| `untypedNotificationStillNoop` | prev `.runningTool`, `Notification` with no type | dot `.runningTool`, and `applyHookEvent(nil, <same event>, at: now) == nil` |

- [ ] **Step 2: Build.** Expected: compile errors (new init labels and Dot cases do not exist). That is the RED step on this machine.

- [ ] **Step 3: Decode.** Add the eight fields and their `CodingKeys` (`effort` is the key for `effortLevel`). Decode every new field with `try?` so an unexpected shape yields nil instead of failing the event. `effortLevel` comes from the nested object through a small private `Decodable` struct with `let level: String?`; do not name it `Effort` (taken in `Models.swift:75`). Add the memberwise init from the Interfaces block.

- [ ] **Step 4: Dot.** Add `compacting` (glyph `"🗜️"`) and `failed` (glyph `"🔴"`) and extend `isRunning`. In `Theme.state`: `.compacting` returns `accent`, `.failed` returns `danger`.

- [ ] **Step 5: Map the events in `applyHookEvent`.** The guards are the design, so take this switch as given (existing cases keep their bodies):

```swift
case "SessionStart" where e.source != "compact":   // compact variant falls to default: no false "finished" mid-turn
case "PostToolUse", "PostToolUseFailure", "PermissionDenied":   // runningModel, as PostToolUse today
case "StopFailure" where e.agent_id == nil:         // .failed, "failed: <error, underscores as spaces, default unknown>", toolName nil
case "PreCompact" where e.trigger == "manual" || prev?.dot.isRunning == true:   // .compacting, "compacting", toolName nil
case "PostCompact" where prev?.dot == .compacting:  // trigger "manual" -> .waiting "waiting prompt"; else .runningModel "running model"
case "Notification" where e.notification_type == "permission_prompt" && prev?.dot.isRunning == true:  // .waitingPermission "needs permission"
case "Notification" where e.notification_type == "idle_prompt" && prev?.dot.isRunning == true:        // .waiting "waiting prompt", toolName nil
```

Update the function's doc comment and the `default` comment so they name what still falls through (untyped/other Notification types, subagent StopFailure, ungated compaction events, SubagentStart/Stop, unknown), and say why each guard exists in one line: subagent events carry the parent `session_id`; async delivery can reorder a late `PostCompact` or notification after the next hook.

- [ ] **Step 6: Verify.** Run the TEST EXECUTION command. Expected: `Build complete!`, all 17 new `ok` lines, `exit=0`.

- [ ] **Step 7: README.** State badge line: add `🗜️ compacting · 🔴 failed (API error)` and note those two need the plugin.

- [ ] **Step 8: Commit**

```bash
git add Sources/ClaudeVitals/HookEvent.swift Sources/ClaudeVitals/Models.swift Sources/ClaudeVitals/Theme.swift Sources/ClaudeVitals/Entry.swift README.md
git commit -m "feat(hooks): map StopFailure, compaction, tool failure, denial and typed notifications"
```

---

### Task 3: Keep "failed" sticky and alert on it

**Files:**
- Modify: `Sources/ClaudeVitals/HookMerge.swift` (`resolveState` and its doc comment)
- Modify: `Sources/ClaudeVitals/Store.swift:4-25` (`AlertKind`, `TransitionTracker.update`)
- Modify: `Sources/ClaudeVitals/Integrations.swift:26-40` (`Notifier.notify`)
- Modify: `Sources/ClaudeVitals/Entry.swift` (`runSelfCheck`)
- Modify: `README.md` (Alerts paragraph)

**Interfaces:**
- Consumes: `Dot.failed`, `Dot.compacting`, `isRunning` from Task 2.
- Produces: `enum AlertKind { case finished, needsPermission, failed }`.

- [ ] **Step 1: Write the checks** in `runSelfCheck()`. `resolveState` checks reuse the existing `hook(_:_:at:)` helper. For the tracker, add a `func card(_ d: Dot) -> Block` helper (copy the `Block` field list from `Tests/ClaudeVitalsTests/TransitionTests.swift:5-9`, session id "a", repo "repo-a").

| check name | input | assertion |
|---|---|---|
| `failedSurvivesSupersessionWhileLivenessConfirmed` | heuristic `(.idle, "idle")`, `liveConfirmed: true`, hook `.failed` at -120, `transcriptMtime: now - 1` | dot `.failed`, `usedHook` |
| `failedFallsBackWhenLivenessUnconfirmed` | same, but `liveConfirmed: false` | dot `.idle`, `!usedHook` |
| `runningToFailedAlertsFailed` | tracker sees `.runningModel`, then `.failed` | alerts `== [Alert(repo: "repo-a", kind: .failed)]` |
| `autoCompactionIsSilent` | `.runningModel`, `.compacting`, `.runningModel` | every update returns `[]` |
| `manualCompactFinishingChimes` | `.compacting`, then `.waiting` | `== [Alert(repo: "repo-a", kind: .finished)]` |

- [ ] **Step 2: Build.** Expected: compile error on `.failed` as an `AlertKind`.

- [ ] **Step 3: Exempt `failed` from supersession** in `resolveState` next to `waitingPermission`. Rewrite the doc comment's exemption paragraph to cover both, and give `failed` its reason in one or two lines: after a terminal API error Claude Code still appends metadata lines (last-prompt, ai-title), and the heuristic would read the zero-usage `<synthetic>` error line as "running" and then "idle". Extend the `ponytail:` ceiling note: `failed` clears on the next hook event or when the session stops being confirmed live.

- [ ] **Step 4: Alert.** Add `AlertKind.failed`; in `TransitionTracker.update`, inside the existing `was.isRunning` block, `.failed` appends `.failed`. Update the struct's doc comment (it lists the transitions). In `Notifier.notify` add the case: title `alert.repo`, body `"Agent stopped on an API error"`.

- [ ] **Step 5: Verify.** TEST EXECUTION command. Expected: `Build complete!`, the 5 new `ok` lines, `exit=0`.

- [ ] **Step 6: README.** Alerts paragraph: alerts fire on running -> waiting, needs permission, or failed (failed needs the plugin).

- [ ] **Step 7: Commit**

```bash
git add Sources/ClaudeVitals/HookMerge.swift Sources/ClaudeVitals/Store.swift Sources/ClaudeVitals/Integrations.swift Sources/ClaudeVitals/Entry.swift README.md
git commit -m "feat(alerts): keep failed sticky under confirmed liveness and alert on it"
```

---

### Task 4: Ring and cost ignore API-error lines, ring follows compaction

**Files:**
- Modify: `Sources/ClaudeVitals/Models.swift` (`Message`, `Line`)
- Modify: `Sources/ClaudeVitals/Collector.swift:189-198` (`deriveContext`)
- Modify: `Sources/ClaudeVitals/TranscriptParser.swift:49` (`effort(path:)`)
- Modify: `Sources/ClaudeVitals/Entry.swift` (`runSelfCheck`)
- Modify: `README.md` (Context % line)

**Interfaces:**
- Produces:
  - `extension Message { var isSynthetic: Bool }`, true when `model == "<synthetic>"`.
  - `struct CompactMetadata: Decodable { let postTokens: Int? }`
  - `Line` gains `let subtype: String?` and `let compactMetadata: CompactMetadata?`, both decoded with `try?` like the existing fields.

- [ ] **Step 1: Write the checks** in `runSelfCheck()`. Build `[Line]` with `parseLines(Data(lines.joined(separator: "\n").utf8), dropFirstPartial: false)` from these fixtures:

```swift
let real = #"{"type":"assistant","message":{"model":"claude-opus-4-8","usage":{"input_tokens":10,"cache_read_input_tokens":300000,"cache_creation_input_tokens":0}}}"#
let synth = #"{"type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","stop_reason":"stop_sequence","usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
let boundary = #"{"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"manual","preTokens":300010,"postTokens":23336}}"#
let bareBoundary = #"{"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"auto"}}"#
```

| check name | lines (file order) | `deriveContext` assertion |
|---|---|---|
| `ringSkipsSyntheticLine` | real, synth | `(300010, 1_000_000, "claude-opus-4-8")` |
| `ringUsesCompactBoundary` | real, boundary | `(23336, 1_000_000, "claude-opus-4-8")` (window still from the pre-compaction usage) |
| `ringIgnoresOlderBoundary` | boundary, real | ctx `300010` |
| `ringIgnoresBoundaryWithoutPostTokens` | real, bareBoundary | ctx `300010` |

Plus `costIgnoresSyntheticModel`: write a temp `.jsonl` (each line newline-terminated) holding `{"type":"assistant","message":{"model":"claude-sonnet-4-6","stop_reason":"end_turn","usage":{"input_tokens":1000000,"output_tokens":0}}}` then `synth`; `TranscriptParser().effort(path:)` returns `model == "claude-sonnet-4-6"` and `abs(cost - 3.0) < 1e-9`. Remove the temp file afterwards.

- [ ] **Step 2: Build and run.** Expected: compile error only if you reference the new members; otherwise `FAIL ringSkipsSyntheticLine` (today the synthetic line wins with ctx 0 and model `<synthetic>`).

- [ ] **Step 3: Models.** Add `isSynthetic`, `CompactMetadata`, and the two `Line` fields per the Interfaces block.

- [ ] **Step 4: `deriveContext(_ lines: [Line]) -> (ctx: Int, limit: Int, model: String)`.** Walk backwards. Remember the `postTokens` of a `compact_boundary` seen BEFORE the first real usage line (a boundary without `postTokens` is ignored). Skip lines whose message `isSynthetic` or has no usage. At the first real usage line return `(postTokens ?? usedTokens, contextWindow(model: model, ctx: usedTokens), model)`: the window comes from the pre-compaction usage so the 1M floor (`ctx > 200_000`) still holds after a compact. With no real usage line, return `(postTokens ?? 0, 200_000, "?")`. Comment why synthetic lines are skipped (zero usage and model `<synthetic>` would drop the ring to 0% and mislabel the model).

- [ ] **Step 5: `TranscriptParser.effort(path:)`.** Skip assistant lines whose message `isSynthetic`, so `e.model` never becomes `<synthetic>` and the whole session is not re-priced at the opus fallback. One-line comment saying exactly that.

- [ ] **Step 6: Verify.** TEST EXECUTION command. Expected: `Build complete!`, the 5 new `ok` lines, `exit=0`. Then `bash Tests/e2e-liveness-check.sh` still prints only `ok` lines (it exercises `--dump`, which runs `deriveContext` on real transcripts).

- [ ] **Step 7: README.** Context % line: the latest real `usage` line (API-error placeholder lines skipped), or the compaction's post-compaction size right after a compaction.

- [ ] **Step 8: Commit**

```bash
git add Sources/ClaudeVitals/Models.swift Sources/ClaudeVitals/Collector.swift Sources/ClaudeVitals/TranscriptParser.swift Sources/ClaudeVitals/Entry.swift README.md
git commit -m "fix(collector): skip synthetic API-error lines and read the compaction size for the ring"
```
