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

    /// 長寬比鎖定已移交 MirrorContainerView（P1-e：全螢幕下 macOS 忽略 contentAspectRatio，
    /// 需要 letterbox 容器統一負責；順帶移除原本硬編碼的 9:20）。此處只保留輸入前置條件。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // P1-c：keyDown/keyUp 需要 first responder；mouseMoved（look）需要視窗開啟
        // acceptsMouseMovedEvents——AppKit 預設不投遞 mouseMoved，兩者缺一都會讓
        // KeymapController 完全收不到輸入。
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

    func makeNSView(context: Context) -> MirrorContainerView {
        let container = MirrorContainerView(frame: .zero)
        let view = container.mirror
        let renderer = Renderer(view: view, box: box)
        renderer?.onFrameSize = { [weak container] w, h in
            container?.frameSize = (w: w, h: h)
        }
        context.coordinator.renderer = renderer
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
        return container
    }

    func updateNSView(_ view: MirrorContainerView, context: Context) {
        context.coordinator.controller = controller
    }

    @MainActor
    final class Coordinator {
        let client: EmulatorClient
        var renderer: Renderer?
        // P1-c：無 profile（nil 或 hasProfile==false，例如編輯模式中）時 sendMouse 退回直接
        // tap——spec §7 驗收 4，P1-a 行為不回歸。
        //
        // 原本這裡有一個 `frameSizeProvider` 的 didSet 佈線，把 renderer.lastFrameSize
        // 餵給 KeymapController 做觸點換算。整套已移除——換算收進 EmulatorClient 之後，
        // App 層不再需要（也不應該）知道該乘什麼尺寸。
        var controller: KeymapController?
        private var resizeTask: Task<Void, Never>?
        private static let defaultStreamSize = (w: 540, h: 1200)

        init(client: EmulatorClient) { self.client = client }

        func sendMouse(nx: Double, ny: Double, down: Bool) {
            // 有作用中 profile 時鍵鼠改走 KeymapController → KeymapEngine，這裡不再重複送 tap。
            guard controller?.hasProfile != true else { return }
            // 直接送正規化座標：換算成 guest 像素需要**實體螢幕解析度**，那是
            // EmulatorClient 才知道的事（來自健康探測）。這裡原本用 lastFrameSize（串流
            // 幀尺寸）自行換算，而兩者在本機相差兩倍，所以每次點擊都偏到左上一半處。
            Task { await client.sendTap(nx: nx, ny: ny, down: down) }
        }

        func resizeDebounced(to pixelSize: CGSize) {
            resizeTask?.cancel()
            resizeTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                // P1-e：長寬比改用實際解碼幀（原本硬編碼 h = w * 20 / 9，遊戲轉橫向就錯）。
                let aspect = renderer?.lastFrameSize ?? Self.defaultStreamSize
                // 上限與偶數對齊的算術在 MirageCore.StreamSize（純函式、有單元測試）。
                let w = StreamSize.width(forContentWidth: Int(pixelSize.width), aspect: aspect)
                let h = StreamSize.height(forWidth: w, aspect: aspect)
                // 只換串流解析度。觸控座標**不隨它改變**——那是 guest 實體螢幕的事，
                // 由 EmulatorClient 從健康探測取得，與我們請求多大的畫面無關。
                await client.setStreamSize(width: w, height: h)
            }
        }
    }
}
