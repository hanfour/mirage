import AppKit
import MetalKit
import MirageCore
import SwiftUI

/// MTKView 子類：滑鼠事件 → 正規化座標 → guest 觸控；鍵盤/滑鼠位移 → KeymapController（P1-c）。
final class MirrorMTKView: MTKView {
    var onMouse: ((_ nx: Double, _ ny: Double, _ down: Bool) -> Void)?
    var onResize: ((_ pixelSize: CGSize) -> Void)?
    // P1-c 鍵位映射：keyDown/keyUp 已解碼為 KeyCode；look 用原始 mouseMoved delta（未關聯游標時為 raw）。
    var onKey: ((_ code: KeyCode, _ down: Bool) -> Void)?
    var onMouseMovedDelta: ((_ dx: Double, _ dy: Double) -> Void)?
    var onFlagsChanged: ((NSEvent) -> Void)?

    // 讓這個 view 能收到 keyDown/keyUp（否則 AppKit responder chain 不會投遞）。
    override var acceptsFirstResponder: Bool { true }

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

        // P1-c：keyDown/keyUp 需要 first responder；mouseMoved（look）需要視窗開啟
        // acceptsMouseMovedEvents——AppKit 預設不投遞 mouseMoved，兩者缺一都會讓
        // KeymapController 完全收不到輸入（無 profile 時不受影響，仍走既有 mouseDown/Dragged/Up）。
        window.acceptsMouseMovedEvents = true
        window.makeFirstResponder(self)
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

    override func mouseMoved(with event: NSEvent) {
        onMouseMovedDelta?(Double(event.deltaX), Double(event.deltaY))
    }

    override func keyDown(with event: NSEvent) {
        if let c = keyCode(from: event) { onKey?(c, true) }
    }
    override func keyUp(with event: NSEvent) {
        if let c = keyCode(from: event) { onKey?(c, false) }
    }
    override func flagsChanged(with event: NSEvent) {
        onFlagsChanged?(event)
    }

    private func keyCode(from event: NSEvent) -> KeyCode? {
        guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return nil }
        return .key(chars)      // W3C key 近似：單字元鍵直接用字元（"w"/"a"/…）
    }
}

struct MirrorView: NSViewRepresentable {
    let client: EmulatorClient
    let box: LatestFrameBox
    // P1-c：nil＝無 profile（P1-a 直接 tap 行為，見 Coordinator.sendMouse）。由 AppModel
    // 非同步載入後才會有值，透過 updateNSView 逐次同步進 Coordinator（makeNSView 只跑一次）。
    var controller: KeymapController?

    func makeCoordinator() -> Coordinator { Coordinator(client: client) }

    func makeNSView(context: Context) -> MirrorMTKView {
        let view = MirrorMTKView(frame: .zero)
        context.coordinator.renderer = Renderer(view: view, box: box)
        context.coordinator.controller = controller
        view.onMouse = { nx, ny, down in
            context.coordinator.sendMouse(nx: nx, ny: ny, down: down)
        }
        view.onResize = { pixelSize in
            context.coordinator.resizeDebounced(to: pixelSize)
        }
        view.onKey = { code, down in
            if down { context.coordinator.controller?.handleKeyDown(code) }
            else { context.coordinator.controller?.handleKeyUp(code) }
        }
        view.onMouseMovedDelta = { dx, dy in
            context.coordinator.controller?.handleMouseMoved(dx: dx, dy: dy)
        }
        view.onFlagsChanged = { event in
            context.coordinator.controller?.handleFlagsChanged(event)
        }
        return view
    }

    func updateNSView(_ view: MirrorMTKView, context: Context) {
        context.coordinator.controller = controller
    }

    @MainActor
    final class Coordinator {
        let client: EmulatorClient
        var renderer: Renderer?
        // P1-c：無 profile（nil 或 hasProfile==false，例如編輯模式中）時 sendMouse 退回直接
        // tap——spec §7 驗收 4，P1-a 行為不回歸。
        var controller: KeymapController?
        private var resizeTask: Task<Void, Never>?
        private var guestSize = (w: 540, h: 1200)

        init(client: EmulatorClient) { self.client = client }

        func sendMouse(nx: Double, ny: Double, down: Bool) {
            // 有作用中 profile 時鍵鼠改走 KeymapController → KeymapEngine，這裡不再重複送 tap。
            guard controller?.hasProfile != true else { return }
            // AUTHORIZED FIX（Task 6 review CRITICAL：滑鼠映射採實際幀尺寸——proto 縮放合約 can-be-less）
            let size = renderer?.lastFrameSize ?? guestSize
            let gx = Int(nx * Double(size.w))
            let gy = Int(ny * Double(size.h))
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
                controller?.setGuestSize((w, h))   // 讓引擎輸出的觸控座標跟著新的串流尺寸換算
            }
        }
    }
}
