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

    /// D7：`fromViewPoint` 翻轉 y 軸（AppKit 左下原點 → guest 左上原點）並夾在 0…1。
    @Test func fromViewPointFlipsYAndClamps() throws {
        let mid = try #require(NormPoint.fromViewPoint(x: 50, y: 100, width: 100, height: 200))
        #expect(mid == NormPoint(x: 0.5, y: 0.5))
        // AppKit 的 y=200（頂端）對應 guest 的 y=0（頂端）。
        let top = try #require(NormPoint.fromViewPoint(x: 0, y: 200, width: 100, height: 200))
        #expect(top == NormPoint(x: 0, y: 0))
        // 越界一律夾住，回傳值永遠是合法的正規化座標。
        let beyond = try #require(NormPoint.fromViewPoint(x: 999, y: -999, width: 100, height: 200))
        #expect(beyond == NormPoint(x: 1, y: 1))
        #expect(beyond.isValid)
    }

    /// 唯一還會回傳 nil 的路徑：視圖尺寸退化。**這是既有行為的補測**（原本就有這道
    /// guard、原本就沒有測試），不是這次改動引入的。第一幀之前 `MirrorContainerView`
    /// 會把 mirror 鋪成 `bounds`，而視窗尺寸為 0 時就是這個情況。
    @Test func fromViewPointRejectsDegenerateBounds() {
        #expect(NormPoint.fromViewPoint(x: 1, y: 1, width: 0, height: 200) == nil)
        #expect(NormPoint.fromViewPoint(x: 1, y: 1, width: 100, height: 0) == nil)
        #expect(NormPoint.fromViewPoint(x: 1, y: 1, width: -1, height: -1) == nil)
    }

    @Test func keyCodeEquatableAndHashable() {
        #expect(KeyCode.key("w") == KeyCode.key("w"))
        #expect(KeyCode.key("w") != KeyCode.key("a"))
        #expect(Set([KeyCode.key("w"), KeyCode.key("w")]).count == 1)
    }
}
