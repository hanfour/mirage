import Foundation
import MirageCore

struct RemoteMirrorConfiguration: Sendable {
    var host = RemoteServerConfiguration.allInterfaces
    var port = RemoteServerConfiguration.defaultPort
    /// 預設 30 fps（spec 第 3 節）。60 fps 是 `.milliseconds(16)`，由呼叫端決定。
    var pullInterval: Duration = .milliseconds(33)
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

/// server 的 `onKeyframeRequested` 在編碼器存在之前就要綁；用這個盒子晚一步指過去。
private final class RemoteKeyframeRelay: @unchecked Sendable {
    private let lock = NSLock()
    private weak var target: (any RemoteFrameEncoding)?

    func attach(_ encoder: any RemoteFrameEncoding) { lock.lock(); target = encoder; lock.unlock() }

    func request() {
        lock.lock(); let encoder = target; lock.unlock()
        encoder?.requestKeyframe()
    }
}

/// 存取單元 → 幀序號 → `RemoteServer.send`。序號從 1 起，每個 controller 一條。
private final class RemoteAccessUnitSequencer: @unchecked Sendable {
    private let lock = NSLock()
    private let server: RemoteServer
    private var sequence: UInt32 = 0

    init(server: RemoteServer) { self.server = server }

    func deliver(_ unit: H264AccessUnit) {
        lock.lock()
        sequence &+= 1
        let number = sequence
        server.send(accessUnit: unit.annexB, keyframe: unit.isKeyframe, sequence: number)
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
    private let onError: @Sendable (String) -> Void
    private let lock = NSLock()
    private var pullTask: Task<Void, Never>?
    private var stopped = false
    private var framesPulled = 0
    private var framesEncoded = 0
    private var encodeFailures = 0

    init(configuration: RemoteMirrorConfiguration,
         secondary: LatestFrameBox,
         inputQueue: InputQueue,
         makeEncoder: (@escaping @Sendable (H264AccessUnit) -> Void) -> any RemoteFrameEncoding,
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
            onKeyframeRequested: { relay.request() },
            onStateChanged: { state in
                continuation.yield(state)
                onStateChanged(state)
            })
        self.server = server
        let sequencer = RemoteAccessUnitSequencer(server: server)
        let encoder = makeEncoder { sequencer.deliver($0) }
        self.encoder = encoder
        relay.attach(encoder)
    }

    var sessionState: RemoteSessionState { server.sessionState }
    var boundPort: Int? { server.boundPort }
    var host: String { configuration.host }

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
        let task = beginStop()
        task?.cancel()
        if let task { await task.value }
        encoder.invalidate()
        await server.stop()
        stateContinuation.finish()
    }

    /// 同步 helper 取得鎖，避免 async context 的 noasync 診斷。
    /// stop 可能發生在 bind await 期間；install 必須拒絕，不能留下拉取 task。
    private func installPullTask() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return false }
        pullTask = Task.detached { [weak self] in
            guard let self else { return }
            await self.pullLoop()
        }
        return true
    }

    private func beginStop() -> Task<Void, Never>? {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        // 保留 task，重複 stop 的呼叫者也必須等它完成。
        return pullTask
    }

    private func recordPull() { lock.lock(); framesPulled += 1; lock.unlock() }
    private func recordEncoded() { lock.lock(); framesEncoded += 1; lock.unlock() }
    private func recordFailure() { lock.lock(); encodeFailures += 1; lock.unlock() }

    // MARK: - 拉取迴圈

    /// `Task.detached`：不綁任何 actor（比照 `InputQueue` 的幫浦）。沒有 viewer 時只睡覺，
    /// 不 `takeLatest`——`LatestFrameBox` 覆蓋舊幀零成本，而拉了不編碼只是白拷貝。
    private func pullLoop() async {
        let interval = configuration.pullInterval
        while !Task.isCancelled {
            do { try await Task.sleep(for: interval) } catch { return }
            guard server.sessionState.hasVideo, let frame = secondary.takeLatest() else { continue }
            recordPull()
            do {
                try encoder.encode(frame)
                recordEncoded()
            } catch {
                recordFailure()
                onError("編碼失敗：\(error)")
                return
            }
        }
    }
}
