import Foundation
import GRPC
import SwiftProtobuf

/// 門面 actor：連線生命週期（reducer + 健康探測迴圈驅動）、串流掛載、輸入注入、狀態發布。
public actor EmulatorClient {
    // 連線迴圈拆在 EmulatorClient+Connection.swift；共用狀態維持 internal、由同一 actor 隔離。
    /// 連線目標。切換模擬器時由 `setEndpoint` 改寫；`ensureChannel()` 每次重建 channel 都讀它。
    var endpoint: EmulatorEndpoint
    let makeTransport: @Sendable (GrpcChannelBox) -> DisplayTransport
    let makeHealthProbe: @Sendable (GrpcChannelBox) -> HealthProbe
    let makeAudioTransport: @Sendable (GrpcChannelBox) -> AudioTransport
    /// MMAP primary transport 的工廠——與 makeTransport（raw RGBA）對稱的注入點，讓
    /// makeDisplayTransport() 的版本選路可以在單元測試中被驗證，不必碰真 channel。
    let makeMmapTransport: @Sendable (GrpcChannelBox) -> DisplayTransport
    let backoff: BackoffPolicy
    let sleeper: @Sendable (Duration) async throws -> Void
    let randomSource: @Sendable () -> Double
    let probeTimeout: Duration

    var state: ConnState = .disconnected
    // 非 private：EmulatorClient+Input.swift（同模組不同檔）的 sendTouches/sendKey 需要讀取
    // channelBox?.client。Swift 的 `private` 是檔案級（含同檔 extension 特例），跨檔 extension
    // 存取需要至少 internal（仍非 public，模組外不可見）。
    var channelBox: GrpcChannelBox?
    var transport: DisplayTransport?
    var probe: HealthProbe?
    /// 最近一次健康探測回報的 emulator 版本字串；決定要建哪種 display transport。
    /// 空字串代表未知 → MmapVersionGate 會拒絕 → 走 raw RGBA（保守）。
    var emulatorVersion = ""
    /// 同一次探測帶出的 guest 實體螢幕解析度，觸控座標換算的唯一權威。
    /// nil = 探測沒帶出可用的 hw.lcd.*，此時觸控注入一律放棄（見 sendTap）。
    ///
    /// 非 private（同 channelBox 的理由）：`EmulatorClient+Input.swift`（同模組不同檔）的
    /// `sendTouches` 需要讀它，而 Swift 的 `private` 是檔案級的。
    var guestDisplay: (w: Int, h: Int)?
    // P1-e 音訊：與 transport/pump 對稱——audioTransport 隨 channel 建立與拆除，
    // audioTask 是消費 task，audioRing 是 App 端提供的 sink（nil = 不掛載）。
    var audioTransport: AudioTransport?
    var audioTask: Task<Void, Never>?
    var audioRing: (any AudioSink)?
    let pump = FramePump()
    var box: (any FrameSink)?
    var streamSize = (w: 540, h: 1200)
    var displayRotation = 0
    var running = false
    private var loopTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    var breakCont: AsyncStream<Void>.Continuation?
    var power: PowerState = .active

    /// 連線路徑診斷。這條路徑先前沒有任何可觀測性——App 層唯一的訊號是
    /// `MIRAGE_FPS_LOG` 的 `fps=`，而它同時受渲染與收幀影響，兩者都沒發生時
    /// 分不出是「沒連上」「連上但沒拉幀」還是「拉到幀但沒畫」。P1-a 到 P1-e
    /// 三個階段都卡在這個盲區（見 RESULTS-p1a.md「pending-unlock」）。
    let connLog = ProcessInfo.processInfo.environment["MIRAGE_CONN_LOG"] == "1"
    // 非 private（同理見上方 channelBox 的說明）：EmulatorClient+Lifecycle.swift 的
    // startClipboardStream() 需要讀寫 clipboardTask/clipboardCall，讀取 guestClipCont。
    var clipboardTask: Task<Void, Never>?
    var clipboardCall: GRPCAsyncServerStreamingCall<
        SwiftProtobuf.Google_Protobuf_Empty, Android_Emulation_Control_ClipData
    >?

    public nonisolated let states: AsyncStream<ConnState>
    let stateCont: AsyncStream<ConnState>.Continuation
    public nonisolated let powerStates: AsyncStream<PowerState>
    private let powerCont: AsyncStream<PowerState>.Continuation
    public nonisolated let guestClipboard: AsyncStream<String>
    let guestClipCont: AsyncStream<String>.Continuation

    /// 預設連線目標：從環境解析（`MIRAGE_HOST` / `MIRAGE_PORT`），不再寫死 `localhost:8554`。
    ///
    /// `EmulatorEndpoint.resolve` 早就存在且有 9 條單元測試，但**只接在 `AppModel` 上**——
    /// 所有用 `EmulatorClient()` 的呼叫端（也就是全部的測試）仍打寫死的 `localhost:8554`。
    /// 後果是整個測試套件**從來沒有在「本機沒有模擬器」的條件下被驗證過**，而那正是 CI
    /// runner 的條件。接上之後 `MIRAGE_PORT=<沒人監聽的埠> swift test` 就是一次確定性的
    /// hermetic 驗證，見 `scripts/ci.sh`。
    ///
    /// 讀環境變數的副作用留在這裡、不塞進 `resolve` 裡——維持 `EmulatorEndpoint` 的純函式
    /// 性質（同檔既有的 `connLog` 也是這樣直接讀環境）。`static let` 而非每次呼叫都解析：
    /// 同一個行程內端點不會變，且讓 `overrideProblem` 只需被回報一次。
    public static let defaultEndpoint = EmulatorEndpoint.resolve(
        environment: ProcessInfo.processInfo.environment)

    public init(host: String = EmulatorClient.defaultEndpoint.host,
                port: Int = EmulatorClient.defaultEndpoint.port,
                makeTransport: @escaping @Sendable (GrpcChannelBox) -> DisplayTransport
                    = { GrpcStreamTransport(channel: $0) },
                makeHealthProbe: @escaping @Sendable (GrpcChannelBox) -> HealthProbe
                    = { GrpcHealthProbe(channel: $0) },
                makeAudioTransport: @escaping @Sendable (GrpcChannelBox) -> AudioTransport
                    = { channel in
                        let base = GrpcAudioTransport(channel: channel)
                        let env = ProcessInfo.processInfo.environment
                        if env["MIRAGE_AUDIO_REOPEN"] == "1" {
                            return AudioReopenTransport(base: base,
                                startEpoch: env["MIRAGE_AUDIO_REOPEN_START_EPOCH"].flatMap(Double.init))
                        }
                        return base
                    },
                makeMmapTransport: @escaping @Sendable (GrpcChannelBox) -> DisplayTransport
                    = { MmapStreamTransport(channel: $0) },
                backoff: BackoffPolicy = .init(),
                sleeper: (@Sendable (Duration) async throws -> Void)? = nil,
                randomSource: @escaping @Sendable () -> Double
                    = { Double.random(in: 0..<1) },
                probeTimeout: Duration = .seconds(1)) {
        self.endpoint = EmulatorEndpoint(host: host, port: port)
        self.makeTransport = makeTransport
        self.makeHealthProbe = makeHealthProbe
        self.makeAudioTransport = makeAudioTransport
        self.makeMmapTransport = makeMmapTransport
        self.backoff = backoff
        // D74：把預設 async 閉包留在非 inlinable 的 init 本體，避免跨模組複製。
        // 已確認為 Swift #92017：public 預設引數的 async 閉包在定義與呼叫端模組各編一份，
        // async context 大小分別為 MirageCore 144 bytes、呼叫端 128 bytes。
        // linker 混用本體與 Tu 大小描述會寫壞 task allocator metadata，直到呼叫者
        // swift_task_dealloc 才 abort：https://github.com/swiftlang/swift/issues/92017
        // 外部驗證修正前測試 3/3 失敗、修正後 3/3 通過；測試執行檔連到不一致的一對。
        // app 目前不發作只是連結時剛好選到一致的一對，換連結順序也可能發作。
        // nil 只代表採用預設 sleeper；實際儲存與呼叫的型別、sleep 與取消語意不變。
        if let sleeper {
            self.sleeper = sleeper
        } else {
            self.sleeper = { try await Task.sleep(for: $0) }
        }
        self.randomSource = randomSource
        self.probeTimeout = probeTimeout
        (states, stateCont) = AsyncStream.makeStream(of: ConnState.self)
        (powerStates, powerCont) = AsyncStream.makeStream(of: PowerState.self)
        (guestClipboard, guestClipCont) = AsyncStream.makeStream(of: String.self)
    }

    /// 啟動連線迴圈。**已在跑時忽略重複呼叫**（D30）。
    ///
    /// 原本這裡直接覆寫 `loopTask`：舊 Task 既不取消、`running` 也還是 true，於是舊迴圈
    /// 繼續跑，兩條連線迴圈同時對同一個 actor 搶 `attachStream()`。當時的觸發路徑是 App 層
    /// 啟動序列掛在 `WindowGroup` 的 `.task` 上——`.task` 每個視窗跑一次，而 `AppModel`
    /// 整個 App 只有一份，開第二個視窗（⌘N）就會對同一個 client 再 `start()` 一次。
    /// 現在啟動改由 `AppDelegate` 呼叫 `AppModel.launch()`，只跑一次；這道防護保留。
    ///
    /// **選擇忽略而不是「先 stop 再 start」**：呼叫端傳的是同一個 box 與同一組尺寸，
    /// 重啟只會平白斷一次線；要換串流尺寸有 `setStreamSize` 專門負責。`stop()` 會把
    /// `running` 放回 false，所以「停掉之後重新啟動」這條正常路徑不受影響。
    ///
    /// **印出來是刻意的**：視窗那一側改用單一實例的 `Window` 之後這個狀態應該不可能
    /// 發生，而一旦發生就代表有人重新引入了多重啟動——靜默忽略會讓那件事再一次
    /// 沒有訊號，而「沒有訊號」正是 D30 能藏這麼久的原因。
    public func start(box: any FrameSink, width: Int, height: Int) async {
        guard !running, stopTask == nil else {
            print("[conn] start() 重複呼叫，已忽略（已有連線迴圈在跑）——上游不該走到這裡，見 D30")
            return
        }
        self.box = box
        streamSize = (width, height)
        running = true
        loopTask = Task { await self.runConnectionLoop() }
    }

    public func setStreamSize(width: Int, height: Int) async {
        streamSize = (width, height)
        if state == .connected { attachStream() }   // 換源，共用當前 breakCont
    }

    /// 設定 guest 顯示方向；觸控座標仍以面板解析度為基準。
    public func setDisplayRotation(_ rotation: Int) {
        guard (0...3).contains(rotation) else { return }
        displayRotation = rotation
    }

    /// App 層（AudioPlayer）提供的音訊 sink。刻意用 setter 而非改 `start` 的簽章——
    /// 改簽章會動到所有既有呼叫端與測試，憑空製造回歸風險。
    public func setAudioSink(_ ring: (any AudioSink)?) {
        audioRing = ring
        if state == .connected { attachAudio() }
    }

    public func stop() async {
        if let stopTask {
            await stopTask.value
            return
        }
        running = false
        let task = Task { await self.finishStopping() }
        stopTask = task
        await task.value
    }

    /// 等待期間 actor 可重入；共用 stopTask 讓重複 stop 等同一輪清理，並擋住 start / setEndpoint。
    private func finishStopping() async {
        breakCont?.yield()          // 喚醒卡在 connectedRun 的迴圈
        loopTask?.cancel()          // 喚醒卡在 sleeper/probe 的迴圈
        // **等舊迴圈真的結束**（2026-09-12，模擬器切換）。原本這裡不等：迴圈若正卡在
        // `probe(timeout:)`，stop() 回來、緊接的 start() 把 running 設回 true 之後它才醒來，
        // runConnectionLoop 的 `if !running { break }` 看到的是 true，接著 dropChannel()
        // 拆掉的是**新迴圈**剛建好的 channel，然後兩條迴圈同時跑。單台時 stop 之後從來
        // 沒有立刻 start 過，所以沒踩到；切換會每次都踩。迴圈的每個 await 之後都檢查
        // running，上面兩行保證它最多再等一次 probeTimeout 就走到那個檢查。
        await loopTask?.value
        loopTask = nil
        await pump.detach()
        detachAudio()
        _ = step(.stopRequested)    // → .disconnected
        dropChannel()
        // 停下來的 client 不知道任何 guest 的事：下一台的解析度與版本要等它自己的探測。
        // 留著舊值，sendTap 會在新 channel 建好、探測還沒回來的那一秒用舊解析度換算座標。
        guestDisplay = nil
        emulatorVersion = ""
        stopTask = nil
    }

    /// 直接注入單點觸控，座標為**正規化轉正座標的 0–1**（左上原點）。
    ///
    /// **刻意不接受絕對像素**：`Touch.x/y` 的座標系是 guest 的實體螢幕（proto 明載
    /// "physical location on the screen"），而 App 層手上只有串流幀尺寸與視窗尺寸，
    /// 兩者都不是它。原本由呼叫端自行換算，結果整條路徑一直乘錯數字——串流 540x1200
    /// 對 guest 1080x2400，每一次點擊都落在目標的左上一半處。把換算收進這裡之後，
    /// 呼叫端**沒有機會**再傳錯尺寸（見 §10 的調查記錄）。
    ///
    /// `guestDisplay` 未知時**靜默不送**：送一個用錯尺寸算出的座標比不送更糟——
    /// 畫面會有反應但點在錯的地方，而使用者會以為是遊戲的問題。
    public func sendTap(nx: Double, ny: Double, down: Bool) async {
        guard let client = channelBox?.client, let display = guestDisplay else { return }
        let point = DisplayRotation.panelPoint(fromUpright: NormPoint(x: nx, y: ny),
                                               rotation: displayRotation)
        let (gx, gy) = point.guestPixel(width: display.w, height: display.h)
        var t = Android_Emulation_Control_Touch()
        t.x = Int32(gx); t.y = Int32(gy); t.identifier = 0; t.pressure = down ? 1024 : 0
        var event = Android_Emulation_Control_TouchEvent()
        event.touches = [t]
        _ = try? await client.sendTouch(event)
    }

    /// guest 的實體螢幕解析度（健康探測帶出）。供 App 層在需要真實尺寸時查詢——
    /// 但**觸控注入不需要它**，換算已收進 sendTap/sendTouches。
    public var displaySize: (w: Int, h: Int)? { guestDisplay }

    /// 目前的連線目標。切換模擬器時由 `setEndpoint` 改寫。
    public var currentEndpoint: EmulatorEndpoint { endpoint }

    /// 連線迴圈是否在跑（`start()` 之後、`stop()` 之前）。
    public var isRunning: Bool { running }

    /// 最近一次要求的串流尺寸（`start` 或 `setStreamSize` 設的）。切換模擬器後重新 `start`
    /// 要沿用它——全螢幕下 MirrorView 已把尺寸換成內容矩形，退回預設會讓畫面糊掉且沒有訊號。
    public var requestedStreamSize: (w: Int, h: Int) { streamSize }

    /// 換連線目標。**只在停下來時允許。** 迴圈在跑時換，舊 channel 會用到下一次重連才換——
    /// 那是「狀態說已切換、畫面還是舊那台」的無訊號故障。回 false 表示沒換；印出來的
    /// 理由與 `start()` 對重複呼叫的處理相同：上游不該走到這裡，走到了要有訊號。
    @discardableResult
    public func setEndpoint(_ target: EmulatorEndpoint) -> Bool {
        guard !running, stopTask == nil else {
            print("[conn] setEndpoint(\(target.host):\(target.port)) 被忽略：連線迴圈在跑或停止中，先等 stop() 再換")
            return false
        }
        endpoint = target
        return true
    }

    public func setGuestClipboard(_ text: String) async {
        guard let client = channelBox?.client else { return }
        var clip = Android_Emulation_Control_ClipData()
        clip.text = text
        _ = try? await client.setClipboard(clip)
    }

    // MARK: - 電源（休眠/喚醒）：channelBox 維持不動，供 wake() 沿用同一連線

    public func suspend() async {
        // 終審 Important 1：不再看 channelBox != nil。原本這半條 guard 會在「dropChannel()
        // 之後、下一次 ensureChannel() 之前」（重連退避期間，可達數秒）提早 return——此時
        // channelBox 為 nil，但 AppLifecycle.windowShouldClose 已經把視窗 orderOut(nil)
        // 隱藏了。power 因此卡在 .active，等重連成功 connectedRun() 照常呼叫
        // attachStream()/attachAudio()，使用者會在看不到視窗的情況下聽到遊戲聲音，直接
        // 違反 spec §4.7「休眠（關視窗）→ detachAudio()」的合約。拿掉這半條是安全的：
        // pump.detach()/detachAudio()/setPower 在無 channel 時皆為 no-op，wake() 也已用
        // `if state == .connected` 自行處理未連線的情形，不需要靠這裡的 guard 防呆。
        guard power == .active else { return }
        setPower(.suspending)
        await pump.detach()                 // 停止拉幀（省 app 端 CPU；qemu 仍在跑）
        detachAudio()                       // 關視窗即靜音（音訊跟畫面走）
        setPower(.suspended)
    }

    public func wake() async {
        guard power == .suspended else { return }
        setPower(.waking)
        // spec §8：suspend 期間 qemu 仍在跑，故 wake 只恢復拉幀，不 load 快照。
        // 載入快照會 rewind、丟失 suspend 期間的 guest 狀態；且活體實測 loadSnapshot
        // 會使運行中的模擬器崩潰（canary 37.2.1，見 RESULTS-p1b §4）。
        // 現在完全不碰快照，suspend 也不儲存快照；SnapshotSaving／GrpcSnapshotService
        // 已於 2026-09-09 隨 D14／D31 刪除。
        if state == .connected { attachStream(); attachAudio() }             // 恢復拉幀/音訊
        setPower(.active)
    }

    private func setPower(_ p: PowerState) {
        if connLog { print("[conn] power \(power)-->\(p)") }
        power = p
        powerCont.yield(p)
    }

}
