import AppKit

// @main lives here (NOT in a file named main.swift, and NOT on the SwiftUI App struct).
@main
struct Entry {
    static func main() {
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
            print("\nusage  (unavailable — token/network)")
        }
    }
}
