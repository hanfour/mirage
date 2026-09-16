import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

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
    public let audioDropped: Int
    public let rejectedForbidden: Int
    public let rejectedBusy: Int
    public let invalidInputMessages: Int
    public let keyframeRequestsThrottled: Int
    public let touchesForwarded: Int
}

public enum RemoteServerError: Error, Equatable {
    case alreadyStarted
    case noLocalAddress
    case upgradeWithoutAdmission
}

enum RemoteUpgradeResult: Sendable {
    case websocket(RemoteUpgradeKind, NIOAsyncChannel<WebSocketFrame, WebSocketFrame>)
    case http(NIOAsyncChannel<HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>>)
}

/// 手機遙控的 HTTP＋WebSocket 伺服器（spec 第 3、4、5 節）。
///
/// 一個實例只能 `start()` 一次；`stop()` 之後要再開就建新的。事件迴圈用
/// `MultiThreadedEventLoopGroup.singleton`，不自建 group、不在 deinit shutdown（D1／D8）。
public final class RemoteServer: @unchecked Sendable {
    typealias Listener = NIOAsyncChannel<EventLoopFuture<RemoteUpgradeResult>, Never>
    private static let maxFrameSize = 1 << 16

    let core: RemoteServerCore
    private let configuration: RemoteServerConfiguration
    private let lock = NSLock()
    private var listener: Listener?
    private var acceptTask: Task<Void, Never>?
    private var port: Int?
    private var started = false
    private var stopped = false

    public init(configuration: RemoteServerConfiguration,
                onTouches: @escaping @Sendable ([TouchSpec]) -> Void,
                onText: @escaping @Sendable (String) -> Void = { _ in },
                onKey: @escaping @Sendable (KeyCode) -> Void = { _ in },
                onClientStats: @escaping @Sendable (RemoteClientStats) -> Void = { _ in },
                onKeyframeRequested: @escaping @Sendable () -> Void = {},
                onStateChanged: @escaping @Sendable (RemoteSessionState) -> Void = { _ in },
                now: @escaping @Sendable () -> ContinuousClock.Instant = { .now })
    {
        self.configuration = configuration
        core = RemoteServerCore(configuration: configuration, onTouches: onTouches, onText: onText, onKey: onKey,
                                onClientStats: onClientStats, onKeyframeRequested: onKeyframeRequested,
                                onStateChanged: onStateChanged, now: now)
    }

    public var sessionState: RemoteSessionState { core.sessionState }

    public var boundPort: Int? {
        lock.lock(); defer { lock.unlock() }
        return port
    }

    public func stats() -> RemoteServerStats { core.snapshot() }

    public func send(accessUnit: Data, keyframe: Bool, sequence: UInt32) {
        core.offer(accessUnit: accessUnit, keyframe: keyframe, sequence: sequence)
    }

    public func send(audio: RemoteAudioMessage) { core.offer(audio: audio) }

    /// 統計使用獨立的最新值槽，不受影像 GOP 丟棄影響。
    public func sendStats(_ json: Data) { core.offerStats(json) }

    /// 語音辨識字幕，走 video channel 的文字訊息，與 stats 同一條路。
    public func send(speech json: Data) { core.offerSpeech(json) }

    /// bind 失敗直接向呼叫者拋錯，UI 可維持功能關閉。
    /// stopped 與 started 分開記錄，涵蓋 bind 尚未完成就停止的情況。
    public func start() async throws -> Int {
        try reserveStart()

        let core = self.core
        let listener: Listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(host: configuration.host, port: configuration.port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try Self.configureChild(channel, core: core)
                }
            }
        guard let boundPort = listener.channel.localAddress?.port else {
            try? await listener.channel.close().get()
            throw RemoteServerError.noLocalAddress
        }
        guard install(listener, port: boundPort) else {
            try? await listener.channel.close().get()
            throw CancellationError()
        }
        return boundPort
    }

    /// 關閉所有子連線，再等 accept 的結構化子 task 全數結束。
    /// 不關閉 singleton event loop group，其他 NIO 使用者仍可繼續工作。
    public func stop() async {
        let (listener, task) = beginStop()
        core.stop()
        if let listener { try? await listener.channel.close().get() }
        task?.cancel()
        if let task { await task.value }
    }

    // NSLock 僅在同步 helper 內取得，避免 async context 的 noasync 診斷。
    // bind 期間 stop 會標記 stopped；之後 install 必須拒絕，不能漏掉 listener。
    private func reserveStart() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { throw RemoteServerError.alreadyStarted }
        started = true
    }

    private func install(_ listener: Listener, port: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return false }
        self.listener = listener
        self.port = port
        let core = self.core
        acceptTask = Task.detached { await Self.acceptLoop(listener, core: core) }
        return true
    }

    private func beginStop() -> (Listener?, Task<Void, Never>?) {
        lock.lock()
        defer { lock.unlock() }
        stopped = true
        started = true
        // 保留 task，讓重複 stop 的呼叫者也等到相同的 accept 迴圈結束。
        return (listener, acceptTask)
    }

    // MARK: - Pipeline

    private static func configureChild(_ channel: any Channel, core: RemoteServerCore) throws
        -> EventLoopFuture<RemoteUpgradeResult>
    {
        guard core.track(channel) else { throw CancellationError() }
        let upgrader = NIOTypedWebSocketServerUpgrader<RemoteUpgradeResult>(
            maxFrameSize: maxFrameSize,
            shouldUpgrade: { channel, head in
                let admitted = core.admitUpgrade(channel: channel, method: head.method.rawValue, uri: head.uri)
                return channel.eventLoop.makeSucceededFuture(admitted == nil ? nil : HTTPHeaders())
            },
            upgradePipelineHandler: { channel, _ in
                channel.eventLoop.makeCompletedFuture {
                    guard let kind = core.kind(of: channel) else { throw RemoteServerError.upgradeWithoutAdmission }
                    let websocket = try NIOAsyncChannel<WebSocketFrame, WebSocketFrame>(wrappingChannelSynchronously: channel)
                    return RemoteUpgradeResult.websocket(kind, websocket)
                }
            })
        let upgradeConfiguration = NIOTypedHTTPServerUpgradeConfiguration(
            upgraders: [upgrader],
            // NIO 2.101.3：NIOTypedHTTPServerUpgraderStateMachine.swift:181-183
            // 對帶 Upgrade 的請求不 buffer head；shouldUpgrade 回 nil 後，
            // NIOTypedHTTPServerUpgradeHandler.swift:352-362 執行此 initializer 再 unbuffer，
            // HTTP 路徑只收到後續 part（無 body 時只有 end），不能等待 head 才回應。
            // RemoteHTTPConnection 會先取 core 保存的拒絕決定，直接寫完整 403／409。
            notUpgradingCompletionHandler: { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(RemoteHTTPResponsePartHandler())
                    let http = try NIOAsyncChannel<HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>>(
                        wrappingChannelSynchronously: channel)
                    return RemoteUpgradeResult.http(http)
                }
            })
        return try channel.pipeline.syncOperations.configureUpgradableHTTPServerPipeline(
            configuration: .init(upgradeConfiguration: upgradeConfiguration))
    }

    // MARK: - Accept 迴圈

    private static func acceptLoop(_ listener: Listener, core: RemoteServerCore) async {
        do {
            try await withThrowingDiscardingTaskGroup { group in
                try await listener.executeThenClose { inbound in
                    for try await upgradeFuture in inbound {
                        group.addTask { await handle(upgradeFuture, core: core) }
                    }
                }
            }
        } catch {
            print("[remote] accept 迴圈結束：\(error)")
        }
    }

    private static func handle(_ future: EventLoopFuture<RemoteUpgradeResult>, core: RemoteServerCore) async {
        do {
            switch try await future.get() {
            case .websocket(.video, let channel): try await RemoteVideoConnection.run(channel, core: core)
            case .websocket(.input, let channel): try await RemoteInputConnection.run(channel, core: core)
            case .websocket(.audio, let channel): try await RemoteAudioConnection.run(channel, core: core)
            case .http(let channel): try await RemoteHTTPConnection.run(channel, core: core)
            }
        } catch {
            print("[remote] 連線結束：\(error)")
        }
    }
}

/// 從 NIO 範例 `NIOWebSocketServer/Server.swift:274-291` 複製：把 `HTTPPart<HTTPResponseHead, ByteBuffer>`
/// 轉成 `HTTPServerResponsePart`，讓 HTTP 路徑能用 `NIOAsyncChannel` 寫回應。
final class RemoteHTTPResponsePartHandler: ChannelOutboundHandler {
    typealias OutboundIn = HTTPPart<HTTPResponseHead, ByteBuffer>
    typealias OutboundOut = HTTPServerResponsePart

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        switch Self.unwrapOutboundIn(data) {
        case .head(let head):
            context.write(Self.wrapOutboundOut(.head(head)), promise: promise)
        case .body(let buffer):
            context.write(Self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: promise)
        case .end(let trailers):
            context.write(Self.wrapOutboundOut(.end(trailers)), promise: promise)
        }
    }
}
