import Foundation
import Testing
@testable import MirageCore

/// 手機回報顯示區域，Mac 端依此請求串流解析度（2026-09-17）。
/// 背景模式沒有鏡像視窗，串流原本停在預設 540×1200，實測 iPhone 需要約 940px 寬。
@Suite struct RemoteViewportTests {
    @Test func decodesViewport() throws {
        let decoded = try RemoteTouchMessageDecoder.decode(
            #"{"type":"viewport","width":393,"height":697.5,"scale":3}"#).get()
        #expect(decoded == .viewport(RemoteViewport(width: 393, height: 697.5, scale: 3)))
    }

    @Test(arguments: [
        #"{"type":"viewport"}"#,
        #"{"type":"viewport","width":0,"height":697,"scale":3}"#,
        #"{"type":"viewport","width":393,"height":-1,"scale":3}"#,
        #"{"type":"viewport","width":393,"height":697,"scale":0}"#,
        #"{"type":"viewport","width":393,"height":697,"scale":9}"#,
        #"{"type":"viewport","width":20000,"height":697,"scale":3}"#,
        #"{"type":"viewport","width":"393","height":697,"scale":3}"#,
        #"{"type":"viewport","width":true,"height":697,"scale":3}"#,
        #"{"type":"viewport","width":1e999,"height":697,"scale":3}"#,
    ]) func rejectsInvalidViewport(_ text: String) {
        let decoded = RemoteTouchMessageDecoder.decode(text)
        if case .failure(let error) = decoded { #expect(error == .invalidViewport || error == .notJSON) }
        else { Issue.record("非法 viewport 被接受：\(text)") }
    }

    /// 實測值：iPhone Safari 頁面 393×697pt、3 倍密度。直向 guest 在這個區域內由高度決定寬度
    /// （697 × 1080 / 2400 ≈ 313pt ≈ 940px），再受 1.8 MP 上限壓到 900×2000。
    @Test func phoneViewportFitsGuestAspectWithinPixelBudget() {
        let size = StreamSize.fitting(RemoteViewport(width: 393, height: 697, scale: 3), aspect: (w: 1080, h: 2400))
        #expect(size.w == 900)
        #expect(size.h == 2000)
    }

    @Test func smallViewportIsNotEnlarged() {
        let size = StreamSize.fitting(RemoteViewport(width: 320, height: 568, scale: 1), aspect: (w: 1080, h: 2400))
        #expect(size.w == 270)       // 568 × 0.45 = 255，低於下限 270 被拉回
        #expect(size.h == 600)
    }

    @Test func landscapeAspectUsesViewportWidth() {
        let size = StreamSize.fitting(RemoteViewport(width: 400, height: 800, scale: 2), aspect: (w: 2400, h: 1080))
        #expect(size.w == 800)
        #expect(size.h == 360)
    }

    @Test func demandsPickLargerRequestAndFallBackWhenEmpty() {
        var demands = StreamDemands()
        #expect(demands.request(fallback: (w: 540, h: 1200)).w == 540)
        demands.window = (w: 858, h: 1906)
        #expect(demands.request(fallback: (w: 540, h: 1200)).w == 858)
        demands.remote = (w: 900, h: 2000)
        let both = demands.request(fallback: (w: 540, h: 1200))
        #expect(both.w == 900)
        #expect(both.h == 2000)
        demands.remote = nil
        #expect(demands.request(fallback: (w: 540, h: 1200)).h == 1906)
        demands.window = nil
        demands.remote = (w: 600, h: 1332)
        #expect(demands.request(fallback: (w: 540, h: 1200)).w == 600)
    }
}
