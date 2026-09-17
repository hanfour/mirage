import SwiftUI

/// SwiftUI 的 App 進入點。
///
/// **刻意保持 internal**：executable target 只有一個轉呼叫的 `@main`（見
/// `Sources/MirageApp/Main.swift`），實際啟動經由 `MirageEntry.main()`。`App` 協定的
/// extension 自帶 `public static func main()`，所以這個型別與 `AppDelegate` 都不必公開——
/// `MirageShell` 的公開介面因此只有 `MirageEntry` 一個函式，其餘 21 檔的可見度一行未改，
/// 測試用 `@testable import MirageShell` 即可觸及。
struct MirageScene: App {
    @State private var model = AppModel()
    // AUTHORIZED ADDITION（Task 4 review: NIO teardown race）— see AppDelegate.swift.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // AUTHORIZED ADDITION (phase0 lesson — see phase0/swift-poc task-8-report.md's
    // `setvbuf` deviation): stdout is block-buffered whenever it isn't a TTY
    // (e.g. redirected to a log file, as the smoke-test harness does), so the
    // `[app] fps=N` lines Renderer prints would sit in the buffer until
    // process exit and be lost entirely on a hard `pkill`. Force line
    // buffering so each fps line flushes as soon as it's printed.
    init() {
        setvbuf(stdout, nil, _IOLBF, 0)
    }

    var body: some Scene {
        // D30：`Window` 而不是 `WindowGroup`——**單一實例場景**。
        //
        // `WindowGroup` 自帶 File → New Window（⌘N），而下面的 `.task` 是**每個視窗跑
        // 一次**、`@State model` 卻是整個 App 一份。兩者一組合，開第二個視窗就會對同一個
        // `AppModel` 重跑整段啟動序列：第二條連線迴圈、第二個 `client.states` 消費者
        // （那是**單一 continuation** 的 AsyncStream，兩個消費者會各自只收到一部分值——
        // `AppModel.start()` 的註解早就寫明這件事，只是沒人想到 `.task` 會跑兩次）、
        // 第二個剪貼簿消費者、第二份 ClipboardWatcher、第二個狀態列圖示。
        //
        // **修法刻意不是在 `.task` 裡加旗標**：旗標是補丁，它讓「可以有兩個視窗」這個
        // 錯誤前提繼續存在，只是擋住其中一個後果。Mirage 鏡像的是一台模擬器，本來就
        // 只該有一個鏡像視窗——換成 `Window` 之後 ⌘N 直接從選單消失，重複啟動這件事
        // 在結構上不存在，順帶讓 `NSApp.windows.first` 這個既有寫法不再有歧義。
        //
        // 關閉視窗不會重跑 `.task`：`AppLifecycle.windowShouldClose` 回傳 false 並
        // `orderOut(nil)`，視窗是**隱藏**不是銷毀，SwiftUI 的 view 樹原封不動。
        Window("Mirage", id: "mirage-mirror") {
            MirrorRootView(model: model)
                .task {
                    appDelegate.model = model   // 供 applicationWillTerminate 使用
                    model.hideWindowEarlyForBackgroundMode()   // 在連線之前藏，縮短視窗露出的時間
                    await model.start()
                    model.startLifecycle()
                    model.seedBuiltInProfiles()   // 必須在 startDetection 之前：偵測命中就會讀那個目錄
                    model.loadKeymap()
                    model.startDetection()
                }
        }
    }
}
