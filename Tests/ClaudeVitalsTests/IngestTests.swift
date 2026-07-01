import XCTest
@testable import ClaudeVitals

final class IngestTests: XCTestCase {
    // A throwaway project dir + session file under the real PROJ, cleaned up after.
    private func makeSession() throws -> (dir: URL, file: URL, sessionId: String) {
        let sessionId = "test-\(UUID().uuidString)"
        let dir = PROJ.appendingPathComponent("-tmp-claudevitals-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(sessionId).jsonl")
        let line = #"{"type":"assistant","cwd":"/tmp/repo","gitBranch":"main","message":{"role":"assistant","model":"claude-opus-4-8","stop_reason":"end_turn","usage":{"input_tokens":10}}}"#
        try (line + "\n").write(to: file, atomically: true, encoding: .utf8)
        return (dir, file, sessionId)
    }

    func testIngestPermissionRequestFlipsCardToWaitingPermission() async throws {
        let s = try makeSession()
        defer { try? FileManager.default.removeItem(at: s.dir) }
        let collector = Collector()
        let e = HookEvent(event: "PermissionRequest", session_id: s.sessionId,
                          cwd: "/tmp/repo", transcript_path: s.file.path, tool_name: "Bash")
        let snap = await collector.ingest(e)
        let block = snap.blocks.first { $0.sessionId == s.sessionId }
        XCTAssertNotNil(block, "ingested session should appear as a card")
        XCTAssertEqual(block?.dot, .waitingPermission)
        XCTAssertTrue(snap.hookDriven)
    }
}
