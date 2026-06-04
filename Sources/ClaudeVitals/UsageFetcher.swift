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
    if s <= 0 { return "now" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h\((s % 3600) / 60)m" }
    return "\(s / 86400)d\((s % 86400) / 3600)h"
}
