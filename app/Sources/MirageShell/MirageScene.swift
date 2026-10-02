import SwiftUI

/// SwiftUI 的 App 進入點。
///
/// **刻意保持 internal**：executable target 只有一個轉呼叫的 `@main`（見
/// `Sources/MirageApp/Main.swift`），實際啟動經由 `MirageEntry.main()`。`App` 協定的
/// extension 自帶 `public static func main()`，所以這個型別與 `AppDelegate` 都不必公開——
/// `MirageShell` 的公開介面因此只有 `MirageEntry` 一個函式，其餘 21 檔的可見度一行未改，
/// 測試用 `@testable import MirageShell` 即可觸及。
struct MirageScene: App {
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

    /// 鏡像視窗改由 `MirrorWindowController`（AppKit）建立；Settings 場景讓 SwiftUI 提供主選單。
    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("設定…") { appDelegate.model?.showSettingsWindow() }
                        .keyboardShortcut(",", modifiers: .command)
                        // AppDelegate 必須可觀察，才能在 model 從 nil 建立後重算選單，並接續追蹤 setupVisible。
                        .disabled(appDelegate.model?.instanceManagerPresentation.setupVisible ?? true)
                }
            }
    }
}
