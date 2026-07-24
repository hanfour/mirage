import Testing
@testable import MirageCore

@Suite struct JoystickMathTests {
    @Test func singleKeyIsUnit() {
        let r = JoystickMath.vector(up: false, down: false, left: false, right: true)
        #expect(abs(r.dx - 1.0) < 1e-9)
        #expect(abs(r.dy - 0.0) < 1e-9)
    }

    @Test func upIsNegativeY() {
        let r = JoystickMath.vector(up: true, down: false, left: false, right: false)
        #expect(abs(r.dy - (-1.0)) < 1e-9)
    }

    @Test func diagonalIsNormalizedNotOverOne() {
        let r = JoystickMath.vector(up: true, down: false, left: false, right: true)
        let mag = (r.dx * r.dx + r.dy * r.dy).squareRoot()
        #expect(abs(mag - 1.0) < 1e-9)       // 對角正規化，不超過 1
    }

    @Test func oppositeKeysCancel() {
        let r = JoystickMath.vector(up: true, down: true, left: false, right: false)
        #expect(abs(r.dx) < 1e-9)
        #expect(abs(r.dy) < 1e-9)
    }

    @Test func allReleasedIsZero() {
        let r = JoystickMath.vector(up: false, down: false, left: false, right: false)
        #expect(r.dx == 0 && r.dy == 0)
    }

    @Test func threeKeysNormalized() {
        // 上+左+右 → 左右相消，剩上 → (0,-1)
        let r = JoystickMath.vector(up: true, down: false, left: true, right: true)
        #expect(abs(r.dx) < 1e-9)
        #expect(abs(r.dy - (-1.0)) < 1e-9)
    }
}
