import Foundation
import GRPC
import SwiftProtobuf

/// 門面 actor：連線生命週期（reducer + 健康探測迴圈驅動）、串流掛載、輸入注入、狀態發布。
public actor EmulatorClient {
    private let host: String
    private let port: Int
    private let makeTransport: @Sendable (GrpcChannelBox) -> DisplayTransport
    private let makeHealthProbe: @Sendable (GrpcChannelBox) -> HealthProbe
    private let makeAudioTransport: @Sendable (GrpcChannelBox) -> AudioTransport
    /// MMAP primary transport 的工廠——與 makeTransport（raw RGBA）對稱的注入點，讓
    /// makeDisplayTransport() 的版本選路可以在單元測試中被驗證，不必碰真 channel。
    private let makeMmapTransport: @Sendable (GrpcChannelBox) -> DisplayTransport
    private let backoff: BackoffPolicy
    private let sleeper: @Sendable (Duration) async throws -> Void
    private let randomSource: @Sendable () -> Double
    private let probeTimeout: Duration

    private var state: ConnState = .disconnected
    // 非 private：EmulatorClient+Input.swift（同模組不同檔）的 sendTouches/sendKey 需要讀取
    // channelBox?.client。Swift 的 `private` 是檔案級（含同檔 extension 特例），跨檔 extension
    // 存取需要至少 internal（仍非 public，模組外不可見）。
    var channelBox: GrpcChannelBox?
    private var transport: DisplayTransport?
    private var probe: HealthProbe?
    /// 最近一次健康探測回報的 emulator 版本字串；決定要建哪種 display transport。
    /// 空字串代表未知 → MmapVersionGate 會拒絕 → 走 raw RGBA（保守）。
    private var emulatorVersion = ""
    // P1-e 音訊：與 transport/pump 對稱——audioTransport 隨 channel 建立與拆除，
    // audioTask 是消費 task，audioRing 是 App 端提供的 sink（nil = 不掛載）。
    private var audioTransport: AudioTransport?
    private var audioTask: Task<Void, Never>?
    private var audioRing: AudioRingBuffer?
    private let pump = FramePump()
    private var box: LatestFrameBox?
    private var streamSize = (w: 540, h: 1200)
    private var running = false
    private var loopTask: Task<Void, Never>?
    private var breakCont: AsyncStream<Void>.Continuation?
    private var power: PowerState = .active
    private var clipboardTask: Task<Void, Never>?
    private var clipboardCall: GRPCAsyncServerStreamingCall<
        SwiftProtobuf.Google_Protobuf_Empty, Android_Emulation_Control_ClipData
    >?

    public nonisolated let states: AsyncStream<ConnState>
    private let stateCont: AsyncStream<ConnState>.Continuation
    public nonisolated let powerStates: AsyncStream<PowerState>
    private let powerCont: AsyncStream<PowerState>.Continuation
    public nonisolated let guestClipboard: AsyncStream<String>
    private let guestClipCont: AsyncStream<String>.Continuation

    public init(host: String = "localhost", port: Int = 8554,
                makeTransport: @escaping @Sendable (GrpcChannelBox) -> DisplayTransport
                    = { GrpcStreamTransport(channel: $0) },
                makeHealthProbe: @escaping @Sendable (GrpcChannelBox) -> HealthProbe
                    = { GrpcHealthProbe(channel: $0) },
                makeAudioTransport: @escaping @Sendable (GrpcChannelBox) -> AudioTransport
                    = { GrpcAudioTransport(channel: $0) },
                makeMmapTransport: @escaping @Sendable (GrpcChannelBox) -> DisplayTransport
                    = { MmapStreamTransport(channel: $0) },
                backoff: BackoffPolicy = .init(),
                sleeper: @escaping @Sendable (Duration) async throws -> Void
                    = { try await Task.sleep(for: $0) },
                randomSource: @escaping @Sendable () -> Double
                    = { Double.random(in: 0..<1) },
                probeTimeout: Duration = .seconds(1)) {
        self.host = host
        self.port = port
        self.makeTransport = makeTransport
        self.makeHealthProbe = makeHealthProbe
        self.makeAudioTransport = makeAudioTransport
        self.makeMmapTransport = makeMmapTransport
        self.backoff = backoff
        self.sleeper = sleeper
        self.randomSource = randomSource
        self.probeTimeout = probeTimeout
        (states, stateCont) = AsyncStream.makeStream(of: ConnState.self)
        (powerStates, powerCont) = AsyncStream.makeStream(of: PowerState.self)
        (guestClipboard, guestClipCont) = AsyncStream.makeStream(of: String.self)
    }

    public func start(box: LatestFrameBox, width: Int, height: Int) async {
        self.box = box
        streamSize = (width, height)
        running = true
        loopTask = Task { await self.runConnectionLoop() }
    }

    public func setStreamSize(width: Int, height: Int) async {
        streamSize = (width, height)
        if state == .connected { attachStream() }   // 換源，共用當前 breakCont
    }

    /// App 層（AudioPlayer）提供的音訊 sink。刻意用 setter 而非改 `start` 的簽章——
    /// 改簽章會動到所有既有呼叫端與測試，憑空製造回歸風險。
    public func setAudioSink(_ ring: AudioRingBuffer?) {
        audioRing = ring
        if state == .connected { attachAudio() }
    }

    public func stop() async {
        running = false
        breakCont?.yield()          // 喚醒卡在 connectedRun 的迴圈
        loopTask?.cancel()          // 喚醒卡在 sleeper/probe 的迴圈
        await pump.detach()
        detachAudio()
        _ = step(.stopRequested)    // → .disconnected
        dropChannel()
        loopTask = nil
    }

    public func sendTap(x: Int, y: Int, down: Bool) async {
        guard let client = channelBox?.client else { return }
        var t = Android_Emulation_Control_Touch()
        t.x = Int32(x); t.y = Int32(y); t.identifier = 0; t.pressure = down ? 1024 : 0
        var event = Android_Emulation_Control_TouchEvent()
        event.touches = [t]
        _ = try? await client.sendTouch(event)
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
        // 會使運行中的模擬器崩潰（canary 37.2.1，見 RESULTS-p1b §4）。save-on-suspend
        // 保留為磁碟檢查點（save 正常），但不在 wake 路徑載入。
        if state == .connected { attachStream(); attachAudio() }             // 恢復拉幀/音訊
        setPower(.active)
    }

    private func setPower(_ p: PowerState) {
        power = p
        powerCont.yield(p)
    }

    // MARK: - 純轉移（reducer 語意不變，只發布狀態、回傳 effect）

    private func step(_ event: ConnEvent) -> ConnEffect {
        let (next, effect) = ConnReducer.reduce(state, event)
        state = next
        stateCont.yield(next)
        return effect
    }

    // MARK: - 重連迴圈（非遞迴：消除 P1-a 終審 Minor #7 的 async frame 堆積）

    private func runConnectionLoop() async {
        _ = step(.connectRequested)                 // → .connecting
        while running {
            let ready = ensureChannel()
            let result: HealthResult = ready ? await (probe?.probe(timeout: probeTimeout) ?? .failed) : .failed
            if !running { break }
            if case .healthy(let version) = result {
                emulatorVersion = version           // Task 6 會用到；此刻先存起來
                makeDisplayTransport()
                _ = step(.connectSucceeded)         // → .connected（gate：只有健康才連上）
                startClipboardStream()
                await connectedRun()                // 阻塞到串流斷或 stop
                guard running else { break }
                await pump.detach()
                detachAudio()
                dropChannel()                       // 斷線先 drop 舊 channel（spec §4.1）
                let effect = step(.streamBroken)    // → .reconnecting(0)
                await backoffDelay(effect)
            } else {
                await pump.detach()
                detachAudio()
                dropChannel()                       // 探測失敗也 drop，下一圈重建
                let effect = step(.connectFailed)   // → .reconnecting(n)（attempt 由 reducer 遞增）
                await backoffDelay(effect)
            }
        }
    }

    /// 確保 channel/probe 存在；斷線後 channelBox 已被 dropChannel 清空，此處重建。
    ///
    /// **transport 刻意不在這裡建立**：要建哪種（MMAP 或 raw RGBA）取決於 emulator 版本，
    /// 而版本要等健康探測回報才知道。改由 makeDisplayTransport() 在探測成功後建立。
    private func ensureChannel() -> Bool {
        if channelBox == nil {
            do {
                let boxCh = try GrpcChannelBox(host: host, port: port)
                channelBox = boxCh
                probe = makeHealthProbe(boxCh)
                audioTransport = makeAudioTransport(boxCh)
            } catch {
                return false
            }
        }
        return probe != nil
    }

    /// 依探測回報的 emulator 版本決定 display transport，並印一次性觀測訊息。
    ///
    /// MMAP 需要 ≥37（36.x 收到 MMAP 請求會 SIGSEGV 弄死使用者的 VM，見 MmapVersionGate）。
    /// 過關就用 FallbackTransport 包起來——MMAP 若實際不寫入（前 3 幀全零）會自動無縫
    /// 降級到 raw RGBA，使用者不會看到黑畫面。
    ///
    /// **執行緒安全前提**：`EmulatorClient` 是 actor，本方法與 `attachStream()`（唯一讀取
    /// `transport` 並呼叫 `frames()` 的地方）皆在 actor 隔離下序列執行——`transport` 不會
    /// 被並發讀寫，`frames()` 也不會被並發呼叫。`FallbackTransport.frames()` 內部「是否已
    /// 降級」的檢查在串流閉包外、非鎖保護，僅在「單一訂閱者」的使用契約下才無害；
    /// 若未來有呼叫端脫離這條 actor 序列，需要重新檢視那個檢查。
    private func makeDisplayTransport() {
        guard let boxCh = channelBox else { return }
        if MmapVersionGate.allows(versionString: emulatorVersion) {
            transport = FallbackTransport(primary: makeMmapTransport(boxCh),
                                          secondary: makeTransport(boxCh))
            print("[transport] mmap enabled (emulator \(emulatorVersion))")
        } else {
            transport = makeTransport(boxCh)
            let v = emulatorVersion.isEmpty ? "unknown" : emulatorVersion
            print("[transport] raw rgba (emulator \(v) < 37)")
        }
    }

    /// connected 期間：掛串流並阻塞到第一個斷線訊號（或 stop）。setStreamSize 換源共用同一 breakCont。
    private func connectedRun() async {
        let (signal, cont) = AsyncStream<Void>.makeStream()
        breakCont = cont
        attachStream()
        attachAudio()
        for await _ in signal { break }
        breakCont = nil
    }

    private func attachStream() {
        // 休眠期間不拉幀（即使底層重連）。防禦性 guard：目前碼庫中「休眠期間斷線觸發重連」
        // 這條路徑其實不可達——suspend() 呼叫 pump.detach() 後，FramePump 沒有存活的
        // consumer task，其 onEnd（唯一會 yield breakCont 的來源，見 signalBreak()）
        // 因此永不觸發，connectedRun() 會一直卡在 suspended 期間收不到斷線訊號。仍保留
        // 此 guard 作為未來重構的安全網。
        guard power != .suspended, power != .suspending else { return }
        guard let transport, let box else { return }
        let stream = transport.frames(width: streamSize.w, height: streamSize.h)
        Task {
            await pump.attach(stream, into: box) { [weak self] err in
                guard err != nil else { return }    // 換源正常結束不算斷
                Task { await self?.signalBreak() }
            }
        }
    }

    private func signalBreak() { breakCont?.yield() }

    /// 與 attachStream 對稱：休眠期間不掛載；無 sink（App 未接 AudioPlayer）時靜默不掛。
    private func attachAudio() {
        guard power != .suspended, power != .suspending else { return }
        guard let audioTransport, let audioRing else { return }
        // 先卸再掛（呼叫 detachAudio 而非只 audioTask?.cancel()）：只取消 Swift Task
        // 中斷不了已 in-flight 的底層 gRPC next() ——guest 靜音時它會無限阻塞，若不顯式
        // cancelStream() 就疊上第二個訂閱，舊 call 會被孤兒化（Task 6 審查發現的缺口，
        // GrpcAudioTransport.packets() 已在 transport 層加了重入保護；這裡加第二層防禦）。
        detachAudio()
        // 終審 Minor 6（SPSC 單一生產者不變式，僅加註解不改碼）：AudioRingBuffer 是
        // SPSC（單生產者單消費者），但「單一生產者」在這裡是靠時序維持，不是靠結構
        // 保證——上面的 detachAudio() 只取消了「舊」Task（`audioTask?.cancel()`），
        // Swift 的 Task 取消是協作式的：舊 Task 內部 `for try await chunk in stream`
        // 迴圈要等下一次掛起點才會真正結束，理論上舊 Task 尾聲的 write() 可以跟下面
        // 新建 Task 第一次的 write() 在時間上重疊，讓兩個生產者同時寫同一個 ring。
        // 這在實務上不可達：舊 Task 停止寫入的時機是它自己的 gRPC stream 迭代器
        // 收到取消訊號那一刻（µs 等級的 CPU 排程延遲），而新 Task 第一次 write()
        // 之前必須先完成一次全新的 streamAudio RPC 往返（一次網路 RTT，數 ms 以上）；
        // 兩個時間尺度差了至少三個數量級，經驗上不會重疊。維持這個不變式不需要額外
        // 同步機制——但這是「靠時序」而非「靠結構」，值得對照它為何成立。
        let stream = audioTransport.packets(format: .standard)
        audioTask = Task { [audioRing] in
            do {
                for try await chunk in stream {
                    if Task.isCancelled { return }
                    audioRing.write(chunk.samples)
                }
            } catch {
                // 終審 Important 2：診斷訊號——若音訊 RPC 單獨失敗而連線本身仍健康
                // （health probe 不會因此觸發重連），少了這行音訊會永久靜默且沒有任何
                // 除錯線索（MIRAGE_AUDIO_LOG 只會印 pkt=0，跟 guest 本來就靜音無法區分）。
                // 刻意不在此自行重連——維持 spec 決策，重連只由畫面串流路徑驅動。
                print("[audio] stream ended: \(error)")
                // 串流斷屬正常（連線斷）；重連由既有連線迴圈負責，此處不自行重連。
                // 注意：**無封包 ≠ 斷線**——guest 靜音時本來就沒有封包，
                // 健康探測仍由 HealthProbe 獨佔負責。
            }
        }
    }

    /// 先取消 Swift Task，再顯式取消底層 RPC。後者不可省略：guest 靜音時
    /// streamAudio 會無限阻塞，Task.cancel() 中斷不了已 in-flight 的 next()。
    private func detachAudio() {
        audioTask?.cancel()
        audioTask = nil
        audioTransport?.cancelStream()
    }

    /// 於 step(.connectSucceeded) 後啟動（在 runConnectionLoop 的 .healthy 分支呼叫）；dropChannel 前取消。
    ///
    /// ADAPTATION (found during Task 5 verification, see task-5-report.md): the brief uses
    /// `client.streamClipboard(.init())`, the `EmulatorControllerAsyncClientProtocol` convenience
    /// method that returns only `GRPCAsyncResponseStream<ClipData>` — it discards the underlying
    /// `GRPCAsyncServerStreamingCall`. That response stream's `next()` only checks
    /// `Task.isCancelled` synchronously at the start of each call (see grpc-swift's
    /// GRPCAsyncResponseStream.swift); it never calls `.cancel()` on the real call. So cancelling
    /// `clipboardTask` does NOT interrupt an already in-flight `next()` await and does NOT resolve
    /// the pending NIO promise — verified empirically: with a real emulator holding the stream
    /// open (nothing else yields further clipboard events), `clipboardTask` never completes on its
    /// own. Using `makeStreamClipboardCall(_:)` instead returns the full `GRPCAsyncServerStreamingCall`,
    /// which has a genuine `.cancel()` (calls `self.call.cancel(promise: nil)`, resolving the
    /// in-flight promise). Storing that call lets `dropChannel()` cancel the real RPC before
    /// tearing down the channel's event-loop group, avoiding both a hang (task never finishing)
    /// and the NIO "leaking promise created" fatal crash (group shut down while a promise is
    /// still outstanding).
    private func startClipboardStream() {
        guard let client = channelBox?.client else { return }
        clipboardTask?.cancel()
        let call = client.makeStreamClipboardCall(.init())
        clipboardCall = call
        // Capture only `responseStream` (explicitly `Sendable` in grpc-swift), not `call`
        // itself (non-Sendable — a data-race warning otherwise, since `Task { }` sends its
        // closure across `self`'s actor isolation).
        let stream = call.responseStream
        clipboardTask = Task { [guestClipCont] in
            do {
                for try await clip in stream {
                    if Task.isCancelled { return }
                    guestClipCont.yield(clip.text)
                }
            } catch { /* 串流斷屬正常（連線斷）；由重連迴圈處理，不在此重連 */ }
        }
    }

    private func backoffDelay(_ effect: ConnEffect) async {
        guard case .scheduleReconnect(let attempt) = effect, running else { return }
        let delay = backoff.delay(attempt: attempt, random: randomSource())
        try? await sleeper(delay)
    }

    // ADAPTATION (found during Task 5 verification, see task-5-report.md): the brief's
    // snippet appends `clipboardTask?.cancel(); clipboardTask = nil` AFTER `channelBox = nil`.
    // That order lets `channelBox`'s deinit (`group.syncShutdownGracefully()`) tear down the
    // NIO EventLoopGroup synchronously while the clipboard stream's in-flight promise on that
    // same group may still be unresolved — a real race that intermittently (~1-in-8 runs,
    // reproduced empirically) trips NIO's "leaking promise created" fatal precondition and
    // crashes the whole process. Cancelling `clipboardCall` (the real RPC, not just the Swift
    // Task — see startClipboardStream's ADAPTATION note above) BEFORE releasing the channel
    // resolves that promise synchronously up front, so the group's graceful shutdown has
    // nothing left dangling. dropChannel stays synchronous — no call-site changes needed.
    private func dropChannel() {
        detachAudio()               // 必須在 channelBox = nil 之前：先解決 in-flight
                                     // promise，NIO group 才不會帶著未解決 promise 關閉
                                     // （P1-b 實證約 1/8 機率觸發 leaking promise 致命錯誤）
        audioTransport = nil
        clipboardCall?.cancel()
        clipboardTask?.cancel()
        clipboardTask = nil
        clipboardCall = nil
        transport = nil
        probe = nil
        channelBox = nil            // deinit → group.syncShutdownGracefully()
    }
}
