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

    /// 迴歸測試（2026-07-28）：**drawable 的尺寸權威是解碼幀，不是視窗**。
    ///
    /// `draw(in:)` 用 `blit.copy` 把 texture 整塊搬進 drawable，blit 要求兩者尺寸完全相等，
    /// 不相等就整幀跳過——畫面全黑。而 texture 尺寸來自 guest 幀、drawable 尺寸來自視窗，
    /// 是兩條獨立演化的路徑：`MTKView.autoResizeDrawable` 預設為 `true`，每次 layout 都會
    /// 把 `drawableSize` 拉回 `bounds × contentScale`，覆蓋掉 `upload()` 依幀尺寸設的值。
    /// 於是「畫面出不出得來」取決於 `resizeDebounced` 請求的串流尺寸有沒有剛好等於視窗的
    /// backing 尺寸——上限 clamp、偶數對齊、letterbox 捨入、debounce 期間任一個都會讓它
    /// 不相等，結果就是 `fps=` 有數字（`upload` 照跑）但畫面全黑。
    ///
    /// 修正是關掉 `autoResizeDrawable`，讓 drawable 尺寸只由幀決定；顯示端的縮放由
    /// CAMetalLayer 免費完成，長寬比已由 `MirrorContainerView` 的 letterbox 保證一致。
    /// 這消除了「兩條尺寸路徑必須精確收斂」這個特殊情況，而不是再加一層條件判斷。
    @MainActor
    @Test func drawableSizeFollowsFrameNotViewBounds() throws {
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 100, height: 200))
        let box = LatestFrameBox()
        let renderer = try #require(Renderer(view: view, box: box))

        box.put(Frame(width: 540, height: 1200, rgba: Data(count: 540 * 1200 * 4)))
        renderer.draw(in: view)
        #expect(view.drawableSize == CGSize(width: 540, height: 1200))

        // 視窗尺寸變動不得把 drawable 拉離幀尺寸——否則 blit 的相等前提就此破裂。
        view.frame = NSRect(x: 0, y: 0, width: 377, height: 811)
        view.layoutSubtreeIfNeeded()
        #expect(view.drawableSize == CGSize(width: 540, height: 1200))
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
