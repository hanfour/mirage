import AppKit
import SwiftUI

/// 啟動流程與鏡像視窗（2026-09-17，規格 `docs/specs/2026-09-17-launch-without-window-design.md`）。
///
/// 原本整段啟動流程寫在 SwiftUI `Window` 的 `.task` 裡，視窗一定先顯示才開始啟動，
/// 背景模式因此會閃一下。現在由 `AppDelegate.applicationDidFinishLaunching` 呼叫 `launch()`，
/// 視窗只在需要時由 `windowController` 建立。
extension AppModel {
    static func makeWindowController(for model: AppModel) -> MirrorWindowController {
        MirrorWindowController { [weak model] in
            guard let model else { return NSView() }
            let host = NSHostingView(rootView: MirrorRootView(model: model))
            host.safeAreaRegions = []
            host.sizingOptions = []
            // hosting view 當 contentView 時，SwiftUI 會在每次 windowDidLayout 依內容去改視窗大小
            // （updateAnimatedWindowSize）；加上 fullSizeContentView 後與 MirrorContainerView 的
            // 長寬比調整互相覆蓋，AppKit 丟出 NSGenericException（Update Constraints in Window
            // 次數超過 view 數）。包一層普通 NSView，視窗大小只由 MirrorWindowController 與
            // MirrorContainerView 決定。
            let container = NSView()
            host.frame = container.bounds
            host.autoresizingMask = [.width, .height]
            container.addSubview(host)
            return container
        }
    }

    /// 順序與原本的 `.task` 相同，不要調換：`seedBuiltInProfiles` 必須在 `startDetection` 之前，
    /// 偵測命中就會讀那個目錄。
    func launch() async {
        if !launchPreferences.effectiveBackgroundMode {
            windowController.window().makeKeyAndOrderFront(nil)
            (NSApp as NSApplication?)?.activate(ignoringOtherApps: true)
        }
        await start()
        startLifecycle()
        seedBuiltInProfiles()
        loadKeymap()
        startDetection()
    }
}
