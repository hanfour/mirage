import Foundation
import NIOCore

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
    private let onText: @Sendable (String) -> Void
    private let onKey: @Sendable (KeyCode) -> Void
    private let onTouches: @Sendable ([TouchSpec]) -> Void
    private let onClientStats: @Sendable (RemoteClientStats) -> Void
    private let onKeyframeRequested: @Sendable () -> Void
    private let onStateChanged: @Sendable (RemoteSessionState) -> Void
    private let now: @Sendable () -> ContinuousClock.Instant

    private let lock = NSLock()
    private var session = RemoteSessionState.initial
    private var queue: RemoteVideoQueue
    private var allocator = RemoteTouchIdentifierAllocator()
    private var stopped = false
    private var pendingRejections: [ObjectIdentifier: RemoteRoute] = [:]
    private var pendingEffects: [@Sendable () -> Void] = []
    private var performingEffects = false
    private var kinds: [ObjectIdentifier: RemoteUpgradeKind] = [:]
    private var channels: [ObjectIdentifier: any Channel] = [:]
    private var pendingStats: Data?
    private var wakeup: AsyncStream<Void>.Continuation?
    private var framesOffered = 0
    private var framesSent = 0
    private var framesDroppedBeforeReset = 0   // 佇列被 requestKeyframe 重置前累積的丟幀
    private var rejectedForbidden = 0
    private var rejectedBusy = 0
    private var invalidInputMessages = 0
    private var touchesForwarded = 0
    private var keyframeRequestsThrottled = 0
    private var lastKeyframeRequest: ContinuousClock.Instant?
    private var lastInvalidLog: ContinuousClock.Instant?

    init(configuration: RemoteServerConfiguration,
         onTouches: @escaping @Sendable ([TouchSpec]) -> Void,
         onText: @escaping @Sendable (String) -> Void = { _ in },
         onKey: @escaping @Sendable (KeyCode) -> Void = { _ in },
         onClientStats: @escaping @Sendable (RemoteClientStats) -> Void = { _ in },
         onKeyframeRequested: @escaping @Sendable () -> Void,
         onStateChanged: @escaping @Sendable (RemoteSessionState) -> Void,
         now: @escaping @Sendable () -> ContinuousClock.Instant)
    {
        self.configuration = configuration
        self.onClientStats = onClientStats
        self.onTouches = onTouches
        self.onKey = onKey
        self.onText = onText
        self.onKeyframeRequested = onKeyframeRequested
        self.onStateChanged = onStateChanged
        self.now = now
        queue = RemoteVideoQueue(limit: configuration.queueLimit)
    }

    var sessionState: RemoteSessionState {
        lock.lock(); defer { lock.unlock() }
        return session
    }

    func snapshot() -> RemoteServerStats {
        lock.lock(); defer { lock.unlock() }
        return RemoteServerStats(framesOffered: framesOffered, framesSent: framesSent,
                                 framesDropped: framesDroppedBeforeReset + queue.dropped,
                                 rejectedForbidden: rejectedForbidden, rejectedBusy: rejectedBusy,
                                 invalidInputMessages: invalidInputMessages,
                                 keyframeRequestsThrottled: keyframeRequestsThrottled, touchesForwarded: touchesForwarded)
    }

    func route(method: String, uri: String) -> RemoteRoute {
        lock.lock(); defer { lock.unlock() }
        return RemoteRequestRouter.route(method: method, uri: uri, token: configuration.token, state: session)
    }

    /// 拒絕決定只取一次，HTTP 路徑不再等 NIO 未保留的 request head，也不重新計數。
    func takePendingRejection(channelID: ObjectIdentifier) -> RemoteRoute? {
        lock.lock(); defer { lock.unlock() }
        return pendingRejections.removeValue(forKey: channelID)
    }

    /// `shouldUpgrade` 呼叫：鎖內路由＋保留名額；拒絕時保存決定並計數。
    /// 原連線即使隨後離開，已決定的 409 也不能變成 426。
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
            pendingRejections[ObjectIdentifier(channel)] = route
            recordHTTPLocked(route)
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
        pendingRejections[id] = nil
        guard let kind = kinds.removeValue(forKey: id) else { lock.unlock(); return }
        var pairedInputs: [any Channel] = []
        if kind == .video {
            pendingStats = nil
            wakeup?.finish(); wakeup = nil
            // 鎖內撤銷舊 input 的資格，再關 socket，阻止緩衝中的觸控繼續轉發。
            // 移除 kind 也避免其延遲 closeFuture 釋放新一組配對的觸控。
            let inputIDs = kinds.filter { $0.value == .input }.map { $0.key }
            for inputID in inputIDs {
                kinds.removeValue(forKey: inputID)
                if let channel = channels[inputID] { pairedInputs.append(channel) }
            }
        }
        let effects = applyLocked(kind == .video ? .videoClosed : .inputClosed)
        pendingEffects.append(contentsOf: effects)
        lock.unlock()
        for channel in pairedInputs { channel.close(promise: nil) }
        performEffects()
    }

    /// 僅供一般 HTTP 請求使用；升級拒絕已在 admitUpgrade 計數。
    func recordHTTP(_ route: RemoteRoute) {
        lock.lock(); defer { lock.unlock() }
        recordHTTPLocked(route)
    }

    private func recordHTTPLocked(_ route: RemoteRoute) {
        switch route {
        case .forbidden: rejectedForbidden += 1
        case .busy, .videoRequired: rejectedBusy += 1
        default: break
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        pendingStats = nil
        let open = Array(channels.values)
        channels.removeAll()
        kinds.removeAll()
        pendingRejections.removeAll()
        wakeup?.finish()
        wakeup = nil
        let effects = applyLocked(.stopRequested)
        pendingEffects.append(contentsOf: effects)
        lock.unlock()
        for channel in open { channel.close(promise: nil) }
        performEffects()
    }

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

    /// 已配對的 video viewer 在 decoder.flush 後要求 IDR；沿用有序的效果回呼。
    func requestVideoKeyframe(channelID: ObjectIdentifier) {
        lock.lock()
        guard !stopped, kinds[channelID] == .video else { lock.unlock(); return }
        let current = now()
        guard Self.allowsKeyframe(lastRequest: lastKeyframeRequest, now: current) else {
            keyframeRequestsThrottled += 1
            lock.unlock()
            return
        }
        lastKeyframeRequest = current
        pendingEffects.append(onKeyframeRequested)
        lock.unlock()
        performEffects()
    }

    /// 純決策：被拒的請求不移動時間窗，500 ms 邊界包含在可放行範圍內。
    static func allowsKeyframe(lastRequest: ContinuousClock.Instant?, now: ContinuousClock.Instant) -> Bool {
        lastRequest.map { now - $0 >= .milliseconds(500) } ?? true
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

    // 慢 viewer 只保留最新一秒統計，避免無上限堆積；不碰影像佇列。
    func offerStats(_ json: Data) {
        lock.lock()
        guard !stopped, session.hasVideo else { lock.unlock(); return }
        pendingStats = json
        let wakeup = self.wakeup
        lock.unlock()
        wakeup?.yield(())
    }

    func popStats(channelID: ObjectIdentifier) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, kinds[channelID] == .video else { return nil }
        defer { pendingStats = nil }
        return pendingStats
    }

    func recordSent() {
        lock.lock(); framesSent += 1; lock.unlock()
    }

    /// 回傳值非 nil 代表要原封 echo 回去（只有 ping）。
    func handleInputText(_ text: String, channelID: ObjectIdentifier) -> String? {
        let decoded = RemoteTouchMessageDecoder.decode(text)
        lock.lock()
        guard !stopped, kinds[channelID] == .input else { lock.unlock(); return nil }
        switch decoded {
        case .success(.clientStats(let stats)):
            let onClientStats = self.onClientStats
            pendingEffects.append { onClientStats(stats) }
            lock.unlock()
            performEffects()
            return nil
        case .success(.ping):
            lock.unlock()
            return text
        case .success(.text(let text, time: _)):
            let onText = self.onText
            pendingEffects.append { onText(text) }
            lock.unlock()
            performEffects()
            return nil
        case .success(.key(let code, time: _)):
            let onKey = self.onKey
            pendingEffects.append { onKey(code) }
            lock.unlock()
            performEffects()
            return nil
        case .success(.touches(let messages)):
            switch allocator.applyBatch(messages) {
            case .success(let batch):
                allocator = batch.allocator
                touchesForwarded += 1
                let onTouches = self.onTouches
                pendingEffects.append { onTouches(batch.specs) }
                lock.unlock()
                performEffects()
            case .failure(let reason):
                noteInvalidLocked("觸控批次被拒：\(reason)")
                lock.unlock()
            }
            return nil
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
        print("[remote] 無效的輸入訊息：\(reason)（累計 \(invalidInputMessages)）")
    }
}
