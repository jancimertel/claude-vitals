# Registry Status Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the two acceptance lines of issue #5 that PR #26 left open. Without the plugin, a finished turn shows as "waiting prompt" within about a second instead of 5-7s. An idle app spawns no `pgrep` while the session registry directory exists.

**Architecture:** Claude Code writes `"status": "busy" | "idle"` into each `~/.claude/sessions/<pid>.json`. PR #26's `FileWatcher` already watches that directory, so the status write triggers a rebuild. `Liveness` carries the set of transcripts whose registry entry says `idle`, and `deriveState` returns waiting at once for an `end_turn` turn in that set. Separately, `liveness` treats an existing registry directory as authoritative (empty means nothing is live) and falls back to the process scan only when the directory does not exist.

**Tech Stack:** Swift 6 (SwiftPM executable target, strict concurrency), Foundation.

**Spec:** GitHub issue #5 (`gh issue view 5`), and the follow-up agreed after PR #26 (`gh pr view 26`). It builds on the PR #26 branch `feat/5-event-driven-refresh`.

## Global Constraints

- Registry facts, verified on this machine (Claude Code 2.1.319-2.1.325): each entry has `status` (`"busy"` or `"idle"`; no other value seen), `statusUpdatedAt` and `updatedAt` (ms). In 7 idle sessions, `idle` was written 10-20ms after the transcript's last line (`system` / `stop_hook_summary`, written after Stop hooks ran), and 0.05-4s after the last `end_turn` (the gap is Stop-hook time). What `status` shows during a permission prompt is unknown, so ONLY the pair "`idle` + last conversational line is assistant `end_turn`" changes behavior. Every other combination keeps today's rules.
- `RegistryEntry` decoding stays tolerant: a missing or wrong-typed `status` decodes as nil and never drops the entry. `pid`, `sessionId`, `cwd` and `startedAt` keep their current decoding behavior. Keep the memberwise initializer working with its current 4 arguments (`Tests/ClaudeVitalsTests/SessionRegistryTests.swift` calls it).
- `deriveState` keeps its existing parameters and gains one with a default (`registryIdle: Bool = false`), so existing callers and the XCTest files still compile.
- Process-scan fallback: runs only when the registry directory does not exist. An existing directory with no live entry means nothing is live. The accepted cost: a stale registry dir next to an older Claude Code that does not write it would show its sessions as ended after 60s quiet.
- Follow existing style: top-level free functions for pure logic, comments explain WHY. No em-dash characters anywhere (code, comments, docs, commits); use a plain hyphen.
- Commits: conventional-commit subject, no `Co-Authored-By` or "Generated with" trailer. Stage ONLY the files the task names with explicit `git add <path>`. `.gitignore` carries an unrelated pending edit that must stay uncommitted; never `git add -A` or `git add .`.
- TEST EXECUTION: this machine has Command Line Tools only, so XCTest and `swift test` are unavailable. The runnable check is `runSelfCheck()` in `Sources/ClaudeVitals/Entry.swift` (prints `ok <name>` per check, `FAIL <name>` and exit 1 on failure). Add new checks right before the `// Menu-bar ring window` block. Verify with `swift build 2>&1 | grep -iE 'warning|error|Build complete' | tail -3 && .build/debug/ClaudeVitals --selfcheck; echo "exit=$?"`: expect `Build complete!`, no warnings, every new `ok <name>`, `exit=0`. `bash Tests/e2e-liveness-check.sh`: the last check ("real registry: N cards for M registry entries") fails on this machine for an environmental reason (live sessions with no transcript yet); every other check must print `ok`. Do NOT launch the GUI app (it plays sounds and posts notifications on the user's desktop).

## Review Focus

- `idle` must only shortcut an `end_turn` turn. A `tool_use` (permission prompt, running tool) or a `user` line (a new turn already started) under `idle` keeps today's state. Pinned by `registryIdleEndTurnWaitsAtOnce`, `registryIdleDoesNotShortcutToolUse`, `registryIdleDoesNotShortcutNewTurn`.
- A registry file with an odd `status` must still count as live. Pinned by `registryStatusDecodesTolerantly`.
- An empty registry directory must not run the process scan; a missing one must. Pinned by `emptyRegistrySkipsProcessScan`, `missingRegistryFallsBackToProcessScan`.

---

### Task 1: Show "waiting" at once when the registry says idle

**Files:**
- Modify: `Sources/ClaudeVitals/SessionRegistry.swift` (`RegistryEntry`)
- Modify: `Sources/ClaudeVitals/Collector.swift` (`deriveState`, `Liveness`, `liveness`, `buildSnapshot`)
- Modify: `Sources/ClaudeVitals/Entry.swift` (`runSelfCheck`)
- Modify: `README.md` (the "Live sessions" bullet, around line 78)

- [ ] **Step 1: Write the checks.** In `runSelfCheck`, right before `// Menu-bar ring window`, add:

```swift
        // Claude Code flips its registry status to idle right after a turn's Stop hooks finish, so an
        // end_turn under idle is finished now, not after LIVE_FILE_S of quiet. Nothing else shortcuts.
        check("registryIdleEndTurnWaitsAtOnce",
              deriveState(lastType: "assistant", lastStop: "end_turn", asksUser: false, age: 0.5, isLive: true, registryIdle: true) == (.waiting, "waiting prompt")
              && deriveState(lastType: "assistant", lastStop: "end_turn", asksUser: false, age: 0.5, isLive: true) == (.runningModel, "running"))
        check("registryIdleDoesNotShortcutToolUse",
              deriveState(lastType: "assistant", lastStop: "tool_use", asksUser: false, age: 0.5, isLive: true, registryIdle: true) == (.runningTool, "running tool"))
        check("registryIdleDoesNotShortcutNewTurn",
              deriveState(lastType: "user", lastStop: nil, asksUser: false, age: 0.5, isLive: true, registryIdle: true) == (.runningModel, "running model"))
        let regDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: regDir, withIntermediateDirectories: true)
        try? Data(#"{"pid":1,"sessionId":"a","cwd":"/r","status":"idle"}"#.utf8).write(to: regDir.appendingPathComponent("1.json"))
        try? Data(#"{"pid":2,"sessionId":"b","cwd":"/r","status":5}"#.utf8).write(to: regDir.appendingPathComponent("2.json"))
        let regs = readRegistry(dir: regDir).sorted { $0.pid < $1.pid }
        check("registryStatusDecodesTolerantly", regs.map(\.status) == ["idle", nil] && regs.map(\.sessionId) == ["a", "b"])
        try? FileManager.default.removeItem(at: regDir)
```

`(Dot, String)` tuples compare with `==` only if `Dot` is `Equatable`. If the compiler refuses, compare `.0` and `.1` separately.

- [ ] **Step 2: Run it.** Expected: the build fails (`extra argument 'registryIdle'`, `value of type 'RegistryEntry' has no member 'status'`).

- [ ] **Step 3: `RegistryEntry.status`.** Add `var status: String? = nil` with a comment (`"busy"` or `"idle"`; Claude Code writes `idle` right after a turn's Stop hooks finish). Replace synthesized decoding with an explicit `CodingKeys` and an `init(from:)` placed in an `extension RegistryEntry` (an initializer in an extension keeps the memberwise one). It decodes `pid`, `sessionId`, `cwd` exactly as now (`try c.decode`, so a missing one still skips the entry), `startedAt` exactly as now (`try c.decodeIfPresent`), and `status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? nil`. Update the struct's doc comment, which describes the tolerance rules.

- [ ] **Step 4: `deriveState(…, registryIdle: Bool = false)`.** Add the parameter last. Right after the `asksUser` early return, add:

```swift
    // Claude Code writes registry status idle right after the turn's Stop hooks finish, so the turn
    // is over now. Without it, the LIVE_FILE_S quiet window below has to stand in for that signal.
    if registryIdle, t == "assistant", stop == "end_turn" { return (.waiting, "waiting prompt") }
```

Update `deriveState`'s doc comment in one sentence to mention it.

- [ ] **Step 5: Plumb it.** `Liveness` gains `let idle: Set<String>` (transcripts whose registry entry reports `idle`). In `liveness`, the registry branch inserts the transcript path into `idle` when `e.status == "idle"`; the process-scan branch passes `[]`. In `buildSnapshot`, pass `registryIdle: liveNow.idle.contains(f)` to `deriveState`.

- [ ] **Step 6: README.** In the "Live sessions" bullet (`README.md`, around line 78), add one sentence: the entry's `status` turns `idle` as soon as a turn finishes, so the card shows "waiting prompt" within about a second without the plugin.

- [ ] **Step 7: Verify** per the Global Constraints. Then run `.build/debug/ClaudeVitals --dump` once: no crash, and cards list.

- [ ] **Step 8: Commit.**

```bash
git add Sources/ClaudeVitals/SessionRegistry.swift Sources/ClaudeVitals/Collector.swift Sources/ClaudeVitals/Entry.swift README.md
git commit -m "feat(collector): show a finished turn at once when the session registry says idle"
```

---

### Task 2: No process scan while the registry directory exists

**Files:**
- Modify: `Sources/ClaudeVitals/Collector.swift` (`liveness`, and the `liveRepos` doc comment if it says the scan runs every tick)
- Modify: `Sources/ClaudeVitals/SessionRegistry.swift` (`readRegistry` doc comment)
- Modify: `Sources/ClaudeVitals/Entry.swift` (`runSelfCheck`)
- Modify: `Tests/e2e-liveness-check.sh` (the "empty registry falls back like a missing one" check)
- Modify: `README.md` (the "Live sessions" bullet's fallback sentence)

- [ ] **Step 1: Write the checks.** In `runSelfCheck`, right before `// Menu-bar ring window`, add:

```swift
        // An existing registry directory is authoritative: empty means nothing is live, so no pgrep.
        // Only a missing directory (older Claude Code) falls back to the process scan.
        let liveDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: liveDir, withIntermediateDirectories: true)
        var scanned = false
        _ = liveness(cache: CollectorCache(), dir: liveDir) { _ in scanned = true; return [:] }
        check("emptyRegistrySkipsProcessScan", !scanned)
        _ = liveness(cache: CollectorCache(), dir: liveDir.appendingPathComponent("absent")) { _ in scanned = true; return [:] }
        check("missingRegistryFallsBackToProcessScan", scanned)
        try? FileManager.default.removeItem(at: liveDir)
```

- [ ] **Step 2: Run it.** Expected: the build fails (`extra arguments` on `liveness`).

- [ ] **Step 3: Implement.** `liveness` becomes `func liveness(cache: CollectorCache, dir: URL = SESSIONS_DIR, scan: (CollectorCache) -> [String: Int] = liveRepos) -> Liveness`. It reads `readRegistry(dir: dir)`. The process-scan branch runs only when `dir` does not exist (`FileManager.default.fileExists(atPath: dir.path)` is false), calling `scan(cache)` instead of `liveRepos(cache:)` directly. When the directory exists, build the registry-branch `Liveness` (possibly empty, `confirmed: true`). Rewrite `liveness`'s doc comment to state the new rule and the accepted cost from the Global Constraints in one sentence. Fix the `readRegistry` doc comment ("The caller treats both the same way" is no longer true) and any `liveRepos` comment claiming the scan runs every tick.

- [ ] **Step 4: e2e.** In `Tests/e2e-liveness-check.sh`, replace the check `empty registry falls back like a missing one` (equality of `d_blocks` and `c_blocks`) with `empty registry skips the process scan`, which passes when `d_blocks -le c_blocks`: without the scan, live-but-quiet sessions lose their cards, so the empty-dir run never shows more cards than the missing-dir run. Write it inline like the last check (the `check` helper only tests equality).

- [ ] **Step 5: README.** In the "Live sessions" bullet, the fallback sentence becomes: when the registry directory does not exist (older Claude Code) the app falls back to `pgrep` + `lsof`; an existing but empty directory means nothing is running.

- [ ] **Step 6: Verify** per the Global Constraints, including the e2e script.

- [ ] **Step 7: Commit.**

```bash
git add Sources/ClaudeVitals/Collector.swift Sources/ClaudeVitals/SessionRegistry.swift Sources/ClaudeVitals/Entry.swift Tests/e2e-liveness-check.sh README.md
git commit -m "feat(collector): skip the process scan while the session registry exists"
```
