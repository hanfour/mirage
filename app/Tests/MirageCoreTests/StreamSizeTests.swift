import Testing
@testable import MirageCore

@Suite struct StreamSizeTests {
    /// P1-e 終審 Minor 4 的核心：直向 9:20 全螢幕不得再算出 1080×2400（2.6 MP）。
    @Test func portraitFullScreenStaysWithinPixelBudget() {
        let aspect = (w: 9, h: 20)
        let w = StreamSize.width(forContentWidth: 1400, aspect: aspect)   // 4K 螢幕的內容矩形
        let h = StreamSize.height(forWidth: w, aspect: aspect)
        #expect(w * h <= StreamSize.maxPixels)
        #expect(w == 900)
        #expect(h == 2000)
    }

    /// 橫向由寬度上限主導（像素預算在 20:9 下寬鬆得多），維持既有行為。
    @Test func landscapeIsBoundedByWidthNotPixels() {
        let aspect = (w: 20, h: 9)
        let w = StreamSize.width(forContentWidth: 3000, aspect: aspect)
        #expect(w == StreamSize.maxWidth)
        #expect(w * StreamSize.height(forWidth: w, aspect: aspect) <= StreamSize.maxPixels)
    }

    /// 小視窗不受任何上限影響——上限只在放大時介入，不得反過來拉高小視窗的請求。
    @Test func smallWindowIsUnaffectedByCaps() {
        #expect(StreamSize.width(forContentWidth: 400, aspect: (w: 9, h: 20)) == 400)
    }

    /// 下限：低於視窗最小寬一律拉回 270。
    @Test func belowMinimumClampsUp() {
        #expect(StreamSize.width(forContentWidth: 10, aspect: (w: 9, h: 20)) == 270)
        #expect(StreamSize.width(forContentWidth: -5, aspect: (w: 9, h: 20)) == 270)
    }

    /// 輸出一律偶數（proto 縮放要求）。
    @Test(arguments: [271, 333, 899, 1079, 1081, 5000])
    func widthIsAlwaysEven(contentWidth: Int) {
        let w = StreamSize.width(forContentWidth: contentWidth, aspect: (w: 9, h: 20))
        #expect(w % 2 == 0)
    }

    /// 退化 aspect（尚未收到第一幀等情形）不得崩、不得除以零。
    @Test(arguments: [(0, 20), (9, 0), (-9, 20)])
    func degenerateAspectFallsBackToWidthOnly(aw: Int, ah: Int) {
        let w = StreamSize.width(forContentWidth: 800, aspect: (w: aw, h: ah))
        #expect(w == 800)
        #expect(StreamSize.height(forWidth: w, aspect: (w: aw, h: ah)) == 2)
    }

    /// 像素預算在任何長寬比下都必須守住（含極端比例）。
    @Test(arguments: [(9, 20), (20, 9), (1, 1), (1, 5), (5, 1), (3, 4)])
    func pixelBudgetHoldsForAnyAspect(aw: Int, ah: Int) {
        let aspect = (w: aw, h: ah)
        let w = StreamSize.width(forContentWidth: 10_000, aspect: aspect)
        let h = StreamSize.height(forWidth: w, aspect: aspect)
        #expect(w * h <= StreamSize.maxPixels)
    }
}
