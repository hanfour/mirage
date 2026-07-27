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
    // AUTHORIZED ADDITION（Task 4 review: NIO teardown race）— see AppDelegate below.
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
        WindowGroup("Mirage") {
            ZStack(alignment: .top) {
                // P1-c: model.keymap 起始為 nil（非同步載入），MirrorView.updateNSView 會在
                // loadKeymap() 完成、@Observable 觸發重繪時把值同步進 Coordinator。
                MirrorView(client: model.client, box: model.box, controller: model.keymap)
                    .dropDestination(for: URL.self) { urls, _ in
                        let apks = urls.filter { $0.pathExtension.lowercased() == "apk" }
                        guard !apks.isEmpty else { return false }
                        Task { await model.installAPKs(apks) }
                        return true
                    }
                ConnectionBanner(state: model.connState)
                keymapOverlayLayer
                // 隱藏按鈕：⌘E 切換編輯模式。用 SwiftUI .keyboardShortcut 走標準
                // performKeyEquivalent 路徑，不需要額外的 NSEvent monitor 生命週期管理，
                // 也不會和 MirrorMTKView.keyDown（一般字元鍵）互相搶事件。
                Button("") { model.toggleEditing() }
                    .keyboardShortcut("e", modifiers: .command)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                InstallBanner(state: model.installState)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .allowsHitTesting(false)
            }
            .frame(minWidth: 270, minHeight: 600)
            .task {
                appDelegate.model = model   // 供 applicationWillTerminate 使用
                await model.start()
                model.startLifecycle()
                model.loadKeymap(guestSize: AppModel.defaultGuestSize)
                model.startDetection()
            }
        }
    }

    // P1-c：編輯模式顯示陽春編輯器，否則顯示唯讀提示 overlay；兩者都在無 profile 時
    // 優雅退化（OverlayEditorView 需要非 nil profile 才有東西可編，KeymapOverlay 本身
    // 就接受 nil 直接不畫任何標記）。獨立成 @MainActor computed var 而非塞進 body 是因為
    // MirrorView 那行已經夠長；標 @MainActor 是因為它讀取的是 model 的 MainActor-isolated
    // 屬性（editing/profile），不像 body 本身有 App 協定的 @MainActor 需求可以白拿。
    @MainActor
    @ViewBuilder
    private var keymapOverlayLayer: some View {
        if model.editing, let profile = model.profile {
            OverlayEditorView(
                // SwiftUI.Binding 明確寫模組名——MirageCore.Binding（keymap 綁定列舉）撞名。
                profile: SwiftUI.Binding(get: { profile }, set: { model.profile = $0 }),
                onSave: { model.saveProfile($0) }
            )
        } else if !model.isFullScreen {
            // P1-e 遊戲模式：全螢幕時隱藏唯讀提示標記（純視覺噪音）。ConnectionBanner
            // 與 InstallBanner 刻意保留——前者是必須知道的異常，後者是使用者主動觸發的回饋。
            KeymapOverlay(profile: model.profile)
        }
    }
}
