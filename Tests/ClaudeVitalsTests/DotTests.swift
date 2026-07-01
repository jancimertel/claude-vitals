import XCTest
@testable import ClaudeVitals

final class DotTests: XCTestCase {
    func testWaitingPermissionGlyphAndNotRunning() {
        XCTAssertEqual(Dot.waitingPermission.glyph, "🔐")
        XCTAssertFalse(Dot.waitingPermission.isRunning)
    }
}
