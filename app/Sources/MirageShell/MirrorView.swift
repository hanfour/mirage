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
    var diagnosticEventID: UUID?
    var compositionID = UUID()
    nonisolated(unsafe) var textWindowObservers: [NSObjectProtocol] = []
    nonisolated(unsafe) private var touchpadScrollMonitor: Any?
    deinit {
        for observer in textWindowObservers { NotificationCenter.default.removeObserver(observer) }
        if let touchpadScrollMonitor { NSEvent.removeMonitor(touchpadScrollMonitor) }
    }

    var ownedKeys: [UInt16: [KeyCode]] = [:]
    var observedGeneration: UInt64?
    var compositionChanged: (() -> Void)?
    let markedOverlay = MarkedTextOverlay(frame: .zero)
    var compositionAnchor: CGPoint?
    var coordinateRect: ((NSRange) -> (NSRect, NSRange))?

    var interpretInput: (([NSEvent]) -> Void)?

    var onMouse: ((_ nx: Double, _ ny: Double, _ down: Bool) -> Void)?
    var isTouchpadScrollEnabled: @MainActor () -> Bool = { false }
    private(set) var isDispatchingTouchpadAction = false
    var onResize: ((_ pixelSize: CGSize) -> Void)?
    // P1-c 鍵位映射：keyDown/keyUp 已解碼為 KeyCode；look 用原始 mouseMoved delta（未關聯游標時為 raw）。
    var onKey: ((_ code: KeyCode, _ down: Bool) -> Void)?
    var onMouseMovedDelta: ((_ dx: Double, _ dy: Double) -> Void)?
    var onFlagsChanged: ((NSEvent) -> Void)?
    private var touchpadDragMachine = TouchpadDragMachine()
    private var leftMouseDown = false

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
        removeTouchpadScrollMonitor()
        cancelTouchpadDrag()
        if window == nil { leftMouseDown = false }
        for observer in textWindowObservers { NotificationCenter.default.removeObserver(observer) }
        textWindowObservers.removeAll()
        guard let window else { cancelComposition(); return }
        textWindowObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.leftMouseDown = false
                self?.cancelComposition()
                self?.cancelTouchpadDrag()
            }
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
        touchpadScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self, weak window] event in
            guard let self, let window, event.windowNumber == window.windowNumber else { return event }
            let hasPhase = event.phase != []
            let hasMomentum = event.momentumPhase != []
            guard event.hasPreciseScrollingDeltas, hasPhase || hasMomentum else { return event }
            MainActor.assumeIsolated { self.handleTouchpadScroll(event) }
            return nil
        }
    }

    private func removeTouchpadScrollMonitor() {
        if let touchpadScrollMonitor {
            NSEvent.removeMonitor(touchpadScrollMonitor)
            self.touchpadScrollMonitor = nil
        }
    }

    func cancelTouchpadDrag() {
        for action in touchpadDragMachine.cancel() { dispatchTouchpadAction(action) }
    }

    private func handleTouchpadScroll(_ event: NSEvent) {
        let phase: TouchpadScrollPhase
        if event.phase.contains(.began) { phase = .began }
        else if event.phase.contains(.changed) { phase = .changed }
        else if event.phase.contains(.ended) { phase = .ended }
        else if event.phase.contains(.cancelled) { phase = .cancelled }
        else { phase = .none }
        let point = convert(event.locationInWindow, from: nil)
        let sample = TouchpadScrollSample(
            phase: phase,
            hasPreciseDeltas: event.hasPreciseScrollingDeltas,
            hasPhase: event.phase != [],
            hasMomentum: event.momentumPhase != [],
            isEnabled: isTouchpadScrollEnabled(),
            leftMouseDown: leftMouseDown || (NSEvent.pressedMouseButtons & 1) != 0,
            location: (Double(point.x), Double(point.y)),
            delta: (Double(event.scrollingDeltaX), Double(event.scrollingDeltaY)),
            size: (Double(bounds.width), Double(bounds.height)))
        for action in touchpadDragMachine.handle(sample) { dispatchTouchpadAction(action) }
    }

    private func dispatchTouchpadAction(_ action: TouchpadDragAction) {
        let point: NormPoint
        let down: Bool
        switch action {
        case .down(let value), .move(let value):
            point = value
            down = true
        case .up(let value):
            point = value
            down = false
        }
        isDispatchingTouchpadAction = true
        defer { isDispatchingTouchpadAction = false }
        onMouse?(point.x, point.y, down)
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

    /// Mirage 不在前景時，點畫面的第一下也送進 Android（同時切到前景），與 iPhone 鏡像輸出相同。
    /// 預設的 false 會讓第一下只用來啟用視窗，使用者要點兩次；測試控制通道在背景點擊也會被吞掉。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        leftMouseDown = true
        cancelTouchpadDrag()
        window?.makeFirstResponder(self)
        if textMode {
            textInput?.queue.invalidateTextSession()
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
            textInput?.queue.invalidateTextSession()
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
        defer { leftMouseDown = false }
        if let (nx, ny) = normalized(event) { onMouse?(nx, ny, false) }
    }

    override func mouseMoved(with event: NSEvent) {
        if !textMode { onMouseMovedDelta?(Double(event.deltaX), Double(event.deltaY)) }
    }

    override func keyDown(with event: NSEvent) {
        synchronizeTextSession()
        diagnosticEventID = UUID()
        textInput?.queue.textDiagnostics.record("key-down", ["eventID": diagnosticEventID!.uuidString,
            "route": event.modifierFlags.contains(.command) ? "appkit-shortcut" : (textMode ? "text" : "keymap"), "virtualKey": String(event.keyCode),
            "repeat": String(event.isARepeat), "window": String(event.windowNumber)])
        if textMode {
            guard !event.modifierFlags.contains(.command) else { super.keyDown(with: event); return }
            acceptsTextCallbacks = true
            eventGeneration = session.generation
            currentTextEvent = event
            eventWasComposing = hasMarkedText()
            defer { currentTextEvent = nil }
            textInput?.queue.textDiagnostics.record("interpret", ["eventID": diagnosticEventID!.uuidString])
            if let interpretInput { interpretInput([event]) }
            else { interpretKeyEvents([event]) }
        } else if let c = keyCode(from: event) {
            ownedKeys[event.keyCode] = [c]
            onKey?(c, true)
        }
    }
    override func keyUp(with event: NSEvent) {
        textInput?.queue.textDiagnostics.record("key-up", ["virtualKey": String(event.keyCode), "guestOwned": String(ownedKeys[event.keyCode] != nil)])
        for code in (ownedKeys.removeValue(forKey: event.keyCode) ?? []).reversed() { onKey?(code, false) }
    }
    override func flagsChanged(with event: NSEvent) {
        if textMode {
            // Modifier events have their own IME path; keyDown is still interpreted exactly once.
            if event.type == .flagsChanged { _ = inputContext?.handleEvent(event) }
        } else { onFlagsChanged?(event) }
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
    /// 由外層傳入 `model.profile != nil`，讓 profile 切換時 SwiftUI 重跑 updateNSView 重設文字模式。
    /// 原本只讀 `controller?.hasProfile`：自動偵測換上 profile 時 controller 是原地 reload，
    /// SwiftUI 不知道要更新，文字模式卡在開著，整套鍵位映射（鍵盤與手把）都沒有作用（2026-10-01 實機查到）。
    var hasProfile: Bool = false
    var textInput: TextInputPresentation? = nil
    /// D6：tap 與鍵位映射的觸控／鍵盤共用**同一條**佇列（由 `AppModel` 持有），
    /// 否則兩條佇列各自有序、彼此無序，切換 profile 的瞬間仍會對調。
    let queue: InputQueue
    let isConnected: Bool
    let isMouseCaptured: @MainActor () -> Bool
    /// Task 4：幀尺寸同時餵給容器（佈局用）與 `AppModel`（overlay 算內容矩形用）。
    let onFrameSize: (Int, Int) -> Void
    /// 視窗需要的串流尺寸。不直接設給 client：手機遙控也有需求，由 `AppModel` 合併兩者。
    let onStreamDemand: @MainActor (_ width: Int, _ height: Int) async -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(client: client, queue: queue, onStreamDemand: onStreamDemand)
    }

    func makeNSView(context: Context) -> MirrorContainerView {
        let container = MirrorContainerView(frame: .zero)
        let view = container.mirror
        let renderer = Renderer(view: view, box: box)
        renderer?.onFrameSize = { [weak container] w, h in
            container?.frameSize = (w: w, h: h)
            onFrameSize(w, h)
        }
        context.coordinator.renderer = renderer
        context.coordinator.bind(view: view, controller: controller)
        context.coordinator.updateTouchpadAvailability(
            connected: isConnected, editing: isEditing, mouseCaptured: isMouseCaptured)
        view.onMouse = { [weak view] nx, ny, down in
            context.coordinator.sendMouse(nx: nx, ny: ny, down: down,
                                          fromTouchpad: view?.isDispatchingTouchpadAction == true)
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
        let profileActive = hasProfile || controller?.hasProfile == true
        let enabled = !isEditing && (textInput?.usesText(hasProfile: profileActive) ?? !profileActive)
        controller?.setTextMode(enabled)
        view.textInput = textInput
        view.textMode = enabled
        view.synchronizeTextSession()
        coordinator.textMode = enabled
    }

    func updateNSView(_ view: MirrorContainerView, context: Context) {
        context.coordinator.bind(view: view.mirror, controller: controller)
        context.coordinator.updateTouchpadAvailability(
            connected: isConnected, editing: isEditing, mouseCaptured: isMouseCaptured)
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
        private var isConnected = false
        private var mouseCaptureState: @MainActor () -> Bool = { false }
        private weak var mirrorView: MirrorMTKView?
        let queue: InputQueue
        private var resizeTask: Task<Void, Never>?
        private static let defaultStreamSize = (w: 540, h: 1200)

        private let onStreamDemand: @MainActor (Int, Int) async -> Void

        private var touchpadScrollEnabled: Bool {
            isConnected && !isEditing && !mouseCaptureState()
        }

        init(client: EmulatorClient, queue: InputQueue,
             onStreamDemand: @escaping @MainActor (Int, Int) async -> Void = { _, _ in }) {
            self.client = client
            self.queue = queue
            self.onStreamDemand = onStreamDemand
        }

        func bind(view: MirrorMTKView, controller: KeymapController?) {
            mirrorView = view
            if self.controller !== controller {
                self.controller?.onLoseFocus = nil
                self.controller = controller
                controller?.onLoseFocus = { [weak self] in self?.mirrorView?.cancelTouchpadDrag() }
            }
            view.isTouchpadScrollEnabled = { [weak self] in self?.touchpadScrollEnabled ?? false }
        }

        func updateTouchpadAvailability(connected: Bool, editing: Bool,
                                        mouseCaptured: @escaping @MainActor () -> Bool) {
            isConnected = connected
            isEditing = editing
            mouseCaptureState = mouseCaptured
            if !touchpadScrollEnabled { mirrorView?.cancelTouchpadDrag() }
        }

        func sendMouse(nx: Double, ny: Double, down: Bool) {
            sendMouse(nx: nx, ny: ny, down: down, fromTouchpad: false)
        }

        func sendMouse(nx: Double, ny: Double, down: Bool, fromTouchpad: Bool) {
            if fromTouchpad {
                if down { guard touchpadScrollEnabled else { return } }
                queue.tap(nx: nx, ny: ny, down: down)
                return
            }
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
                // 長寬比取 guest 解析度，幀只決定直橫，理由見 StreamSize.aspect。
                let aspect = StreamSize.aspect(guest: await client.displaySize,
                                               frame: renderer?.lastFrameSize ?? Self.defaultStreamSize)
                // 上限與偶數對齊的算術在 MirageCore.StreamSize（純函式、有單元測試）。
                let w = StreamSize.width(forContentWidth: Int(pixelSize.width), aspect: aspect)
                let h = StreamSize.height(forWidth: w, aspect: aspect)
                // 只換串流解析度。觸控座標**不隨它改變**——那是 guest 實體螢幕的事，
                // 由 EmulatorClient 從健康探測取得，與我們請求多大的畫面無關。
                await onStreamDemand(w, h)
            }
        }
    }
}
