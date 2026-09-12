import Foundation
import NIOCore

public struct RemoteServerConfiguration: Sendable {
    public static let defaultPort = 8765
    public static let allInterfaces = "0.0.0.0"

    public let host: String
    public let port: Int
    public let token: PairingToken
    public let viewerPage: Data
    public let queueLimit: Int

    public init(host: String = allInterfaces, port: Int = defaultPort, token: PairingToken, viewerPage: Data,
                queueLimit: Int = RemoteVideoQueue.defaultLimit)
    {
        self.host = host
        self.port = port
        self.token = token
        self.viewerPage = viewerPage
        self.queueLimit = queueLimit
    }
}

public struct RemoteServerStats: Sendable, Equatable {
    public let framesOffered: Int
    public let framesSent: Int
    public let framesDropped: Int
    public let rejectedForbidden: Int
    public let rejectedBusy: Int
    public let invalidInputMessages: Int
    public let touchesForwarded: Int
}

enum RemoteUpgradeKind: Sendable {
    case video
    case input
}

/// `RemoteServer` 的全部可變狀態，一把鎖（比照 `LatestFrameBox`）。
///
/// reducer 在鎖內套用、效果（回呼）一律在鎖外執行，避免回呼再進來拿鎖。每條子 channel 都
/// 在 `track` 登記，`closeFuture` 觸發 `channelClosed`，所以 video／input 的關閉只有一條路徑。
final class RemoteServerCore: @unchecked Sendable {
    static let invalidLogInterval: Duration = .seconds(1)

    let configuration: RemoteServerConfiguration
    private let onTouches: @Sendable ([TouchSpec]) -> Void
    private let onKeyframeRequested: @Sendable () -> Void
    private let onStateChanged: @Sendable (RemoteSessionState) -> Void
    private let now: @Sendable () -> ContinuousClock.Instant

    private let lock = NSLock()
    private var session = RemoteSessionState.initial
    private var queue: RemoteVideoQueue
    private var allocator = RemoteTouchIdentifierAllocator()
    private var stopped = false
    private var rejectedRoutes: [ObjectIdentifier: RemoteRoute] = [:]
    private var pendingEffects: [@Sendable () -> Void] = []
    private var performingEffects = false
    private var kinds: [ObjectIdentifier: RemoteUpgradeKind] = [:]
    private var channels: [ObjectIdentifier: any Channel] = [:]
    private var wakeup: AsyncStream<Void>.Continuation?
    private var framesOffered = 0
    private var framesSent = 0
    private var framesDroppedBeforeReset = 0   // 佇列被 requestKeyframe 重置前累積的丟幀
    private var rejectedForbidden = 0
    private var rejectedBusy = 0
    private var invalidInputMessages = 0
    private var touchesForwarded = 0
    private var lastInvalidLog: ContinuousClock.Instant?

    init(configuration: RemoteServerConfiguration,
         onTouches: @escaping @Sendable ([TouchSpec]) -> Void,
         onKeyframeRequested: @escaping @Sendable () -> Void,
         onStateChanged: @escaping @Sendable (RemoteSessionState) -> Void,
         now: @escaping @Sendable () -> ContinuousClock.Instant)
    {
        self.configuration = configuration
        self.onTouches = onTouches
        self.onKeyframeRequested = onKeyframeRequested
        self.onStateChanged = onStateChanged
        self.now = now
        queue = RemoteVideoQueue(limit: configuration.queueLimit)
    }

    // MARK: - 查詢

    var sessionState: RemoteSessionState {
        lock.lock(); defer { lock.unlock() }
        return session
    }

    func snapshot() -> RemoteServerStats {
        lock.lock(); defer { lock.unlock() }
        return RemoteServerStats(framesOffered: framesOffered, framesSent: framesSent,
                                 framesDropped: framesDroppedBeforeReset + queue.dropped,
                                 rejectedForbidden: rejectedForbidden, rejectedBusy: rejectedBusy,
                                 invalidInputMessages: invalidInputMessages, touchesForwarded: touchesForwarded)
    }

    // MARK: - 連線生命週期

    func route(channelID: ObjectIdentifier, method: String, uri: String) -> RemoteRoute {
        lock.lock(); defer { lock.unlock() }
        // shouldUpgrade 拒絕時的決定不可因原連線剛好離開而從 409 變成 426。
        return rejectedRoutes[channelID]
            ?? RemoteRequestRouter.route(method: method, uri: uri, token: configuration.token, state: session)
    }

    /// `shouldUpgrade` 呼叫：鎖內路由＋保留名額。回 nil 代表拒絕，NIO 會把請求交回 HTTP 路徑算狀態碼。
    func admitUpgrade(channel: any Channel, method: String, uri: String) -> RemoteUpgradeKind? {
        lock.lock()
        guard !stopped, channels[ObjectIdentifier(channel)] != nil else { lock.unlock(); return nil }
        let route = RemoteRequestRouter.route(method: method, uri: uri, token: configuration.token, state: session)
        let kind: RemoteUpgradeKind?
        switch route {
        case .upgradeVideo: kind = .video
        case .upgradeInput: kind = .input
        default: kind = nil
        }
        guard let kind else {
            rejectedRoutes[ObjectIdentifier(channel)] = route
            lock.unlock()
            return nil
        }
        kinds[ObjectIdentifier(channel)] = kind
        let effects = applyLocked(kind == .video ? .videoOpened : .inputOpened)
        pendingEffects.append(contentsOf: effects)
        lock.unlock()
        performEffects()
        return kind
    }

    func kind(of channel: any Channel) -> RemoteUpgradeKind? {
        lock.lock(); defer { lock.unlock() }
        return kinds[ObjectIdentifier(channel)]
    }

    func track(_ channel: any Channel) -> Bool {
        let id = ObjectIdentifier(channel)
        lock.lock()
        guard !stopped else {
            lock.unlock()
            channel.close(promise: nil)
            return false
        }
        channels[id] = channel
        lock.unlock()
        channel.closeFuture.whenComplete { [weak self] _ in self?.channelClosed(id) }
        return true
    }

    func channelClosed(_ id: ObjectIdentifier) {
        lock.lock()
        channels[id] = nil
        rejectedRoutes[id] = nil
        guard let kind = kinds.removeValue(forKey: id) else { lock.unlock(); return }
        if kind == .video { wakeup?.finish(); wakeup = nil }
        let effects = applyLocked(kind == .video ? .videoClosed : .inputClosed)
        pendingEffects.append(contentsOf: effects)
        lock.unlock()
        performEffects()
    }

    func recordHTTP(_ route: RemoteRoute) {
        lock.lock(); defer { lock.unlock() }
        switch route {
        case .forbidden: rejectedForbidden += 1
        case .busy: rejectedBusy += 1
        default: break
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        let open = Array(channels.values)
        channels.removeAll()
        kinds.removeAll()
        rejectedRoutes.removeAll()
        wakeup?.finish()
        wakeup = nil
        let effects = applyLocked(.stopRequested)
        pendingEffects.append(contentsOf: effects)
        lock.unlock()
        for channel in open { channel.close(promise: nil) }
        performEffects()
    }

    // MARK: - 影像

    /// 沒有 viewer 時只計數。有 viewer 但寫出迴圈還沒 attach（升級回應還在路上）時照樣入列，
    /// `attachVideoWakeups()` 會立刻 yield 一次把它們送出去。
    func offer(accessUnit: Data, keyframe: Bool, sequence: UInt32) {
        lock.lock()
        framesOffered += 1
        guard session.hasVideo else { lock.unlock(); return }
        let entry = RemoteVideoQueue.Entry(sequence: sequence, isKeyframe: keyframe, accessUnit: accessUnit)
        let (next, accepted) = queue.offering(entry)
        queue = next
        let wakeup = self.wakeup
        lock.unlock()
        if accepted { wakeup?.yield(()) }
    }

    /// 寫出迴圈在連線建立後呼叫。回傳的 stream 每收到一個值代表「佇列有東西」；
    /// 立刻 yield 一次是為了把連線建立前就排進佇列的 keyframe 送出去。
    func attachVideoWakeups(channelID: ObjectIdentifier) -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        lock.lock()
        guard !stopped, kinds[channelID] == .video else {
            lock.unlock()
            continuation.finish()
            return stream
        }
        wakeup?.finish()
        wakeup = continuation
        lock.unlock()
        continuation.yield(())
        return stream
    }

    func popVideoEntry(channelID: ObjectIdentifier) -> RemoteVideoQueue.Entry? {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, kinds[channelID] == .video else { return nil }
        let (next, entry) = queue.popping()
        queue = next
        return entry
    }

    func recordSent() {
        lock.lock(); framesSent += 1; lock.unlock()
    }

    // MARK: - 輸入

    /// 回傳值非 nil 代表要原封 echo 回去（只有 ping）。
    func handleInputText(_ text: String, channelID: ObjectIdentifier) -> String? {
        let decoded = RemoteTouchMessageDecoder.decode(text)
        lock.lock()
        guard !stopped, kinds[channelID] == .input else { lock.unlock(); return nil }
        switch decoded {
        case .success(.ping):
            lock.unlock()
            return text
        case .success(.touch(let message)):
            let (next, outcome) = allocator.apply(message)
            allocator = next
            switch outcome {
            case .emit(let spec):
                touchesForwarded += 1
                let onTouches = self.onTouches
                pendingEffects.append { onTouches([spec]) }
                lock.unlock()
                performEffects()
            case .rejected(let reason):
                noteInvalidLocked("觸控被拒：\(reason)")
                lock.unlock()
            }
            return nil
        case .failure(let error):
            noteInvalidLocked("解碼失敗：\(error)")
            lock.unlock()
            return nil
        }
    }

    // MARK: - 私有

    /// 只在鎖內呼叫。回傳要在鎖外執行的效果（含狀態變更通知）。
    private func applyLocked(_ event: RemoteSessionEvent) -> [@Sendable () -> Void] {
        let (next, effect) = RemoteSessionReducer.reduce(session, event)
        var effects: [@Sendable () -> Void] = []
        if next != session {
            session = next
            let onStateChanged = self.onStateChanged
            effects.append { onStateChanged(next) }
        }
        switch effect {
        case .none:
            break
        case .rejectBusy:
            rejectedBusy += 1
        case .requestKeyframe:
            framesDroppedBeforeReset += queue.dropped
            queue = RemoteVideoQueue(limit: configuration.queueLimit)
            let onKeyframeRequested = self.onKeyframeRequested
            effects.append { onKeyframeRequested() }
        case .releaseTouches:
            let (cleared, released) = allocator.releaseAll()
            allocator = cleared
            if !released.isEmpty {
                touchesForwarded += 1
                let onTouches = self.onTouches
                effects.append { onTouches(released) }
            }
        }
        return effects
    }

    /// 鎖內按 reducer／觸控順序排效果，單一 drainer 在鎖外呼叫。
    /// 避免 down 回呼晚於 stop 的 release；回呼可重入 stats/send 而不死鎖。
    private func performEffects() {
        lock.lock()
        guard !performingEffects else { lock.unlock(); return }
        performingEffects = true
        while !pendingEffects.isEmpty {
            let effect = pendingEffects.removeFirst()
            lock.unlock()
            effect()
            lock.lock()
        }
        performingEffects = false
        lock.unlock()
    }

    /// 只在鎖內呼叫。計數每則都算，log 每秒最多一行（spec 第 7 節）。
    private func noteInvalidLocked(_ reason: String) {
        invalidInputMessages += 1
        let current = now()
        if let last = lastInvalidLog, current - last < Self.invalidLogInterval { return }
        lastInvalidLog = current
        print("[remote] 無效的觸控訊息：\(reason)（累計 \(invalidInputMessages)）")
    }
}
