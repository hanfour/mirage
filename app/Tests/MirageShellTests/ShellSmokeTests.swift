import AppKit
import MirageCore          // ViewportFit / AudioRingBuffer / InstallResult 皆為 public，不需 @testable
import Testing
@testable import MirageShell

/// App 層 smoke test——本階段的意義是**證明 `@testable import MirageShell` 這條路真的通**，
/// 不是補齊測試覆蓋（那是另一輪）。三個測項刻意挑不同性質的目標：AppKit view 佈局、
/// 碰 AVFoundation 的型別、純值型別。
@Suite struct ShellSmokeTests {
    /// 最有價值的一條：直接驗證 P1-e 全螢幕的核心前提——容器確實把 `MirrorMTKView`
    /// 擺在 `ViewportFit` 算出的內容矩形上。這條先前只能靠讀碼相信。
    /// `NSView.layout()` 不需要視窗，headless 可跑。
    @MainActor
    @Test func containerLetterboxesMirrorIntoFitRect() {
        let container = MirrorContainerView(frame: NSRect(x: 0, y: 0, width: 1000, height: 1000))
        container.frameSize = (w: 1920, h: 1080)      // 橫向幀塞進正方形 bounds → 上下黑邊
        container.layout()

        let expected = ViewportFit.fit(frame: (w: 1920, h: 1080), in: (w: 1000, h: 1000))
        #expect(Int(container.mirror.frame.width) == expected.width)
        #expect(Int(container.mirror.frame.height) == expected.height)
        #expect(Int(container.mirror.frame.origin.x) == expected.x)
        #expect(Int(container.mirror.frame.origin.y) == expected.y)
        #expect(container.mirror.frame.height < container.bounds.height)   // 確實有黑邊
    }

    /// 證明碰 AVFoundation 的型別也在可測範圍內（不啟動 engine，只驗狀態切換）。
    @MainActor
    @Test func audioPlayerMuteTogglesState() {
        let player = AudioPlayer(ring: AudioRingBuffer(capacitySamples: 64))
        #expect(!player.isMuted)
        player.setMuted(true)
        #expect(player.isMuted)
        player.setMuted(false)
        #expect(!player.isMuted)
    }

    /// 純值型別，證明最基本的 import 路徑通（`InstallItem` 內含 MirageCore 的 `InstallResult`，
    /// 順帶驗證兩個 module 的型別可以在測試裡一起用）。
    @Test func installStateFinishedCarriesItems() {
        let state = InstallState.finished([
            InstallItem(name: "ok.apk", result: .success),
            InstallItem(name: "bad.apk", result: .failure("INSTALL_FAILED_OLDER_SDK")),
        ])
        guard case .finished(let items) = state else {
            Issue.record("預期 .finished，實得 \(state)")
            return
        }
        #expect(items.count == 2)
        #expect(items[0].name == "ok.apk")
        #expect(items[0].result == .success)
        #expect(items[1].result == .failure("INSTALL_FAILED_OLDER_SDK"))
    }
}
