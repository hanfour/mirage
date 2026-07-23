import Foundation
import MetalKit
import MirageCore

/// vsync 拉取渲染：每次 draw 從 box 同步拉最新幀，replaceRegion 上傳後 blit。
// ADAPTATION (compile-forced, strict concurrency): the installed SDK's
// MetalKit/AppKit overlay marks MTKView/NSWindow properties touched below
// (`delegate`, `preferredFramesPerSecond`, `drawableSize`, `window`,
// `contentAspectRatio`) as `@MainActor`-isolated. `Renderer` was previously
// unannotated, so `init`/`upload` (called on the main thread in practice —
// SwiftUI's `makeNSView` and MTKView's own display-link callback both run on
// main) tripped "main actor-isolated property ... can not be mutated from a
// nonisolated context" warnings under `-strict-concurrency=complete`.
// Annotating the whole class `@MainActor` matches actual runtime behavior
// exactly (no semantic change) and satisfies the compiler.
@MainActor
final class Renderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let box: LatestFrameBox
    private var texture: MTLTexture?
    // AUTHORIZED FIX（Task 6 review CRITICAL：滑鼠映射採實際幀尺寸——proto 縮放合約 can-be-less）
    private(set) var lastFrameSize: (w: Int, h: Int)?
    private var fpsCount = 0
    private var fpsWindowStart = CFAbsoluteTimeGetCurrent()
    private let fpsLog = ProcessInfo.processInfo.environment["MIRAGE_FPS_LOG"] == "1"

    init?(view: MTKView, box: LatestFrameBox) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.box = box
        super.init()
        view.device = device
        view.colorPixelFormat = .rgba8Unorm
        view.framebufferOnly = false
        view.isPaused = false                  // 內建 display link 驅動
        view.enableSetNeedsDisplay = false     // 每 vsync 呼叫 draw（勿走 needsDisplay 路徑）
        view.preferredFramesPerSecond = 60
        view.delegate = self
    }

    func draw(in view: MTKView) {
        if let frame = box.takeLatest() { upload(frame, into: view) }
        guard let texture,
              let drawable = view.currentDrawable,
              drawable.texture.width == texture.width,
              drawable.texture.height == texture.height,
              let cb = queue.makeCommandBuffer(),
              let blit = cb.makeBlitCommandEncoder() else { return }
        blit.copy(from: texture, to: drawable.texture)
        blit.endEncoding()
        cb.present(drawable)
        cb.commit()
    }

    private func upload(_ frame: Frame, into view: MTKView) {
        // AUTHORIZED FIX（Task 6 review CRITICAL：滑鼠映射採實際幀尺寸——proto 縮放合約 can-be-less）
        lastFrameSize = (frame.width, frame.height)
        if texture?.width != frame.width || texture?.height != frame.height {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: frame.width, height: frame.height, mipmapped: false)
            desc.usage = [.shaderRead]
            texture = device.makeTexture(descriptor: desc)
            let size = CGSize(width: frame.width, height: frame.height)
            view.drawableSize = size
            // AUTHORIZED FIX（使用者驗收回報：畫面變形——視窗長寬比鎖定）: kept, not
            // removed. The initial-distortion bug is fixed in
            // MirrorMTKView.viewDidMoveToWindow (fires before any frame
            // exists, independent of `window` possibly being nil here on the
            // first upload). This line still earns its keep as a safety net
            // for later frames whose actual decoded size legitimately
            // changes (e.g. after a resize round-trip) — it keeps the
            // window's aspect ratio truthful to the *real* frame dimensions
            // rather than only to the requested stream size.
            view.window?.contentAspectRatio = NSSize(width: frame.width,
                                                     height: frame.height)
        }
        frame.rgba.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture?.replace(region: MTLRegionMake2D(0, 0, frame.width, frame.height),
                             mipmapLevel: 0, withBytes: base,
                             bytesPerRow: frame.width * 4)
        }
        if fpsLog {
            fpsCount += 1
            let now = CFAbsoluteTimeGetCurrent()
            let elapsed = now - fpsWindowStart
            if elapsed >= 1.0 {
                print("[app] fps=\(Int((Double(fpsCount) / elapsed).rounded()))")
                fpsCount = 0
                fpsWindowStart = now
            }
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}
