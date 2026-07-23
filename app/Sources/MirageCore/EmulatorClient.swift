import Foundation

/// 門面 actor：連線生命週期（reducer 驅動）、串流掛載、輸入注入、狀態發布。
public actor EmulatorClient {
    private let host: String
    private let port: Int
    private let makeTransport: @Sendable (GrpcChannelBox) -> DisplayTransport
    private let backoff: BackoffPolicy
    private let sleeper: @Sendable (Duration) async throws -> Void
    private let randomSource: @Sendable () -> Double

    private var state: ConnState = .disconnected
    private var channelBox: GrpcChannelBox?
    private var transport: DisplayTransport?
    private let pump = FramePump()
    private var box: LatestFrameBox?
    private var streamSize = (w: 540, h: 1200)
    private var running = false

    public nonisolated let states: AsyncStream<ConnState>
    private let stateCont: AsyncStream<ConnState>.Continuation

    public init(host: String = "localhost", port: Int = 8554,
                makeTransport: @escaping @Sendable (GrpcChannelBox) -> DisplayTransport
                    = { GrpcStreamTransport(channel: $0) },
                backoff: BackoffPolicy = .init(),
                sleeper: @escaping @Sendable (Duration) async throws -> Void
                    = { try await Task.sleep(for: $0) },
                randomSource: @escaping @Sendable () -> Double
                    = { Double.random(in: 0..<1) }) {
        self.host = host
        self.port = port
        self.makeTransport = makeTransport
        self.backoff = backoff
        self.sleeper = sleeper
        self.randomSource = randomSource
        (states, stateCont) = AsyncStream.makeStream(of: ConnState.self)
    }

    public func start(box: LatestFrameBox, width: Int, height: Int) async {
        self.box = box
        streamSize = (width, height)
        running = true
        await apply(.connectRequested)
    }

    public func setStreamSize(width: Int, height: Int) async {
        streamSize = (width, height)
        if state == .connected { attachStream() }
    }

    public func stop() async {
        running = false
        await pump.detach()
        await apply(.stopRequested)
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

    // MARK: - reducer 驅動

    private func apply(_ event: ConnEvent) async {
        let (next, effect) = ConnReducer.reduce(state, event)
        state = next
        stateCont.yield(next)
        switch effect {
        case .startConnect:
            await doConnect()
        case .scheduleReconnect(let attempt):
            guard running else { return }
            let delay = backoff.delay(attempt: attempt, random: randomSource())
            try? await sleeper(delay)
            guard running else { return }
            await doConnect()
        case .none:
            break
        }
    }

    private func doConnect() async {
        do {
            if transport == nil {
                // 測試路徑：makeTransport 可完全忽略 channelBox；
                // 生產路徑：建 channel 供 transport 與輸入共用。
                let boxCh = try GrpcChannelBox(host: host, port: port)
                channelBox = boxCh
                transport = makeTransport(boxCh)
            }
            await apply(.connectSucceeded)
            attachStream()
        } catch {
            await apply(.connectFailed)
        }
    }

    private func attachStream() {
        guard let transport, let box else { return }
        let stream = transport.frames(width: streamSize.w, height: streamSize.h)
        Task {
            await pump.attach(stream, into: box) { [weak self] err in
                guard err != nil else { return }  // 正常結束（換源）不觸發重連
                Task { await self?.streamBroke() }
            }
        }
    }

    private func streamBroke() async {
        guard running else { return }
        await apply(.streamBroken)
    }
}
