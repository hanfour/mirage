import Foundation
import MirageCore

struct RemoteMirrorConfiguration: Sendable {
    var host = RemoteServerConfiguration.allInterfaces
    var port = RemoteServerConfiguration.defaultPort
    /// 預設 30 fps，啟動環境變數可覆寫為 5–60 fps。
    var pullInterval: Duration = .nanoseconds(1_000_000_000 / 30)
    /// 靜止畫面預設每秒 4 次拷貝／硬體編碼，遠低於動態畫面的 30 fps。
    var heartbeatInterval: Duration = .milliseconds(250)
    let token: PairingToken
    let viewerPage: Data

    init(token: PairingToken, viewerPage: Data) {
        self.token = token
        self.viewerPage = viewerPage
    }
}

struct RemoteMirrorStats: Sendable, Equatable {
    let server: RemoteServerStats
    let framesPulled: Int
    let framesEncoded: Int
    let encodeFailures: Int
}

/// server 在 controller 初始化完成前就要綁回呼；弱參照避免循環持有。
private final class RemoteKeyframeRelay: @unchecked Sendable {
    private let lock = NSLock()
    private weak var target: RemoteMirrorController?

    func attach(_ controller: RemoteMirrorController) { lock.lock(); target = controller; lock.unlock() }

    func request() {
        lock.lock(); let controller = target; lock.unlock()
        controller?.requestKeyframe()
    }
}

/// 存取單元 → 幀序號 → `RemoteServer.send`。序號從 1 起，每個 controller 一條。
private final class RemoteAccessUnitSequencer: @unchecked Sendable {
    private let lock = NSLock()
    private let server: RemoteServer
    private var sequence: UInt32 = 0
    private var window = RemoteLatencyWindow()
    private var windowStarted = ContinuousClock.now

    init(server: RemoteServer) { self.server = server }

    func recordPull(age: Duration, transitMs: Double?, heartbeat: Bool) {
        lock.lock(); defer { lock.unlock() }
        window.recordPull(age: age, transitMs: transitMs, heartbeat: heartbeat)
    }

    func publishIfDue(now: ContinuousClock.Instant = .now) {
        lock.lock()
        let interval = now - windowStarted
        guard interval >= .seconds(1) else { lock.unlock(); return }
        let summary = window.drain(interval: interval)
        windowStarted = now
        lock.unlock()
        do { server.sendStats(try JSONEncoder().encode(summary)) }
        catch { print("[remote] 統計 JSON 編碼失敗：\(error)") }
    }

    func deliver(_ unit: H264AccessUnit, started: ContinuousClock.Instant) {
        let arrived = ContinuousClock.now
        lock.lock()
        sequence &+= 1
        let number = sequence
        server.send(accessUnit: unit.annexB, keyframe: unit.isKeyframe, sequence: number)
        window.recordCompletion(encode: arrived - started, send: ContinuousClock.now - arrived)
        lock.unlock()
    }
}

/// 手機遙控的執行期：`LatestFrameBox`（`BroadcastFrameSink.secondary`）→ 拉取迴圈 → 編碼器 →
/// `RemoteServer`；手機觸控 → `InputQueue.touches`（spec 第 2 節設計決定 2：不直接呼叫
/// `EmulatorClient`，兩個並發 Task 各自送會在網路上超車，見 D6）。
///
/// 一個實例對應一個 server 生命週期：`RemoteServer` 只能 `start` 一次，所以「中斷連線／換
/// token」是建新的 controller、沿用同一個 `secondary`。
final class RemoteMirrorController: @unchecked Sendable {
    let secondary: LatestFrameBox
    let token: PairingToken
    /// 單一訂閱者的狀態事件；先送 initial，server stop 後結束。
    /// 直接在 server 回呼送出，不依賴 MainActor 的選單鏡像。
    let states: AsyncStream<RemoteSessionState>
    private let stateContinuation: AsyncStream<RemoteSessionState>.Continuation
    private let configuration: RemoteMirrorConfiguration
    private let server: RemoteServer
    private let encoder: any RemoteFrameEncoding
    private let sequencer: RemoteAccessUnitSequencer
    private let onError: @Sendable (String) -> Void
    private let lock = NSLock()
    // 拉取、重連的立即送幀及 stop/invalidate 共用序列佇列；server／VT 回呼不等待它。
    private let encodingQueue = DispatchQueue(label: "mirage.remote.encoding")
    private var lastFrame: Frame?
    private var lastEncodedAt: ContinuousClock.Instant?
    private var pendingKeyframe = false
    private var encodingFailed = false
    private var pullTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var stopped = false
    private var framesPulled = 0
    private var framesEncoded = 0
    private var encodeFailures = 0

    init(configuration: RemoteMirrorConfiguration,
         secondary: LatestFrameBox,
         inputQueue: InputQueue,
         makeEncoder: () -> any RemoteFrameEncoding,
         onText: @escaping @Sendable (String) -> Void = { _ in },
         onError: @escaping @Sendable (String) -> Void = { _ in },
         onStateChanged: @escaping @Sendable (RemoteSessionState) -> Void = { _ in })
    {
        self.configuration = configuration
        self.secondary = secondary
        self.token = configuration.token
        self.onError = onError
        let (states, continuation) = AsyncStream<RemoteSessionState>.makeStream(bufferingPolicy: .bufferingNewest(8))
        self.states = states
        self.stateContinuation = continuation
        continuation.yield(.initial)
        let relay = RemoteKeyframeRelay()
        let server = RemoteServer(
            configuration: RemoteServerConfiguration(host: configuration.host, port: configuration.port,
                                                     token: configuration.token, viewerPage: configuration.viewerPage),
            onTouches: { inputQueue.touches($0) },
            onText: onText,
            onKey: { code in
                inputQueue.key(code, down: true)
                inputQueue.key(code, down: false)
            },
            onKeyframeRequested: { relay.request() },
            onStateChanged: { state in
                continuation.yield(state)
                onStateChanged(state)
            })
        self.server = server
        self.sequencer = RemoteAccessUnitSequencer(server: server)
        self.encoder = makeEncoder()
        relay.attach(self)
    }

    var sessionState: RemoteSessionState { server.sessionState }
    var boundPort: Int? { server.boundPort }
    var host: String { configuration.host }
    var pullInterval: Duration { configuration.pullInterval }

    func stats() -> RemoteMirrorStats {
        lock.lock(); defer { lock.unlock() }
        return RemoteMirrorStats(server: server.stats(), framesPulled: framesPulled,
                                 framesEncoded: framesEncoded, encodeFailures: encodeFailures)
    }

    /// 埠被佔用時 `server.start()` 拋錯，這裡原樣往上丟，拉取迴圈不啟動。
    func start() async throws -> Int {
        let port = try await server.start()
        guard installPullTask() else {
            await server.stop()
            throw CancellationError()
        }
        return port
    }

    func stop() async {
        let (task, statsTask) = beginStop()
        task?.cancel()
        statsTask?.cancel()
        if let task { await task.value }
        if let statsTask { await statsTask.value }
        await withCheckedContinuation { continuation in
            encodingQueue.async {
                self.encoder.invalidate()
                self.lastFrame = nil
                continuation.resume()
            }
        }
        await server.stop()
        stateContinuation.finish()
    }

    /// 同步 helper 取得鎖，避免 async context 的 noasync 診斷。
    /// stop 可能發生在 bind await 期間；install 必須拒絕，不能留下拉取 task。
    private func installPullTask() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return false }
        // 獨立計時，不讓慢編碼或沒有新幀遮住每秒統計。
        let sequencer = self.sequencer
        statsTask = Task.detached {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                sequencer.publishIfDue()
            }
        }
        pullTask = Task.detached { [weak self] in
            guard let self else { return }
            await self.pullLoop()
        }
        return true
    }

    private func beginStop() -> (Task<Void, Never>?, Task<Void, Never>?) {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        // 保留 task，重複 stop 的呼叫者也必須等它完成。
        return (pullTask, statsTask)
    }

    private func recordPull() { lock.lock(); framesPulled += 1; lock.unlock() }
    private func recordEncoded() { lock.lock(); framesEncoded += 1; lock.unlock() }
    private func recordFailure() { lock.lock(); encodeFailures += 1; lock.unlock() }

    // MARK: - 拉取迴圈

    /// 新 viewer 的 false → true 會由 server 立即要求 keyframe；不等拉取 tick。
    /// flush 後的補幀請求也走同一路徑。沒有可用幀時保留請求直到第一幀抵達。
    func requestKeyframe() {
        encodingQueue.async { [weak self] in
            guard let self, self.canEncode, self.server.sessionState.hasVideo else { return }
            self.pendingKeyframe = true
            self.encoder.requestKeyframe()
            _ = self.pullAndEncode()
        }
    }

    private var canEncode: Bool {
        lock.lock(); defer { lock.unlock() }
        return !stopped && !encodingFailed
    }

    /// 僅在 encodingQueue 上執行。心跳用快取像素，但更新 PTS；新幀若早於上次心跳，
    /// 也需抬高 PTS，避免 VideoToolbox 收到重複／倒退的時間戳。
    private func pullAndEncode() -> Bool {
        guard canEncode else { return false }
        guard server.sessionState.hasVideo else { return true }
        let fresh = secondary.takeLatest()
        let now = ContinuousClock.now
        if let fresh {
            lastFrame = fresh
            recordPull()
        }
        let heartbeatDue = lastEncodedAt.map { now - $0 >= configuration.heartbeatInterval } ?? true
        guard fresh != nil || pendingKeyframe || heartbeatDue, let cached = lastFrame else { return true }
        // 心跳與間歇的新幀不要求 IDR；只有 viewer 的明確請求走 requestKeyframe。
        // 尺寸重建與 MaxKeyFrameInterval 則由編碼器自身決定。
        let pts: ContinuousClock.Instant
        if fresh == nil || lastEncodedAt.map({ cached.receivedAt <= $0 }) == true {
            pts = now
        } else {
            pts = cached.receivedAt
        }
        let frame = Frame(width: cached.width, height: cached.height, rgba: cached.rgba,
                          receivedAt: pts, transitMs: cached.transitMs)
        do {
            let sequencer = self.sequencer
            sequencer.recordPull(age: now - cached.receivedAt, transitMs: cached.transitMs, heartbeat: fresh == nil)
            let started = ContinuousClock.now
            try encoder.encode(frame) { unit in sequencer.deliver(unit, started: started) }
            lastEncodedAt = now
            pendingKeyframe = false
            recordEncoded()
            return true
        } catch {
            lock.lock(); encodingFailed = true; lock.unlock()
            recordFailure()
            onError("編碼失敗：\(error)")
            return false
        }
    }

    /// 沒有 viewer 時不 takeLatest／不編碼；每次等待工作完成，不累積過期 tick。
    private func pullLoop() async {
        while !Task.isCancelled {
            do { try await Task.sleep(for: configuration.pullInterval) } catch { return }
            let keepPulling: Bool = await withCheckedContinuation { continuation in
                encodingQueue.async { continuation.resume(returning: self.pullAndEncode()) }
            }
            if !keepPulling { return }
        }
    }
}
