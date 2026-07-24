import Testing
@testable import MirageCore

@Suite struct NormPointTests {
    @Test func validWithinUnitSquare() {
        #expect(NormPoint(x: 0.5, y: 0.5).isValid)
        #expect(NormPoint(x: 0, y: 1).isValid)
    }

    @Test func invalidOutOfRange() {
        #expect(!NormPoint(x: -0.1, y: 0.5).isValid)
        #expect(!NormPoint(x: 0.5, y: 1.1).isValid)
    }

    @Test func guestPixelScalesToFrame() {
        let (x, y) = NormPoint(x: 0.5, y: 0.25).guestPixel(width: 540, height: 1200)
        #expect(x == 270)
        #expect(y == 300)
    }

    @Test func keyCodeEquatableAndHashable() {
        #expect(KeyCode.key("w") == KeyCode.key("w"))
        #expect(KeyCode.key("w") != KeyCode.key("a"))
        #expect(Set([KeyCode.key("w"), KeyCode.key("w")]).count == 1)
    }
}
