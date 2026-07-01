import XCTest
@testable import ClaudeVitals

final class EventSocketTests: XCTestCase {
    func testReceivesAndDecodesOneEvent() throws {
        let path = NSTemporaryDirectory() + "vitals-test-\(UUID().uuidString).sock"
        let got = expectation(description: "event received")
        var received: HookEvent?
        let socket = EventSocket(path: path) { e in received = e; got.fulfill() }
        socket.start()
        defer { socket.stop() }

        // Give the listener a moment to bind.
        Thread.sleep(forTimeInterval: 0.1)

        // Raw client: connect, write one JSON line, close (EOF signals end-of-message).
        let fd = socket_client_connect(path)
        XCTAssertGreaterThanOrEqual(fd, 0, "client should connect")
        let json = #"{"hook_event_name":"Stop","session_id":"xyz"}"#
        _ = json.withCString { write(fd, $0, strlen($0)) }
        close(fd)

        wait(for: [got], timeout: 2.0)
        XCTAssertEqual(received?.event, "Stop")
        XCTAssertEqual(received?.session_id, "xyz")
    }

    // Minimal AF_UNIX client used only by this test.
    private func socket_client_connect(_ path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { p in
            path.withCString { strncpy(p, $0, sunPathSize - 1) }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        if r != 0 { close(fd); return -1 }
        return fd
    }
}
