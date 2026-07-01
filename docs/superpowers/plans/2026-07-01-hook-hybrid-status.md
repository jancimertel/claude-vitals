# Hook-Hybrid Status Feedback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Claude Code plugin whose lifecycle hooks push precise state events over a Unix domain socket to the Claude Vitals app, making agent status instant and accurate while the transcript stays the source of numbers.

**Architecture:** Hooks own state (keyed by `session_id`), transcripts own numbers, polling is the safety net. Each hook event flows `emit.sh -> nc -U -> vitals.sock -> EventSocket -> Collector.ingest -> Snapshot -> Store -> UI`. A per-session precedence rule uses fresh hook state when it exists and falls back to the existing `deriveState` heuristic otherwise, so un-instrumented sessions behave exactly as today.

**Tech Stack:** Swift 6.2 (SwiftPM executable target), AppKit/SwiftUI, POSIX AF_UNIX sockets, XCTest. Plugin is pure shell (`nc`, no `jq`).

## Global Constraints

- Platform floor: macOS 14 (`.macOS(.v14)`); developed on macOS 26.
- swift-tools-version 6.0; no new external package dependencies (stdlib/Foundation/AppKit/SwiftUI/Network/XCTest only).
- Plugin hooks MUST be `async: true` so monitoring never blocks a tool or turn.
- Plugin emit script MUST be dependency-free (no `jq`); it forwards stdin to the socket via `/usr/bin/nc -U`.
- The plugin is the only install path; the app never writes `~/.claude/settings.json`.
- Socket path: `~/.claude-vitals/vitals.sock`. The emit script honors `CLAUDE_VITALS_SOCK` for testability.
- Hook freshness window: `HOOK_FRESH_S = 15` seconds (hook state wins while newer than this).
- No em-dash characters (`-` only) anywhere, including code comments and commit messages.
- Follow existing code style: top-level free functions for pure logic, `actor Collector` owns cross-tick state, `@MainActor` `Store` owns UI state.
- TEST EXECUTION (environment): this machine has Command Line Tools only, no Xcode, so `XCTest` and `swift test` are unavailable. Write the XCTest files exactly as specified (they run later in Xcode/CI), but VERIFY each task with `swift build` (which does not compile test targets and so is unaffected by the missing XCTest). Ignore the plan's `swift test --filter ...` / RED-GREEN commands; substitute `swift build` (expect: "Build complete!"). Reviewers: do not treat un-run tests as a defect here, but still read the test code for correctness.
- Adding a `Dot` case requires updating every exhaustive switch over `Dot`: `Dot.glyph` (Models.swift) and `Theme.state(_:)` (Theme.swift). `waitingPermission` uses the amber `waiting` color (it is an attention state, not idle).

---

### Task 1: Add test target + `Dot.waitingPermission` state

**Files:**
- Modify: `Package.swift`
- Modify: `Sources/ClaudeVitals/Models.swift:56-69` (the `Dot` enum)
- Test: `Tests/ClaudeVitalsTests/DotTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `Dot.waitingPermission` case; `Dot.glyph` returns `"🔐"` for it; `Dot.isRunning` is `false` for it. A working `ClaudeVitalsTests` XCTest target that can `@testable import ClaudeVitals`.

- [ ] **Step 1: Add the test target to `Package.swift`**

Replace the `targets:` array so it includes a test target:

```swift
    targets: [
        .executableTarget(
            name: "ClaudeVitals",
            path: "Sources/ClaudeVitals"
        ),
        .testTarget(
            name: "ClaudeVitalsTests",
            dependencies: ["ClaudeVitals"],
            path: "Tests/ClaudeVitalsTests"
        )
    ]
```

- [ ] **Step 2: Write the failing test**

Create `Tests/ClaudeVitalsTests/DotTests.swift`:

```swift
import XCTest
@testable import ClaudeVitals

final class DotTests: XCTestCase {
    func testWaitingPermissionGlyphAndNotRunning() {
        XCTAssertEqual(Dot.waitingPermission.glyph, "🔐")
        XCTAssertFalse(Dot.waitingPermission.isRunning)
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter DotTests`
Expected: FAIL to compile with "type 'Dot' has no member 'waitingPermission'".

- [ ] **Step 4: Add the case**

In `Sources/ClaudeVitals/Models.swift`, change the `Dot` enum to add the case and glyph:

```swift
enum Dot: String, Sendable, Equatable {
    case runningModel, runningTool, waiting, waitingPermission, idle, ended

    var glyph: String {
        switch self {
        case .runningModel:      return "🟢"
        case .runningTool:       return "🔧"
        case .waiting:           return "🟡"
        case .waitingPermission: return "🔐"
        case .idle:              return "⚪️"
        case .ended:             return "⚫️"
        }
    }
    var isRunning: Bool { self == .runningModel || self == .runningTool }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter DotTests`
Expected: PASS (also confirms the test target builds and can import the executable module).

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/ClaudeVitals/Models.swift Tests/ClaudeVitalsTests/DotTests.swift
git commit -m "Add waitingPermission Dot state and test target"
```

---

### Task 2: `HookEvent`, `HookStatus`, and the event reducer

**Files:**
- Create: `Sources/ClaudeVitals/HookEvent.swift`
- Test: `Tests/ClaudeVitalsTests/HookEventTests.swift`

**Interfaces:**
- Consumes: `Dot` (Task 1).
- Produces:
  - `struct HookEvent: Decodable, Sendable { let event: String; let session_id: String; let cwd: String?; let transcript_path: String?; let tool_name: String? }` (CodingKeys map `event` to JSON `hook_event_name`).
  - `struct HookStatus: Sendable { var dot: Dot; var state: String; var toolName: String?; var alive: Bool; var at: Date }`
  - `func applyHookEvent(_ prev: HookStatus?, _ e: HookEvent, at now: Date) -> HookStatus`
  - `let HOOK_FRESH_S: TimeInterval = 15`

- [ ] **Step 1: Write the failing test**

Create `Tests/ClaudeVitalsTests/HookEventTests.swift`:

```swift
import XCTest
@testable import ClaudeVitals

final class HookEventTests: XCTestCase {
    private func decode(_ json: String) throws -> HookEvent {
        try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
    }

    func testDecodeMapsHookEventName() throws {
        let e = try decode(#"{"hook_event_name":"PreToolUse","session_id":"abc","cwd":"/r","transcript_path":"/t.jsonl","tool_name":"Bash"}"#)
        XCTAssertEqual(e.event, "PreToolUse")
        XCTAssertEqual(e.session_id, "abc")
        XCTAssertEqual(e.tool_name, "Bash")
    }

    func testDecodeToleratesMissingOptionalFields() throws {
        let e = try decode(#"{"hook_event_name":"Stop","session_id":"abc"}"#)
        XCTAssertEqual(e.event, "Stop")
        XCTAssertNil(e.tool_name)
        XCTAssertNil(e.transcript_path)
    }

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testPreToolUseGoesRunningToolWithName() {
        let e = HookEvent(event: "PreToolUse", session_id: "s", cwd: nil, transcript_path: nil, tool_name: "Bash")
        let s = applyHookEvent(nil, e, at: t0)
        XCTAssertEqual(s.dot, .runningTool)
        XCTAssertEqual(s.state, "running Bash")
        XCTAssertEqual(s.toolName, "Bash")
        XCTAssertTrue(s.alive)
        XCTAssertEqual(s.at, t0)
    }

    func testPermissionRequestGoesWaitingPermission() {
        let e = HookEvent(event: "PermissionRequest", session_id: "s", cwd: nil, transcript_path: nil, tool_name: "Bash")
        let s = applyHookEvent(nil, e, at: t0)
        XCTAssertEqual(s.dot, .waitingPermission)
        XCTAssertEqual(s.state, "needs permission")
    }

    func testStopGoesWaitingPrompt() {
        let e = HookEvent(event: "Stop", session_id: "s", cwd: nil, transcript_path: nil, tool_name: nil)
        let s = applyHookEvent(nil, e, at: t0)
        XCTAssertEqual(s.dot, .waiting)
        XCTAssertEqual(s.state, "waiting prompt")
    }

    func testSessionEndGoesEndedNotAlive() {
        let e = HookEvent(event: "SessionEnd", session_id: "s", cwd: nil, transcript_path: nil, tool_name: nil)
        let s = applyHookEvent(nil, e, at: t0)
        XCTAssertEqual(s.dot, .ended)
        XCTAssertFalse(s.alive)
    }

    func testSubagentEventsDoNotChangeStateButBumpTimestamp() {
        let base = applyHookEvent(nil, HookEvent(event: "PreToolUse", session_id: "s", cwd: nil, transcript_path: nil, tool_name: "Bash"), at: t0)
        let later = t0.addingTimeInterval(3)
        let e = HookEvent(event: "SubagentStart", session_id: "s", cwd: nil, transcript_path: nil, tool_name: nil)
        let s = applyHookEvent(base, e, at: later)
        XCTAssertEqual(s.dot, .runningTool)      // unchanged
        XCTAssertEqual(s.at, later)              // timestamp advanced (keeps hook state fresh)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter HookEventTests`
Expected: FAIL to compile with "cannot find 'HookEvent' in scope".

- [ ] **Step 3: Implement `HookEvent.swift`**

Create `Sources/ClaudeVitals/HookEvent.swift`:

```swift
import Foundation

/// Hook state wins over the transcript heuristic while its last event is newer than this.
let HOOK_FRESH_S: TimeInterval = 15

/// One lifecycle event delivered by the Claude Code plugin over the socket. Field names mirror the
/// hook stdin payload; `event` maps the payload's `hook_event_name`.
struct HookEvent: Decodable, Sendable {
    let event: String
    let session_id: String
    let cwd: String?
    let transcript_path: String?
    let tool_name: String?

    enum CodingKeys: String, CodingKey {
        case event = "hook_event_name"
        case session_id, cwd, transcript_path, tool_name
    }

    init(event: String, session_id: String, cwd: String?, transcript_path: String?, tool_name: String?) {
        self.event = event; self.session_id = session_id
        self.cwd = cwd; self.transcript_path = transcript_path; self.tool_name = tool_name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        event = try c.decode(String.self, forKey: .event)
        session_id = try c.decode(String.self, forKey: .session_id)
        cwd = try? c.decodeIfPresent(String.self, forKey: .cwd)
        transcript_path = try? c.decodeIfPresent(String.self, forKey: .transcript_path)
        tool_name = try? c.decodeIfPresent(String.self, forKey: .tool_name)
    }
}

/// The current hook-derived state for one session. `at` is receipt time (used for the freshness gate).
struct HookStatus: Sendable {
    var dot: Dot
    var state: String
    var toolName: String?
    var alive: Bool
    var at: Date
}

/// Fold one event into the running per-session status. Numbers (tokens/ctx/cost) are NOT tracked here;
/// they come from the transcript. Subagent events carry no state change - they exist only to trigger an
/// immediate re-parse (which recomputes the file-based subagent count) at the call site.
func applyHookEvent(_ prev: HookStatus?, _ e: HookEvent, at now: Date) -> HookStatus {
    var s = prev ?? HookStatus(dot: .idle, state: "idle", toolName: nil, alive: true, at: now)
    s.at = now
    switch e.event {
    case "SessionStart":      s.alive = true;  s.dot = .waiting;          s.state = "waiting prompt"; s.toolName = nil
    case "SessionEnd":        s.alive = false; s.dot = .ended;            s.state = "ended";          s.toolName = nil
    case "UserPromptSubmit":  s.dot = .runningModel; s.state = "running model"; s.toolName = nil
    case "PreToolUse":        s.dot = .runningTool;  s.state = "running \(e.tool_name ?? "tool")"; s.toolName = e.tool_name
    case "PostToolUse":       s.dot = .runningModel; s.state = "running model"; s.toolName = nil
    case "PermissionRequest": s.dot = .waitingPermission; s.state = "needs permission"; s.toolName = e.tool_name
    case "Stop":              s.dot = .waiting;      s.state = "waiting prompt"; s.toolName = nil
    // Notification is a backstop (PermissionRequest/Stop carry the real transitions); subagent events
    // only trigger a re-parse. All three just refresh the timestamp (via s.at = now above), no state change.
    case "Notification", "SubagentStart", "SubagentStop": break
    default: break
    }
    return s
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter HookEventTests`
Expected: PASS (all 7 cases).

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeVitals/HookEvent.swift Tests/ClaudeVitalsTests/HookEventTests.swift
git commit -m "Add HookEvent, HookStatus, and event reducer"
```

---

### Task 3: `resolveState` precedence (pure merge)

**Files:**
- Create: `Sources/ClaudeVitals/HookMerge.swift`
- Test: `Tests/ClaudeVitalsTests/HookMergeTests.swift`

**Interfaces:**
- Consumes: `Dot`, `HookStatus`, `HOOK_FRESH_S`.
- Produces: `func resolveState(heuristic: (dot: Dot, state: String), isLive: Bool, hook: HookStatus?, now: Date) -> (dot: Dot, state: String, live: Bool, usedHook: Bool)`

- [ ] **Step 1: Write the failing test**

Create `Tests/ClaudeVitalsTests/HookMergeTests.swift`:

```swift
import XCTest
@testable import ClaudeVitals

final class HookMergeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)
    private let heuristic: (dot: Dot, state: String) = (.runningTool, "running tool")

    func testNoHookFallsBackToHeuristic() {
        let r = resolveState(heuristic: heuristic, isLive: true, hook: nil, now: now)
        XCTAssertEqual(r.dot, .runningTool)
        XCTAssertEqual(r.state, "running tool")
        XCTAssertTrue(r.live)
        XCTAssertFalse(r.usedHook)
    }

    func testFreshHookWins() {
        let hook = HookStatus(dot: .waitingPermission, state: "needs permission", toolName: "Bash", alive: true, at: now.addingTimeInterval(-2))
        let r = resolveState(heuristic: heuristic, isLive: true, hook: hook, now: now)
        XCTAssertEqual(r.dot, .waitingPermission)
        XCTAssertEqual(r.state, "needs permission")
        XCTAssertTrue(r.usedHook)
    }

    func testStaleHookIsIgnored() {
        let hook = HookStatus(dot: .waitingPermission, state: "needs permission", toolName: nil, alive: true, at: now.addingTimeInterval(-(HOOK_FRESH_S + 1)))
        let r = resolveState(heuristic: heuristic, isLive: true, hook: hook, now: now)
        XCTAssertEqual(r.dot, .runningTool)      // heuristic
        XCTAssertFalse(r.usedHook)
    }

    func testHookLivenessOverridesProcessLiveness() {
        let hook = HookStatus(dot: .ended, state: "ended", toolName: nil, alive: false, at: now)
        let r = resolveState(heuristic: heuristic, isLive: true, hook: hook, now: now)
        XCTAssertEqual(r.dot, .ended)
        XCTAssertFalse(r.live)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter HookMergeTests`
Expected: FAIL to compile with "cannot find 'resolveState' in scope".

- [ ] **Step 3: Implement `HookMerge.swift`**

Create `Sources/ClaudeVitals/HookMerge.swift`:

```swift
import Foundation

/// Per-session precedence: a hook event newer than HOOK_FRESH_S is authoritative for state and liveness;
/// otherwise the existing transcript heuristic drives the card (so un-instrumented sessions are unchanged
/// and a session whose plugin was disabled degrades gracefully after one window).
func resolveState(heuristic: (dot: Dot, state: String), isLive: Bool, hook: HookStatus?, now: Date)
    -> (dot: Dot, state: String, live: Bool, usedHook: Bool) {
    if let h = hook, now.timeIntervalSince(h.at) < HOOK_FRESH_S {
        return (h.dot, h.state, h.alive, true)
    }
    return (heuristic.dot, heuristic.state, isLive, false)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter HookMergeTests`
Expected: PASS (all 4 cases).

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeVitals/HookMerge.swift Tests/ClaudeVitalsTests/HookMergeTests.swift
git commit -m "Add resolveState hook/heuristic precedence merge"
```

---

### Task 4: Wire hooks into `buildSnapshot` and add `Collector.ingest`

**Files:**
- Modify: `Sources/ClaudeVitals/Collector.swift:227-244` (`candidateFiles`), `:294-344` (`buildSnapshot`), `:346-355` (`Collector` actor + `buildSnapshot()` one-shot)
- Modify: `Sources/ClaudeVitals/Models.swift:104-113` (`Snapshot` gains `hookDriven`)
- Test: `Tests/ClaudeVitalsTests/IngestTests.swift`

**Interfaces:**
- Consumes: `HookEvent`, `HookStatus`, `applyHookEvent`, `resolveState`, `HOOK_FRESH_S`, `RECENT_WINDOW`.
- Produces:
  - `Snapshot.hookDriven: Bool`
  - `buildSnapshot(parser:cache:hooks:hookFiles:)` with `hooks: [String: HookStatus] = [:]` and `hookFiles: Set<String> = []`
  - `Collector.ingest(_ e: HookEvent) -> Snapshot`

- [ ] **Step 1: Add `hookDriven` to `Snapshot` (Models.swift)**

Replace the `Snapshot` struct in `Sources/ClaudeVitals/Models.swift`:

```swift
struct Snapshot: Sendable {
    let blocks: [Block]
    let running: Int
    let subsRunning: Int
    let totalIn: Int, totalOut: Int, totalCw: Int, totalCr: Int
    let totalCost: Double
    let hookDriven: Bool   // any card currently backed by fresh hook state

    static let empty = Snapshot(blocks: [], running: 0, subsRunning: 0,
                                totalIn: 0, totalOut: 0, totalCw: 0, totalCr: 0, totalCost: 0,
                                hookDriven: false)
}
```

- [ ] **Step 2: Write the failing test**

Create `Tests/ClaudeVitalsTests/IngestTests.swift`. This drives a real `Collector` through a fresh session created under a temp `HOME`-independent transcript is not possible because `PROJ` is fixed; instead assert the ingest+merge path against the actor's returned snapshot for a synthetic session file the test writes into the real `PROJ`, then cleans up.

```swift
import XCTest
@testable import ClaudeVitals

final class IngestTests: XCTestCase {
    // A throwaway project dir + session file under the real PROJ, cleaned up after.
    private func makeSession() throws -> (dir: URL, file: URL, sessionId: String) {
        let sessionId = "test-\(UUID().uuidString)"
        let dir = PROJ.appendingPathComponent("-tmp-claudevitals-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(sessionId).jsonl")
        let line = #"{"type":"assistant","cwd":"/tmp/repo","gitBranch":"main","message":{"role":"assistant","model":"claude-opus-4-8","stop_reason":"end_turn","usage":{"input_tokens":10}}}"#
        try (line + "\n").write(to: file, atomically: true, encoding: .utf8)
        return (dir, file, sessionId)
    }

    func testIngestPermissionRequestFlipsCardToWaitingPermission() async throws {
        let s = try makeSession()
        defer { try? FileManager.default.removeItem(at: s.dir) }
        let collector = Collector()
        let e = HookEvent(event: "PermissionRequest", session_id: s.sessionId,
                          cwd: "/tmp/repo", transcript_path: s.file.path, tool_name: "Bash")
        let snap = await collector.ingest(e)
        let block = snap.blocks.first { $0.sessionId == s.sessionId }
        XCTAssertNotNil(block, "ingested session should appear as a card")
        XCTAssertEqual(block?.dot, .waitingPermission)
        XCTAssertTrue(snap.hookDriven)
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter IngestTests`
Expected: FAIL to compile with "extra argument 'hookDriven'" already resolved by Step 1, then FAIL with "value of type 'Collector' has no member 'ingest'".

- [ ] **Step 4: Update `candidateFiles` to accept extra files (Collector.swift)**

Replace `candidateFiles` so hook-seeded transcript paths are always included:

```swift
/// Every PROJ/*/*.jsonl touched < RECENT_WINDOW (grace), plus each live repo's active session (always),
/// plus any hook-seeded transcript paths (a brand-new session emits SessionStart before its file ages in).
func candidateFiles(live: [String: Int], extra: Set<String> = []) -> Set<String> {
    let fm = FileManager.default
    let now = Date()
    var files = Set<String>()

    if let dirs = try? fm.contentsOfDirectory(at: PROJ, includingPropertiesForKeys: [.isDirectoryKey]) {
        for dir in dirs {
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            guard let sessions = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for f in sessions where f.pathExtension == "jsonl" {
                if let m = mtime(f.path), now.timeIntervalSince(m) < RECENT_WINDOW { files.insert(f.path) }
            }
        }
    }
    return files.union(liveSessionFiles(live: live)).union(extra.filter { FileManager.default.fileExists(atPath: $0) })
}
```

- [ ] **Step 5: Thread hooks through `buildSnapshot` (Collector.swift)**

Change the `buildSnapshot(parser:cache:)` signature and the per-session merge. Replace the function header and the state/append region:

```swift
func buildSnapshot(parser: TranscriptParser, cache: CollectorCache,
                   hooks: [String: HookStatus] = [:], hookFiles: Set<String> = []) -> Snapshot {
    let live = liveRepos(cache: cache)
    let activeFiles = liveSessionFiles(live: live)   // the exact session each live agent is driving
    let now = Date()
    var blocks: [Block] = []
    var anyHookDriven = false
    let candidates = candidateFiles(live: live, extra: hookFiles)

    for f in candidates {
        guard let m = mtime(f) else { continue }
        let age = now.timeIntervalSince(m)
        let ps = parseSession(f, mtime: m, size: fileSize(f), cache: cache)
        let (headCwd, branch) = headMetaCached(f, cache: cache)
        let (subsTotal, subsRunning) = deriveSubagents(f)
        let e = parser.effort(path: f)

        let sessionId = URL(fileURLWithPath: f).deletingPathExtension().lastPathComponent
        let heuristicIsLive = activeFiles.contains(f)
        let dirName = URL(fileURLWithPath: f).deletingLastPathComponent().lastPathComponent
        let liveMatch = live.first { encodeRepo($0.key) == dirName }
        let cwd = headCwd.isEmpty ? (liveMatch?.key ?? "") : headCwd
        let repo = cwd.isEmpty ? dirName : URL(fileURLWithPath: cwd).lastPathComponent

        let heuristic = deriveState(lastType: ps.lastType, lastStop: ps.lastStop, asksUser: ps.asksUser, age: age, isLive: heuristicIsLive)
        let resolved = resolveState(heuristic: (heuristic.0, heuristic.1), isLive: heuristicIsLive, hook: hooks[sessionId], now: now)
        if resolved.usedHook { anyHookDriven = true }

        blocks.append(Block(
            sessionId: sessionId,
            repo: repo, cwd: cwd, branch: branch, age: Int(age),
            dot: resolved.dot, state: resolved.state,
            ctx: ps.ctx, ctxLimit: ps.ctxLimit, ctxPct: ps.ctxLimit > 0 ? Double(ps.ctx) / Double(ps.ctxLimit) * 100 : 0,
            model: ps.ctxModel == "?" ? e.model : ps.ctxModel,
            inTok: e.inTok, outTok: e.outTok, cw: e.cw, cr: e.cr, cost: e.cost,
            turns: e.turns, tools: e.tools,
            subsTotal: subsTotal, subsRunning: subsRunning,
            live: resolved.live, pids: liveMatch?.value ?? 0))
    }

    cache.parsed = cache.parsed.filter { candidates.contains($0.key) }

    blocks.sort { (($0.live ? 0 : 1), $0.age) < (($1.live ? 0 : 1), $1.age) }

    return Snapshot(
        blocks: blocks,
        running: blocks.filter { $0.dot.isRunning }.count,
        subsRunning: blocks.reduce(0) { $0 + $1.subsRunning },
        totalIn: blocks.reduce(0) { $0 + $1.inTok },
        totalOut: blocks.reduce(0) { $0 + $1.outTok },
        totalCw: blocks.reduce(0) { $0 + $1.cw },
        totalCr: blocks.reduce(0) { $0 + $1.cr },
        totalCost: blocks.reduce(0) { $0 + $1.cost },
        hookDriven: anyHookDriven)
}
```

- [ ] **Step 6: Add hook state + `ingest` to the `Collector` actor (Collector.swift)**

Replace the `Collector` actor:

```swift
/// GUI path: persistent caches live inside the actor, so each refresh only re-reads files that
/// changed and only `lsof`s newly-seen pids (effort stays O(appended bytes)). Hook state also lives
/// here so all state funnels through one actor (no extra locking).
actor Collector {
    private let parser = TranscriptParser()
    private let cache = CollectorCache()
    private var hooks: [String: HookStatus] = [:]
    private var hookFiles: Set<String> = []

    func snapshot() -> Snapshot { buildSnapshot(parser: parser, cache: cache, hooks: hooks, hookFiles: hookFiles) }

    /// Fold one hook event into per-session state, seed its transcript as a candidate, and rebuild.
    func ingest(_ e: HookEvent) -> Snapshot {
        hooks[e.session_id] = applyHookEvent(hooks[e.session_id], e, at: Date())
        if let tp = e.transcript_path { hookFiles.insert(tp) }
        let cutoff = Date().addingTimeInterval(-RECENT_WINDOW)
        hooks = hooks.filter { $0.value.at > cutoff }        // bound growth
        return buildSnapshot(parser: parser, cache: cache, hooks: hooks, hookFiles: hookFiles)
    }
}
```

- [ ] **Step 7: Run test to verify it passes**

Run: `swift test --filter IngestTests`
Expected: PASS. Also run the whole suite to confirm nothing regressed: `swift test`
Expected: PASS (DotTests, HookEventTests, HookMergeTests, IngestTests).

- [ ] **Step 8: Commit**

```bash
git add Sources/ClaudeVitals/Collector.swift Sources/ClaudeVitals/Models.swift Tests/ClaudeVitalsTests/IngestTests.swift
git commit -m "Merge hook state into buildSnapshot; add Collector.ingest"
```

---

### Task 5: `EventSocket` (POSIX AF_UNIX listener)

**Files:**
- Create: `Sources/ClaudeVitals/EventSocket.swift`
- Test: `Tests/ClaudeVitalsTests/EventSocketTests.swift`

**Interfaces:**
- Consumes: `HookEvent`.
- Produces:
  - `let VITALS_DIR: URL` (= `~/.claude-vitals`) and `let VITALS_SOCK: String` (= `~/.claude-vitals/vitals.sock`)
  - `final class EventSocket { init(path: String, onEvent: @escaping @Sendable (HookEvent) -> Void); func start(); func stop() }`

- [ ] **Step 1: Write the failing test**

Create `Tests/ClaudeVitalsTests/EventSocketTests.swift`. It starts the listener on a temp path, connects with a raw POSIX client, writes one JSON line, and asserts the decoded event arrives:

```swift
import XCTest
@testable import ClaudeVitals

final class EventSocketTests: XCTestCase {
    func testReceivesAndDecodesOneEvent() throws {
        let path = NSTemporaryDirectory() + "vitals-test-\(UUID().uuidString).sock"
        let got = expectation(description: "event received")
        var received: HookEvent?
        let socket = EventSocket(path: path) { e in received = e; got.fulfill() }
        socket.start()
        defer { socket.stop() }

        // Give the listener a moment to bind.
        Thread.sleep(forTimeInterval: 0.1)

        // Raw client: connect, write one JSON line, close (EOF signals end-of-message).
        let fd = socket_client_connect(path)
        XCTAssertGreaterThanOrEqual(fd, 0, "client should connect")
        let json = #"{"hook_event_name":"Stop","session_id":"xyz"}"#
        _ = json.withCString { write(fd, $0, strlen($0)) }
        close(fd)

        wait(for: [got], timeout: 2.0)
        XCTAssertEqual(received?.event, "Stop")
        XCTAssertEqual(received?.session_id, "xyz")
    }

    // Minimal AF_UNIX client used only by this test.
    private func socket_client_connect(_ path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { p in
            path.withCString { strncpy(p, $0, MemoryLayout.size(ofValue: addr.sun_path) - 1) }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        if r != 0 { close(fd); return -1 }
        return fd
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter EventSocketTests`
Expected: FAIL to compile with "cannot find 'EventSocket' in scope".

- [ ] **Step 3: Implement `EventSocket.swift`**

Create `Sources/ClaudeVitals/EventSocket.swift`:

```swift
import Foundation

let VITALS_DIR = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude-vitals")
let VITALS_SOCK = VITALS_DIR.appendingPathComponent("vitals.sock").path

/// AF_UNIX stream listener. Each hook connection writes one JSON line then closes; we read to EOF,
/// decode a HookEvent, and hand it to `onEvent` off the main thread. Plain POSIX sockets (Network
/// framework has no public UNIX-domain listener), which are rock solid for this.
final class EventSocket {
    private let path: String
    private let onEvent: @Sendable (HookEvent) -> Void
    private var fd: Int32 = -1
    private var running = false
    private let queue = DispatchQueue(label: "com.claudevitals.socket")

    init(path: String, onEvent: @escaping @Sendable (HookEvent) -> Void) {
        self.path = path
        self.onEvent = onEvent
    }

    func start() {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        unlink(path)                                    // clear any stale socket from a previous run

        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { p in
            path.withCString { strncpy(p, $0, MemoryLayout.size(ofValue: addr.sun_path) - 1) }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0, listen(fd, 32) == 0 else { close(fd); fd = -1; return }

        running = true
        queue.async { [weak self] in self?.acceptLoop() }
    }

    private func acceptLoop() {
        while running {
            let client = accept(fd, nil, nil)
            if client < 0 { break }
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(client, &buf, buf.count)
                if n <= 0 { break }
                data.append(contentsOf: buf[0..<n])
            }
            close(client)
            // A line-delimited payload may include a trailing newline; JSONDecoder tolerates it.
            if let e = try? JSONDecoder().decode(HookEvent.self, from: data) {
                onEvent(e)
            }
        }
    }

    func stop() {
        running = false
        if fd >= 0 { close(fd); fd = -1 }
        unlink(path)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter EventSocketTests`
Expected: PASS (event received and decoded).

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeVitals/EventSocket.swift Tests/ClaudeVitalsTests/EventSocketTests.swift
git commit -m "Add EventSocket AF_UNIX listener with round-trip test"
```

---

### Task 6: Wire the socket into `Store` + distinct alerts + hook-aware poll

**Files:**
- Modify: `Sources/ClaudeVitals/Store.swift:4-21` (`TransitionTracker`), `:23-49` (`Store` init + loop), `:82-89` (`apply`)
- Modify: `Sources/ClaudeVitals/Integrations.swift` (Notifier text for the two alert kinds)
- Test: `Tests/ClaudeVitalsTests/TransitionTests.swift`

**Interfaces:**
- Consumes: `EventSocket`, `VITALS_SOCK`, `Collector.ingest`, `HookEvent`, `Dot`, `Snapshot.hookDriven`.
- Produces:
  - `enum AlertKind: Sendable { case finished, needsPermission }`
  - `struct Alert: Sendable, Equatable { let repo: String; let kind: AlertKind }`
  - `TransitionTracker.update(_ blocks: [Block]) -> [Alert]`

- [ ] **Step 1: Write the failing test**

Create `Tests/ClaudeVitalsTests/TransitionTests.swift`:

```swift
import XCTest
@testable import ClaudeVitals

final class TransitionTests: XCTestCase {
    private func block(_ id: String, _ dot: Dot) -> Block {
        Block(sessionId: id, repo: "repo-\(id)", cwd: "", branch: "", age: 0, dot: dot, state: "",
              ctx: 0, ctxLimit: 200_000, ctxPct: 0, model: "?", inTok: 0, outTok: 0, cw: 0, cr: 0,
              cost: 0, turns: 0, tools: 0, subsTotal: 0, subsRunning: 0, live: true, pids: 1)
    }

    func testRunningToWaitingEmitsFinished() {
        var t = TransitionTracker()
        _ = t.update([block("a", .runningModel)])
        let alerts = t.update([block("a", .waiting)])
        XCTAssertEqual(alerts, [Alert(repo: "repo-a", kind: .finished)])
    }

    func testRunningToPermissionEmitsNeedsPermission() {
        var t = TransitionTracker()
        _ = t.update([block("a", .runningTool)])
        let alerts = t.update([block("a", .waitingPermission)])
        XCTAssertEqual(alerts, [Alert(repo: "repo-a", kind: .needsPermission)])
    }

    func testNoAlertWhenStayingRunning() {
        var t = TransitionTracker()
        _ = t.update([block("a", .runningModel)])
        XCTAssertEqual(t.update([block("a", .runningTool)]), [])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TransitionTests`
Expected: FAIL to compile with "cannot find 'Alert' in scope".

- [ ] **Step 3: Rewrite `TransitionTracker` to emit typed alerts (Store.swift)**

Replace the top of `Sources/ClaudeVitals/Store.swift` (the `TransitionTracker` struct) with:

```swift
enum AlertKind: Sendable { case finished, needsPermission }
struct Alert: Sendable, Equatable { let repo: String; let kind: AlertKind }

/// Edge detector: fire alerts only on running -> waiting/permission transitions (not every poll).
struct TransitionTracker {
    private var prev: [String: Dot] = [:]

    mutating func update(_ blocks: [Block]) -> [Alert] {
        var alerts: [Alert] = []
        var seen = Set<String>()
        for b in blocks {
            seen.insert(b.sessionId)
            if let was = prev[b.sessionId], was.isRunning {
                if b.dot == .waitingPermission { alerts.append(Alert(repo: b.repo, kind: .needsPermission)) }
                else if b.dot == .waiting { alerts.append(Alert(repo: b.repo, kind: .finished)) }
            }
            prev[b.sessionId] = b.dot
        }
        prev = prev.filter { seen.contains($0.key) }   // prune ended sessions
        return alerts
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TransitionTests`
Expected: PASS.

- [ ] **Step 5: Update `Notifier` for two alert kinds (Integrations.swift)**

In `Sources/ClaudeVitals/Integrations.swift`, replace the existing `notifyWaiting(repo:)` method (lines 19-27) with a kind-aware `notify(_:)` that keeps the same bundle guard and no-sound behavior:

```swift
    func notify(_ alert: Alert) {
        guard AppEnv.isBundled else { return }
        let content = UNMutableNotificationContent()
        switch alert.kind {
        case .finished:
            content.title = alert.repo
            content.body = "Agent finished - waiting for your prompt"
        case .needsPermission:
            content.title = alert.repo
            content.body = "Agent needs permission to continue"
        }
        content.sound = nil   // NSSound already chimes; avoid a double-ding
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
```

`notifyWaiting(repo:)` has no other callers (only `Store.apply` used it, and Step 6 switches that to `notify(_:)`), so replacing it is safe.

- [ ] **Step 6: Wire `EventSocket` + alert routing + hook-aware cadence into `Store` (Store.swift)**

Update the `Store` class. Add the socket property and start it in `init`; route socket events through `ingest`; make the poll interval hook-aware; and update `apply` to dispatch typed alerts.

```swift
    private let collector = Collector()
    private var tracker = TransitionTracker()
    private var loop: Task<Void, Never>?
    private var usageLoop: Task<Void, Never>?
    private var lastUsageFetch: Date = .distantPast
    private var socket: EventSocket?

    init() { start(); startUsage(); startSocket() }

    deinit { loop?.cancel(); usageLoop?.cancel(); socket?.stop() }

    /// Hook events -> immediate targeted rebuild (no waiting for the poll tick).
    private func startSocket() {
        let s = EventSocket(path: VITALS_SOCK) { [weak self] e in
            Task { @MainActor in await self?.handleHookEvent(e) }
        }
        s.start()
        socket = s
    }

    private func handleHookEvent(_ e: HookEvent) async {
        let snap = await collector.ingest(e)
        apply(snap)
    }
```

Change the poll loop so it backs off to 5s whenever hooks are actively driving state (they deliver transitions instantly), while un-instrumented sessions keep the responsive 1.5s busy cadence:

```swift
    private func start() {
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let s = await self.collector.snapshot()
                self.apply(s)
                let busy = s.running > 0 || s.subsRunning > 0
                let interval: Double = s.hookDriven ? 5 : (busy ? 1.5 : 5)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }
```

Update `apply` to route typed alerts:

```swift
    private func apply(_ s: Snapshot) {
        for alert in tracker.update(s.blocks) {
            Chime.play()
            if AppEnv.isBundled { Notifier.shared.notify(alert) }
        }
        snap = s
        labelImage = renderLabelImage()
    }
```

- [ ] **Step 7: Build and run the full suite**

Run: `swift build`
Expected: builds with no errors.
Run: `swift test`
Expected: PASS (all suites).

- [ ] **Step 8: Commit**

```bash
git add Sources/ClaudeVitals/Store.swift Sources/ClaudeVitals/Integrations.swift Tests/ClaudeVitalsTests/TransitionTests.swift
git commit -m "Wire EventSocket into Store; distinct permission alert; hook-aware poll"
```

---

### Task 7: `--emit` debug subcommand

**Files:**
- Modify: `Sources/ClaudeVitals/Entry.swift`

**Interfaces:**
- Consumes: `VITALS_SOCK`, `HookEvent`.
- Produces: `ClaudeVitals --emit <EventName> [session_id]` connects to the socket and sends one synthetic event (manual/integration testing without Claude Code).

- [ ] **Step 1: Add the `--emit` branch to `Entry.main` (Entry.swift)**

At the top of `main()`, before the `--dump` check, add:

```swift
        if let i = CommandLine.arguments.firstIndex(of: "--emit"), i + 1 < CommandLine.arguments.count {
            let event = CommandLine.arguments[i + 1]
            let sid = (i + 2 < CommandLine.arguments.count) ? CommandLine.arguments[i + 2] : "debug-session"
            emitDebug(event: event, sessionId: sid)
            return
        }
```

Add the helper to `Entry`:

```swift
    static func emitDebug(event: String, sessionId: String) {
        let json = #"{"hook_event_name":"\#(event)","session_id":"\#(sessionId)","tool_name":"Bash"}"#
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { print("socket() failed"); return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { p in
            VITALS_SOCK.withCString { strncpy(p, $0, MemoryLayout.size(ofValue: addr.sun_path) - 1) }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        if r != 0 { print("connect() failed - is the app running?"); close(fd); return }
        _ = json.withCString { write(fd, $0, strlen($0)) }
        close(fd)
        print("emitted \(event) for \(sessionId)")
    }
```

Entry.swift already `import AppKit`; add `import Foundation` if the POSIX symbols do not resolve (they come in via Foundation/Darwin).

- [ ] **Step 2: Build**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 3: Manual smoke test**

In one terminal: `swift run ClaudeVitals` (launches the app; the socket binds).
In another: `swift run ClaudeVitals --emit PermissionRequest my-session`
Expected: prints `emitted PermissionRequest for my-session`; the app's menu-bar popover shows a card for `my-session` in the 🔐 "needs permission" state within a moment.

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeVitals/Entry.swift
git commit -m "Add --emit debug subcommand for synthetic hook events"
```

---

### Task 8: The plugin (`plugin/claude-vitals/`) + README

**Files:**
- Create: `plugin/claude-vitals/plugin.json`
- Create: `plugin/claude-vitals/hooks/hooks.json`
- Create: `plugin/claude-vitals/hooks/emit.sh`
- Test: `Tests/ClaudeVitalsTests/EmitScriptTests.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: `EventSocket` / `VITALS_SOCK` (the running app), `CLAUDE_VITALS_SOCK` env override.
- Produces: an installable Claude Code plugin whose 10 hook events forward stdin to the socket.

- [ ] **Step 1: Write `plugin.json`**

Create `plugin/claude-vitals/plugin.json`:

```json
{
  "name": "claude-vitals",
  "version": "0.1.0",
  "description": "Pushes Claude Code session lifecycle events to the Claude Vitals menu-bar app for instant status."
}
```

- [ ] **Step 2: Write the emit script**

Create `plugin/claude-vitals/hooks/emit.sh`:

```sh
#!/bin/sh
# Forward the hook's stdin JSON (already contains hook_event_name, session_id, cwd,
# transcript_path, tool_name) straight to the Claude Vitals app socket. No jq, no parsing.
# Fails fast and harmlessly if the app is not running.
SOCK="${CLAUDE_VITALS_SOCK:-$HOME/.claude-vitals/vitals.sock}"
exec /usr/bin/nc -U -w1 "$SOCK"
```

Make it executable:

```bash
chmod +x plugin/claude-vitals/hooks/emit.sh
```

- [ ] **Step 3: Write `hooks.json`**

Create `plugin/claude-vitals/hooks/hooks.json`. Every event runs the same async, non-blocking emit command:

```json
{
  "hooks": {
    "SessionStart":     [{ "hooks": [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/emit.sh", "async": true }] }],
    "SessionEnd":       [{ "hooks": [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/emit.sh", "async": true }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/emit.sh", "async": true }] }],
    "PreToolUse":       [{ "matcher": "*", "hooks": [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/emit.sh", "async": true }] }],
    "PostToolUse":      [{ "matcher": "*", "hooks": [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/emit.sh", "async": true }] }],
    "PermissionRequest":[{ "matcher": "*", "hooks": [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/emit.sh", "async": true }] }],
    "Notification":     [{ "hooks": [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/emit.sh", "async": true }] }],
    "Stop":             [{ "hooks": [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/emit.sh", "async": true }] }],
    "SubagentStart":    [{ "hooks": [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/emit.sh", "async": true }] }],
    "SubagentStop":     [{ "hooks": [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/emit.sh", "async": true }] }]
  }
}
```

Note for the implementer: hook config shapes vary slightly by Claude Code version. If `/plugin` rejects a `matcher` on a non-tool event, drop the `matcher` key for that event. Verify the exact schema against the installed version's `hooks` docs during Step 6.

- [ ] **Step 4: Write the emit-script test**

Create `Tests/ClaudeVitalsTests/EmitScriptTests.swift`. It starts an `EventSocket` on a temp path, runs `emit.sh` with `CLAUDE_VITALS_SOCK` pointing at it and a JSON payload on stdin, and asserts the event arrives:

```swift
import XCTest
@testable import ClaudeVitals

final class EmitScriptTests: XCTestCase {
    func testEmitScriptDeliversStdinToSocket() throws {
        let path = NSTemporaryDirectory() + "vitals-emit-\(UUID().uuidString).sock"
        let got = expectation(description: "event via emit.sh")
        var received: HookEvent?
        let socket = EventSocket(path: path) { e in received = e; got.fulfill() }
        socket.start()
        defer { socket.stop() }
        Thread.sleep(forTimeInterval: 0.1)

        // Resolve the repo-root emit.sh relative to this source file.
        let scriptURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("plugin/claude-vitals/hooks/emit.sh")
        XCTAssertTrue(FileManager.default.fileExists(atPath: scriptURL.path), "emit.sh should exist at \(scriptURL.path)")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = [scriptURL.path]
        var env = ProcessInfo.processInfo.environment
        env["CLAUDE_VITALS_SOCK"] = path
        proc.environment = env
        let stdin = Pipe()
        proc.standardInput = stdin
        try proc.run()
        let json = #"{"hook_event_name":"UserPromptSubmit","session_id":"emit-test"}"#
        stdin.fileHandleForWriting.write(Data(json.utf8))
        stdin.fileHandleForWriting.closeFile()
        proc.waitUntilExit()

        wait(for: [got], timeout: 2.0)
        XCTAssertEqual(received?.event, "UserPromptSubmit")
        XCTAssertEqual(received?.session_id, "emit-test")
    }
}
```

- [ ] **Step 5: Run the emit-script test**

Run: `swift test --filter EmitScriptTests`
Expected: PASS (the shell script's stdin reached the socket and decoded).

- [ ] **Step 6: Manual install + real-session verification**

```bash
/plugin install ./plugin/claude-vitals
```
Enable at user scope. With the app running (`swift run ClaudeVitals` or the bundled `.app`), start a normal Claude Code session in any repo and:
- Trigger a Bash permission prompt -> the card flips to 🔐 "needs permission" near-instantly (previously showed "running tool").
- Let a turn finish -> the card flips to 🟡 "waiting prompt" and the chime fires immediately.
Expected: transitions appear in well under a second, without waiting for the poll.

- [ ] **Step 7: Document in README**

Add a section to `README.md` after "How it works (data layer)":

```markdown
## Fast triggers (optional plugin)

For instant, precise status (permission prompts, turn/ tool transitions, subagent activity) install the
bundled Claude Code plugin once:

    /plugin install ./plugin/claude-vitals

At user scope it applies to every session in every repo. Its hooks push lifecycle events over a Unix
domain socket (`~/.claude-vitals/vitals.sock`) to the running app, which uses them as the authoritative,
low-latency source of session state while the transcript stays the source of tokens/context/cost.
Without the plugin the app falls back to transcript polling exactly as before. Disable anytime via
`/plugin`.
```

- [ ] **Step 8: Commit**

```bash
git add plugin/claude-vitals README.md Tests/ClaudeVitalsTests/EmitScriptTests.swift
git commit -m "Add claude-vitals plugin (hooks + emit.sh) and docs"
```

---

## Self-Review Notes

- **Spec coverage:** principle/precedence (Tasks 3-4), data flow (Tasks 4-6), event mapping (Task 2), plugin + emit.sh + async (Task 8), EventSocket transport (Task 5), Swift changes incl. candidate seeding and hookDriven cadence (Tasks 4, 6), waitingPermission + distinct alerts (Tasks 1, 6), fallback/edge cases (resolveState freshness Task 3; socket rebind Task 5), testing incl. `--emit` (Task 7) - all mapped.
- **Assumption to verify during Task 8 Step 6:** hook `session_id` equals the transcript filename UUID (the join key). If a real session shows a card that does not merge, confirm the payload's `session_id` and, if it differs, key hook state by the `transcript_path` filename stem instead.
- **Type consistency:** `resolveState` returns a 4-tuple incl. `usedHook` (Task 3) consumed in `buildSnapshot` (Task 4); `Alert`/`AlertKind` defined in Task 6 and used by `Notifier.notify` same task; `Snapshot.hookDriven` added in Task 4 and read in Task 6's loop.
```
