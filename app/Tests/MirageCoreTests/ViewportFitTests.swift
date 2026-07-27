import Testing
@testable import MirageCore

@Suite struct ViewportFitTests {
    /// 這條是「視窗模式零回歸」的形式化保證：長寬比一致 → 黑邊為 0、退化成滿版。
    @Test func sameAspectFillsCompletely() {
        let r = ViewportFit.fit(frame: (w: 9, h: 20), in: (w: 270, h: 600))
        #expect(r == FitRect(x: 0, y: 0, width: 270, height: 600))
    }

    @Test func landscapeFrameInSquareBoundsGetsTopBottomBars() {
        let r = ViewportFit.fit(frame: (w: 1920, h: 1080), in: (w: 1000, h: 1000))
        #expect(r.width == 1000)
        #expect(r.height == 562)          // 1080 * 1000 / 1920 = 562（整數截斷）
        #expect(r.x == 0)
        #expect(r.y == 219)               // (1000 - 562) / 2
    }

    @Test func portraitFrameInWideBoundsGetsLeftRightBars() {
        let r = ViewportFit.fit(frame: (w: 1080, h: 1920), in: (w: 1600, h: 1000))
        #expect(r.height == 1000)
        #expect(r.width == 562)           // 1080 * 1000 / 1920 = 562
        #expect(r.y == 0)
        #expect(r.x == 519)               // (1600 - 562) / 2
    }

    @Test func squareFrameInSquareBoundsFills() {
        let r = ViewportFit.fit(frame: (w: 512, h: 512), in: (w: 300, h: 300))
        #expect(r == FitRect(x: 0, y: 0, width: 300, height: 300))
    }

    @Test func extremeRatioNeverExceedsBounds() {
        let r = ViewportFit.fit(frame: (w: 1, h: 1000), in: (w: 1920, h: 1080))
        #expect(r.width <= 1920)
        #expect(r.height <= 1080)
        #expect(r.x >= 0)
        #expect(r.y >= 0)
    }

    @Test(arguments: [
        (0, 100, 100, 100), (100, 0, 100, 100),
        (100, 100, 0, 100), (100, 100, 100, 0),
        (-9, 20, 270, 600), (9, 20, -270, 600),
    ])
    func degenerateInputReturnsZero(fw: Int, fh: Int, bw: Int, bh: Int) {
        #expect(ViewportFit.fit(frame: (w: fw, h: fh), in: (w: bw, h: bh)) == .zero)
    }

    /// P1-e fast-follow：極端長寬比讓某一維度整數截斷成 0 的情形。輸入合法（皆 > 0）
    /// 所以不走 `.zero` 早退，但算出的內容矩形其中一邊會是 0。這不是錯誤——呼叫端
    /// `MirrorContainerView.layout()` 有 `rect.width > 0, rect.height > 0` 的 guard，
    /// 會退回鋪滿而不是佈局出一個 0 寬/0 高的 view。此測項把「函式在這種輸入下仍給出
    /// 不為負、不超界的結果」釘住，避免日後有人以為要在函式內加特例。
    @Test(arguments: [
        (1000, 1, 1, 1000),      // 極寬幀塞進極窄 bounds → 高度截斷成 0
        (1, 1000, 1000, 1),      // 極高幀塞進極扁 bounds → 寬度截斷成 0
    ])
    func extremeRatioTruncatingToZeroStaysInBounds(fw: Int, fh: Int, bw: Int, bh: Int) {
        let r = ViewportFit.fit(frame: (w: fw, h: fh), in: (w: bw, h: bh))
        #expect(r.width >= 0)
        #expect(r.height >= 0)
        #expect(r.width <= bw)
        #expect(r.height <= bh)
        #expect(r.x >= 0)
        #expect(r.y >= 0)
        #expect(r.x + r.width <= bw)
        #expect(r.y + r.height <= bh)
        // 至少一邊被截斷成 0 —— 這正是本測項要記錄的情形
        #expect(r.width == 0 || r.height == 0)
    }
}
