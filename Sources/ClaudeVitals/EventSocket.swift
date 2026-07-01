import Foundation

let VITALS_DIR = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude-vitals")
let VITALS_SOCK = VITALS_DIR.appendingPathComponent("vitals.sock").path

/// AF_UNIX stream listener. Each hook connection writes one JSON line then closes; we read to EOF,
/// decode a HookEvent, and hand it to `onEvent` off the main thread. Plain POSIX sockets (Network
/// framework has no public UNIX-domain listener), which are rock solid for this.
final class EventSocket {
    private let path: String
    private let onEvent: @Sendable (HookEvent) -> Void
    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "com.claudevitals.socket")

    init(path: String, onEvent: @escaping @Sendable (HookEvent) -> Void) {
        self.path = path
        self.onEvent = onEvent
    }

    func start() {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        unlink(path)                                    // clear any stale socket from a previous run

        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { p in
            path.withCString { strncpy(p, $0, sunPathSize - 1) }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0, listen(fd, 32) == 0 else { close(fd); fd = -1; return }

        // Run the blocking accept loop off-main. Capture fd + onEvent by value (both Sendable) so the
        // closure does not capture self. stop() closes fd, which makes accept() fail and ends the loop.
        let listenFd = fd
        let handler = onEvent
        queue.async { EventSocket.acceptLoop(fd: listenFd, onEvent: handler) }
    }

    private static func acceptLoop(fd: Int32, onEvent: @Sendable (HookEvent) -> Void) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { break }
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(client, &buf, buf.count)
                if n <= 0 { break }
                data.append(contentsOf: buf[0..<n])
            }
            close(client)
            // A line-delimited payload may include a trailing newline; JSONDecoder tolerates it.
            if let e = try? JSONDecoder().decode(HookEvent.self, from: data) {
                onEvent(e)
            }
        }
    }

    func stop() {
        // Closing the listening fd unblocks the accept() the loop is parked in (accept returns -1 ->
        // loop ends). This relies on Darwin/BSD close-unblocks-accept semantics; fine for this
        // macOS-only app, but note it is not POSIX-guaranteed (unreliable on Linux) if ever ported.
        if fd >= 0 { close(fd); fd = -1 }
        unlink(path)
    }
}
