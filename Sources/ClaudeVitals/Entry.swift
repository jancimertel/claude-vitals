import AppKit
import Foundation

// @main lives here (NOT in a file named main.swift, and NOT on the SwiftUI App struct).
@main
struct Entry {
    static func main() {
        if let i = CommandLine.arguments.firstIndex(of: "--emit"), i + 1 < CommandLine.arguments.count {
            let event = CommandLine.arguments[i + 1]
            let sid = (i + 2 < CommandLine.arguments.count) ? CommandLine.arguments[i + 2] : "debug-session"
            emitDebug(event: event, sessionId: sid)
            return
        }
        if CommandLine.arguments.contains("--dump") {
            runDump()                                         // headless data-layer test, no GUI
            return
        }
        if CommandLine.arguments.contains("--selfcheck") {
            runSelfCheck()                                    // headless resolveState assertions, no GUI
            return
        }
        NSApplication.shared.setActivationPolicy(.accessory)  // suppress Dock flash before the App launches
        ClaudeVitalsApp.main()                                // App protocol's static main()
    }

    static func runDump() {
        let snap = buildSnapshot()
        print("running=\(snap.running)  subagents_running=\(snap.subsRunning)  blocks=\(snap.blocks.count)\n")
        for b in snap.blocks {
            let repo = b.repo.padding(toLength: 28, withPad: " ", startingAt: 0)
            let state = b.state.padding(toLength: 14, withPad: " ", startingAt: 0)
            print("\(b.dot.glyph) \(repo) \(state) "
                + "ctx \(String(format: "%5.1f", b.ctxPct))%  "
                + "\(human(b.inTok + b.outTok)) tok  $\(String(format: "%.2f", b.cost))  "
                + "\(b.turns)t/\(b.tools)tools  sub \(b.subsRunning)/\(b.subsTotal)  "
                + "\(b.branch)  \(b.age)s"
                + (b.title.isEmpty ? "" : "  \"\(b.title)\""))
        }
        if let u = RateLimitFetcher.fetchSync() {
            let f = u.fiveH.map { String(format: "%.0f%%", $0) } ?? "-"
            let w = u.sevenD.map { String(format: "%.0f%%", $0) } ?? "-"
            print("\nusage (live)  5h=\(f) (resets \(resetIn(u.fiveHReset) ?? "?"))  "
                + "7d=\(w) (resets \(resetIn(u.sevenDReset) ?? "?"))  status=\(u.status ?? "?")")
        } else {
            print("\nusage  (unavailable - token/network)")
        }
    }

    /// resolveState is a pure function and --dump never carries hook state, so nothing else exercises
    /// the hook-merge logic on this machine; XCTest needs Xcode, which isn't installed here.
    static func runSelfCheck() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let heuristic: (dot: Dot, state: String) = (.runningTool, "running tool")
        func check(_ name: String, _ cond: Bool) {
            guard cond else { print("FAIL \(name)"); exit(1) }
            print("ok \(name)")
        }
        func hook(_ dot: Dot, _ state: String, at: TimeInterval, alive: Bool = true) -> HookStatus {
            HookStatus(dot: dot, state: state, toolName: nil, alive: alive, at: now.addingTimeInterval(at))
        }

        let r1 = resolveState(heuristic: heuristic, isLive: true, liveConfirmed: false, hook: nil, transcriptMtime: now, now: now)
        check("noHookFallsBackToHeuristic", r1.dot == .runningTool && r1.state == "running tool" && r1.live && !r1.usedHook)

        let r2 = resolveState(heuristic: heuristic, isLive: true, liveConfirmed: false, hook: hook(.waitingPermission, "needs permission", at: -2), transcriptMtime: now, now: now)
        check("freshHookWins", r2.dot == .waitingPermission && r2.usedHook)

        let staleHook = hook(.waitingPermission, "needs permission", at: -(HOOK_FRESH_S + 1))
        let r3 = resolveState(heuristic: heuristic, isLive: true, liveConfirmed: false, hook: staleHook, transcriptMtime: now.addingTimeInterval(-(HOOK_FRESH_S + 1)), now: now)
        check("staleHookIgnoredWhenLivenessUnconfirmed", r3.dot == .runningTool && !r3.usedHook)

        let permHook = hook(.waitingPermission, "needs permission", at: -120)
        let r4 = resolveState(heuristic: heuristic, isLive: true, liveConfirmed: true, hook: permHook, transcriptMtime: now.addingTimeInterval(-120), now: now)
        check("stalePermissionSurvivesWhileLivenessConfirmed", r4.dot == .waitingPermission && r4.usedHook)

        // Supersession only applies to a supersedable state; a local heuristic distinct from the hook's
        // dot keeps the assertion from passing for the wrong reason.
        let toolHook = hook(.runningTool, "running Bash", at: -120)
        let r5 = resolveState(heuristic: (.waiting, "waiting prompt"), isLive: true, liveConfirmed: true, hook: toolHook, transcriptMtime: now.addingTimeInterval(-1), now: now)
        check("hookSupersededWhenTranscriptAdvancesPastWindow", r5.dot == .waiting && !r5.usedHook)

        // A pending permission prompt is exempt from supersession: a sibling tool_result landing
        // while the user decides must not revoke the badge.
        let r6 = resolveState(heuristic: heuristic, isLive: true, liveConfirmed: true, hook: permHook, transcriptMtime: now.addingTimeInterval(-1), now: now)
        check("supersededExemptForPendingPermission", r6.dot == .waitingPermission && r6.usedHook)

        // Pins the strict `>` threshold: exactly HOOK_FRESH_S past the hook is NOT yet superseded.
        let r7 = resolveState(heuristic: heuristic, isLive: true, liveConfirmed: true, hook: toolHook, transcriptMtime: now.addingTimeInterval(-120 + HOOK_FRESH_S), now: now)
        check("notSupersededAtExactBoundary", r7.dot == .runningTool && r7.state == "running Bash" && r7.usedHook)

        let r8 = resolveState(heuristic: heuristic, isLive: true, liveConfirmed: false, hook: hook(.ended, "ended", at: 0, alive: false), transcriptMtime: now, now: now)
        check("hookLivenessOverridesProcessLiveness", r8.dot == .ended && r8.usedHook && !r8.live)

        exit(0)
    }

    static func emitDebug(event: String, sessionId: String) {
        let json = #"{"hook_event_name":"\#(event)","session_id":"\#(sessionId)","tool_name":"Bash"}"#
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { print("socket() failed"); return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { p in
            VITALS_SOCK.withCString { strncpy(p, $0, sunPathSize - 1) }
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
}
