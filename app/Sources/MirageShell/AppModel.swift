import AppKit
import MirageCore

@MainActor
@Observable
final class AppModel {
    /// 連線目標可用 `MIRAGE_HOST` / `MIRAGE_PORT` 覆寫（預設仍是 `localhost:8554`）。
    /// 需要它是因為量測與多實例都不可能只面對一台模擬器——見 `EmulatorEndpoint`。
    ///
    /// 解析已下沉到 `EmulatorClient.defaultEndpoint`（2026-07-29，D10）：先前這裡自己
    /// 解析一次、`EmulatorClient()` 的預設值卻寫死 `localhost:8554`，於是**只有 App 走這條路，
    /// 所有測試都繞過它**。兩份各自解析的複本遲早會漂移，現在只有一份。
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
    var isFullScreen = false  // P1-e: 系統通知驅動（涵蓋綠燈/⌃⌘F/選單列）
    let audioRing = AudioRingBuffer()
    var audioPlayer: AudioPlayer?
    // P1-d: 遊戲偵測→啟用接線。detector 輪詢前景 package（無 adb 時保持 nil，
    // 靜默不偵測）；currentPackage/override 一起餵給 ActivationDecider 決定要不要
    // 套用 keymap；store 獨立於 loadKeymap/saveProfile 既有的 ProfileStore.standard()
    // 呼叫（未合併，避免動到既有 P1-c 路徑）。
    private var detector: GameDetector?
    private(set) var currentPackage: String?
    private(set) var override: ManualOverride = .auto
    private let store = ProfileStore.standard()

    // APK 拖放安裝（Phase-1）：installState 供 InstallBanner 呈現；generation 令牌讓
    // 自動消失只清掉「產生它的那一批」，避免舊 dismiss 清掉使用者剛拖入的新批次。
    // 兩者原本是 private(set)/private——Task 8 review 修正把讀寫邏輯搬進
    // AppModel+Install.swift 後，SE-0169 的同檔 private 互通不再適用（不同檔案），
    // 故放寬成預設 internal（比照 audioRing/audioPlayer 的既有先例）。
    var installState: InstallState = .idle
    var installGeneration = 0

    /// `client.start` 的**初始串流尺寸**——要求 emulator 送多大的畫面，之後由
    /// `resizeDebounced` 依視窗大小調整。
    ///
    /// 名字裡的 "guest" 容易誤導，但它**不是** guest 的實體螢幕解析度，也絕不能拿來換算
    /// 觸控座標——那是 `EmulatorClient` 從健康探測取得的另一組數字（本機 1080x2400，
    /// 與這裡的 540x1200 差兩倍）。混淆這兩者正是 §10 那個 bug 的成因。
    static let defaultStreamSize: (w: Int, h: Int) = (540, 1200)

    /// PLACEHOLDER：目前哪個 game 在跑（gameId）尚未有偵測機制，先寫死——與 Task 7 brief
    /// 一致，實際綁定留待後續任務（見 task-7-report.md pending-human 清單）。
    static let gameId = "com.example.game"

    func start() async {
        // 端點無論如何都印一行：「連到另一台模擬器」的症狀（畫面不是預期的那台）跟
        // 「連不上」長得完全不一樣，沒有這行就只能靠猜。壞掉的覆寫更要印——靜默退回
        // 預設會讓人盯著錯的畫面卻毫無線索。
        let endpoint = EmulatorClient.defaultEndpoint
        print("[app] endpoint=\(endpoint.host):\(endpoint.port)")
        if let problem = endpoint.overrideProblem {
            print("[app] 環境變數覆寫無效：\(problem)")
        }

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
        await client.start(box: box, width: Self.defaultStreamSize.w, height: Self.defaultStreamSize.h)
    }

    /// 啟動時載入 profile；找不到／解析失敗一律吞成 nil（直接模式），對齊 spec §5「無 profile
    /// 不得崩潰」——與 loadKeymap 呼叫端（body 的 .task）同一批啟動流程，但獨立成一步，
    /// 這樣往後要換成「偵測目前遊戲」時只需要改這一個函式。
    func loadKeymap() {
        profile = try? ProfileStore.standard().load(gameId: Self.gameId)
        keymap = KeymapController(client: client, profile: profile)
        mouseCapture.updateCapture(shouldCapture: shouldCapture)
    }

    /// ⌘E：切換編輯模式。編輯時放開游標（要看得到、能拖拉调整 binding）；離開編輯時，
    /// 如果有作用中 profile 就重新捕捉（回到 look 手感）——實際捕捉與否交給
    /// `shouldCapture` 統一判斷（見下方），不在這裡重複「有沒有 profile」的條件。
    ///
    /// AUTHORIZED FIX（P1-d 終審 Important：⌘E 在無 profile 時的行為）：`OverlayEditorView`
    /// 吃的是非 optional 的 `KeymapProfile`（見 body 的 keymapOverlayLayer，需要
    /// `let profile = model.profile` 才能顯示），沒有作用中 profile（偵測未啟用任何
    /// keymap、或使用者手動 disable）時「沒東西可編」。guard 只擋「原本沒在編輯、且沒
    /// profile」這一種情況──已經在編輯模式時 ⌘E 永遠允許切回去（例如編輯途中偵測把
    /// 遊戲切到 .inactive，使用者仍要能用 ⌘E 離開編輯模式），不會卡死在 editing=true
    /// 出不來。
    func toggleEditing() {
        guard editing || profile != nil else { return }
        editing.toggle()
        keymap?.setEditing(editing)
        mouseCapture.updateCapture(shouldCapture: shouldCapture)
    }

    /// Task 7（P1-c 終審 Important：游標陷阱）：是否該捕捉游標的統一判斷式，供
    /// `loadKeymap`/`toggleEditing`/`applyActivation` 共用，取代原本三處各自重複的
    /// 「有 profile 就 capture」判斷。額外收緊兩個條件：
    ///   - `NSApp.keyWindow != nil`——app 不在前景（被 alt-tab 切走、或背景啟動）時
    ///     不該捕捉，否則使用者會被系統級鎖住游標、只剩 ⌘E/quit 能逃脫。
    ///   - （ADAPTATION，見 task-7-report.md）brief 原文還要求 gate 在
    ///     「目前 profile 的 bindings 是否含 .look」——但這裡仍用 `keymap?.hasProfile`
    ///     而非 `profile != nil` 判斷，因為即使兩者現在同步（UPDATE，P1-d 終審
    ///     Important 已修正：`applyActivation()` 現在會把 `keymap?.reload(p)` 套用的
    ///     結果同步寫回 `profile`，見該函式），要正確算 look-only gating 仍得幫
    ///     KeymapController/KeymapEngine 新增「目前 engine 是否有 look binding」的
    ///     查詢，但本任務檔案範圍明確只列 MouseCapture.swift/AppModel.swift；比照
    ///     brief 明文允許的簡化版本，退回「有 profile 且非編輯且為 key window」，
    ///     不含 look 檢查（pending-human 記錄）。
    ///
    /// P1-e fast-follow：可見度由 `private` 放寬為 internal——`AppModel+Focus.swift` 的
    /// `didBecomeKey` 觀察者需要跨檔讀它（SE-0169：`private` 不跨檔），與
    /// `startAudio()`／`setupFullScreen()` 抽 extension 時同一個理由。
    var shouldCapture: Bool {
        keymap?.hasProfile == true && !editing && NSApp.keyWindow != nil
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
        // AUTHORIZED FIX（P1-d 終審 Important：⌘E 編輯器讀到 stale profile）：
        // 原本只呼叫 keymap?.reload(p) 套用到引擎，沒有同步寫回 `profile`——
        // ⌘E 的 OverlayEditorView 讀的是 `profile`，偵測切換遊戲後編輯器仍會顯示
        // 切換前（甚至啟動時）的舊 profile。這裡跟 saveProfile/loadKeymap 的既有
        // 慣例對齊：套用引擎的同時也寫回 `profile`，兩者永遠同步。
        case .active(let p): keymap?.reload(p); profile = p
        case .inactive:      keymap?.reload(nil); profile = nil
        }
        menuBar?.updateGame(package: currentPackage, active: keymap?.hasProfile == true)
        // Task 7：偵測切換 profile（含變成 .inactive）後，捕捉狀態也要跟著重新判斷——
        // 否則例如「原本無 profile 未捕捉，偵測到遊戲切成 active」的情況會漏掉 capture()。
        mouseCapture.updateCapture(shouldCapture: shouldCapture)
    }

    func startLifecycle() {
        lifecycle = AppLifecycle(client: client)
        menuBar = MenuBarController(
            onWake: { [weak self] in self?.wake() },
            onShow: { [weak self] in self?.wake() }
        )
        menuBar?.updateStatus(Self.label(connState))   // 補上 menuBar 建立前已錯過的狀態
        // D2：選單列的 Android 實體鍵。down 之後緊接 up——guest 收到的是一次完整按放，
        // 不是按住不放。sendKey 在未連線時靜默不送（與 sendTap/sendTouches 一致）。
        menuBar?.onAndroidKey = { [client] w3c in
            Task {
                await client.sendKey(.key(w3c), down: true)
                await client.sendKey(.key(w3c), down: false)
            }
        }
        setupFullScreen()
        setupFocusTracking()
        startAudio()
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

    // AUTHORIZED ADDITION（Task 4 review: NIO teardown race）— see AppDelegate.swift
    // for the full rationale. `nonisolated` on purpose: it only touches
    // `client`, a `let`-bound Sendable actor reference, so it can run to
    // completion off the main thread/MainActor executor — required because
    // the caller (AppDelegate.applicationWillTerminate) blocks the main
    // thread on a semaphore while this runs.
    /// 更正（2026-07-29，D1）：這 200ms 是在等一個**已經不存在**的競態
    /// （`GrpcChannelBox.deinit` 的阻塞式 NIO 拆除，見 AppDelegate.swift 頂端的更正註記）。
    /// 現在 `client.stop()` 回來時 channel 已顯式關閉、group 的拆除也已非阻塞地發出。
    /// 保留未動的理由同上：改 ⌘Q 路徑需要實機驗證，而 headless 驅動不了它。
    nonisolated func shutdown() async {
        await client.stop()
        try? await Task.sleep(for: .milliseconds(200))
    }
}
