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

/// Empty when the directory does not exist (older Claude Code) or holds no readable entry. The caller
/// treats both the same way: the registry has nothing to say, so it falls back to process scanning.
func readRegistry(dir: URL = SESSIONS_DIR) -> [RegistryEntry] {
    guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
        return []
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
