import Testing
@testable import MirageCore

@Suite struct EditorGeometryTests {
    /// 內容矩形有黑邊時，正規化座標必須落在**內容矩形內**，不是整個視窗。
    /// 這是本 task 的本體：舊寫法用視窗尺寸換算，有黑邊就對不上。
    @Test func viewPointIsRelativeToContentRectNotWindow() {
        // 1000x1000 視窗裡塞 9:20 直向幀 → 左右黑邊，內容矩形 x=275 width=450
        let rect = ViewportFit.fit(frame: (w: 9, h: 20), in: (w: 1000, h: 1000))
        #expect(rect == FitRect(x: 275, y: 0, width: 450, height: 1000))

        let mid = EditorGeometry.viewPoint(for: NormPoint(x: 0.5, y: 0.5), in: rect)
        #expect(mid.x == 500)      // 275 + 450*0.5
        #expect(mid.y == 500)

        let topLeft = EditorGeometry.viewPoint(for: NormPoint(x: 0, y: 0), in: rect)
        #expect(topLeft.x == 275)  // **不是 0**——0 是黑邊，不是 guest 的左緣
        #expect(topLeft.y == 0)
    }

    /// 反向換算是正向的逆。
    @Test func normPointRoundTripsThroughViewPoint() {
        let rect = ViewportFit.fit(frame: (w: 9, h: 20), in: (w: 1000, h: 1000))
        let original = NormPoint(x: 0.25, y: 0.8)
        let v = EditorGeometry.viewPoint(for: original, in: rect)
        let back = EditorGeometry.normPoint(x: v.x, y: v.y, in: rect)
        #expect(back != nil)
        #expect(abs((back?.x ?? -1) - original.x) < 0.0001)
        #expect(abs((back?.y ?? -1) - original.y) < 0.0001)
    }

    /// 拖到黑邊上必須夾回 0…1，不能產生越界座標——與 D7／D12 同一條立場：
    /// 送越界座標比不送更糟（畫面有反應但點在錯的地方）。
    @Test func normPointClampsPointsInTheLetterbox() throws {
        let rect = ViewportFit.fit(frame: (w: 9, h: 20), in: (w: 1000, h: 1000))
        let left = EditorGeometry.normPoint(x: 10, y: 500, in: rect)     // 落在左黑邊
        #expect(left?.x == 0)
        #expect(try #require(left).isValid)
        let right = EditorGeometry.normPoint(x: 990, y: 500, in: rect)   // 落在右黑邊
        #expect(right?.x == 1)
        #expect(try #require(right).isValid)
    }

    /// 退化矩形（尚未收到任何幀）→ nil，呼叫端據此不換算。
    @Test func normPointRejectsDegenerateRect() {
        #expect(EditorGeometry.normPoint(x: 1, y: 1, in: .zero) == nil)
        #expect(EditorGeometry.radius(fromPoints: 10, in: .zero) == nil)
    }

    /// radius 的正規化基準是**寬度**（沿用 KeymapOverlay 既有慣例），不是高度也不是對角線。
    @Test func radiusIsNormalisedAgainstWidth() {
        let rect = ViewportFit.fit(frame: (w: 9, h: 20), in: (w: 1000, h: 1000))
        #expect(EditorGeometry.radiusInPoints(0.12, in: rect) == 54)     // 450 * 0.12
        let back = EditorGeometry.radius(fromPoints: 54, in: rect)
        #expect(abs((back ?? -1) - 0.12) < 0.0001)
    }

    /// 橫向幀 → **上下**黑邊，`FitRect.y` 非 0。
    ///
    /// 補這條的理由：其餘測試全用直向幀（左右黑邊、`y` 恆為 0），所以把 `viewPoint` 的
    /// `Double(rect.y) +` 拿掉也不會有任何測試變紅。橫向遊戲是產品支援的情境。
    @Test func viewPointHonoursVerticalLetterboxOffset() {
        let rect = ViewportFit.fit(frame: (w: 20, h: 9), in: (w: 1000, h: 1000))
        #expect(rect.x == 0)
        #expect(rect.y > 0)              // 上下黑邊
        let top = EditorGeometry.viewPoint(for: NormPoint(x: 0, y: 0), in: rect)
        #expect(top.y == Double(rect.y)) // **不是 0**——0 是黑邊，不是 guest 的上緣
        let mid = EditorGeometry.viewPoint(for: NormPoint(x: 0.5, y: 0.5), in: rect)
        #expect(mid.y == Double(rect.y) + Double(rect.height) * 0.5)
    }
}
