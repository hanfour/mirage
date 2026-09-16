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
            ZStack(alignment: .top) {
                // P1-c: model.keymap 起始為 nil（非同步載入），MirrorView.updateNSView 會在
                // loadKeymap() 完成、@Observable 觸發重繪時把值同步進 Coordinator。
                MirrorView(client: model.client, box: model.box,
                           controller: model.keymap, isEditing: model.editing, textInput: model.textInput,
                           queue: model.inputQueue,
                           onFrameSize: { w, h in model.frameSize = (w: w, h: h) })
                    .dropDestination(for: URL.self) { urls, _ in
                        let apks = urls.filter { $0.pathExtension.lowercased() == "apk" }
                        guard !apks.isEmpty else { return false }
                        Task { await model.installAPKs(apks) }
                        return true
                    }
                TextInputControls(state: model.textInput)
                    .onChange(of: model.textInput.mode) { _, _ in
                        model.mouseCapture.updateCapture(shouldCapture: model.shouldCapture)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
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
                SpeechOverlay(text: model.speechText) { text in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            // **setter 刻意什麼都不做**（2026-07-30，D5 階段 B 終審 I1）。
            //
            // SwiftUI 關閉 `.alert` 時（無論按哪個按鈕）都會把 `isPresented` 的 binding
            // 設回 `false`。原本的 setter 因此會在按「存檔」之後補一次 `cancelLeave()`
            // ——在 I1 之前那是冪等的無害動作，但現在不是了：存檔失敗時
            // `confirmLeaveSaving()` **刻意保留** `pendingLeaveConfirmation`，好讓提示
            // 留在畫面上；setter 若把它清掉，一次失敗的存檔看起來就跟成功一模一樣
            // （對話框關閉、留在編輯模式），而變更其實一個位元組都沒寫出去。
            //
            // 代價：Esc 關不掉這個對話框（`role: .cancel` 的「繼續編輯」仍然可以，它自己
            // 呼叫 `cancelLeave()`）。有未存變更時本來就該要求明確選擇三者其一，
            // 這個取捨可以接受。
            // 存檔失敗時改顯示原因；按「繼續編輯」才清除兩個提示狀態。
            .alert("有未存的鍵位變更", isPresented: Binding(
                get: { model.pendingLeaveConfirmation && model.profileSaveError == nil },
                set: { _ in }
            )) {
                Button("存檔") { model.confirmLeaveSaving() }
                Button("捨棄", role: .destructive) { model.confirmLeaveDiscarding() }
                Button("繼續編輯", role: .cancel) { model.cancelLeave() }
            } message: {
                Text("離開編輯模式會丟掉這些變更。")
            }
            // 同上：SwiftUI 自動關閉時不清狀態，僅由按鈕明確返回編輯器。
            .alert("鍵位設定無法存檔", isPresented: Binding(
                get: { model.profileSaveError != nil },
                set: { _ in }
            )) {
                Button("繼續編輯", role: .cancel) { model.dismissProfileSaveError() }
            } message: {
                Text(model.profileSaveError ?? "")
            }
            .frame(minWidth: 270, minHeight: 600)
            .task {
                appDelegate.model = model   // 供 applicationWillTerminate 使用
                await model.start()
                model.startLifecycle()
                model.seedBuiltInProfiles()   // 必須在 startDetection 之前：偵測命中就會讀那個目錄
                model.loadKeymap()
                model.startDetection()
            }
        }
    }

    // P1-c：編輯模式顯示編輯器（overlay ＋ 底部抽屜），否則顯示唯讀提示 overlay；兩者都
    // 在無東西可編時優雅退化（OverlayEditorView 需要非 nil `editorSession` 才顯示，
    // KeymapOverlay 本身就接受 nil profile 直接不畫任何標記）。獨立成 @MainActor computed
    // var 而非塞進 body 是因為 MirrorView 那行已經夠長；標 @MainActor 是因為它讀取的是
    // model 的 MainActor-isolated 屬性（editing/editorSession/profile），不像 body 本身
    // 有 App 協定的 @MainActor 需求可以白拿。
    @MainActor
    @ViewBuilder
    private var keymapOverlayLayer: some View {
        if model.editing, let session = model.editorSession {
            OverlayEditorView(session: session,
                              frameSize: model.frameSize,
                              onSelect: { model.selectBinding($0) },
                              onMove: { model.moveSelectedBinding(to: $0) },
                              onSave: { model.saveEditorSession() },
                              onRadius: { model.setSelectedRadius($0) },
                              onSensitivity: { model.setSelectedSensitivity($0) })
        } else if !model.isFullScreen {
            // P1-e 遊戲模式：全螢幕時隱藏唯讀提示標記（純視覺噪音）。ConnectionBanner
            // 與 InstallBanner 刻意保留——前者是必須知道的異常，後者是使用者主動觸發的回饋。
            KeymapOverlay(profile: model.profile, frameSize: model.frameSize)
        }
    }
}
