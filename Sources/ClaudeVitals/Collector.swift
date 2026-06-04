import Foundation

// MARK: - Constants

let PROJ = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
/// Grace window: a session whose `claude` process has exited lingers this long as an "ended" card
/// before dropping off. Live sessions are never subject to this (they stay via the live-repo branch).
let RECENT_WINDOW: TimeInterval = 3 * 60
let LIVE_FILE_S: TimeInterval = 5
let SUBAGENT_LIVE_S: TimeInterval = 10
let TAIL_BYTES = 256 * 1024
let HEAD_BYTES = 64 * 1024

// MARK: - Shell + filesystem helpers (all pure / stateless)

func runCmd(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do { try p.run() } catch { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

/// A single `lsof` to resolve one pid's cwd (the slow call). "" if it has no cwd line yet.
func lsofCwd(_ pid: String) -> String {
    let lsof = runCmd("/usr/sbin/lsof", ["-a", "-p", pid, "-d", "cwd", "-Fn"])
    for line in lsof.split(whereSeparator: \.isNewline) where line.hasPrefix("n") {
        return String(line.dropFirst())
    }
    return ""
}

/// repo cwd -> count of live interactive `claude` processes (absolute tool paths: .app PATH lacks /usr/sbin).
///
/// `pgrep` is cheap and runs every tick; the per-pid `lsof` (the slow call) runs ONLY for pids we
/// haven't resolved yet — a process's cwd is fixed for its lifetime, so the result is cached and dead
/// pids are pruned each tick. Empty results aren't cached, so a pid whose cwd isn't readable yet
/// (just-spawned, between stat/open) is retried next tick instead of stuck blank.
func liveRepos(cache: CollectorCache) -> [String: Int] {
    var out: [String: Int] = [:]
    let pgrep = runCmd("/usr/bin/pgrep", ["-f", "native-binary/claude.*stream-json"])
    let pids = pgrep.split(whereSeparator: \.isNewline).map(String.init)
    cache.pidCwd = cache.pidCwd.filter { Set(pids).contains($0.key) }   // prune exited processes
    for pid in pids {
        let cwd: String
        if let cached = cache.pidCwd[pid] {
            cwd = cached
        } else {
            cwd = lsofCwd(pid)
            if !cwd.isEmpty { cache.pidCwd[pid] = cwd }
        }
        if !cwd.isEmpty { out[cwd, default: 0] += 1 }
    }
    return out
}

/// Mirror Python re.sub(r'[^A-Za-z0-9]','-'): per unicode scalar (not byte), keep ASCII alnum else '-'.
func encodeRepo(_ path: String) -> String {
    var s = ""
    s.reserveCapacity(path.count)
    for scalar in path.unicodeScalars {
        let v = scalar.value
        let alnum = (v >= 48 && v <= 57) || (v >= 65 && v <= 90) || (v >= 97 && v <= 122)
        s.append(alnum ? Character(scalar) : "-")
    }
    return s
}

func mtime(_ path: String) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
}

func fileSize(_ path: String) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int) ?? 0
}

// MARK: - JSONL parsing

func parseLines(_ data: Data, dropFirstPartial: Bool) -> [Line] {
    var parts = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
    if dropFirstPartial, !parts.isEmpty { parts.removeFirst() }
    let dec = JSONDecoder()
    var out: [Line] = []
    for part in parts where !part.isEmpty {
        if let line = try? dec.decode(Line.self, from: Data(part)) { out.append(line) }
    }
    return out
}

/// Last `TAIL_BYTES` of a transcript, parsed (drops the first partial line if we seeked).
func tailObjects(_ path: String) -> [Line] {
    guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
    defer { try? fh.close() }
    let size = (try? fh.seekToEnd()) ?? 0
    var seeked = false
    if size > UInt64(TAIL_BYTES) {
        try? fh.seek(toOffset: size - UInt64(TAIL_BYTES)); seeked = true
    } else {
        try? fh.seek(toOffset: 0)
    }
    let data = (try? fh.readToEnd()) ?? Data()
    return parseLines(data, dropFirstPartial: seeked)
}

/// First line carrying cwd (the literal first line is an "operation" line with no cwd).
func headMeta(_ path: String) -> (cwd: String, branch: String) {
    guard let fh = FileHandle(forReadingAtPath: path) else { return ("", "") }
    defer { try? fh.close() }
    let data = (try? fh.read(upToCount: HEAD_BYTES)) ?? Data()
    for l in parseLines(data, dropFirstPartial: false) where (l.cwd?.isEmpty == false) {
        return (l.cwd ?? "", l.gitBranch ?? "")
    }
    return ("", "")
}

/// cwd/branch live in the transcript head and never change for a given file, so read+parse the 64KB
/// head exactly once per path. Don't cache an empty result: a freshly-created file may not have its
/// first cwd-bearing line written yet, so retry until one appears.
func headMetaCached(_ path: String, cache: CollectorCache) -> (cwd: String, branch: String) {
    if let h = cache.head[path] { return h }
    let h = headMeta(path)
    if !h.cwd.isEmpty { cache.head[path] = h }
    return h
}

// MARK: - Per-session derivations

/// Scan tail backward for the last user|assistant line (transcripts end with pr-link/ai-title/etc.).
///
/// Age (file mtime) is the PRIMARY signal — it's reliable regardless of process detection. `isLive`
/// (a detected `claude` process is driving this exact session) is used only as a POSITIVE upgrade:
/// it promotes a quiet finished turn from "ended" to "waiting prompt". It never forces "ended", so a
/// session that's actively being written is never mislabeled when `pgrep` fails to see its process
/// (observed: `pgrep -f` misses live VS Code `claude` processes). The old code returned "waiting
/// prompt" for ANY `end_turn` at any age, so a session that finished 15 min ago looked like a live
/// agent awaiting input — the stale-card bug.
func deriveState(lastType: String?, lastStop: String?, asksUser: Bool, age: TimeInterval, isLive: Bool) -> (Dot, String) {
    // No conversational line yet (freshly created / mid-first-write) -> not "running".
    guard let t = lastType else { return (.idle, "idle") }
    let stop = lastStop
    // An interactive prompt (AskUserQuestion / plan approval) is a tool_use that stays pending until
    // the user answers — on disk it's indistinguishable from a running tool, but it's actually waiting
    // for the user. True at any age (the question may have been posed this second or minutes ago).
    if t == "assistant", stop == "tool_use", asksUser { return (.waiting, "waiting prompt") }
    if age < LIVE_FILE_S {                                  // written this second -> actively running
        if t == "assistant", stop == "tool_use" { return (.runningTool, "running tool") }
        if t == "user" { return (.runningModel, "running model") }
        return (.runningModel, "running")
    }
    if age < 60 {                                           // brief gap mid-turn / just finished
        if t == "assistant", stop == "tool_use" { return (.runningTool, "running tool") }
        if t == "assistant", stop == "end_turn" { return (.waiting, "waiting prompt") }
        return (.runningModel, "running model")
    }
    // Quiet for >60s. With a live process attached the agent is genuinely running/waiting/idle; with
    // none the session has ended (and ages out of the grace window shortly after).
    guard isLive else { return (.ended, "ended") }
    // A still-unanswered tool_use means a long-running tool is in flight (a subagent or long bash can
    // easily exceed 60s while the main transcript stays untouched) — not idle. The tool_result hasn't
    // landed yet; once it does the last line becomes a `user` line and this no longer matches.
    if t == "assistant", stop == "tool_use" { return (.runningTool, "running tool") }
    if t == "assistant", stop == "end_turn" { return (.waiting, "waiting prompt") }
    return (.idle, "idle")
}

/// Context window for a model id. The transcript records neither the window size nor a 1M marker:
/// the API model field is bare ("claude-opus-4-8") — the "[1m]" suffix lives only in Claude Code's
/// display id, never on disk. Modern Opus 4.x and Sonnet 4.5+ default to a 1M window, so assuming
/// 200K mislabels them, peaking at a false 90-100% across the 180K-200K band (observed: opus-4-7 and
/// opus-4-8 sessions routinely reach 500K-700K of live context). Map by family; keep the
/// observed-context floor (ctx>200k ⇒ at least 1M) so any 1M model we don't list still self-corrects
/// once it crosses 200K.
func contextWindow(model: String, ctx: Int) -> Int {
    let oneMillion = model.contains("opus-4")        // opus 4.x (4-6/4-7/4-8 verified, forward-match)
        || model.contains("sonnet-4-5")
        || model.contains("sonnet-4-6")
    return (oneMillion || ctx > 200_000) ? 1_000_000 : 200_000
}

func deriveContext(_ lines: [Line]) -> (ctx: Int, limit: Int, model: String) {
    for l in lines.reversed() {
        if let u = l.message?.usage {
            let ctx = (u.input_tokens ?? 0) + (u.cache_read_input_tokens ?? 0) + (u.cache_creation_input_tokens ?? 0)
            let model = l.message?.model ?? "?"
            return (ctx, contextWindow(model: model, ctx: ctx), model)
        }
    }
    return (0, 200_000, "?")
}

func deriveSubagents(_ sessionFile: String) -> (total: Int, running: Int) {
    let url = URL(fileURLWithPath: sessionFile)
    let stem = url.deletingPathExtension().lastPathComponent
    let dir = url.deletingLastPathComponent().appendingPathComponent(stem).appendingPathComponent("subagents")
    guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
        return (0, 0)
    }
    let jsonls = files.filter { $0.pathExtension == "jsonl" }
    let now = Date()
    let running = jsonls.filter { (mtime($0.path).map { now.timeIntervalSince($0) < SUBAGENT_LIVE_S }) ?? false }.count
    return (jsonls.count, running)
}

/// The session file each live agent is actively driving: the newest `.jsonl` in every live repo.
/// This is per-SESSION liveness — within one repo only the active session counts as live, so older
/// sessions (e.g. after /clear, restart, or compaction) are correctly treated as ended, not "waiting".
func liveSessionFiles(live: [String: Int]) -> Set<String> {
    let fm = FileManager.default
    var files = Set<String>()
    for repo in live.keys {
        let dir = PROJ.appendingPathComponent(encodeRepo(repo))
        guard let sessions = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
        let jsonls = sessions.filter { $0.pathExtension == "jsonl" }
        if let newest = jsonls.max(by: { (mtime($0.path) ?? .distantPast) < (mtime($1.path) ?? .distantPast) }) {
            files.insert(newest.path)
        }
    }
    return files
}

/// Every PROJ/*/*.jsonl touched < RECENT_WINDOW (grace), plus each live repo's active session (always).
func candidateFiles(live: [String: Int]) -> Set<String> {
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
    // A live agent's active session always shows, even if it's been quietly waiting longer than the grace.
    return files.union(liveSessionFiles(live: live))
}

// MARK: - Cross-tick caches (actor-owned; bound the per-tick cost)

/// The expensive file-derived fields for one session, keyed by (mtime, size). Holds NO time-dependent
/// value (age/state/liveness are recomputed cheaply each tick) — only what the file bytes determine.
/// Tools that pause for the user: their `tool_use` stays pending (no tool_result) until the user
/// answers, so on disk they look identical to a running tool but are actually "waiting prompt".
let USER_PROMPT_TOOLS: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

struct ParsedSession {
    let mtime: Date
    let size: Int
    let lastType: String?    // type of the last user|assistant line (for deriveState)
    let lastStop: String?    // its stop_reason
    let asksUser: Bool       // last line is a pending question/plan-approval tool -> awaiting the user
    let ctx: Int
    let ctxLimit: Int
    let ctxModel: String
}

/// Reused across refreshes inside the Collector actor so each tick only does work the filesystem
/// actually changed: head meta read once per path, parsed tail re-read only on mtime/size change,
/// pid->cwd `lsof` only for new processes.
final class CollectorCache {
    var pidCwd: [String: String] = [:]                          // pid -> cwd (stable for process life)
    var head: [String: (cwd: String, branch: String)] = [:]     // path -> immutable head meta
    var parsed: [String: ParsedSession] = [:]                   // path -> content-derived fields
}

/// Tail-derived fields for a session, served from cache unless the file's mtime+size changed (the
/// quiet-grace-window steady state, where nothing is appended, costs zero reads here).
func parseSession(_ path: String, mtime m: Date, size: Int, cache: CollectorCache) -> ParsedSession {
    if let p = cache.parsed[path], p.size == size, p.mtime == m { return p }
    let lines = tailObjects(path)
    let lastConv = lines.last { $0.type == "user" || $0.type == "assistant" }
    let asksUser = lastConv?.message?.content?.contains {
        $0.type == "tool_use" && USER_PROMPT_TOOLS.contains($0.name ?? "")
    } ?? false
    let (ctx, limit, model) = deriveContext(lines)
    let p = ParsedSession(mtime: m, size: size,
                          lastType: lastConv?.type, lastStop: lastConv?.message?.stop_reason,
                          asksUser: asksUser,
                          ctx: ctx, ctxLimit: limit, ctxModel: model)
    cache.parsed[path] = p
    return p
}

// MARK: - Snapshot assembly (the single source of truth)

func buildSnapshot(parser: TranscriptParser, cache: CollectorCache) -> Snapshot {
    let live = liveRepos(cache: cache)
    let activeFiles = liveSessionFiles(live: live)   // the exact session each live agent is driving
    let now = Date()
    var blocks: [Block] = []
    let candidates = candidateFiles(live: live)

    for f in candidates {
        guard let m = mtime(f) else { continue }
        let age = now.timeIntervalSince(m)
        let ps = parseSession(f, mtime: m, size: fileSize(f), cache: cache)
        let (headCwd, branch) = headMetaCached(f, cache: cache)
        let (subsTotal, subsRunning) = deriveSubagents(f)
        let e = parser.effort(path: f)

        // Per-session liveness: a card is "live" only if it's the session an alive `claude` process is
        // actively driving. Project-level matching (dirName) still recovers cwd/pids when head lacks them.
        let isLive = activeFiles.contains(f)
        let dirName = URL(fileURLWithPath: f).deletingLastPathComponent().lastPathComponent
        let liveMatch = live.first { encodeRepo($0.key) == dirName }
        let cwd = headCwd.isEmpty ? (liveMatch?.key ?? "") : headCwd
        let repo = cwd.isEmpty ? dirName : URL(fileURLWithPath: cwd).lastPathComponent

        let (dot, state) = deriveState(lastType: ps.lastType, lastStop: ps.lastStop, asksUser: ps.asksUser, age: age, isLive: isLive)

        blocks.append(Block(
            sessionId: URL(fileURLWithPath: f).deletingPathExtension().lastPathComponent,
            repo: repo, cwd: cwd, branch: branch, age: Int(age),
            dot: dot, state: state,
            ctx: ps.ctx, ctxLimit: ps.ctxLimit, ctxPct: ps.ctxLimit > 0 ? Double(ps.ctx) / Double(ps.ctxLimit) * 100 : 0,
            model: ps.ctxModel == "?" ? e.model : ps.ctxModel,
            inTok: e.inTok, outTok: e.outTok, cw: e.cw, cr: e.cr, cost: e.cost,
            turns: e.turns, tools: e.tools,
            subsTotal: subsTotal, subsRunning: subsRunning,
            live: isLive, pids: liveMatch?.value ?? 0))
    }

    cache.parsed = cache.parsed.filter { candidates.contains($0.key) }   // drop sessions out of the window

    blocks.sort { (($0.live ? 0 : 1), $0.age) < (($1.live ? 0 : 1), $1.age) }

    return Snapshot(
        blocks: blocks,
        running: blocks.filter { $0.dot.isRunning }.count,
        subsRunning: blocks.reduce(0) { $0 + $1.subsRunning },
        totalIn: blocks.reduce(0) { $0 + $1.inTok },
        totalOut: blocks.reduce(0) { $0 + $1.outTok },
        totalCw: blocks.reduce(0) { $0 + $1.cw },
        totalCr: blocks.reduce(0) { $0 + $1.cr },
        totalCost: blocks.reduce(0) { $0 + $1.cost })
}

/// One-shot (headless --dump): fresh caches, full parse once.
func buildSnapshot() -> Snapshot { buildSnapshot(parser: TranscriptParser(), cache: CollectorCache()) }

/// GUI path: persistent caches live inside the actor, so each refresh only re-reads files that
/// changed and only `lsof`s newly-seen pids (effort stays O(appended bytes)).
actor Collector {
    private let parser = TranscriptParser()
    private let cache = CollectorCache()
    func snapshot() -> Snapshot { buildSnapshot(parser: parser, cache: cache) }
}

// MARK: - Formatting (shared by --dump and the UI)

func human(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1_000 { return String(format: "%.0fk", Double(n) / 1_000) }
    return String(n)
}

func ageStr(_ s: Int) -> String {
    if s < 60 { return "\(s)s ago" }
    if s < 3600 { return "\(s / 60)m ago" }
    return "\(s / 3600)h ago"
}
