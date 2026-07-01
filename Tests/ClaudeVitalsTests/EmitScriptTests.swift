import XCTest
@testable import ClaudeVitals

final class EmitScriptTests: XCTestCase {
    func testEmitScriptDeliversStdinToSocket() throws {
        let path = NSTemporaryDirectory() + "vitals-emit-\(UUID().uuidString).sock"
        let got = expectation(description: "event via emit.sh")
        var received: HookEvent?
        let socket = EventSocket(path: path) { e in received = e; got.fulfill() }
        socket.start()
        defer { socket.stop() }
        Thread.sleep(forTimeInterval: 0.1)

        // Resolve the repo-root emit.sh relative to this source file.
        let scriptURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("plugin/claude-vitals/hooks/emit.sh")
        XCTAssertTrue(FileManager.default.fileExists(atPath: scriptURL.path), "emit.sh should exist at \(scriptURL.path)")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = [scriptURL.path]
        var env = ProcessInfo.processInfo.environment
        env["CLAUDE_VITALS_SOCK"] = path
        proc.environment = env
        let stdin = Pipe()
        proc.standardInput = stdin
        try proc.run()
        let json = #"{"hook_event_name":"UserPromptSubmit","session_id":"emit-test"}"#
        stdin.fileHandleForWriting.write(Data(json.utf8))
        stdin.fileHandleForWriting.closeFile()
        proc.waitUntilExit()

        wait(for: [got], timeout: 2.0)
        XCTAssertEqual(received?.event, "UserPromptSubmit")
        XCTAssertEqual(received?.session_id, "emit-test")
    }
}
