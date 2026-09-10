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
    private let box: any FrameSink
    private var texture: MTLTexture?
    // AUTHORIZED FIX（Task 6 review CRITICAL：滑鼠映射採實際幀尺寸——proto 縮放合約 can-be-less）
    private(set) var lastFrameSize: (w: Int, h: Int)?
    /// P1-e：幀尺寸變動時通知容器重算 letterbox（含遊戲轉向時的長寬比翻轉）。
    var onFrameSize: ((Int, Int) -> Void)?
    private var fpsWindow: FpsWindow
    private let fpsLog = ProcessInfo.processInfo.environment["MIRAGE_FPS_LOG"] == "1"
    private var lastDrawStart: CFAbsoluteTime?
    private let latencyLog = ProcessInfo.processInfo.environment["MIRAGE_LATENCY_LOG"] == "1"
    private var latency = LatencyWindow()
    private var transit = TransitWindow()
    private var latencyWindowStart = CFAbsoluteTimeGetCurrent()

    init?(device: MTLDevice, box: any FrameSink) {
        let fpsStartedAt = CFAbsoluteTimeGetCurrent()
        guard let blitter = MirrorBlitter(device: device) else { return nil }
        self.device = device
        self.blitter = blitter
        self.box = box
        self.fpsWindow = FpsWindow(startedAt: fpsStartedAt, counters: box.stats())
        super.init()
    }

    convenience init?(view: MTKView, box: any FrameSink) {
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
        var drawStartedAt: CFAbsoluteTime?
        var drawIntervalMs: Double?
        if fpsLog {
            let now = CFAbsoluteTimeGetCurrent()
            drawStartedAt = now
            if let lastDrawStart {
                drawIntervalMs = (now - lastDrawStart) * 1000.0
            }
            lastDrawStart = now
        }

        let arrived = box.takeLatest()
        if let arrived { upload(arrived) }
        // 注意這裡**沒有**尺寸相符的檢查。取樣繪製對來源與目的尺寸沒有任何要求——
        // 那正是重點：emulator 回什麼尺寸不受我們控制（proto 縮放合約 can-be-less，
        // 實測請求 562 會回 561），把它放進不變式就是把顯示的正確性交給運氣。
        // 保留原本的合併 guard；texture 尚未建立是首幀狀態，不算 drawable 取得失敗。
        let textureAvailable = texture != nil
        guard let texture, let drawable = view.currentDrawable,
              let buffer = blitter.makeCommandBuffer() else {
            recordDrawTiming(intervalMs: drawIntervalMs,
                             durationMs: nil,
                             outcome: timingOutcome(hasFrame: arrived != nil,
                                                    noDrawable: textureAvailable))
            return
        }
        blitter.encode(texture, into: drawable.texture, on: buffer)
        buffer.present(drawable)
        buffer.commit()
        let durationMs = drawStartedAt.map {
            (CFAbsoluteTimeGetCurrent() - $0) * 1000.0
        }
        recordDrawTiming(intervalMs: drawIntervalMs,
                         durationMs: durationMs,
                         outcome: timingOutcome(hasFrame: arrived != nil,
                                                noDrawable: false))
        // 只有走到這裡才算一幀：新幀確實被送上螢幕。
        if let arrived {
            countPresentedFrame()
            recordLatency(since: arrived.receivedAt, transitMs: arrived.transitMs)
        }
    }

    private func timingOutcome(hasFrame: Bool,
                               noDrawable: Bool) -> DrawTimingWindow.Outcome {
        var outcome: DrawTimingWindow.Outcome = []
        if !hasFrame { outcome.insert(.noFrame) }
        if noDrawable { outcome.insert(.noDrawable) }
        return outcome
    }

    private func recordDrawTiming(intervalMs: Double?,
                                  durationMs: Double?,
                                  outcome: DrawTimingWindow.Outcome) {
        guard fpsLog else { return }
        fpsWindow.recordDraw(interval: intervalMs, duration: durationMs, outcome: outcome)
    }

    /// `MIRAGE_LATENCY_LOG=1`：每秒印一行「幀抵達 Mirage → present」的 p50/p95。
    ///
    /// 這不是完整的 input-to-photon。完整鏈路包含輸入注入、guest 反應、
    /// 幀產生與傳輸、抵達到 present，以及 Mac 上屏。
    /// 驗收線 2 只加總輸入注入、傳輸與抵達到 present；guest 反應與上屏未量。
    /// 舊 Python 偵測器量出的 78.1ms 已作廢，不能拿來補上前段。
    /// 三段刻意分開量，才能知道各段佔多少，判斷該優化輸入、傳輸還是渲染，
    /// 補上 §12 所記錄、阻礙優化決策的資訊缺口。
    private func recordLatency(since arrival: ContinuousClock.Instant, transitMs: Double?) {
        guard latencyLog else { return }
        latency.record(ContinuousClock.now - arrival)
        transit.record(transitMs)
        let now = CFAbsoluteTimeGetCurrent()
        guard now - latencyWindowStart >= 1.0 else { return }
        if let s = latency.summary() {
            print(String(format: "[app] lat p50=%.1fms p95=%.1fms n=%d",
                         s.p50, s.p95, s.count))
        }
        if let s = transit.latency.summary() {
            print(String(format: "[app] transit p50=%.1fms p95=%.1fms n=%d invalid=%d unavailable=%d",
                         s.p50, s.p95, s.count, transit.invalid, transit.unavailable))
        } else {
            print("[app] transit p50=NA p95=NA n=0 invalid=\(transit.invalid) unavailable=\(transit.unavailable)")
        }
        transit.reset()
        latency.reset()
        latencyWindowStart = now
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
        if let report = fpsWindow.record(presented: true, at: CFAbsoluteTimeGetCurrent(),
                                         counters: { box.stats() }) {
            let frameWindow = report.frames
            let drawWindow = report.draw
            // `[app] fps=` 與 `[app] frames` 必須在同一個分支背靠背印出，且一對一。
            // `verify_fps_fullscreen.sh` 以 `fps_samples` 的數量作為 `frames_median`
            // 的跳過數，兩者不能分開或改變輸出次數。draw 統計也在這個同一秒窗口
            // 輸出，但累加是在每次 draw，故包含沒有新幀的 vsync；窗口邊界仍只在
            // present 時檢查，維持既有 fps／frames 的行為。
            print("[app] fps=\(report.fps)")
            print("[app] frames arrived=\(frameWindow.arrived) dropped=\(frameWindow.dropped) presented=\(frameWindow.presented)")
            print(String(format: "[app] draw calls=%d gap20=%d maxgap=%dms in_p95=%.1fms nodrawable=%d noframe=%d",
                         drawWindow.calls,
                         drawWindow.gapOver20ms,
                         drawWindow.maxGapMs,
                         drawWindow.inP95Ms,
                         drawWindow.noDrawable,
                         drawWindow.noFrame))
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
