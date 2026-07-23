import Foundation
import Testing
@testable import MirageCore

@Suite struct FrameTests {
    @Test func validFrame() {
        let f = Frame(width: 2, height: 3, rgba: Data(count: 24))
        #expect(f.isValid)
    }

    @Test func invalidSizeMismatch() {
        #expect(!Frame(width: 2, height: 3, rgba: Data(count: 23)).isValid)
    }

    @Test func invalidZeroDimensions() {
        #expect(!Frame(width: 0, height: 3, rgba: Data()).isValid)
    }
}
