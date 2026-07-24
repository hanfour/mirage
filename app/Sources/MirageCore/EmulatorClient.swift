import Foundation

/// 門面 actor：連線生命週期（reducer + 健康探測迴圈驅動）、串流掛載、輸入注入、狀態發布。
public actor EmulatorClient {
    private let host: String
    private let port: Int
    private let makeTransport: @Sendable (GrpcChannelBox) -> DisplayTransport
    private let makeHealthProbe: @Sendable (GrpcChannelBox) -> HealthProbe
    private let backoff: BackoffPolicy
    private let sleeper: @Sendable (Duration) async throws -> Void
    private let randomSource: @Sendable () -> Double
    private let probeTimeout: Duration

    private var state: ConnState = .disconnected
    private var channelBox: GrpcChannelBox?
    private var transport: DisplayTransport?
    private var probe: HealthProbe?
    private let pump = FramePump()
    private var box: LatestFrameBox?
    private var streamSize = (w: 540, h: 1200)
    private var running = false
    private var loopTask: Task<Void, Never>?
    private var breakCont: AsyncStream<Void>.Continuation?

    public nonisolated let states: AsyncStream<ConnState>
    private let stateCont: AsyncStream<ConnState>.Continuation

    public init(host: String = "localhost", port: Int = 8554,
                makeTransport: @escaping @Sendable (GrpcChannelBox) -> DisplayTransport
                    = { GrpcStreamTransport(channel: $0) },
                makeHealthProbe: @escaping @Sendable (GrpcChannelBox) -> HealthProbe
                    = { GrpcHealthProbe(channel: $0) },
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
        self.backoff = backoff
        self.sleeper = sleeper
        self.randomSource = randomSource
        self.probeTimeout = probeTimeout
        (states, stateCont) = AsyncStream.makeStream(of: ConnState.self)
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

    public func stop() async {
        running = false
        breakCont?.yield()          // 喚醒卡在 connectedRun 的迴圈
        loopTask?.cancel()          // 喚醒卡在 sleeper/probe 的迴圈
        await pump.detach()
        _ = step(.stopRequested)    // → .disconnected
        dropChannel()
        loopTask = nil
    }

    public func sendTap(x: Int, y: Int, down: Bool) async {
        guard let client = channelBox?.client else { return }
        var touch = Android_Emulation_Control_Touch()
        touch.x = Int32(x); touch.y = Int32(y)
        touch.identifier = 0
        touch.pressure = down ? 1024 : 0
        var event = Android_Emulation_Control_TouchEvent()
        event.touches = [touch]
        _ = try? await client.sendTouch(event)
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
                await connectedRun()                // 阻塞到串流斷或 stop
                guard running else { break }
                await pump.detach()
                dropChannel()                       // 斷線先 drop 舊 channel（spec §4.1）
                let effect = step(.streamBroken)    // → .reconnecting(0)
                await backoffDelay(effect)
            } else {
                await pump.detach()
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
        for await _ in signal { break }
        breakCont = nil
    }

    private func attachStream() {
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

    private func backoffDelay(_ effect: ConnEffect) async {
        guard case .scheduleReconnect(let attempt) = effect, running else { return }
        let delay = backoff.delay(attempt: attempt, random: randomSource())
        try? await sleeper(delay)
    }

    private func dropChannel() {
        transport = nil
        probe = nil
        channelBox = nil            // deinit → group.syncShutdownGracefully()
    }
}
