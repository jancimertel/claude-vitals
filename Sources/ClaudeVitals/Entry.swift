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
                + "\(b.branch)  \(b.age)s")
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
