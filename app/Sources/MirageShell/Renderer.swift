import Foundation
import MetalKit
import MirageCore

/// vsync 拉取渲染：每次 draw 從 box 同步拉最新幀，replaceRegion 上傳後 blit。
// ADAPTATION (compile-forced, strict concurrency): the installed SDK's
// MetalKit/AppKit overlay marks MTKView properties touched below
// (`delegate`, `preferredFramesPerSecond`, `drawableSize`) as
// `@MainActor`-isolated. `Renderer` was previously
// unannotated, so `init`/`upload` (called on the main thread in practice —
// SwiftUI's `makeNSView` and MTKView's own display-link callback both run on
// main) tripped "main actor-isolated property ... can not be mutated from a
// nonisolated context" warnings under `-strict-concurrency=complete`.
// Annotating the whole class `@MainActor` matches actual runtime behavior
// exactly (no semantic change) and satisfies the compiler.
@MainActor
final class Renderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let blitter: MirrorBlitter
    private let box: LatestFrameBox
    private var texture: MTLTexture?
    // AUTHORIZED FIX（Task 6 review CRITICAL：滑鼠映射採實際幀尺寸——proto 縮放合約 can-be-less）
    private(set) var lastFrameSize: (w: Int, h: Int)?
    /// P1-e：幀尺寸變動時通知容器重算 letterbox（含遊戲轉向時的長寬比翻轉）。
    var onFrameSize: ((Int, Int) -> Void)?
    private var fpsCount = 0
    private var fpsWindowStart = CFAbsoluteTimeGetCurrent()
    private let fpsLog = ProcessInfo.processInfo.environment["MIRAGE_FPS_LOG"] == "1"

    init?(device: MTLDevice, box: LatestFrameBox) {
        guard let blitter = MirrorBlitter(device: device) else { return nil }
        self.device = device
        self.blitter = blitter
        self.box = box
        super.init()
    }

    convenience init?(view: MTKView, box: LatestFrameBox) {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.init(device: device, box: box)
        view.device = device
        view.colorPixelFormat = .rgba8Unorm
        view.isPaused = false                  // 內建 display link 驅動
        view.enableSetNeedsDisplay = false     // 每 vsync 呼叫 draw（勿走 needsDisplay 路徑）
        view.preferredFramesPerSecond = 60
        view.delegate = self
    }

    func draw(in view: MTKView) {
        let arrived = box.takeLatest()
        if let arrived { upload(arrived) }
        // 注意這裡**沒有**尺寸相符的檢查。取樣繪製對來源與目的尺寸沒有任何要求——
        // 那正是重點：emulator 回什麼尺寸不受我們控制（proto 縮放合約 can-be-less，
        // 實測請求 562 會回 561），把它放進不變式就是把顯示的正確性交給運氣。
        guard let texture, let drawable = view.currentDrawable,
              let buffer = blitter.makeCommandBuffer() else { return }
        blitter.encode(texture, into: drawable.texture, on: buffer)
        buffer.present(drawable)
        buffer.commit()
        // 只有走到這裡才算一幀：新幀確實被送上螢幕。
        if arrived != nil { countPresentedFrame() }
    }

    /// `MIRAGE_FPS_LOG` 的 `fps=`：**每秒有多少張新幀真的被 present 到螢幕上**。
    ///
    /// 這個計數點原本在 `upload()` 裡，量的是「幀上傳到 texture」——那在 `draw()` 的
    /// 早退 guard **之前**，所以幀進得來但一個像素都沒畫上螢幕時，`fps=` 照樣是漂亮的
    /// 兩位數。這個落差先後兩次讓「畫面全黑」被誤判成已修好（見
    /// `docs/specs/2026-07-28-mirror-never-rendered-investigation.md` §7、§8）。
    ///
    /// 也刻意**不**在沒有新幀的 vsync 計數：重畫同一張不是畫面更新，那樣量出來的會恆等於
    /// 螢幕更新率，看起來永遠達標。驗收線要的是「使用者看到的畫面多久換一次」。
    private func countPresentedFrame() {
        guard fpsLog else { return }
        fpsCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - fpsWindowStart
        if elapsed >= 1.0 {
            print("[app] fps=\(Int((Double(fpsCount) / elapsed).rounded()))")
            fpsCount = 0
            fpsWindowStart = now
        }
    }

    /// 不再需要 `MTKView`：drawable 的尺寸交回給 MTKView 自己管（`autoResizeDrawable`
    /// 的預設行為，跟著視窗走），取樣繪製不要求它與幀尺寸有任何關係。
    private func upload(_ frame: Frame) {
        // AUTHORIZED FIX（Task 6 review CRITICAL：滑鼠映射採實際幀尺寸——proto 縮放合約 can-be-less）
        lastFrameSize = (frame.width, frame.height)
        if texture?.width != frame.width || texture?.height != frame.height {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: frame.width, height: frame.height, mipmapped: false)
            desc.usage = [.shaderRead]
            texture = device.makeTexture(descriptor: desc)
            // P1-e：長寬比的唯一權威是 MirrorContainerView——它依實際幀尺寸擺放
            // MirrorMTKView，取樣縮放因此不會變形。
            onFrameSize?(frame.width, frame.height)
        }
        frame.rgba.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture?.replace(region: MTLRegionMake2D(0, 0, frame.width, frame.height),
                             mipmapLevel: 0, withBytes: base,
                             bytesPerRow: frame.width * 4)
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}
