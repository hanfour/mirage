import AppKit
import MetalKit
import MirageCore
import SwiftUI

/// MTKView 子類：滑鼠事件 → 正規化座標 → guest 觸控；鍵盤/滑鼠位移 → KeymapController（P1-c）。
final class MirrorMTKView: MTKView {
    var textMode = true { didSet { if oldValue != textMode { cancelComposition() } } }
    var textInput: TextInputPresentation?
    var session = TextInputSession()
    var acceptsTextCallbacks = false
    var eventGeneration: UInt64?
    var currentTextEvent: NSEvent?
    var eventWasComposing = false
    nonisolated(unsafe) var textWindowObservers: [NSObjectProtocol] = []
    deinit { for observer in textWindowObservers { NotificationCenter.default.removeObserver(observer) } }

    var ownedKeys: [UInt16: [KeyCode]] = [:]
    var observedGeneration: UInt64?
    var compositionChanged: (() -> Void)?
    let markedOverlay = MarkedTextOverlay(frame: .zero)
    var compositionAnchor: CGPoint?
    var coordinateRect: ((NSRange) -> (NSRect, NSRange))?

    var interpretInput: (([NSEvent]) -> Void)?

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
        updateMarkedOverlay()
    }

    /// 長寬比鎖定已移交 MirrorContainerView（P1-e：全螢幕下 macOS 忽略 contentAspectRatio，
    /// 需要 letterbox 容器統一負責；順帶移除原本硬編碼的 9:20）。此處只保留輸入前置條件。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        AppLifecycle.diagnose("mirror-viewDidMoveToWindow", window: window)
        for observer in textWindowObservers { NotificationCenter.default.removeObserver(observer) }
        textWindowObservers.removeAll()
        guard let window else { cancelComposition(); return }
        textWindowObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelComposition() }
        })
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification,
                     NSWindow.didChangeBackingPropertiesNotification, NSWindow.didEnterFullScreenNotification,
                     NSWindow.didExitFullScreenNotification] {
            textWindowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateMarkedOverlay() }
            })
        }
        updateMarkedOverlay()
        // P1-c：keyDown/keyUp 需要 first responder；mouseMoved（look）需要視窗開啟
        // acceptsMouseMovedEvents——AppKit 預設不投遞 mouseMoved，兩者缺一都會讓
        // KeymapController 完全收不到輸入。
        window.acceptsMouseMovedEvents = true
        window.makeFirstResponder(self)
    }

    private func normalized(_ event: NSEvent) -> (Double, Double)? {
        let p = convert(event.locationInWindow, from: nil)
        // D7：越界**不再**回傳 nil。原本這裡有一道 `(0...1).contains` 的 guard，
        // 而 drag 途中 AppKit 會把 mouseDragged/mouseUp 繼續送給這個 view（即使游標
        // 已離開），於是「拖到黑邊或視窗外放開」的 up 被整個丟掉，guest 端留著一根
        // 永遠按著的手指。夾住的算術在 `NormPoint.fromViewPoint`（純函式、有測試）。
        guard let n = NormPoint.fromViewPoint(x: Double(p.x), y: Double(p.y),
                                              width: Double(bounds.width),
                                              height: Double(bounds.height))
        else { return nil }
        return (n.x, n.y)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if textMode {
            cancelComposition()
            let point = convert(event.locationInWindow, from: nil)
            if bounds.contains(point), bounds.width > 0, bounds.height > 0 {
                compositionAnchor = CGPoint(x: point.x / bounds.width, y: point.y / bounds.height)
                updateMarkedOverlay()
            }
        }
        if let (nx, ny) = normalized(event) { onMouse?(nx, ny, true) }
    }
    override func mouseDragged(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if textMode {
            cancelComposition()
            let point = convert(event.locationInWindow, from: nil)
            if bounds.contains(point), bounds.width > 0, bounds.height > 0 {
                compositionAnchor = CGPoint(x: point.x / bounds.width, y: point.y / bounds.height)
                updateMarkedOverlay()
            }
        }
        if let (nx, ny) = normalized(event) { onMouse?(nx, ny, true) }
    }
    override func mouseUp(with event: NSEvent) {
        if let (nx, ny) = normalized(event) { onMouse?(nx, ny, false) }
    }

    override func mouseMoved(with event: NSEvent) {
        if !textMode { onMouseMovedDelta?(Double(event.deltaX), Double(event.deltaY)) }
    }

    override func keyDown(with event: NSEvent) {
        synchronizeTextSession()
        if textMode {
            guard !event.modifierFlags.contains(.command) else { super.keyDown(with: event); return }
            acceptsTextCallbacks = true
            eventGeneration = session.generation
            currentTextEvent = event
            eventWasComposing = hasMarkedText()
            defer { currentTextEvent = nil }
            if let interpretInput { interpretInput([event]) }
            else { interpretKeyEvents([event]) }
        } else if let c = keyCode(from: event) {
            ownedKeys[event.keyCode] = [c]
            onKey?(c, true)
        }
    }
    override func keyUp(with event: NSEvent) {
        for code in (ownedKeys.removeValue(forKey: event.keyCode) ?? []).reversed() { onKey?(code, false) }
    }
    override func flagsChanged(with event: NSEvent) {
        if !textMode { onFlagsChanged?(event) }
    }

    /// 換算邏輯本身在 `MirageCore.KeyTranslate`（純函式、逐行單元測試）——這裡只負責
    /// 從 `NSEvent` 取欄位。原本這個函式直接回 `.key(chars)`，那對 Enter 會送 "\r"、
    /// 對方向鍵會送私用區字元，emulator 都不認得；而且沒有擋 ⌘ 組合。
    private func keyCode(from event: NSEvent) -> KeyCode? {
        KeyTranslate.w3c(virtualKey: event.keyCode,
                         characters: event.charactersIgnoringModifiers,
                         hasCommand: event.modifierFlags.contains(.command))
    }
}

struct MirrorView: NSViewRepresentable {
    let client: EmulatorClient
    let box: any FrameSink
    // P1-c：nil＝無 profile（P1-a 直接 tap 行為，見 Coordinator.sendMouse）。由 AppModel
    // 非同步載入後才會有值，透過 updateNSView 逐次同步進 Coordinator（makeNSView 只跑一次）。
    var controller: KeymapController?
    /// D22：由 `AppModel.editing` 驅動，透過 `updateNSView` 逐次同步進 Coordinator。
    var isEditing: Bool
    var textInput: TextInputPresentation? = nil
    /// D6：tap 與鍵位映射的觸控／鍵盤共用**同一條**佇列（由 `AppModel` 持有），
    /// 否則兩條佇列各自有序、彼此無序，切換 profile 的瞬間仍會對調。
    let queue: InputQueue
    /// Task 4：幀尺寸同時餵給容器（佈局用）與 `AppModel`（overlay 算內容矩形用）。
    let onFrameSize: (Int, Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(client: client, queue: queue) }

    func makeNSView(context: Context) -> MirrorContainerView {
        let container = MirrorContainerView(frame: .zero)
        let view = container.mirror
        let renderer = Renderer(view: view, box: box)
        renderer?.onFrameSize = { [weak container] w, h in
            container?.frameSize = (w: w, h: h)
            onFrameSize(w, h)
        }
        context.coordinator.renderer = renderer
        context.coordinator.controller = controller
        context.coordinator.isEditing = isEditing
        view.onMouse = { nx, ny, down in
            context.coordinator.sendMouse(nx: nx, ny: ny, down: down)
        }
        view.onResize = { pixelSize in
            context.coordinator.resizeDebounced(to: pixelSize)
        }
        view.onKey = { code, down in
            if context.coordinator.textMode { queue.key(code, down: down) }
            else if down { context.coordinator.controller?.handleKeyDown(code) }
            else { context.coordinator.controller?.handleKeyUp(code) }
        }
        view.onMouseMovedDelta = { dx, dy in
            context.coordinator.controller?.handleMouseMoved(dx: dx, dy: dy)
        }
        view.onFlagsChanged = { event in
            context.coordinator.controller?.handleFlagsChanged(event)
        }
        configureText(view, coordinator: context.coordinator)
        return container
    }

    private func configureText(_ view: MirrorMTKView, coordinator: Coordinator) {
        let enabled = !isEditing && (textInput?.usesText(hasProfile: controller?.hasProfile == true) ?? (controller?.hasProfile != true))
        controller?.setTextMode(enabled)
        view.textInput = textInput
        view.textMode = enabled
        view.synchronizeTextSession()
        coordinator.textMode = enabled
    }

    func updateNSView(_ view: MirrorContainerView, context: Context) {
        context.coordinator.controller = controller
        context.coordinator.isEditing = isEditing
        configureText(view.mirror, coordinator: context.coordinator)
    }

    @MainActor
    final class Coordinator {
        let client: EmulatorClient
        var renderer: Renderer?
        // P1-c：無 profile 時 sendMouse 退回直接 tap——spec §7 驗收 4，P1-a 行為不回歸。
        // D22：`hasProfile` 不再涵蓋編輯模式（見下面 `isEditing`），這句只談「有沒有 profile」。
        //
        // 原本這裡有一個 `frameSizeProvider` 的 didSet 佈線，把 renderer.lastFrameSize
        // 餵給 KeymapController 做觸點換算。整套已移除——換算收進 EmulatorClient 之後，
        // App 層不再需要（也不應該）知道該乘什麼尺寸。
        var controller: KeymapController?
        /// D22：編輯模式下一律不送滑鼠事件。與 `hasProfile` 是**兩件事**：
        /// 前者問「該不該交給引擎」，這個問「該不該送出去」。
        var isEditing = false
        var textMode = false
        let queue: InputQueue
        private var resizeTask: Task<Void, Never>?
        private static let defaultStreamSize = (w: 540, h: 1200)

        init(client: EmulatorClient, queue: InputQueue) {
            self.client = client
            self.queue = queue
        }

        func sendMouse(nx: Double, ny: Double, down: Bool) {
            // D22：編輯中一律不送。使用者正在拖鍵位，不是在玩。
            guard !isEditing else { return }
            // 有作用中 profile 時鍵鼠改走 KeymapController → KeymapEngine，這裡不再重複送 tap。
            guard textMode || controller?.hasProfile != true else { return }
            // 直接送正規化座標：換算成 guest 像素需要**實體螢幕解析度**，那是
            // EmulatorClient 才知道的事（來自健康探測）。這裡原本用 lastFrameSize（串流
            // 幀尺寸）自行換算，而兩者在本機相差兩倍，所以每次點擊都偏到左上一半處。
            //
            // D6：走佇列而不是自己開 Task。原本 mouseDown/mouseUp 各開一個 Task，對調
            // 就是 guest 的手指永遠按著——與鍵盤直通同一種「沒有自癒路徑」的失效。
            queue.tap(nx: nx, ny: ny, down: down)
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
