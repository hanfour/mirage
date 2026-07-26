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
    private let backoff: BackoffPolicy
    private let sleeper: @Sendable (Duration) async throws -> Void
    private let randomSource: @Sendable () -> Double
    private let probeTimeout: Duration

    private var state: ConnState = .disconnected
    private var channelBox: GrpcChannelBox?
    private var transport: DisplayTransport?
    private var probe: HealthProbe?
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
        guard power == .active, channelBox != nil else { return }
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
            if result == .healthy {
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

    /// 確保 channel/transport/probe 存在；斷線後 channelBox 已被 dropChannel 清空，此處重建。
    private func ensureChannel() -> Bool {
        if channelBox == nil {
            do {
                let boxCh = try GrpcChannelBox(host: host, port: port)
                channelBox = boxCh
                transport = makeTransport(boxCh)
                probe = makeHealthProbe(boxCh)
                audioTransport = makeAudioTransport(boxCh)
            } catch {
                return false
            }
        }
        return transport != nil && probe != nil
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
        let stream = audioTransport.packets(format: .standard)
        audioTask = Task { [audioRing] in
            do {
                for try await chunk in stream {
                    if Task.isCancelled { return }
                    audioRing.write(chunk.samples)
                }
            } catch {
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

// MARK: - 多指觸控 / 鍵盤注入（Task 6：消費 Task 4 TouchSpec、Task 1 KeyCode）

extension EmulatorClient {
    /// 純建構——供單元測試，不需 channel。
    static func buildTouchEvent(_ touches: [TouchSpec], width: Int, height: Int)
        -> Android_Emulation_Control_TouchEvent
    {
        var event = Android_Emulation_Control_TouchEvent()
        event.touches = touches.map { spec in
            let (gx, gy) = spec.point.guestPixel(width: width, height: height)
            var t = Android_Emulation_Control_Touch()
            t.x = Int32(gx); t.y = Int32(gy)
            t.identifier = Int32(spec.identifier)
            t.pressure = spec.down ? 1024 : 0
            return t
        }
        return event
    }

    /// 純建構——`.mouse` 無對應 KeyboardEvent，回 nil（呼叫端忽略）。
    static func buildKeyEvent(_ code: KeyCode, down: Bool)
        -> Android_Emulation_Control_KeyboardEvent?
    {
        guard case .key(let w3c) = code else { return nil }
        var ev = Android_Emulation_Control_KeyboardEvent()
        ev.eventType = down ? .keydown : .keyup
        ev.key = w3c
        return ev
    }

    public func sendTouches(_ touches: [TouchSpec], width: Int, height: Int) async {
        guard let client = channelBox?.client else { return }
        _ = try? await client.sendTouch(Self.buildTouchEvent(touches, width: width, height: height))
    }

    public func sendKey(_ code: KeyCode, down: Bool) async {
        guard let client = channelBox?.client, let ev = Self.buildKeyEvent(code, down: down) else { return }
        _ = try? await client.sendKey(ev)
    }
}
