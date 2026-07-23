import XCTest
@testable import MirageCore

final class FrameTests: XCTestCase {
    func testValidFrame() {
        let f = Frame(width: 2, height: 3, rgba: Data(count: 24))
        XCTAssertTrue(f.isValid)
    }

    func testInvalidSizeMismatch() {
        XCTAssertFalse(Frame(width: 2, height: 3, rgba: Data(count: 23)).isValid)
    }

    func testInvalidZeroDimensions() {
        XCTAssertFalse(Frame(width: 0, height: 3, rgba: Data()).isValid)
    }
}
