# Event-Driven Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Without the plugin, a session state change reaches the UI in about a second instead of up to 8s, and the idle app rebuilds every 15s instead of every 8s. Long-finished sessions stop firing a false "Finished" chime when Claude Code appends bookkeeping lines to their transcript.

**Architecture:** A new `FileWatcher` (one FSEvents stream, owned the way `EventSocket` owns the hook socket) watches `PROJ` and `SESSIONS_DIR` and calls `Store.refreshNow()`. `refreshNow()` cuts the poll loop's sleep short through a cancellable nap plus a dirty flag, so the watcher, the Refresh button and opening the popover all share the loop's single rebuild path. The poll stays as a backstop: 2s while a session without hooks runs or the popover is open, 15s otherwise. In `Collector`, a transcript that ends in untimestamped lines takes its age from the newest timestamped line, not from the file's mtime.

**Tech Stack:** Swift 6 (SwiftPM executable target, strict concurrency), Foundation, CoreServices (FSEvents), SwiftUI.

**Spec:** GitHub issue #5 (`gh issue view 5`), plus the `/issue-triage` result: proposal 2 (watcher + bookkeeping fix) with proposal 3's re-arm, so a write that wakes an idle loop puts it straight back on the 2s cadence.

## Global Constraints

- Platform floor macOS 14, swift-tools-version 6.0, no new dependencies. CoreServices ships with macOS.
- Watched dirs: `PROJ` (`Collector.swift:5`) and `SESSIONS_DIR` (`SessionRegistry.swift:7`, which `CLAUDE_VITALS_SESSIONS_DIR` can override). FSEvents latency 0.5s with `kFSEventStreamCreateFlagNoDefer` (the first event after a quiet spell fires at once; later ones are coalesced).
- Backstop poll interval: `popoverOpen || (busy && !hookDriven) ? 2 : 15` seconds. `busy` is unchanged: `s.running > 0 || s.subsRunning > 0`.
- Transcript facts, verified in 30 recent local transcripts: a finished transcript usually ends in lines with no `timestamp` field (`last-prompt`, `cost-state`, `bridge-session`, `tools-used`, `mode`, `ai-title`, `session-owner`). Some are appended 71s to 2h after the last turn. Conversational lines, `system`, `attachment`, `api-request` and `pr-link` lines carry `"timestamp":"2026-11-15T19:29:20.543Z"` (ISO 8601, UTC, milliseconds).
- `deriveState` (`Collector.swift:143`) and its `LIVE_FILE_S` / 60s thresholds stay unchanged. The hook path (`Store.startSocket`, `Collector.ingest`) stays unchanged.
- Follow existing style: top-level free functions for pure logic, comments explain WHY. No em-dash characters anywhere (code, comments, docs, commits); use a plain hyphen.
- Commits: conventional-commit subject, no `Co-Authored-By` or "Generated with" trailer. Stage ONLY the files the task names with explicit `git add <path>`. `.gitignore` carries an unrelated pending edit that must stay uncommitted; never `git add -A` or `git add .`.
- TEST EXECUTION: this machine has Command Line Tools only, so XCTest and `swift test` are unavailable. The runnable check is `runSelfCheck()` in `Sources/ClaudeVitals/Entry.swift` (prints `ok <name>` per check, `FAIL <name>` and exit 1 on failure). Add new checks there, right before the `// Menu-bar ring window` block. Verify with `swift build 2>&1 | tail -1 && .build/debug/ClaudeVitals --selfcheck; echo "exit=$?"` and expect `Build complete!`, every new `ok <name>` line, and `exit=0`. Do NOT launch the GUI app (it plays sounds and posts notifications on the user's desktop).

## Review Focus

- A long-finished session whose transcript gets an untimestamped append must not flip to running. Pinned by `stampAfterUnstampedTail`. When the last line has a timestamp, or none does, age stays mtime-based (`noStampWhenLastLineStamped`, `noStampWithoutAnyStamp`).
- The watcher must fire for a watched dir that did not exist when it started, and must ignore writes elsewhere under the same parent. FSEvents reports real paths (`/private/var/...`), so the filter has to compare canonical paths. Pinned by `watcherSeesDirCreatedLater` and `watcherIgnoresSiblings`.
- `refreshNow()` must never lose a wakeup (a write during a rebuild triggers one more rebuild) and must never pile up loops (exactly one loop task, ever).

---

### Task 1: Age a transcript from its last timestamped line

**Files:**
- Modify: `Sources/ClaudeVitals/Collector.swift` (new `lastStamp`, `ParsedSession`, `parseSession`, `buildSnapshot`)
- Modify: `Sources/ClaudeVitals/Entry.swift` (`runSelfCheck`)

- [ ] **Step 1: Write the checks.** In `runSelfCheck`, right before `// Menu-bar ring window`, add:

```swift
        // Untimestamped bookkeeping appended after a finished turn is not activity.
        func linesOf(_ ls: [String]) -> [Line] { parseLines(Data(ls.joined(separator: "\n").utf8), dropFirstPartial: false) }
        let turnEnd = #"{"type":"assistant","timestamp":"2026-11-15T10:00:00.000Z","message":{"stop_reason":"end_turn"}}"#
        let costState = #"{"type":"cost-state"}"#
        let lastPrompt = #"{"type":"last-prompt"}"#
        check("stampAfterUnstampedTail", lastStamp(linesOf([turnEnd, lastPrompt, costState])) == Date(timeIntervalSince1970: 1_794_736_800))
        check("noStampWhenLastLineStamped", lastStamp(linesOf([costState, turnEnd])) == nil)
        check("noStampWithoutAnyStamp", lastStamp(linesOf([lastPrompt, costState])) == nil)
```

- [ ] **Step 2: Run it.** Expected: the build fails with `cannot find 'lastStamp' in scope`.

- [ ] **Step 3: Implement `lastStamp`.** In `Collector.swift`, directly above `struct ParsedSession`, add:

```swift
/// When a transcript ends in lines without a timestamp, the time of the newest line that has one.
/// Claude Code appends untimestamped bookkeeping (last-prompt, cost-state, bridge-session) to a
/// finished transcript, sometimes minutes or hours after its last turn. Each append bumps the mtime,
/// which made a long-finished session look like it was running for a few seconds and then fire a
/// false "finished" alert. Nil when the last line has a timestamp (mtime is right) or no line in the
/// tail has one (nothing better than mtime).
func lastStamp(_ lines: [Line]) -> Date? {
    guard let last = lines.last, last.timestamp == nil else { return nil }
    guard let ts = lines.last(where: { $0.timestamp != nil })?.timestamp else { return nil }
    return try? Date(ts, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true))
}
```

If that format style does not parse `2026-11-15T10:00:00.000Z` (the check tells you), use `Date.ISO8601FormatStyle(includingFractionalSeconds: true)` instead. A timestamp that fails to parse returns nil, which falls back to mtime.

- [ ] **Step 4: Carry it through `ParsedSession`.** Add a field after `title`:

```swift
    let stampedAt: Date?     // see lastStamp: set only when the tail ends in untimestamped lines
```

and pass `stampedAt: lastStamp(lines)` in the `ParsedSession(...)` call in `parseSession`. It is content-derived, so the existing (mtime, size) cache key still holds.

- [ ] **Step 5: Use it in `buildSnapshot`.** Replace

```swift
        guard let m = mtime(f) else { continue }
        let age = now.timeIntervalSince(m)
        let ps = parseSession(f, mtime: m, size: fileSize(f), cache: cache)
```

with

```swift
        guard let m = mtime(f) else { continue }
        let ps = parseSession(f, mtime: m, size: fileSize(f), cache: cache)
        // A bookkeeping append is not activity: age from the last timestamped line instead (lastStamp).
        let age = now.timeIntervalSince(ps.stampedAt.map { min($0, m) } ?? m)
```

Leave `transcriptMtime: m` in the `resolveState` call as it is.

- [ ] **Step 6: Run the checks.** Expected: `Build complete!`, `ok stampAfterUnstampedTail`, `ok noStampWhenLastLineStamped`, `ok noStampWithoutAnyStamp`, `exit=0`. Then run `.build/debug/ClaudeVitals --dump` once: no crash, and cards still list.

- [ ] **Step 7: Commit.**

```bash
git add Sources/ClaudeVitals/Collector.swift Sources/ClaudeVitals/Entry.swift
git commit -m "fix(collector): age a transcript from its last timestamped line, not bookkeeping appends"
```

---

### Task 2: FileWatcher

**Files:**
- Create: `Sources/ClaudeVitals/FileWatcher.swift`
- Modify: `Sources/ClaudeVitals/Entry.swift` (`runSelfCheck`)

- [ ] **Step 1: Write the checks.** In `runSelfCheck`, right before `// Menu-bar ring window`, add:

```swift
        // The watcher fires for a watched dir created after it started (older Claude Code has no
        // sessions dir), and ignores writes elsewhere under the same parent. The temp dir sits under
        // /var, which FSEvents reports as /private/var, so this also pins the path canonicalization.
        let wRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: wRoot, withIntermediateDirectories: true)
        let wDir = wRoot.appendingPathComponent("sessions")
        let fired = DispatchSemaphore(value: 0)
        let watcher = FileWatcher(dirs: [wDir], latency: 0.1) { fired.signal() }
        watcher.start()
        Thread.sleep(forTimeInterval: 0.5)                  // FSEvents reports only writes after the stream is live
        try? Data("x".utf8).write(to: wRoot.appendingPathComponent("other.json"))
        check("watcherIgnoresSiblings", fired.wait(timeout: .now() + 1.5) == .timedOut)
        try? FileManager.default.createDirectory(at: wDir, withIntermediateDirectories: true)
        try? Data("x".utf8).write(to: wDir.appendingPathComponent("1.json"))
        check("watcherSeesDirCreatedLater", fired.wait(timeout: .now() + 3) == .success)
        watcher.stop()
        try? FileManager.default.removeItem(at: wRoot)
```

- [ ] **Step 2: Run it.** Expected: the build fails with `cannot find 'FileWatcher' in scope`.

- [ ] **Step 3: Create `FileWatcher.swift`.**

```swift
import CoreServices
import Foundation

/// Calls `onChange` (on its own queue) when anything under one of `dirs` changes: one FSEvents stream,
/// events coalesced over `latency` seconds. It watches each dir's parent and filters by path, so a dir
/// that does not exist yet (older Claude Code has no sessions dir) still reports once it is created.
/// Nothing is read here; the caller rebuilds its snapshot.
final class FileWatcher {
    private let dirs: [URL]
    private let latency: CFTimeInterval
    private let onChange: @Sendable () -> Void
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.claudevitals.filewatcher")

    init(dirs: [URL], latency: CFTimeInterval = 0.5, onChange: @escaping @Sendable () -> Void) {
        self.dirs = dirs
        self.latency = latency
        self.onChange = onChange
    }

    /// What the C callback needs, handed over through the stream context's info pointer.
    private final class Box: Sendable {
        let prefixes: [String]
        let onChange: @Sendable () -> Void
        init(prefixes: [String], onChange: @escaping @Sendable () -> Void) {
            self.prefixes = prefixes
            self.onChange = onChange
        }
    }

    func start() {
        guard stream == nil else { return }
        let box = Box(prefixes: dirs.map { FileWatcher.canonical($0) + "/" }, onChange: onChange)
        let roots = Array(Set(dirs.map { FileWatcher.canonical($0.deletingLastPathComponent()) }))
        var ctx = FSEventStreamContext(
            version: 0, info: Unmanaged.passRetained(box).toOpaque(), retain: nil,
            release: { info in if let info { Unmanaged<Box>.fromOpaque(info).release() } },
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            // Directory-level events: each path is the dir whose contents changed.
            let hit = list.contains { p in
                let dir = p.hasSuffix("/") ? p : p + "/"
                return box.prefixes.contains { dir.hasPrefix($0) }
            }
            // Dropped events: FSEvents can't say what changed, so assume it was ours.
            let dropped = (0..<count).contains {
                flags[$0] & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
            }
            if hit || dropped { box.onChange() }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &ctx, roots as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else {
            Unmanaged<Box>.fromOpaque(ctx.info!).release()
            return
        }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)            // releases the Box through the context's release callback
        stream = nil
    }

    /// FSEvents reports real paths (symlinks resolved, /var as /private/var), so the filter compares
    /// against the same. realpath needs an existing path: a missing dir resolves its parent instead.
    private static func canonical(_ url: URL) -> String {
        if let p = realpath(url.path, nil) { defer { free(p) }; return String(cString: p) }
        let parent = url.deletingLastPathComponent()
        if let p = realpath(parent.path, nil) { defer { free(p) }; return String(cString: p) + "/" + url.lastPathComponent }
        return url.standardizedFileURL.path
    }
}
```

This is a sketch against the C API: if the compiler disagrees with a signature (closure parameter types, `CFArray` bridging, `Sendable` on `Box`), fix it the smallest way that keeps the behavior, and say what you changed in the report.

- [ ] **Step 4: Run the checks.** Expected: `Build complete!`, `ok watcherIgnoresSiblings`, `ok watcherSeesDirCreatedLater`, `exit=0`. Run `--selfcheck` three times in a row to rule out flakiness, and report the three results.

- [ ] **Step 5: Commit.**

```bash
git add Sources/ClaudeVitals/FileWatcher.swift Sources/ClaudeVitals/Entry.swift
git commit -m "feat(collector): add an FSEvents file watcher"
```

---

### Task 3: Wake the poll loop on file changes

**Files:**
- Modify: `Sources/ClaudeVitals/Store.swift`
- Modify: `README.md` (lines 92 and 127)
- Modify: `INSTALL.md` (lines 9 and 64)

- [ ] **Step 1: State.** In `Store`, next to `private var socket: EventSocket?`, add:

```swift
    private var watcher: FileWatcher?
    private var nap: Task<Void, Never>?   // the poll loop's current sleep; refreshNow cuts it short
    private var dirty = false             // a refresh was asked for while a rebuild ran
```

`init()` becomes `init() { startLoading(); start(); startUsage(); startSocket(); startWatcher(); startSweep() }`. The `isolated deinit` also calls `watcher?.stop()` and `nap?.cancel()`.

- [ ] **Step 2: The watcher.** Below `handleHookEvent`, add:

```swift
    /// Transcript and session-registry writes -> immediate rebuild, so a state change shows within about
    /// a second without the plugin. The poll in start() stays as the backstop for what no write
    /// announces: time thresholds (LIVE_FILE_S, the 60s ended mark, RECENT_WINDOW) and a process that
    /// dies without removing its registry file.
    private func startWatcher() {
        let w = FileWatcher(dirs: [PROJ, SESSIONS_DIR]) { [weak self] in
            Task { @MainActor in self?.refreshNow() }
        }
        w.start()
        watcher = w
    }
```

- [ ] **Step 3: The loop.** Replace `start()` and `refreshNow()` with:

```swift
    private func start() {
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.dirty = false
                let s = await self.collector.snapshot()
                self.apply(s)
                if self.dirty { continue }            // a write landed mid-rebuild and may not be in `s`
                let busy = s.running > 0 || s.subsRunning > 0
                // Writes wake the loop (refreshNow), so the poll only catches what no write announces.
                // 2s keeps the 5s running -> waiting flip (LIVE_FILE_S) prompt for sessions without hooks,
                // and the open popover's "Ns ago" moving. Otherwise 15s.
                let interval: Double = self.popoverOpen || (busy && !s.hookDriven) ? 2 : 15
                let nap = Task { try? await Task.sleep(for: .seconds(interval)) }
                self.nap = nap
                await nap.value
            }
        }
    }

    /// Rebuild now: cut the poll loop's sleep short, or, mid-rebuild, run one more right after it.
    /// The file watcher, the Refresh button and opening the popover all come through here, so there is
    /// one rebuild path and never more than one loop.
    func refreshNow() {
        dirty = true
        nap?.cancel()
    }
```

- [ ] **Step 4: Popover.** `popoverOpen`'s `didSet` becomes `didSet { if popoverOpen { catchUp(); refreshNow() } }`, so opening it shows the cached snapshot at once and a fresh one a moment later.

- [ ] **Step 5: Stale comments in `Store.swift`.** In the `updateLabelImage` doc comment, "The poll loop calls this every 2–8s, so the mark moves on time" becomes "The poll loop calls this at least every 15s, so the mark moves on time". In the `freshUsage` doc comment, "The poll loop re-renders the ring within 2–8s of a reset" becomes "The poll loop re-renders the ring within 15s of a reset". Replace any en-dash you touch with a hyphen.

- [ ] **Step 6: Docs.**
  - `README.md:92`: replace `Polling is adaptive: **1.5s** while anything runs, **5s** idle.` with `Refresh is event-driven: a file watcher on the transcripts and the session registry rebuilds within about a second of any write. A backstop poll catches what no write announces (time thresholds, a crashed process): **2s** while a session without hooks runs or the popover is open, **15s** otherwise.` Keep the rest of that paragraph.
  - `README.md:127`: `adaptive poll loop` becomes `file-watch-driven refresh loop with a backstop poll`.
  - `INSTALL.md:9`: `just via polling (1.5-5s) instead of push` becomes `just via file watching instead of push`.
  - `INSTALL.md:64`: `polling every 1.5-5s` becomes `rebuilding on every file change, with a 2-15s backstop poll`.

- [ ] **Step 7: Verify.** `swift build 2>&1 | tail -1 && .build/debug/ClaudeVitals --selfcheck; echo "exit=$?"`: `Build complete!`, all checks ok, `exit=0`. Then `swift build 2>&1 | grep -i warning | grep -i -E 'Store|FileWatcher'` prints nothing new. `bash Tests/e2e-liveness-check.sh` passes as before.

- [ ] **Step 8: Commit.**

```bash
git add Sources/ClaudeVitals/Store.swift README.md INSTALL.md
git commit -m "feat(app): refresh on file changes, poll only as a 2s/15s backstop"
```
