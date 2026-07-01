import XCTest
@testable import ClaudeVitals

final class HookMergeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)
    private let heuristic: (dot: Dot, state: String) = (.runningTool, "running tool")

    func testNoHookFallsBackToHeuristic() {
        let r = resolveState(heuristic: heuristic, isLive: true, hook: nil, now: now)
        XCTAssertEqual(r.dot, .runningTool)
        XCTAssertEqual(r.state, "running tool")
        XCTAssertTrue(r.live)
        XCTAssertFalse(r.usedHook)
    }

    func testFreshHookWins() {
        let hook = HookStatus(dot: .waitingPermission, state: "needs permission", toolName: "Bash", alive: true, at: now.addingTimeInterval(-2))
        let r = resolveState(heuristic: heuristic, isLive: true, hook: hook, now: now)
        XCTAssertEqual(r.dot, .waitingPermission)
        XCTAssertEqual(r.state, "needs permission")
        XCTAssertTrue(r.usedHook)
    }

    func testStaleHookIsIgnored() {
        let hook = HookStatus(dot: .waitingPermission, state: "needs permission", toolName: nil, alive: true, at: now.addingTimeInterval(-(HOOK_FRESH_S + 1)))
        let r = resolveState(heuristic: heuristic, isLive: true, hook: hook, now: now)
        XCTAssertEqual(r.dot, .runningTool)      // heuristic
        XCTAssertFalse(r.usedHook)
    }

    func testHookLivenessOverridesProcessLiveness() {
        let hook = HookStatus(dot: .ended, state: "ended", toolName: nil, alive: false, at: now)
        let r = resolveState(heuristic: heuristic, isLive: true, hook: hook, now: now)
        XCTAssertEqual(r.dot, .ended)
        XCTAssertFalse(r.live)
    }
}
