import Foundation

/// Real account-wide subscription usage, read from Anthropic's unified rate-limit response headers
/// (the same numbers `/usage` shows). 0–100%; ≥100% (or status "rejected") = limit exceeded.
struct RateUsage: Sendable {
    var fiveH: Double?
    var sevenD: Double?
    var fiveHReset: Date?
    var sevenDReset: Date?
    var status: String?
    var capturedAt: Date

    var maxPct: Double? { [fiveH, sevenD].compactMap { $0 }.max() }

    /// The window the menu-bar ring shows. Below the limit, the one `source` picks (5h falls back to
    /// weekly when the headers lack it). At the limit, the window that blocks, in either mode, since
    /// being blocked must never hide behind a lower 5h number. With both full, the later reset wins:
    /// the user waits for that one. The percent and its reset always come from the same window, so the
    /// drain counts down to the right time.
    func ring(_ source: MenuSource) -> RingWindow? {
        let windows = [(fiveH, fiveHReset), (sevenD, sevenDReset)]
            .compactMap { pct, reset in pct.map { RingWindow(pct: $0, reset: reset) } }
        // max(by:) keeps the first of equal elements, so ties go to 5h.
        func highest(_ ws: [RingWindow]) -> RingWindow? { ws.max { $0.pct < $1.pct } }
        let full = windows.filter { $0.pct >= 100 }
        if !full.isEmpty {
            let timed = full.filter { $0.reset != nil }
            return timed.max { $0.reset! < $1.reset! } ?? highest(full)
        }
        switch source {
        case .fiveHour: return windows.first
        case .higher: return highest(windows)
        }
    }

    /// A window whose reset time has passed is empty: 0% until the next message starts a new one.
    /// This lets the display drop at the reset without an API call, which would itself use quota and
    /// start a new 5h window while the user may be away.
    func current(now: Date = Date()) -> RateUsage {
        var u = self
        if fiveH != nil, let r = fiveHReset, r <= now { u.fiveH = 0; u.fiveHReset = nil }
        if sevenD != nil, let r = sevenDReset, r <= now { u.sevenD = 0; u.sevenDReset = nil }
        return u
    }
}

/// Tracks which Claude account is logged in, via `oauthAccount.accountUuid` in ~/.claude.json, which
/// `/login` rewrites. Reading this file instead of the Keychain avoids a `security` call (and a possible
/// Keychain prompt) on every check. Claude Code writes the file often, so it's re-parsed only when its
/// mtime changes.
struct AccountWatcher {
    private static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    private var mtime: Date?
    private var accountId: String?
    private var seen = false

    /// True when the logged-in account differs from the one seen on the previous call. The first
    /// successful read only records the account: launch already fetches usage on its own.
    mutating func changed() -> Bool {
        guard let m = (try? FileManager.default.attributesOfItem(atPath: Self.url.path))?[.modificationDate] as? Date,
              m != mtime else { return false }
        // A half-written file fails to parse: leave mtime alone so the next tick retries.
        guard let data = try? Data(contentsOf: Self.url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        mtime = m
        let id = (obj["oauthAccount"] as? [String: Any])?["accountUuid"] as? String
        defer { accountId = id; seen = true }
        return seen && id != accountId
    }
}

/// Reads usage via the Claude Code OAuth token from the Keychain + a minimal /v1/messages call.
/// The unified-ratelimit headers only appear on /v1/messages responses (not count_tokens), so the
/// call generates ~1 token — negligible against the limits. Relies on Claude Code keeping the token
/// fresh; on auth failure we return nil and keep the last good value.
enum RateLimitFetcher {
    private static func token() -> String? {
        let raw = runCmd("/usr/bin/security",
                         ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let oauth = (obj["claudeAiOauth"] as? [String: Any]) ?? obj
        return oauth["accessToken"] as? String
    }

    static func fetch() async -> RateUsage? {
        guard let tok = token(), let url = URL(string: "https://api.anthropic.com/v1/messages") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "authorization")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("claude-code-20250219,oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("claude-cli/2.1.160 (external,cli)", forHTTPHeaderField: "user-agent")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = Data(#"{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"."}]}"#.utf8)

        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return nil }

        func header(_ k: String) -> String? { http.value(forHTTPHeaderField: k) }
        func pct(_ k: String) -> Double? { header(k).flatMap(Double.init).map { $0 * 100 } }
        func date(_ k: String) -> Date? { header(k).flatMap(Double.init).map { Date(timeIntervalSince1970: $0) } }

        let five = pct("anthropic-ratelimit-unified-5h-utilization")
        let seven = pct("anthropic-ratelimit-unified-7d-utilization")
        guard five != nil || seven != nil else { return nil }
        return RateUsage(
            fiveH: five, sevenD: seven,
            fiveHReset: date("anthropic-ratelimit-unified-5h-reset"),
            sevenDReset: date("anthropic-ratelimit-unified-7d-reset"),
            status: header("anthropic-ratelimit-unified-status"),
            capturedAt: Date())
    }

    /// Blocking variant for the headless --dump path.
    static func fetchSync() -> RateUsage? {
        let sem = DispatchSemaphore(value: 0)
        let box = Box()
        Task { box.value = await fetch(); sem.signal() }
        sem.wait()
        return box.value
    }
    private final class Box: @unchecked Sendable { var value: RateUsage? }
}

/// "2h13m" / "3d4h" / "now" until a reset timestamp, relative to `now`.
func resetIn(_ date: Date?, now: Date = Date()) -> String? {
    guard let date else { return nil }
    let s = Int(date.timeIntervalSince(now))
    return s <= 0 ? "now" : durStr(s)
}

/// "45m" / "2h13m" / "3d4h" for a duration in seconds.
func durStr(_ s: Int) -> String {
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h\((s % 3600) / 60)m" }
    return "\(s / 86400)d\((s % 86400) / 3600)h"
}

/// Which usage window the menu-bar ring shows below the limit (set from the right-click menu).
enum MenuSource: String, CaseIterable {
    case fiveHour, higher

    var title: String { self == .fiveHour ? "5-Hour Window" : "Whichever Is Higher" }

    static var saved: MenuSource {
        get { UserDefaults.standard.string(forKey: "menuSource").flatMap(MenuSource.init) ?? .fiveHour }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "menuSource") }
    }
}

/// One usage window as the ring draws it: its percent and when it resets.
struct RingWindow: Equatable, Sendable {
    var pct: Double
    var reset: Date?
}
