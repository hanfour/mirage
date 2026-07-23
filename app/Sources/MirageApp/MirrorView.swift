import AppKit
import MetalKit
import MirageCore
import SwiftUI

/// MTKView 子類：滑鼠事件 → 正規化座標 → guest 觸控。
final class MirrorMTKView: MTKView {
    var onMouse: ((_ nx: Double, _ ny: Double, _ down: Bool) -> Void)?
    var onResize: ((_ pixelSize: CGSize) -> Void)?

    override func layout() {
        super.layout()
        onResize?(convertToBacking(bounds).size)
    }

    // AUTHORIZED FIX（使用者驗收回報：畫面變形——視窗長寬比鎖定）
    //
    // Root cause: SwiftUI's WindowGroup gives the window an initial content
    // size unrelated to the guest's 9:20 aspect ratio, and Renderer.upload()
    // only assigns `view.window?.contentAspectRatio` when the *texture* size
    // changes — at that point `window` can still be nil (first upload can
    // race window attachment), so the assignment silently no-ops and the
    // mismatched window stretches the CAMetalLayer's drawable, distorting
    // the image from the very first frame.
    //
    // Fix: lock the aspect ratio — and immediately conform the window's
    // *current* size to it — as soon as this view is attached to a window
    // (`viewDidMoveToWindow` fires unconditionally at that point, unlike
    // waiting on the first decoded frame), so the window is never shown
    // undistorted-then-corrected; it's correct from the start.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        let aspect = NSSize(width: 9, height: 20)
        window.contentAspectRatio = aspect
        let w = max(window.frame.width, 270)
        window.setContentSize(NSSize(width: w, height: w * aspect.height / aspect.width))
    }

    private func normalized(_ event: NSEvent) -> (Double, Double)? {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let nx = Double(p.x / bounds.width)
        let ny = 1.0 - Double(p.y / bounds.height)
        guard (0...1).contains(nx), (0...1).contains(ny) else { return nil }
        return (nx, ny)
    }

    override func mouseDown(with event: NSEvent) {
        if let (nx, ny) = normalized(event) { onMouse?(nx, ny, true) }
    }
    override func mouseDragged(with event: NSEvent) {
        if let (nx, ny) = normalized(event) { onMouse?(nx, ny, true) }
    }
    override func mouseUp(with event: NSEvent) {
        if let (nx, ny) = normalized(event) { onMouse?(nx, ny, false) }
    }
}

struct MirrorView: NSViewRepresentable {
    let client: EmulatorClient
    let box: LatestFrameBox

    func makeCoordinator() -> Coordinator { Coordinator(client: client) }

    func makeNSView(context: Context) -> MirrorMTKView {
        let view = MirrorMTKView(frame: .zero)
        context.coordinator.renderer = Renderer(view: view, box: box)
        view.onMouse = { nx, ny, down in
            context.coordinator.sendMouse(nx: nx, ny: ny, down: down)
        }
        view.onResize = { pixelSize in
            context.coordinator.resizeDebounced(to: pixelSize)
        }
        return view
    }

    func updateNSView(_ view: MirrorMTKView, context: Context) {}

    @MainActor
    final class Coordinator {
        let client: EmulatorClient
        var renderer: Renderer?
        private var resizeTask: Task<Void, Never>?
        private var guestSize = (w: 540, h: 1200)

        init(client: EmulatorClient) { self.client = client }

        func sendMouse(nx: Double, ny: Double, down: Bool) {
            let gx = Int(nx * Double(guestSize.w))
            let gy = Int(ny * Double(guestSize.h))
            Task { await client.sendTap(x: gx, y: gy, down: down) }
        }

        func resizeDebounced(to pixelSize: CGSize) {
            resizeTask?.cancel()
            resizeTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                // guest 長寬比 9:20 固定；以視窗像素寬換算串流尺寸（偶數對齊）
                let w = max(Int(pixelSize.width) & ~1, 270)
                let h = w * 20 / 9
                guestSize = (w, h)
                await client.setStreamSize(width: w, height: h)
            }
        }
    }
}
