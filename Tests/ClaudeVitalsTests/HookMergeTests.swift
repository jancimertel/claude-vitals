import XCTest
@testable import ClaudeVitals

final class HookMergeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)
    private let heuristic: (dot: Dot, state: String) = (.runningTool, "running tool")

    func testNoHookFallsBackToHeuristic() {
        let r = resolveState(heuristic: heuristic, isLive: true, liveConfirmed: false,
                             hook: nil, transcriptMtime: now, now: now)
        XCTAssertEqual(r.dot, .runningTool)
        XCTAssertEqual(r.state, "running tool")
        XCTAssertTrue(r.live)
        XCTAssertFalse(r.usedHook)
    }

    func testFreshHookWins() {
        let hook = HookStatus(dot: .waitingPermission, state: "needs permission", toolName: "Bash", alive: true, at: now.addingTimeInterval(-2))
        let r = resolveState(heuristic: heuristic, isLive: true, liveConfirmed: false,
                             hook: hook, transcriptMtime: now.addingTimeInterval(-2), now: now)
        XCTAssertEqual(r.dot, .waitingPermission)
        XCTAssertEqual(r.state, "needs permission")
        XCTAssertTrue(r.usedHook)
    }

    func testStaleHookIsIgnoredWhenLivenessUnconfirmed() {
        let staleAt = now.addingTimeInterval(-(HOOK_FRESH_S + 1))
        let hook = HookStatus(dot: .waitingPermission, state: "needs permission", toolName: nil, alive: true, at: staleAt)
        let r = resolveState(heuristic: heuristic, isLive: true, liveConfirmed: false,
                             hook: hook, transcriptMtime: staleAt, now: now)
        XCTAssertEqual(r.dot, .runningTool)      // heuristic
        XCTAssertFalse(r.usedHook)
    }

    /// Regression test for issue #2: an unanswered permission prompt must keep its badge past
    /// HOOK_FRESH_S as long as the registry confirms the session is still alive. The transcript sat
    /// still while the user decided, so its mtime matches the hook - not superseded.
    func testStalePermissionSurvivesWhileLivenessConfirmed() {
        let permAt = now.addingTimeInterval(-120)
        let hook = HookStatus(dot: .waitingPermission, state: "needs permission", toolName: "Bash", alive: true, at: permAt)
        let r = resolveState(heuristic: heuristic, isLive: true, liveConfirmed: true,
                             hook: hook, transcriptMtime: permAt, now: now)
        XCTAssertEqual(r.dot, .waitingPermission)
        XCTAssertTrue(r.usedHook)
    }

    /// A local heuristic distinct from the hook's `.runningTool` so the assertion can't pass because
    /// the two states happen to coincide.
    func testHookSupersededWhenTranscriptAdvancesPastWindow() {
        let localHeuristic: (dot: Dot, state: String) = (.waiting, "waiting prompt")
        let hookAt = now.addingTimeInterval(-120)
        let hook = HookStatus(dot: .runningTool, state: "running Bash", toolName: "Bash", alive: true, at: hookAt)
        let r = resolveState(heuristic: localHeuristic, isLive: true, liveConfirmed: true,
                             hook: hook, transcriptMtime: now.addingTimeInterval(-1), now: now)
        XCTAssertEqual(r.dot, .waiting)
        XCTAssertFalse(r.usedHook)
    }

    /// Regression: a pending permission prompt must survive a sibling tool_result landing outside
    /// HOOK_FRESH_S (parallel tool_use batch): `.waitingPermission` is exempt from supersession
    /// outright, since re-deriving from the heuristic here would also re-fire the permission alert.
    func testSupersededExemptForPendingPermission() {
        let permAt = now.addingTimeInterval(-120)
        let hook = HookStatus(dot: .waitingPermission, state: "needs permission", toolName: "Bash", alive: true, at: permAt)
        let r = resolveState(heuristic: heuristic, isLive: true, liveConfirmed: true,
                             hook: hook, transcriptMtime: now.addingTimeInterval(-1), now: now)
        XCTAssertEqual(r.dot, .waitingPermission)
        XCTAssertTrue(r.usedHook)
    }

    /// Pins the strict `>` threshold: a transcript write exactly HOOK_FRESH_S after the hook is NOT yet
    /// superseded (the existing +119s-margin test above doesn't exercise the boundary itself).
    func testNotSupersededAtExactBoundary() {
        let hookAt = now.addingTimeInterval(-120)
        let hook = HookStatus(dot: .runningTool, state: "running Bash", toolName: "Bash", alive: true, at: hookAt)
        let r = resolveState(heuristic: heuristic, isLive: true, liveConfirmed: true,
                             hook: hook, transcriptMtime: hookAt.addingTimeInterval(HOOK_FRESH_S), now: now)
        XCTAssertEqual(r.dot, .runningTool)
        XCTAssertEqual(r.state, "running Bash")
        XCTAssertTrue(r.usedHook)
    }

    func testHookLivenessOverridesProcessLiveness() {
        let hook = HookStatus(dot: .ended, state: "ended", toolName: nil, alive: false, at: now)
        let r = resolveState(heuristic: heuristic, isLive: true, liveConfirmed: false,
                             hook: hook, transcriptMtime: now, now: now)
        XCTAssertEqual(r.dot, .ended)
        XCTAssertFalse(r.live)
    }
}
