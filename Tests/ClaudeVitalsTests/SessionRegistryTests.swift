import XCTest
@testable import ClaudeVitals

final class SessionRegistryTests: XCTestCase {
    private var tmp: URL!

    override func setUp() {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vitals-registry-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    private func write(_ name: String, _ body: String, in dir: URL? = nil) {
        try? Data(body.utf8).write(to: (dir ?? tmp).appendingPathComponent(name))
    }

    private func entry(startedAt: Double?) -> RegistryEntry {
        RegistryEntry(pid: 7, sessionId: "s1", cwd: "/work/repo", startedAt: startedAt)
    }

    // MARK: readRegistry

    func testMissingDirectoryReturnsNil() {
        XCTAssertNil(readRegistry(dir: tmp.appendingPathComponent("absent")))
    }

    func testEmptyDirectoryReturnsEmptyNotNil() {
        XCTAssertEqual(readRegistry(dir: tmp), [])
    }

    func testDecodesKnownFieldsAndIgnoresUnknown() {
        write("42.json", #"{"pid":42,"sessionId":"s1","cwd":"/r","startedAt":1000,"status":"busy","future":{"x":1}}"#)
        XCTAssertEqual(readRegistry(dir: tmp), [RegistryEntry(pid: 42, sessionId: "s1", cwd: "/r", startedAt: 1000)])
    }

    func testSkipsBrokenEntriesAndNonJsonFiles() {
        write("1.json", #"{"pid":1,"sessionId":"ok","cwd":"/r"}"#)   // startedAt is optional
        write("2.json", #"{"pid":2,"cwd":"/r"}"#)                     // no sessionId -> skipped
        write("3.json", "not json")
        write("1.abc.key", "secret")                                  // sibling key files are not entries
        XCTAssertEqual(readRegistry(dir: tmp), [RegistryEntry(pid: 1, sessionId: "ok", cwd: "/r", startedAt: nil)])
    }

    // MARK: isLiveEntry

    func testDeadPidIsNotLive() {
        XCTAssertFalse(isLiveEntry(entry(startedAt: 1_000_000), startTime: { _ in nil }))
    }

    func testProcessStartedJustBeforeSessionIsLive() {
        XCTAssertTrue(isLiveEntry(entry(startedAt: 1_000_000), startTime: { _ in Date(timeIntervalSince1970: 999.5) }))
    }

    func testProcessStartedAfterSessionIsAReusedPid() {
        let reused = Date(timeIntervalSince1970: 1000 + PID_REUSE_SKEW_S + 1)
        XCTAssertFalse(isLiveEntry(entry(startedAt: 1_000_000), startTime: { _ in reused }))
    }

    func testMissingStartedAtTrustsARunningPid() {
        XCTAssertTrue(isLiveEntry(entry(startedAt: nil), startTime: { _ in Date() }))
    }

    func testProcessStartTimeOfSelfAndOfMissingPid() {
        XCTAssertNotNil(processStartTime(getpid()))
        XCTAssertNil(processStartTime(999_999))   // above the macOS pid ceiling, so it never exists
    }

    // MARK: transcriptPath

    func testTranscriptPathPrefersTheProjectDirDerivedFromCwd() {
        let dir = tmp.appendingPathComponent(encodeRepo("/work/repo"))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        write("s1.jsonl", "", in: dir)
        XCTAssertEqual(transcriptPath(for: entry(startedAt: nil), projects: tmp),
                       dir.appendingPathComponent("s1.jsonl").path)
    }

    func testTranscriptPathFallsBackToSessionIdSearch() {
        let dir = tmp.appendingPathComponent("-some-other-project")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        write("s1.jsonl", "", in: dir)
        XCTAssertEqual(transcriptPath(for: entry(startedAt: nil), projects: tmp),
                       dir.appendingPathComponent("s1.jsonl").path)
    }

    func testTranscriptPathIsNilBeforeTheTranscriptExists() {
        XCTAssertNil(transcriptPath(for: entry(startedAt: nil), projects: tmp))
    }
}
