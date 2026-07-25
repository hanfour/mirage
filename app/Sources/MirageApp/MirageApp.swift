import AppKit
import MirageCore
import SwiftUI

@main
struct MirageApp: App {
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
                ConnectionBanner(state: model.connState)
                keymapOverlayLayer
                // 隱藏按鈕：⌘E 切換編輯模式。用 SwiftUI .keyboardShortcut 走標準
                // performKeyEquivalent 路徑，不需要額外的 NSEvent monitor 生命週期管理，
                // 也不會和 MirrorMTKView.keyDown（一般字元鍵）互相搶事件。
                Button("") { model.toggleEditing() }
                    .keyboardShortcut("e", modifiers: .command)
                    .frame(width: 0, height: 0)
                    .opacity(0)
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
        } else {
            KeymapOverlay(profile: model.profile)
        }
    }
}

@MainActor
@Observable
final class AppModel {
    let client = EmulatorClient()
    let box = LatestFrameBox()
    var connState: ConnState = .disconnected

    // Task 6: 選單列、剪貼簿橋接、視窗關閉/喚醒生命週期。
    var menuBar: MenuBarController?
    var lifecycle: AppLifecycle?
    var watcher: ClipboardWatcher?
    private var bridge = ClipboardBridge()

    // P1-c: 鍵位映射——KeymapController 橋接輸入、profile 供 overlay/編輯器讀寫、
    // editing 由 ⌘E 切換、mouseCapture 管 look 模式的游標鎖定。
    var keymap: KeymapController?
    var profile: KeymapProfile?
    var editing = false
    let mouseCapture = MouseCapture()

    // P1-d: 遊戲偵測→啟用接線。detector 輪詢前景 package（無 adb 時保持 nil，
    // 靜默不偵測）；currentPackage/override 一起餵給 ActivationDecider 決定要不要
    // 套用 keymap；store 獨立於 loadKeymap/saveProfile 既有的 ProfileStore.standard()
    // 呼叫（未合併，避免動到既有 P1-c 路徑）。
    private var detector: GameDetector?
    private(set) var currentPackage: String?
    private(set) var override: ManualOverride = .auto
    private let store = ProfileStore.standard()

    /// 兩處共用（client.start 的初始尺寸、KeymapController 的初始 guestSize），避免同一組
    /// 數字散在兩個檔案裡各寫一份（原本 540/1200 只出現在 start() 一處，Task 7 新增第二個
    /// 消費者時順手收斂成常數，不算擴大改動範圍）。
    static let defaultGuestSize: (w: Int, h: Int) = (540, 1200)

    /// PLACEHOLDER：目前哪個 game 在跑（gameId）尚未有偵測機制，先寫死——與 Task 7 brief
    /// 一致，實際綁定留待後續任務（見 task-7-report.md pending-human 清單）。
    static let gameId = "com.example.game"

    func start() async {
        // RECONCILIATION (Task 6 brief vs. this file): the brief's `startLifecycle()`
        // snippet spins up a SECOND `for await s in client.states` loop to feed
        // `menuBar?.updateStatus`. `client.states` is a plain single-continuation
        // `AsyncStream` (see EmulatorClient.swift) — it is not a broadcast/multicast
        // stream, so two independent `for await` consumers would each only receive
        // a subset of emitted values (elements are split between whichever iterator
        // calls `next()` first), silently desyncing `connState` (already consumed
        // here, pre-dating Task 6) from the menu bar label. Fixed by keeping this
        // as the SOLE consumer of `client.states` and having it drive both
        // `connState` and `menuBar?.updateStatus` together; `startLifecycle()`
        // seeds the label with the already-known `connState` at menuBar-creation
        // time (menuBar is nil until then, so earlier emissions would otherwise
        // be missed by it).
        Task { [client] in
            for await s in client.states {
                await MainActor.run {
                    self.connState = s
                    self.menuBar?.updateStatus(Self.label(s))
                }
            }
        }
        await client.start(box: box, width: Self.defaultGuestSize.w, height: Self.defaultGuestSize.h)
    }

    /// 啟動時載入 profile；找不到／解析失敗一律吞成 nil（直接模式），對齊 spec §5「無 profile
    /// 不得崩潰」——與 loadKeymap 呼叫端（body 的 .task）同一批啟動流程，但獨立成一步，
    /// 這樣往後要換成「偵測目前遊戲」時只需要改這一個函式。
    func loadKeymap(guestSize: (w: Int, h: Int)) {
        profile = try? ProfileStore.standard().load(gameId: Self.gameId)
        keymap = KeymapController(client: client, profile: profile, guestSize: guestSize)
        if keymap?.hasProfile == true { mouseCapture.capture() }
    }

    /// ⌘E：切換編輯模式。編輯時放開游標（要看得到、能拖拉调整 binding）；離開編輯時，
    /// 如果有作用中 profile 就重新捕捉（回到 look 手感）。
    func toggleEditing() {
        editing.toggle()
        keymap?.setEditing(editing)
        if editing {
            mouseCapture.release()
        } else if keymap?.hasProfile == true {
            mouseCapture.capture()
        }
    }

    /// OverlayEditorView 的「存檔」呼叫這裡：version+1 已在編輯器裡算好，這裡只管原子寫
    /// 檔＋讓當前 session 的引擎立即套用新 binding。失敗只記錄不丟例外中斷編輯流程——
    /// 使用者可見的錯誤提示（例如存檔失敗 toast）留待後續（pending-human，無 GUI 無法驗證）。
    func saveProfile(_ p: KeymapProfile) {
        do {
            try ProfileStore.standard().save(p)
            profile = p
            keymap?.reload(p)
        } catch {
            print("[keymap] profile save failed: \(error)")
        }
    }

    /// 啟動前景遊戲偵測（P1-d）。無 adb（找不到 SDK/非可執行檔）→ 靜默不偵測，維持
    /// 目前直接模式，對齊 spec 保守降級原則（同 loadKeymap 對「找不到 profile」的處理）。
    ///
    /// Task 6 偏離 brief 字面順序："尾綁" menuBar 回呼——這裡改成放在 adb guard 之前。
    /// 原因：手動覆蓋（停用 keymap／套用指定 profile）跟有沒有 adb 偵測是兩件事，沒有 adb
    /// 時使用者仍應該能從選單列手動套用 profile；若照原字面放在 guard 之後，無 adb 環境會
    /// 直接 return，選單列的三個回呼永遠不會被綁定，變成「有 bug 而不是設計」的特殊情況。
    func startDetection() {
        menuBar?.onDisable = { [weak self] in self?.setOverride(.disabled) }
        menuBar?.onAuto = { [weak self] in self?.setOverride(.auto) }
        menuBar?.onForce = { [weak self] gid in
            if let p = try? self?.store.load(gameId: gid) { self?.setOverride(.force(p)) }
        }
        guard let adb = AdbClient.standard() else { return }
        detector = GameDetector(adb: adb) { [weak self] pkg in
            self?.onForeground(pkg)
        }
        detector?.start()
    }

    /// GameDetector 回呼：前景 package 變動（含變成 nil）時重新跑一次啟用決策。
    private func onForeground(_ pkg: String?) {
        currentPackage = pkg
        applyActivation()
    }

    /// Task 6（選單列手動覆蓋 UI）呼叫：切換 auto/force/disabled 後立即重新決策。
    func setOverride(_ o: ManualOverride) {
        override = o
        applyActivation()
    }

    /// 純決策與 I/O 的接合點：load profile（I/O，失敗吞成 nil）→ ActivationDecider（純函式）
    /// →套用到 keymap engine →回報選單列。currentPackage 為 nil（無前景/adb 失敗）時
    /// loadedProfile 自然是 nil，ActivationDecider 在 .auto 下會決成 .inactive——不需要
    /// 額外的 nil 特例分支。
    private func applyActivation() {
        let loaded: KeymapProfile? = currentPackage.flatMap { try? store.load(gameId: $0) }
        switch ActivationDecider.decide(loadedProfile: loaded, override: override) {
        case .active(let p): keymap?.reload(p)
        case .inactive:      keymap?.reload(nil)
        }
        menuBar?.updateGame(package: currentPackage, active: keymap?.hasProfile == true)
    }

    func startLifecycle() {
        lifecycle = AppLifecycle(client: client)
        menuBar = MenuBarController(
            onWake: { [weak self] in self?.wake() },
            onShow: { [weak self] in self?.wake() }
        )
        menuBar?.updateStatus(Self.label(connState))   // 補上 menuBar 建立前已錯過的狀態

        // guest→host 剪貼簿：經 bridge 防回音後寫 NSPasteboard
        Task { [weak self, client] in
            for await text in client.guestClipboard {
                await MainActor.run { self?.applyGuestClipboard(text) }
            }
        }

        // host→guest：watcher 輪詢 → 經 bridge → setGuestClipboard
        watcher = ClipboardWatcher { [weak self] text in self?.applyHostClipboard(text) }
        watcher?.start()

        // 視窗關閉→休眠、喚醒→load 交由 AppLifecycle 當 NSWindowDelegate；
        // 用 Task 讓出一輪 run loop，確保 WindowGroup 的視窗已完成建立掛載。
        Task { [weak self] in
            await MainActor.run {
                NSApp.windows.first?.delegate = self?.lifecycle
            }
        }
    }

    private func applyGuestClipboard(_ text: String) {
        let (ok, next) = bridge.shouldPropagate(value: text, direction: .guestToHost)
        bridge = next
        guard ok else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        watcher?.syncBaseline()          // 別把自己剛寫入的值當 host 變更
    }

    private func applyHostClipboard(_ text: String) {
        let (ok, next) = bridge.shouldPropagate(value: text, direction: .hostToGuest)
        bridge = next
        guard ok else { return }
        Task { await client.setGuestClipboard(text) }
    }

    private func wake() {
        let window = NSApp.windows.first
        lifecycle?.wake(showing: window)
    }

    static func label(_ s: ConnState) -> String {
        switch s {
        case .connected: return "已連線"
        case .connecting: return "連線中"
        case .reconnecting(let n): return "重連中（第 \(n + 1) 次）"
        case .disconnected: return "未連線"
        }
    }

    // AUTHORIZED ADDITION（Task 4 review: NIO teardown race）— see AppDelegate
    // below for the full rationale. `nonisolated` on purpose: it only touches
    // `client`, a `let`-bound Sendable actor reference, so it can run to
    // completion off the main thread/MainActor executor — required because
    // the caller (AppDelegate.applicationWillTerminate) blocks the main
    // thread on a semaphore while this runs.
    nonisolated func shutdown() async {
        await client.stop()
        try? await Task.sleep(for: .milliseconds(200))
    }
}

// AUTHORIZED ADDITION（Task 4 review: NIO teardown race）
//
// task-4-report.md Concern 1: EmulatorClient.stop() cancels the frame pump
// and applies `.stopRequested` but does not wait for the underlying gRPC
// stream's cancellation to propagate through NIO before
// GrpcChannelBox.deinit's blocking `group.syncShutdownGracefully()` runs.
// Today this races and prints "Cannot schedule tasks on an EventLoop that
// has already shut down" on stderr; SwiftNIO's own message says this will
// be upgraded to a forced crash in a future release. On quit, AppModel and
// its EmulatorClient/GrpcChannelBox become eligible for deallocation as
// soon as the process starts tearing down — nothing today drains the
// in-flight stream cancellation first.
//
// Fix: on quit, explicitly `await client.stop()` then sleep ~200ms (empirically
// generous headroom for gRPC/NIO to finish unwinding the cancelled stream)
// before allowing the process to actually exit. `AppModel.shutdown()` above
// does exactly that.
//
// Wiring: NSApplicationDelegateAdaptor + `applicationWillTerminate` +
// a semaphore, not WindowGroup's `.onDisappear`. `.onDisappear` only fires
// when a window closes and macOS does not terminate the app when its last
// window closes by default — so it would never fire on Cmd+Q / dock "Quit"
// while the window is still open, which is the common quit path. In
// contrast `applicationWillTerminate(_:)` is NSApplication's synchronous,
// always-called pre-exit hook: returning from it is what allows the process
// to actually exit, so blocking it on a semaphore until the async drain
// finishes is the simplest way to guarantee the drain runs to completion
// before teardown.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationWillTerminate(_ notification: Notification) {
        guard let model else { return }
        let sema = DispatchSemaphore(value: 0)
        Task.detached {
            await model.shutdown()
            sema.signal()
        }
        sema.wait()
    }
}
