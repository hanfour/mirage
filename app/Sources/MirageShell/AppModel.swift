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
    let box: any FrameSink
    /// `client.start` 實際拿到的 sink。遙控關閉時**就是** `box`（同一個物件，行為零改變）；
    /// 開啟時是 `BroadcastFrameSink(primary: box, secondary:)`。Renderer 一直拿 `box`
    /// （`MirrorRootView.swift`），扇出的 `takeLatest` 代理到它，所以 Renderer 不必知道這件事。
    /// 切換模擬器也傳它（`AppModel+Instances.swift`），否則遙控開著時切台會讓扇出靜默消失。
    @ObservationIgnored var activeSink: any FrameSink
    /// 手機遙控的執行期；nil = 功能關閉。
    @ObservationIgnored var remoteAddresses: () -> [HostAddress] = { HostAddresses.current() }
    let pairingTokens: PairingTokenStore
    let launchPreferences: LaunchPreferences
    /// 鏡像視窗。init 最後才能設定（需要 self），所以是 IUO；建立它不會建立視窗。
    @ObservationIgnored var windowController: MirrorWindowController!
    var remote: RemoteMirrorController?
    var remoteMenuState: RemoteMenuState = .off
    /// enable／disable／disconnect 都會 await，MainActor 期間會重入；進行中就忽略新要求。
    @ObservationIgnored var remoteTransitionInProgress = false
    @ObservationIgnored var remoteGeneration = UUID()
    @ObservationIgnored var remotePendingError: String?
    @ObservationIgnored var makeRemoteEncoder: RemoteEncoderFactory = { fail in
        RemoteVideoEncoder(onError: fail)
    }
    var connState: ConnState = .disconnected
    /// 目前接著的模擬器。初值來自環境（`MIRAGE_HOST`／`MIRAGE_PORT`），之後只由
    /// `switchInstance` 在 `client.setEndpoint` 成功後寫回。
    ///
    /// 這是 `client.currentEndpoint` 在 MainActor 上的鏡像，不是第二份真相：選單列的
    /// `menuNeedsUpdate` 是同步的，拿不到 actor 裡的值。寫入紀律寫在 `switchInstance`。
    var currentEndpoint: EmulatorEndpoint = EmulatorClient.defaultEndpoint
    /// 序列化選單連續點選；已完成的 Task 可直接 await，下一個要求會替換它。
    @ObservationIgnored var instanceSwitchTask: Task<Void, Never>?


    /// 所有輸入事件的唯一序列化出口（D6）。
    ///
    /// **一台 guest 一條佇列**，不是一個呼叫端一條：鍵位映射的觸控、滑鼠 tap、選單列
    /// 的 Android 實體鍵全部走這一條。各自持有一條佇列的話，每條內部有序但彼此之間
    /// 沒有順序——例如切換 profile 的瞬間 tap 與觸控快照仍可能對調，等於沒修。
    let inputQueue: InputQueue
    let textInput: TextInputPresentation

    /// **參數都有預設值，產品呼叫端（`AppDelegate.applicationWillFinishLaunching` 的 `AppModel()`）
    /// 一個字都不用改。** 開這道縫只為了測試能餵暫存目錄與固定的 starter——構造 `AppModel`
    /// 原本會在使用者真實的 Application Support 底下建目錄（D13 記載的「光建構就有 8 個
    /// 全域副作用」之一），測試不該碰那裡。
    init(store: ProfileStore = .standard(),
         pairingTokens: PairingTokenStore = PairingTokenStore(),
         launchPreferences: LaunchPreferences = LaunchPreferences(),
         starterBindings: @escaping @Sendable () -> [Binding] = { BuiltInProfiles.starterBindings() })
    {
        self.pairingTokens = pairingTokens
        self.launchPreferences = launchPreferences
        self.store = store
        self.starterBindings = starterBindings
        let sink = FrameSinkFactory.make(from: ProcessInfo.processInfo.environment)
        box = sink
        activeSink = sink
        activeAudioSink = audioRing
        inputQueue = InputQueue(injector: client)
        textInput = TextInputPresentation(queue: inputQueue)
        if ProcessInfo.processInfo.environment["MIRAGE_CONN_LOG"] == "1" {
            print("[app] frame sink=\(FrameSinkFactory.label(for: box))")
        }
        windowController = Self.makeWindowController(for: self)
    }

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
    /// 編輯中的 binding 清單與選取狀態。非編輯時為 nil。
    ///
    /// **由 `AppModel` 持有而不是 view 的 `@State`**：抽屜與 overlay 是兩個 view，要共用
    /// 同一份選取；而且 ⌘E 離開時要檢查未存變更，那件事發生在這一層。放進 view 各持一份
    /// 遲早不同步。
    var editorSession: EditorSession?
    /// 有未存變更卻按了 ⌘E——Scene 據此跳「存檔／捨棄／繼續編輯」。
    ///
    /// **為什麼需要它**：`.leave` 會呼叫 `applyActivation()` 從磁碟重新取真相，也就是
    /// 丟掉記憶體裡的 profile。階段 A 那是對的（使用者還不能改任何東西）；階段 B 拖曳
    /// 上線之後，同一行就變成「按 ⌘E ＝靜默丟掉剛才調的所有東西」。
    var pendingLeaveConfirmation = false
    /// 存檔失敗原因，供 Scene 的錯誤提示使用。
    // Profiles extension 跨檔寫入；仍受 MainActor 隔離。
    var profileSaveError: String?

    func dismissProfileSaveError() {
        profileSaveError = nil
        cancelLeave()
    }
    let mouseCapture = MouseCapture()
    var isFullScreen = false  // P1-e: 系統通知驅動（涵蓋綠燈/⌃⌘F/選單列）
    /// 目前解碼幀的尺寸。`(0, 0)` 代表尚未收到任何幀。
    ///
    /// **為什麼 `AppModel` 需要知道它**：keymap overlay 畫在 Scene 層的 ZStack 上，而
    /// guest 畫面被 `MirrorContainerView` letterbox 進 `ViewportFit.fit(...)` 的內容矩形。
    /// 沒有幀尺寸就算不出那個矩形，標記只能用整個視窗換算——一有黑邊就與真正的觸點錯開。
    /// 資料流是 `Renderer.onFrameSize` → `MirrorView` →（這裡）＋ `MirrorContainerView`，
    /// 同一個回呼餵兩個出口，既有那條不動。
    var frameSize: (w: Int, h: Int) = (0, 0)
    let audioRing = AudioRingBuffer(
        collectPacketSizes: ProcessInfo.processInfo.environment["MIRAGE_AUDIO_LOG"] == "1")
    /// 比照 `activeSink`：遙控關閉時就是 `audioRing` 本身，開啟時換成扇出包裝。
    /// 不能寫成 `lazy`，`@Observable` 會把儲存屬性變成計算屬性、兩者不相容；
    /// 也不能在宣告處直接指定 `audioRing`，屬性初始式裡還取不到 self。所以在 init 設定。
    @ObservationIgnored var activeAudioSink: any AudioSink
    var audioPlayer: AudioPlayer?
    /// 語音轉文字（2026-09-16）。`speechText` 是給字幕浮層看的，所以要被觀察；
    /// 其餘是實作細節，標 ObservationIgnored 免得每包樣本都觸發畫面重算。
    var speechText = ""
    @ObservationIgnored var speechEnabled = false
    @ObservationIgnored var speechTranscriber: SpeechTranscriber?
    @ObservationIgnored var speechSegmenter = SpeechSegmenter()
    /// 手機遙控的音訊下游。與語音辨識並存，所以存起來而不是每次重建。
    @ObservationIgnored var remoteAudioForwarder: (any AudioSink)?
    // P1-d: 遊戲偵測→啟用接線。detector 輪詢前景 package（無 adb 時保持 nil，
    // 靜默不偵測）；currentPackage/override 一起餵給 ActivationDecider 決定要不要
    // 套用 keymap。（2026-07-30 更新：`saveProfile` 原本另外呼叫 `ProfileStore.standard()`，
    // 與這個 `store` 各自獨立；D5 階段 A review 發現那條寫入路徑因此測不到，已改成
    // 共用同一個注入的 `store`——見 `saveProfile` 的註解。）
    // AppModel+Profiles.swift 共用的狀態，因跨檔存取維持 internal。
    var detector: GameDetector?
    /// 放寬為可寫（2026-07-30，D5 階段 A）：`toggleEditing` 的行為取決於它，
    /// 而測試設不了 `private(set)` 就測不到那條路徑。比照本檔 `installState`／
    /// `installGeneration` 先前為了同樣理由放寬的既有先例。
    /// **產品碼的唯一寫入點仍是 `onForeground(_:)`**——放寬是為了可測，不是邀請別處去改它。
    var currentPackage: String?
    var override: ManualOverride = .auto
    let store: ProfileStore
    /// starter 版面的來源。注入是為了讓 `toggleEditing` 測得到——產品路徑餵的是
    /// `BuiltInProfiles.starterBindings`（會讀 bundle，不可單元測試）。
    let starterBindings: @Sendable () -> [Binding]

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

    func start() async {
        // 端點無論如何都印一行：「連到另一台模擬器」的症狀（畫面不是預期的那台）跟
        // 「連不上」長得完全不一樣，沒有這行就只能靠猜。壞掉的覆寫更要印——靜默退回
        // 預設會讓人盯著錯的畫面卻毫無線索。
        let endpoint = currentEndpoint
        logEndpoint(endpoint)
        if let problem = endpoint.overrideProblem {
            print("[app] 環境變數覆寫無效：\(problem)")
        }
        if let problem = launchPreferences.backgroundModeOverrideProblem {
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
        // 活體腳本用 MIRAGE_REMOTE=1 讓 App 一啟動就開遙控。client 還沒 start，所以這裡只換
        // activeSink，不會多一次重啟。
        if let options = RemoteLaunchOptions.parse(ProcessInfo.processInfo.environment) {
            for problem in options.problems { print("[remote] 環境變數覆寫無效：\(problem)") }
            await enableRemote(port: options.port, token: options.token, pullInterval: options.pullInterval)
        } else if launchPreferences.effectiveBackgroundMode {
            await enableRemote()   // 同一條路徑：client 還沒 start，只換 activeSink
        }
        Task { [client] in
            for await s in client.states {
                await MainActor.run {
                    if self.connState != s { self.inputQueue.invalidateTextSession() }
                    self.connState = s
                    self.menuBar?.updateStatus(Self.label(s))
                }
            }
        }
        await client.start(box: activeSink, width: Self.defaultStreamSize.w, height: Self.defaultStreamSize.h)
    }

    func startLifecycle() {
        lifecycle = AppLifecycle(client: client, hasActiveRemoteViewer: { [weak self] in
            self?.hasActiveRemoteViewer ?? false
        }, backgroundMode: { [weak self] in
            self?.launchPreferences.effectiveBackgroundMode ?? false
        })
        if let lifecycle { windowController.attach(delegate: lifecycle) }
        AppLifecycle.diagnose("assign-selected-after", window: windowController.existingWindow)
        menuBar = MenuBarController(
            onWake: { [weak self] in self?.wake() },
            onShow: { [weak self] in self?.wake() }
        )
        menuBar?.updateStatus(Self.label(connState))   // 補上 menuBar 建立前已錯過的狀態
        setupBackgroundModeMenu()
        // D2：選單列的 Android 實體鍵。down 之後緊接 up——guest 收到的是一次完整按放，
        // 不是按住不放。sendKey 在未連線時靜默不送（與 sendTap/sendTouches 一致）。
        // D6：走同一條佇列。原本這裡自己開一個 Task 循序 await 兩次——那一對內部確實
        // 有序，但它與鍵位映射送出的事件之間仍然沒有順序，實體鍵可以插進一組 down/up
        // 中間。改走佇列之後「一台 guest 只有一種輸入順序」才是真的。
        menuBar?.onAndroidKey = { [inputQueue] w3c in
            inputQueue.key(.key(w3c), down: true)
            inputQueue.key(.key(w3c), down: false)
        }
        setupFullScreen()
        setupInstanceMenu()
        setupRemoteMenu()
        setupFocusTracking()
        startAudio()
        // guest→host 剪貼簿：經 bridge 防回音後寫 NSPasteboard
        Task { [weak self, client] in
            for await text in client.guestClipboard {
                await MainActor.run { self?.applyGuestClipboard(text) }
            }
        }
        // host→guest：watcher 輪詢 → bridge → 共用 InputQueue 的 clipboard gate
        watcher = ClipboardWatcher { [weak self] text in self?.applyHostClipboard(text) }
        watcher?.start()
        // 背景模式的休眠或叫回視窗要用到 AppLifecycle，所以放在它建立之後。
        applyBackgroundModeAfterStart()
    }

    private func applyGuestClipboard(_ text: String) {
        guard inputQueue.observeGuestClipboard(text) else { return }
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
        inputQueue.hostClipboardChanged(text)
    }

    /// 選單列「喚醒／顯示視窗」與 Dock 圖示點擊（`AppDelegate.applicationShouldHandleReopen`）共用。
    func wake() {
        lifecycle?.wake(showing: windowController.window())
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
