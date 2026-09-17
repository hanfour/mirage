import AppKit
import MirageCore
import ObjectiveC

/// 生命週期協調：視窗關閉→休眠（不退出，選單列常駐）、喚醒→恢復、Cmd+Q→乾淨 teardown。
@MainActor
final class AppLifecycle: NSObject, NSWindowDelegate {
    private let client: EmulatorClient
    private let hasActiveRemoteViewer: () -> Bool
    private let backgroundMode: () -> Bool
    private var policy = LifecyclePolicy()
    private var powerTask: Task<Void, Never>?

    init(client: EmulatorClient, hasActiveRemoteViewer: @escaping () -> Bool = { false },
         backgroundMode: @escaping () -> Bool = { false }) {
        self.client = client
        self.hasActiveRemoteViewer = hasActiveRemoteViewer
        self.backgroundMode = backgroundMode
        super.init()
        if ProcessInfo.processInfo.environment["MIRAGE_CONN_LOG"] == "1" {
            NotificationCenter.default.addObserver(
                self, selector: #selector(diagnoseWillClose(_:)),
                name: NSWindow.willCloseNotification, object: nil)
            NotificationCenter.default.addObserver(
                self, selector: #selector(diagnoseDidBecomeActive(_:)),
                name: NSApplication.didBecomeActiveNotification, object: nil)
        }
    }

    // Observe actual closure separately from a request to hide the window.
    @objc private func diagnoseWillClose(_ notification: Notification) {
        Self.diagnose("willClose", window: notification.object as? NSWindow)
    }

    @objc private func diagnoseDidBecomeActive(_ notification: Notification) {
        Self.diagnose("didBecomeActive", window: NSApp.keyWindow)
    }

    static func diagnose(_ event: String, window: NSWindow?, receiver: String = "nil",
                         result: String = "nil", action: String = "nil") {
        guard ProcessInfo.processInfo.environment["MIRAGE_CONN_LOG"] == "1" else { return }
        let app = NSApp as NSApplication?
        let appDelegate = app?.delegate
        let appDelegateType = LifecycleDiagnostics.typeName(appDelegate)
        let hasClosePolicy = appDelegate?.responds(to: NSSelectorFromString("applicationShouldTerminateAfterLastWindowClosed:")) ?? false
        func containsMirror(_ view: NSView) -> Bool {
            view is MirrorMTKView || view.subviews.contains { containsMirror($0) }
        }
        let fields: [(String, String)] = [
            ("event", event), ("appDelegate", appDelegateType),
            ("respondsToLastWindowPolicy", String(hasClosePolicy)),
            ("isActive", app.map { String($0.isActive) } ?? "nil"),
            ("mainMenuNil", String(app?.mainMenu == nil)),
            ("mainMenuItems", app?.mainMenu.map { String($0.numberOfItems) } ?? "nil"),
            ("activationPolicy", app.map { String($0.activationPolicy().rawValue) } ?? "nil"),
            ("receiver", receiver), ("return", result), ("action", action),
            ("windowCount", String((NSApp as NSApplication?)?.windows.count ?? 0)),
            ("window", window.map { String(describing: ObjectIdentifier($0)) } ?? "nil"),
            ("windowClass", LifecycleDiagnostics.typeName(window)), ("number", window.map { String($0.windowNumber) } ?? "nil"),
            ("identifier", window?.identifier?.rawValue ?? "nil"),
            ("mirror", String(window?.contentView.map { containsMirror($0) } ?? false)),
            ("key", String(window?.isKeyWindow ?? false)), ("visible", String(window?.isVisible ?? false)),
            ("delegate", LifecycleDiagnostics.typeName(window?.delegate)), ("lifecycle", String(window?.delegate is AppLifecycle)),
            ("contentView", LifecycleDiagnostics.typeName(window?.contentView)), ("controller", LifecycleDiagnostics.typeName(window?.windowController)),
            ("level", window.map { String($0.level.rawValue) } ?? "nil"),
            ("styleMask", window.map { String($0.styleMask.rawValue) } ?? "nil"),
            ("width", window.map { String(format: "%.0f", $0.frame.width) } ?? "nil"),
            ("height", window.map { String(format: "%.0f", $0.frame.height) } ?? "nil"),
            ("excludedFromWindowsMenu", String(window?.isExcludedFromWindowsMenu ?? false))
        ]
        print("[wake-diag] " + fields.map { "\($0.0)=\(LifecycleDiagnostics.token($0.1))" }.joined(separator: " "))
    }

    /// 視窗即將關閉 → 觸發休眠而非退出（回傳 false 阻止關閉，改為隱藏）。
    /// 手機連著時只隱藏不休眠：畫面要繼續送到手機（spec 第 6 節）。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let remoteActive = hasActiveRemoteViewer()
        Self.diagnose("windowShouldClose", window: sender, result: "false",
                      action: remoteActive ? "hide-only(remote)" : "suspend")
        sender.orderOut(nil)                 // 隱藏視窗，app 續存（選單列常駐）
        if let policy = LaunchPreferences.policyAfterWindowHidden(backgroundMode: backgroundMode()) {
            (NSApp as NSApplication?)?.setActivationPolicy(policy)   // 背景模式：回到只留選單列
        }
        didHideWindow()
        return false
    }

    /// windowShouldClose 的邏輯入口；獨立於 NSWindow，headless 測試走同一條路。
    func didHideWindow() {
        suspendIfNeeded(policy.didHide(remoteViewerActive: hasActiveRemoteViewer()))
    }

    var isWindowHidden: Bool { policy.isHidden }

    func remoteViewerDisconnected() {
        suspendIfNeeded(policy.remoteViewerDisconnected())
    }

    /// 關視窗與最後一條 video 斷線共用；policy 保證重複通知只觸發一次休眠。
    private func suspendIfNeeded(_ needed: Bool) {
        guard needed else { return }
        enqueuePowerChange(resuming: false)
    }

    /// 不顯示視窗或啟用 App；完成恢復後，呼叫端再要求 keyframe。
    func remoteViewerConnected() async {
        if policy.remoteViewerConnected() { enqueuePowerChange(resuming: true) }
        await powerTask?.value
    }

    // suspend 會 await pump.detach；必須等它完成才 wake，避免落在 .suspending 而被忽略。
    private func enqueuePowerChange(resuming: Bool) {
        let previous = powerTask
        powerTask = Task { [client] in
            await previous?.value
            if resuming { await client.wake() } else { await client.suspend() }
        }
    }

    func wake(showing window: NSWindow?) {
        Self.diagnose("wake", window: window, action: policy.suspended ? "resume" : "show")
        let shouldResume = policy.consumeResume()
        // 背景模式是 accessory：視窗要拿到鍵盤焦點與主選單快捷鍵，先切回 regular。
        // 一般模式本來就是 regular，這行不改變任何事。
        (NSApp as NSApplication?)?.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        Self.diagnose("wake-before-activate", window: window)
        // L：顯示視窗後明確啟用 app，嘗試恢復主選單快捷鍵；仍需活體驗證 ⌘Q。
        NSApp.activate(ignoringOtherApps: true)
        Self.diagnose("wake-after-activate", window: window)
        guard shouldResume else { return }
        enqueuePowerChange(resuming: true)
    }
}

/// 診斷欄位的純轉換，不讀取應用程式或視窗狀態。
enum LifecycleDiagnostics {
    static func typeName(_ object: AnyObject?) -> String {
        guard let object, let runtimeClass = object_getClass(object) else { return "nil" }
        return NSStringFromClass(runtimeClass)
    }

    static func token(_ value: String) -> String {
        value.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.:"))
        ) ?? "nil"
    }
}
