import CoreServices
import Foundation

/// Calls `onChange` (on its own queue) when anything under one of `dirs` changes: one FSEvents stream,
/// events coalesced over `latency` seconds. It watches each dir's parent and filters by path, so a dir
/// that does not exist yet (older Claude Code has no sessions dir) still reports once something is written
/// inside it: events are per directory, and the dir's own creation shows up only as an event on the parent.
/// Nothing is read here; the caller rebuilds its snapshot.
final class FileWatcher {
    private let dirs: [URL]
    private let latency: CFTimeInterval
    private let onChange: @Sendable () -> Void
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.claudevitals.filewatcher")

    init(dirs: [URL], latency: CFTimeInterval = 0.5, onChange: @escaping @Sendable () -> Void) {
        self.dirs = dirs
        self.latency = latency
        self.onChange = onChange
    }

    /// What the C callback needs, handed over through the stream context's info pointer.
    private final class Box: Sendable {
        let prefixes: [String]
        let onChange: @Sendable () -> Void
        init(prefixes: [String], onChange: @escaping @Sendable () -> Void) {
            self.prefixes = prefixes
            self.onChange = onChange
        }
    }

    func start() {
        guard stream == nil else { return }
        let box = Box(prefixes: dirs.map { FileWatcher.canonical($0) + "/" }, onChange: onChange)
        let roots = Array(Set(dirs.map { URL(fileURLWithPath: FileWatcher.canonical($0)).deletingLastPathComponent().path }))
        var ctx = FSEventStreamContext(
            version: 0, info: Unmanaged.passRetained(box).toOpaque(), retain: nil,
            release: { info in if let info { Unmanaged<Box>.fromOpaque(info).release() } },
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            // Directory-level events: each path is the dir whose contents changed.
            let hit = list.contains { p in
                let dir = p.hasSuffix("/") ? p : p + "/"
                return box.prefixes.contains { dir.hasPrefix($0) }
            }
            // Dropped events: FSEvents can't say what changed, so assume it was ours.
            let dropped = (0..<count).contains {
                flags[$0] & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
            }
            if hit || dropped { box.onChange() }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &ctx, roots as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else {
            Unmanaged<Box>.fromOpaque(ctx.info!).release()
            return
        }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)            // releases the Box through the context's release callback
        stream = nil
    }

    /// FSEvents reports real paths (symlinks resolved, /var as /private/var), so the filter compares
    /// against the same. realpath needs an existing path: a missing dir resolves its parent instead.
    private static func canonical(_ url: URL) -> String {
        if let p = realpath(url.path, nil) { defer { free(p) }; return String(cString: p) }
        let parent = url.deletingLastPathComponent()
        if let p = realpath(parent.path, nil) { defer { free(p) }; return String(cString: p) + "/" + url.lastPathComponent }
        return url.standardizedFileURL.path
    }
}
