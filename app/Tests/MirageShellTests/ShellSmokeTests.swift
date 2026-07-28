import AppKit
import Foundation
import MetalKit
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

    /// 迴歸測試（2026-07-28，「鏡像顯示從未運作」的根因）。
    ///
    /// `start()` 原本以 **interleaved** 格式呼叫 `AVAudioEngine.connect(_:to:format:)`。
    /// AVAudioEngine 的節點連接只接受 deinterleaved，interleaved 會讓它丟出
    /// `kAudioUnitErr_FormatNotSupported`(-10868) 的 **NSException**——那是 Obj-C 例外，
    /// Swift 的 `do/catch` 攔不到（原碼的 catch 只包住 `engine.start()`，且對 NSException
    /// 本來就無效）。它在 `@MainActor` 上把 `startLifecycle()` 的執行整個扯斷，MainActor
    /// 自此不再 drain：`client.states` 的消費者永遠收不到值（橫幅卡在「未連線」）、
    /// MTKView 的 draw 停止（`fps=` 恆為 0）。三個階段都把這個現象誤記成「螢幕鎖定」。
    /// 完整證據見 `docs/specs/2026-07-28-mirror-never-rendered-investigation.md`。
    ///
    /// **這條測試的價值不在斷言，而在「`start()` 能返回」**：格式若再被改回 interleaved，
    /// NSException 會讓整個測試程序 abort，這條就永遠跑不完。斷言刻意不碰
    /// `engine.isRunning`——沒有音訊輸出裝置的機器上 `engine.start()` 本來就會失敗，
    /// 那是既有且刻意的降級路徑，不該讓這條測試變成環境相依。
    @MainActor
    @Test func audioPlayerStartReturnsWithoutTrapping() {
        let player = AudioPlayer(ring: AudioRingBuffer(capacitySamples: 4_096))
        player.start()
        player.start()          // 二次呼叫必須是 no-op，不得重複 attach
        player.stop()
        #expect(!player.isMuted)
    }

    /// 迴歸測試（2026-07-28 第二輪）：**任意來源尺寸都必須畫得出來**。
    ///
    /// 前一版用 `blit.copy` 搬運，blit 要求來源與目的尺寸完全相等，於是整條顯示路徑的
    /// 正確性被押在「emulator 回傳的幀尺寸剛好等於 drawable 尺寸」上。但幀尺寸**根本不受
    /// 我們控制**——proto 的縮放合約是 can-be-less，實測請求 562x1248 會回 561x1248
    /// （奇數）。當時的症狀是 30 秒收到 1080 幀、`fps=` 卻一行都沒有、畫面全黑。
    ///
    /// 改用 render pass 取樣繪製之後，來源與目的尺寸再無任何關係。這條測試直接驗那件事：
    /// 用一個奇數寬的來源（重現當時的 561）畫進尺寸完全不同的目標，讀回像素確認畫上去了。
    ///
    /// ⚠️ **預設不跑，需 `MIRAGE_LIVE_METAL=1`**（比照 `MIRAGE_LIVE_MMAP` / `MIRAGE_LIVE_AUDIO`
    /// 的既有慣例）。這是降低觸發機率的權宜，不是修好了什麼——歸因要寫對：
    ///
    /// **這個測試套件本身就是 flaky 的，與本測試無關。** 症狀是 26–30 條 async 測試
    /// started 之後永遠不 complete、主執行緒閒置在 run loop。實測基準：把本輪**所有**改動
    /// stash 掉、回到 `6056dbd` 跑四次，**2 次卡住 2 次通過**。也就是說先前每一次
    /// 「189 tests passed」都有約一半機率只是運氣。嫌疑指向
    /// `nio-teardown-injectable-channel-debt` 那筆既有的債（完整套件 log 裡的
    /// `Cannot schedule tasks on an EventLoop that has already shut down` 是同一條線索）。
    ///
    /// 本測試被執行時觸發機率明顯升高（樣本小，但四次修隔離都無效正是因為問題不在這裡），
    /// 所以先 gate 起來。**這不是根治**——根治要處理那筆 NIO 債。
    /// 單獨跑：`MIRAGE_LIVE_METAL=1 swift test --filter rendersAnySource`。
    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MIRAGE_LIVE_METAL"] == "1",
                   "需 MIRAGE_LIVE_METAL=1——見上方說明"))
    func rendersAnySourceSizeIntoAnyTargetSize() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let blitter = try #require(MirrorBlitter(device: device))

        // 來源：561x1248（實測會觸發黑畫面的那個奇數尺寸），填成已知的純紅。
        // 用 stride 就地寫入而非 `.enumerated().map`——後者要為 280 萬個元素各跑一次
        // closure 並配置第二個陣列，在 -Onone 的測試 build 下慢到像卡死。
        let src = try #require(Self.makeTexture(device, width: 561, height: 1248, usage: [.shaderRead]))
        var red = [UInt8](repeating: 0, count: 561 * 1248 * 4)
        for i in stride(from: 0, to: red.count, by: 4) {
            red[i] = 255          // R
            red[i + 3] = 255      // A
        }
        red.withUnsafeBytes { raw in
            src.replace(region: MTLRegionMake2D(0, 0, 561, 1248), mipmapLevel: 0,
                        withBytes: raw.baseAddress!, bytesPerRow: 561 * 4)
        }

        // 目標：尺寸與來源毫無關係（更小、長寬比也不同）。
        let dst = try #require(Self.makeTexture(device, width: 320, height: 200,
                                                usage: [.renderTarget, .shaderRead]))
        await blitter.render(src, into: dst)

        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { raw in
            dst.getBytes(raw.baseAddress!, bytesPerRow: 4,
                         from: MTLRegionMake2D(160, 100, 1, 1), mipmapLevel: 0)
        }
        #expect(pixel[0] > 200, "目標中心應該被來源的紅色填上，實得 RGBA=\(pixel)")
        #expect(pixel[1] < 60)
    }

    private static func makeTexture(_ device: MTLDevice, width: Int, height: Int,
                                    usage: MTLTextureUsage) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        d.usage = usage
        return device.makeTexture(descriptor: d)
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
