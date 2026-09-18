# Session Registry Liveness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Derive session liveness from Claude Code's session registry so every open session gets its own live card, with `pgrep`/`lsof` kept only as the fallback for Claude Code versions that have no registry.

**Architecture:** A new `SessionRegistry.swift` reads `~/.claude/sessions/<pid>.json`, keeps only entries whose process is really the one that wrote them, and resolves each entry to its transcript file. `Collector.swift` asks one new function, `liveness(cache:)`, which returns the live transcript set plus a per-cwd count from the registry, or from the existing process scan when the registry directory does not exist. Everything downstream of those two values (state heuristic, hook merge, UI) is unchanged.

**Tech Stack:** Swift 6.2 (SwiftPM executable target), Foundation, Darwin (`proc_pidinfo`), XCTest.

**Spec:** GitHub issue #1, https://github.com/jancimertel/claude-vitals/issues/1 (`gh issue view 1`).

## Global Constraints

- Platform floor: macOS 14 (`.macOS(.v14)`); swift-tools-version 6.0; no new package dependencies (Foundation/Darwin/XCTest only).
- Spec, verbatim: "Read the registry as the source of liveness, keyed by `sessionId`, so each open session maps to exactly one transcript. An entry counts as live only when its pid is running and the process start time matches, because a file can outlive a killed process. When the registry directory does not exist (older Claude Code), fall back to the current pgrep path."
- Spec, verbatim: "every open session gets its own live card no matter how many share a repo, terminal and VS Code sessions are both detected, and the steady state makes no `lsof` calls."
- Spec, verbatim: "The file format is internal to Claude Code and `claude agents --json` is the documented contract, so decoding has to tolerate missing and unknown fields."
- Measured on real sessions: a Claude Code process starts 0.4-0.7s BEFORE the `startedAt` its registry entry records. `proc_pidinfo` returns nothing for a pid that does not exist.
- Follow existing code style: top-level free functions for pure logic, doc comments that explain WHY, `actor Collector` owns cross-tick state.
- No em-dash characters anywhere (code, comments, docs, commit messages). Use a plain hyphen.
- Commits: conventional-commit subject, no `Co-Authored-By` or "Generated with" trailer. Stage ONLY the files the task names with explicit `git add <path>`. `.gitignore` carries an unrelated pending edit that must stay uncommitted; never use `git add -A` or `git add .`.
- TEST EXECUTION (environment): this machine has Command Line Tools only, no Xcode, so `XCTest` and `swift test` are unavailable. Write the XCTest file exactly as specified (it runs later in Xcode/CI), and VERIFY with `swift build` (expect `Build complete!`), which does not compile test targets. Task 2 adds a runnable end-to-end check through `--dump`. Reviewers: un-run XCTest is the known environment limit, but still read the test code for correctness.

---

### Task 1: Session registry module

**Files:**
- Create: `Sources/ClaudeVitals/SessionRegistry.swift`
- Test: `Tests/ClaudeVitalsTests/SessionRegistryTests.swift`

**Interfaces:**
- Consumes: `PROJ: URL` and `encodeRepo(_ path: String) -> String`, both already defined in `Sources/ClaudeVitals/Collector.swift`.
- Produces:
  - `let SESSIONS_DIR: URL`
  - `let PID_REUSE_SKEW_S: TimeInterval`
  - `struct RegistryEntry: Decodable, Sendable, Equatable { let pid: Int32; let sessionId: String; let cwd: String; let startedAt: Double? }`
  - `func readRegistry(dir: URL = SESSIONS_DIR) -> [RegistryEntry]?`
  - `func processStartTime(_ pid: Int32) -> Date?`
  - `func isLiveEntry(_ e: RegistryEntry, startTime: (Int32) -> Date? = processStartTime) -> Bool`
  - `func transcriptPath(for e: RegistryEntry, projects: URL = PROJ) -> String?`

- [ ] **Step 1: Write the test file**

Create `Tests/ClaudeVitalsTests/SessionRegistryTests.swift`:

```swift
import XCTest
@testable import ClaudeVitals

final class SessionRegistryTests: XCTestCase {
    private var tmp: URL!

    override func setUp() {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vitals-registry-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    private func write(_ name: String, _ body: String, in dir: URL? = nil) {
        try? Data(body.utf8).write(to: (dir ?? tmp).appendingPathComponent(name))
    }

    private func entry(startedAt: Double?) -> RegistryEntry {
        RegistryEntry(pid: 7, sessionId: "s1", cwd: "/work/repo", startedAt: startedAt)
    }

    // MARK: readRegistry

    func testMissingDirectoryReturnsNil() {
        XCTAssertNil(readRegistry(dir: tmp.appendingPathComponent("absent")))
    }

    func testEmptyDirectoryReturnsEmptyNotNil() {
        XCTAssertEqual(readRegistry(dir: tmp), [])
    }

    func testDecodesKnownFieldsAndIgnoresUnknown() {
        write("42.json", #"{"pid":42,"sessionId":"s1","cwd":"/r","startedAt":1000,"status":"busy","future":{"x":1}}"#)
        XCTAssertEqual(readRegistry(dir: tmp), [RegistryEntry(pid: 42, sessionId: "s1", cwd: "/r", startedAt: 1000)])
    }

    func testSkipsBrokenEntriesAndNonJsonFiles() {
        write("1.json", #"{"pid":1,"sessionId":"ok","cwd":"/r"}"#)   // startedAt is optional
        write("2.json", #"{"pid":2,"cwd":"/r"}"#)                     // no sessionId -> skipped
        write("3.json", "not json")
        write("1.abc.key", "secret")                                  // sibling key files are not entries
        XCTAssertEqual(readRegistry(dir: tmp), [RegistryEntry(pid: 1, sessionId: "ok", cwd: "/r", startedAt: nil)])
    }

    // MARK: isLiveEntry

    func testDeadPidIsNotLive() {
        XCTAssertFalse(isLiveEntry(entry(startedAt: 1_000_000), startTime: { _ in nil }))
    }

    func testProcessStartedJustBeforeSessionIsLive() {
        XCTAssertTrue(isLiveEntry(entry(startedAt: 1_000_000), startTime: { _ in Date(timeIntervalSince1970: 999.5) }))
    }

    func testProcessStartedAfterSessionIsAReusedPid() {
        let reused = Date(timeIntervalSince1970: 1000 + PID_REUSE_SKEW_S + 1)
        XCTAssertFalse(isLiveEntry(entry(startedAt: 1_000_000), startTime: { _ in reused }))
    }

    func testMissingStartedAtTrustsARunningPid() {
        XCTAssertTrue(isLiveEntry(entry(startedAt: nil), startTime: { _ in Date() }))
    }

    func testProcessStartTimeOfSelfAndOfMissingPid() {
        XCTAssertNotNil(processStartTime(getpid()))
        XCTAssertNil(processStartTime(999_999))   // above the macOS pid ceiling, so it never exists
    }

    // MARK: transcriptPath

    func testTranscriptPathPrefersTheProjectDirDerivedFromCwd() {
        let dir = tmp.appendingPathComponent(encodeRepo("/work/repo"))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        write("s1.jsonl", "", in: dir)
        XCTAssertEqual(transcriptPath(for: entry(startedAt: nil), projects: tmp),
                       dir.appendingPathComponent("s1.jsonl").path)
    }

    func testTranscriptPathFallsBackToSessionIdSearch() {
        let dir = tmp.appendingPathComponent("-some-other-project")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        write("s1.jsonl", "", in: dir)
        XCTAssertEqual(transcriptPath(for: entry(startedAt: nil), projects: tmp),
                       dir.appendingPathComponent("s1.jsonl").path)
    }

    func testTranscriptPathIsNilBeforeTheTranscriptExists() {
        XCTAssertNil(transcriptPath(for: entry(startedAt: nil), projects: tmp))
    }
}
```

- [ ] **Step 2: Write the implementation**

Create `Sources/ClaudeVitals/SessionRegistry.swift`:

```swift
import Darwin
import Foundation

/// Claude Code's per-process session registry: one `<pid>.json` per running session, the same data
/// `claude agents --json` prints. `CLAUDE_VITALS_SESSIONS_DIR` overrides the location so the negative
/// paths (dead pid, reused pid, no registry) can be exercised through `--dump` on machines without XCTest.
let SESSIONS_DIR: URL = ProcessInfo.processInfo.environment["CLAUDE_VITALS_SESSIONS_DIR"]
    .map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")

/// Slack for the pid-reuse check. Measured: a live Claude Code process starts ~0.5s BEFORE the
/// `startedAt` it records, so a few seconds never rejects a real session.
let PID_REUSE_SKEW_S: TimeInterval = 5

/// The subset of a registry file this app uses. The format is internal to Claude Code, so decoding is
/// tolerant: unknown fields are ignored, and an entry missing pid/sessionId/cwd is skipped, not fatal.
struct RegistryEntry: Decodable, Sendable, Equatable {
    let pid: Int32
    let sessionId: String
    let cwd: String
    let startedAt: Double?   // ms since epoch; nil disables the pid-reuse check for that entry
}

/// nil when the registry directory does not exist (older Claude Code), so the caller can fall back to
/// process scanning. An existing but empty directory is a valid "no sessions" answer, not a fallback.
func readRegistry(dir: URL = SESSIONS_DIR) -> [RegistryEntry]? {
    guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
        return nil
    }
    let dec = JSONDecoder()
    return files.filter { $0.pathExtension == "json" }.compactMap { f in
        (try? Data(contentsOf: f)).flatMap { try? dec.decode(RegistryEntry.self, from: $0) }
    }
}

/// Start time of a running process we own; nil when it does not exist, so this doubles as the
/// "is the pid running" check (no separate `kill(pid, 0)`).
func processStartTime(_ pid: Int32) -> Date? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1e6)
}

/// A registry file can outlive a killed process, and its pid can then be reused. The entry is live only
/// if the pid is running AND that process started no later than the session did: whatever reused the
/// pid necessarily started after the stale entry's `startedAt`.
func isLiveEntry(_ e: RegistryEntry, startTime: (Int32) -> Date? = processStartTime) -> Bool {
    guard let started = startTime(e.pid) else { return false }
    guard let at = e.startedAt else { return true }
    return started.timeIntervalSince1970 <= at / 1000 + PID_REUSE_SKEW_S
}

/// The transcript a registry entry is driving. Claude Code names the project directory after the
/// session's cwd, so that path is tried first; a session that has since changed directory is found by
/// its session id under any project directory. nil until the transcript's first line is written.
func transcriptPath(for e: RegistryEntry, projects: URL = PROJ) -> String? {
    let fm = FileManager.default
    let name = e.sessionId + ".jsonl"
    let derived = projects.appendingPathComponent(encodeRepo(e.cwd)).appendingPathComponent(name).path
    if fm.fileExists(atPath: derived) { return derived }
    let dirs = (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
    return dirs.map { $0.appendingPathComponent(name).path }.first { fm.fileExists(atPath: $0) }
}
```

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!` with no warnings from `SessionRegistry.swift`.

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeVitals/SessionRegistry.swift Tests/ClaudeVitalsTests/SessionRegistryTests.swift
git commit -m "feat(registry): read Claude Code session registry with pid-reuse check"
```

---

### Task 2: Drive liveness from the registry

**Files:**
- Modify: `Sources/ClaudeVitals/Collector.swift` (the `liveRepos` doc comment, `liveSessionFiles` area, `candidateFiles`, and the first lines of `buildSnapshot`)
- Modify: `README.md` (the "Live sessions" bullet under "How it works (data layer)")

**Interfaces:**
- Consumes (from Task 1, in `Sources/ClaudeVitals/SessionRegistry.swift`):
  - `func readRegistry(dir: URL = SESSIONS_DIR) -> [RegistryEntry]?` - nil means "no registry directory".
  - `func isLiveEntry(_ e: RegistryEntry, startTime: (Int32) -> Date? = processStartTime) -> Bool`
  - `func transcriptPath(for e: RegistryEntry, projects: URL = PROJ) -> String?`
  - `RegistryEntry` has `cwd: String`.
- Produces: `struct Liveness { let files: Set<String>; let repos: [String: Int] }` and `func liveness(cache: CollectorCache) -> Liveness`. `candidateFiles` changes its first parameter from `live: [String: Int]` to `active: Set<String>`.

- [ ] **Step 1: Mark the process scan as the fallback**

In `Sources/ClaudeVitals/Collector.swift`, the doc comment on `liveRepos` starts with:

```swift
/// repo cwd -> count of live interactive `claude` processes (absolute tool paths: .app PATH lacks /usr/sbin).
```

Replace that one line with:

```swift
/// FALLBACK ONLY (see `liveness`): used when Claude Code has no session registry.
/// repo cwd -> count of live interactive `claude` processes (absolute tool paths: .app PATH lacks /usr/sbin).
```

- [ ] **Step 2: Add `Liveness` and `liveness(cache:)`**

In `Sources/ClaudeVitals/Collector.swift`, directly after the closing brace of `liveSessionFiles(live:)` and before the doc comment of `candidateFiles`, insert:

```swift
/// Which sessions are live right now: the transcript each one drives, and a per-cwd session count.
struct Liveness {
    let files: Set<String>
    let repos: [String: Int]
}

/// The session registry is the source of liveness: one entry per running session, keyed by session id,
/// so several sessions in one repo are each live (the process scan could only bless the newest
/// transcript per repo) and terminal sessions count too. No `pgrep`/`lsof` on this path. Without a
/// registry directory (older Claude Code) the process scan below still drives everything.
func liveness(cache: CollectorCache) -> Liveness {
    guard let entries = readRegistry() else {
        let repos = liveRepos(cache: cache)
        return Liveness(files: liveSessionFiles(live: repos), repos: repos)
    }
    var files = Set<String>()
    var repos: [String: Int] = [:]
    for e in entries where isLiveEntry(e) {
        repos[e.cwd, default: 0] += 1
        if let path = transcriptPath(for: e) { files.insert(path) }
    }
    return Liveness(files: files, repos: repos)
}
```

- [ ] **Step 3: Make `candidateFiles` take the live transcript set**

Replace the doc comment and signature:

```swift
/// Every PROJ/*/*.jsonl touched < RECENT_WINDOW (grace), plus each live repo's active session (always),
/// plus any hook-seeded transcript paths (a brand-new session emits SessionStart before its file ages in).
func candidateFiles(live: [String: Int], extra: Set<String> = []) -> Set<String> {
```

with:

```swift
/// Every PROJ/*/*.jsonl touched < RECENT_WINDOW (grace), plus every live session's transcript (always),
/// plus any hook-seeded transcript paths (a brand-new session emits SessionStart before its file ages in).
func candidateFiles(active: Set<String>, extra: Set<String> = []) -> Set<String> {
```

and in the same function replace:

```swift
    return files.union(liveSessionFiles(live: live)).union(extra.filter { p in
```

with:

```swift
    return files.union(active).union(extra.filter { p in
```

- [ ] **Step 4: Use `liveness` in `buildSnapshot`**

In `buildSnapshot(parser:cache:hooks:hookFiles:)` replace:

```swift
    let live = liveRepos(cache: cache)
    let activeFiles = liveSessionFiles(live: live)   // the exact session each live agent is driving
```

with:

```swift
    let liveNow = liveness(cache: cache)
    let live = liveNow.repos
    let activeFiles = liveNow.files                  // the exact transcript each live session is driving
```

and replace:

```swift
    let candidates = candidateFiles(live: live, extra: hookFiles)
```

with:

```swift
    let candidates = candidateFiles(active: activeFiles, extra: hookFiles)
```

Nothing else in `buildSnapshot` changes: `live` is still the `[String: Int]` it was, and `activeFiles` is still a `Set<String>`.

- [ ] **Step 5: Update the README data-layer bullet**

In `README.md` under "How it works (data layer)", replace the whole "Live sessions" bullet (three lines, starting with `- **Live sessions**` and ending with `(robust even if a transcript header lacks `cwd`).`) with:

```markdown
- **Live sessions** - Claude Code's session registry, `~/.claude/sessions/<pid>.json` (the data behind
  `claude agents --json`): one entry per running session with its `sessionId` and `cwd`. An entry is
  live when its pid is running and that process started no later than the session, which rules out a
  stale file whose pid was reused. Without a registry (older Claude Code) the app falls back to
  `pgrep` + `lsof` and treats the newest transcript per repo as the live one.
```

- [ ] **Step 6: Build**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 7: Run the end-to-end check**

This exercises the real binary against a fake registry, because XCTest cannot run here. Run it from the repo root with `bash` (not zsh) exactly as written:

```bash
BIN=.build/debug/ClaudeVitals
FAKE="$(mktemp -d)/sessions"; mkdir -p "$FAKE"
OLD=$(ls -tr "$HOME"/.claude/projects/*/*.jsonl | head -1)   # oldest transcript: far outside the grace window
SID=$(basename "$OLD" .jsonl)
NOW_MS=$(( $(date +%s) * 1000 ))
# dead pid: never live
printf '{"pid":999999,"sessionId":"%s","cwd":"/nonexistent","startedAt":%s}' "$SID" "$NOW_MS" > "$FAKE/999999.json"
# running pid (this shell) whose process started long AFTER startedAt: a reused pid, never live
printf '{"pid":%s,"sessionId":"%s","cwd":"/nonexistent","startedAt":1000}' "$$" "$SID" > "$FAKE/$$.json"
A=$(CLAUDE_VITALS_SESSIONS_DIR="$FAKE" "$BIN" --dump | head -1)
# same running pid with a plausible startedAt: live, so the old transcript becomes a card
printf '{"pid":%s,"sessionId":"%s","cwd":"/nonexistent","startedAt":%s}' "$$" "$SID" "$NOW_MS" > "$FAKE/$$.json"
B=$(CLAUDE_VITALS_SESSIONS_DIR="$FAKE" "$BIN" --dump | head -1)
C=$(CLAUDE_VITALS_SESSIONS_DIR="$FAKE/absent" "$BIN" --dump | head -1)
R=$("$BIN" --dump | head -1)
echo "A dead+reused     : $A"
echo "B plus one live   : $B"
echo "C no registry dir : $C"
echo "R real registry   : $R"
echo "live registry entries on this machine: $(ls "$HOME"/.claude/sessions/*.json 2>/dev/null | wc -l | tr -d ' ')"
```

Expected:
- `B` reports exactly one more `blocks=` than `A` (the live entry surfaced a transcript that is otherwise far too old to show; the dead and reused entries did not).
- `C` still reports `blocks=` of 1 or more when a VS Code Claude session is open (the pgrep fallback works).
- `R` reports `blocks=` greater than or equal to the number of live registry entries printed on the last line.

Put the five echoed lines in your report verbatim.

- [ ] **Step 8: Commit**

```bash
git add Sources/ClaudeVitals/Collector.swift README.md
git commit -m "feat(collector): derive liveness from the session registry, pgrep as fallback"
```
