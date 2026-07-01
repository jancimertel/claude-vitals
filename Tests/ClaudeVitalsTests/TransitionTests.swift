import XCTest
@testable import ClaudeVitals

final class TransitionTests: XCTestCase {
    private func block(_ id: String, _ dot: Dot) -> Block {
        Block(sessionId: id, repo: "repo-\(id)", title: "", cwd: "", branch: "", age: 0, dot: dot, state: "",
              ctx: 0, ctxLimit: 200_000, ctxPct: 0, model: "?", inTok: 0, outTok: 0, cw: 0, cr: 0,
              cost: 0, turns: 0, tools: 0, subsTotal: 0, subsRunning: 0, live: true, pids: 1)
    }

    func testRunningToWaitingEmitsFinished() {
        var t = TransitionTracker()
        _ = t.update([block("a", .runningModel)])
        let alerts = t.update([block("a", .waiting)])
        XCTAssertEqual(alerts, [Alert(repo: "repo-a", kind: .finished)])
    }

    func testRunningToPermissionEmitsNeedsPermission() {
        var t = TransitionTracker()
        _ = t.update([block("a", .runningTool)])
        let alerts = t.update([block("a", .waitingPermission)])
        XCTAssertEqual(alerts, [Alert(repo: "repo-a", kind: .needsPermission)])
    }

    func testNoAlertWhenStayingRunning() {
        var t = TransitionTracker()
        _ = t.update([block("a", .runningModel)])
        XCTAssertEqual(t.update([block("a", .runningTool)]), [])
    }
}
