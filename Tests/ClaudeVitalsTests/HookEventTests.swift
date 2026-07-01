import XCTest
@testable import ClaudeVitals

final class HookEventTests: XCTestCase {
    private func decode(_ json: String) throws -> HookEvent {
        try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
    }

    func testDecodeMapsHookEventName() throws {
        let e = try decode(#"{"hook_event_name":"PreToolUse","session_id":"abc","cwd":"/r","transcript_path":"/t.jsonl","tool_name":"Bash"}"#)
        XCTAssertEqual(e.event, "PreToolUse")
        XCTAssertEqual(e.session_id, "abc")
        XCTAssertEqual(e.tool_name, "Bash")
    }

    func testDecodeToleratesMissingOptionalFields() throws {
        let e = try decode(#"{"hook_event_name":"Stop","session_id":"abc"}"#)
        XCTAssertEqual(e.event, "Stop")
        XCTAssertNil(e.tool_name)
        XCTAssertNil(e.transcript_path)
    }

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testPreToolUseGoesRunningToolWithName() {
        let e = HookEvent(event: "PreToolUse", session_id: "s", cwd: nil, transcript_path: nil, tool_name: "Bash")
        let s = applyHookEvent(nil, e, at: t0)
        XCTAssertEqual(s.dot, .runningTool)
        XCTAssertEqual(s.state, "running Bash")
        XCTAssertEqual(s.toolName, "Bash")
        XCTAssertTrue(s.alive)
        XCTAssertEqual(s.at, t0)
    }

    func testPermissionRequestGoesWaitingPermission() {
        let e = HookEvent(event: "PermissionRequest", session_id: "s", cwd: nil, transcript_path: nil, tool_name: "Bash")
        let s = applyHookEvent(nil, e, at: t0)
        XCTAssertEqual(s.dot, .waitingPermission)
        XCTAssertEqual(s.state, "needs permission")
    }

    func testStopGoesWaitingPrompt() {
        let e = HookEvent(event: "Stop", session_id: "s", cwd: nil, transcript_path: nil, tool_name: nil)
        let s = applyHookEvent(nil, e, at: t0)
        XCTAssertEqual(s.dot, .waiting)
        XCTAssertEqual(s.state, "waiting prompt")
    }

    func testSessionEndGoesEndedNotAlive() {
        let e = HookEvent(event: "SessionEnd", session_id: "s", cwd: nil, transcript_path: nil, tool_name: nil)
        let s = applyHookEvent(nil, e, at: t0)
        XCTAssertEqual(s.dot, .ended)
        XCTAssertFalse(s.alive)
    }

    func testNotificationDoesNotChangeStateWhileRunning() {
        let running = applyHookEvent(nil, HookEvent(event: "PreToolUse", session_id: "s", cwd: nil, transcript_path: nil, tool_name: "Bash"), at: t0)
        let later = t0.addingTimeInterval(2)
        let s = applyHookEvent(running, HookEvent(event: "Notification", session_id: "s", cwd: nil, transcript_path: nil, tool_name: nil), at: later)
        XCTAssertEqual(s.dot, .runningTool)   // unchanged - no false "finished" transition
        XCTAssertEqual(s.state, "running Bash")
        XCTAssertEqual(s.at, later)           // timestamp still advances (liveness backstop)
    }

    func testSubagentEventsDoNotChangeStateButBumpTimestamp() {
        let base = applyHookEvent(nil, HookEvent(event: "PreToolUse", session_id: "s", cwd: nil, transcript_path: nil, tool_name: "Bash"), at: t0)
        let later = t0.addingTimeInterval(3)
        let e = HookEvent(event: "SubagentStart", session_id: "s", cwd: nil, transcript_path: nil, tool_name: nil)
        let s = applyHookEvent(base, e, at: later)
        XCTAssertEqual(s.dot, .runningTool)      // unchanged
        XCTAssertEqual(s.at, later)              // timestamp advanced (keeps hook state fresh)
    }
}
