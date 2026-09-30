import AppKit
import SwiftUI

/// 鏡像視窗的內容。原本寫在 `MirageScene` 的 `Window { }` 裡，2026-09-17 抽出來，
/// 讓 `MirrorWindowController` 可以放進 `NSHostingView`（規格
/// `docs/specs/2026-09-17-launch-without-window-design.md`）。內容沒有改。
struct MirrorRootView: View {
    let model: AppModel

    var body: some View {
        ZStack(alignment: .top) {
            // P1-c: model.keymap 起始為 nil（非同步載入），MirrorView.updateNSView 會在
            // loadKeymap() 完成、@Observable 觸發重繪時把值同步進 Coordinator。
            MirrorView(client: model.client, box: model.box,
                       controller: model.keymap, isEditing: model.editing, textInput: model.textInput,
                       queue: model.inputQueue,
                       onFrameSize: { w, h in model.frameSize = (w: w, h: h) },
                       onStreamDemand: { w, h in await model.updateWindowStreamDemand(width: w, height: h) })
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
            if !model.instanceManagerPresentation.setupVisible {
                ConnectionBanner(
                    state: model.connState,
                    instanceState: model.instanceManagerPresentation.currentInstanceState,
                    avd: model.instanceManagerPresentation.currentAVD ?? "",
                    logURL: model.instanceManagerPresentation.logURL,
                    tableError: model.instanceManagerPresentation.tableError,
                    specError: model.instanceManagerPresentation.specError,
                    onRestart: { Task { await model.restartCurrentInstance() } },
                    onShowLog: {
                        if let url = model.instanceManagerPresentation.logURL {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    })
            }
            keymapOverlayLayer
            // 隱藏按鈕：⌘E 切換編輯模式。用 SwiftUI .keyboardShortcut 走標準
            // performKeyEquivalent 路徑，不需要額外的 NSEvent monitor 生命週期管理，
            // 也不會和 MirrorMTKView.keyDown（一般字元鍵）互相搶事件。
            Button("") { model.toggleEditing() }
                .keyboardShortcut("e", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
            Button("") { model.sendAndroidKey("AudioVolumeUp") }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
            Button("") { model.sendAndroidKey("AudioVolumeDown") }
                .keyboardShortcut(.downArrow, modifiers: .command)
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
        .allowsHitTesting(!model.instanceManagerPresentation.setupVisible)
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
