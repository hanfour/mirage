import Foundation

/// 消費者同步記錄完成時間，只有選用的日誌計時器獨立執行。
/// 鎖只保護統計窗口，不包住注入器呼叫或 await。
private final class InputLatencyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var window = LatencyWindow()

    func record(_ duration: Duration) {
        lock.lock()
        window.record(duration)
        lock.unlock()
    }

    func flush() {
        lock.lock()
        let summary = window.summary()
        window.reset()
        lock.unlock()
        if let s = summary {
            print(String(format: "[app] inject p50=%.1fms p95=%.1fms n=%d",
                         s.p50, s.p95, s.count))
        }
    }
}

/// 輸入事件的唯一排序入口（D6）：同一 consumer 依入列順序發起與等待傳輸呼叫。
/// RPC 回覆不等於 guest 消費；文字交易另有可調保留期，完成仍為 submittedUnverified。
///
/// **為什麼是這個形狀**：原本每個輸入事件各開一個 unstructured Task，於是「有幾個
/// 事件就有幾種可能的順序」。路上沒有任何一層擋得住——MainActor 排隊 → `EmulatorClient`
/// actor → 兩個各自獨立的 unary RPC，HTTP/2 跨 stream 不保證到達順序。修法不是加序號
/// 比對、不是加重試，那些都是在亂序發生之後才補救；這裡是把資料結構換掉，讓亂序在結構
/// 上不可能發生：**一條串流、一個消費者**，所以只有一種順序。
///
/// 這一條不變式同時修掉兩種形態的失效：
/// - **邊緣事件**（鍵盤直通的 down/up）對調＝guest 那顆鍵永遠按著，沒有自癒路徑，而且
///   汙染的是整個 guest 鍵盤輸入，不只當下那款遊戲。
/// - **全狀態快照**（`TouchFrame`）晚到的舊快照覆蓋新狀態＝幽靈觸點或吃掉動作，症狀
///   是「遊戲沒反應」——又一個看起來像遊戲問題的靜默錯誤。
public final class InputQueue: Sendable {
    private enum Command: Sendable {
        case text(TextCommit, TextAdmission, AsyncStream<TextCommitResult>.Continuation)
        case clipboard(UInt64)
        case barrier(AsyncStream<Void>.Continuation)
        case key(KeyCode, down: Bool, queuedAt: ContinuousClock.Instant?)
        case touches([TouchSpec], queuedAt: ContinuousClock.Instant?)
        case tap(nx: Double, ny: Double, down: Bool, queuedAt: ContinuousClock.Instant?)
    }

    private let cont: InputCommandBuffer<Command>
    private let latencyEnabled: Bool
    public let inputStatistics: InputStatistics
    public let textDiagnostics: TextInputDiagnostics
    public let textCoordinator: TextClipboardCoordinator
    private let textTransport: (any TextCommitTransport)?

    public convenience init(injector: any InputInjecting) {
        self.init(injector: injector,
                  latencyEnabled: ProcessInfo.processInfo.environment["MIRAGE_INPUT_LATENCY"] == "1")
    }

    /// 量測入列到 RPC 完成，包含佇列與 actor 等待。
    /// 不包含 MirrorView 在入列前處理 AppKit 事件的時間。
    convenience init(injector: any InputInjecting, latencyEnabled: Bool) {
        self.init(injector: injector, textTransport: injector as? any TextCommitTransport,
                  textPolicy: TextSubmissionPolicy.configured(environment: ProcessInfo.processInfo.environment),
                  latencyEnabled: latencyEnabled)
    }

    public init(injector: any InputInjecting, textTransport: (any TextCommitTransport)?,
                textPolicy: Result<TextSubmissionPolicy, TextCommitIssue>,
                textClock: TextCommitClock = .continuous, latencyEnabled: Bool = false,
                textDiagnostics: TextInputDiagnostics = TextInputDiagnostics()) {
        let inputStatistics = InputStatistics()
        self.inputStatistics = inputStatistics
        let coordinator = TextClipboardCoordinator(policy: textPolicy, clock: textClock)
        self.textDiagnostics = textDiagnostics
        self.textCoordinator = coordinator
        self.textTransport = textTransport
        self.latencyEnabled = latencyEnabled
        let cont = InputCommandBuffer<Command> { command in
            if case .touches(let specs, _) = command, !specs.isEmpty,
               specs.allSatisfy({ $0.down && $0.isRemoteMove }) {
                return Set(specs.map(\.identifier))
            }
            return nil
        }
        self.cont = cont
        // `Task.detached` 而非 `Task`：後者會繼承呼叫端的 actor（實際呼叫端
        // `AppModel` 是 @MainActor），讓這條幫浦白白掛在 MainActor 上，每個事件多一次
        // 來回跳躍。幫浦本身不碰任何 UI 狀態，沒有理由綁在任何 actor 上。
        Task.detached {
            let recorder = latencyEnabled ? InputLatencyRecorder() : nil
            let timer: Task<Void, Never>? = recorder.map { recorder in
                Task {
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(1)) }
                        catch { return }
                        // Renderer 在 MainActor 成對輸出，這裡也在同一 actor
                        // 印出日誌，避免 inject 插入配對行之間。
                        await MainActor.run { recorder.flush() }
                    }
                }
            }
            defer { timer?.cancel() }
            for await _ in cont.wakeups {
                while true {
                    // 遠端 120 Hz 壓測也走這裡；每個消費週期收集約一幀的 move。
                    // 本機快照與所有邊緣不主動等待，亦不以 down=true 猜測 move。
                    if cont.firstIsMove { try? await Task.sleep(for: .milliseconds(16)) }
                    guard let entry = cont.pop() else { break }
                    let command = entry.command
                    let queuedAt: ContinuousClock.Instant?
                    switch command {
                    case .text(let commit, let admission, let receipt):
                        // 同一 consumer 等到 settle 或具名失敗才繼續，禁止另開傳輸 Task。
                        do {
                            let result: TextCommitResult
                            if let stopped = coordinator.begin(commit, admission: admission) { result = stopped }
                            else if let textTransport {
                                result = await TextCommitExecutor(transport: textTransport, clock: textClock)
                                    .execute(commit, policy: admission.policy,
                                             validity: { coordinator.validity(commit) },
                                             willWrite: { coordinator.rememberOwnWrite($0) },
                                             phaseChanged: {
                                                 coordinator.phase($0, for: commit)
                                                 textDiagnostics.record("phase", ["commitID": commit.id.uuidString, "phase": String(describing: $0)])
                                             })
                            } else { result = TextCommitResult(commit: commit, outcome: .failedBeforePaste(.transport("unsupported"))) }
                            textDiagnostics.record("result", ["commitID": commit.id.uuidString, "outcome": String(describing: result.outcome)])
                            receipt.yield(coordinator.finish(result)); receipt.finish()
                        }
                        continue
                    case .clipboard(let revision):
                        if let value = coordinator.hostValue(for: revision), let textTransport {
                            coordinator.rememberOwnWrite(value)
                            do { try await textTransport.writeTextClipboard(value, timeout: .seconds(2)) }
                            catch { coordinator.clipboardWriteFailed(.transport(String(describing: error)), revision: revision, value: value) }
                        }
                        continue
                    case .barrier(let receipt):
                        receipt.yield(()); receipt.finish(); continue
                    case .key(let code, let down, let time):
                        queuedAt = time
                        textDiagnostics.record("guest-key-dispatch", ["key": Self.diagnosticKey(code), "down": String(down)])
                        await injector.sendKey(code, down: down)
                    case .touches(let specs, let time):
                        queuedAt = time
                        inputStatistics.recordRPC(coalesced: entry.coalesced)
                        await injector.sendTouches(specs)
                    case .tap(let nx, let ny, let down, let time):
                        queuedAt = time
                        await injector.sendTap(nx: nx, ny: ny, down: down)
                    }
                    if let queuedAt {
                        recorder?.record(ContinuousClock.now - queuedAt)
                    }
                }
            }
        }
    }

    /// 佇列擁有者消失時收掉幫浦，否則那個 Task 會連同 `injector` 一起永遠活著。
    /// 消費者 Task 只捕捉 `injector` 與 `stream`、不捕捉 `self`，所以 deinit 真的會到。
    deinit { textCoordinator.invalidateSession(); cont.finish() }

    /// 同步入列，回傳單一結果 stream；觀察結果的 Task 不決定入列順序。
    public func commitText(_ commit: TextCommit) -> AsyncStream<TextCommitResult> {
        let (stream, receipt) = AsyncStream.makeStream(of: TextCommitResult.self, bufferingPolicy: .bufferingNewest(1))
        switch textCoordinator.reserve(commit) {
        case .accepted(let admission):
            let duration = admission.policy.settleDelay.components
            textDiagnostics.record("commit-enqueued", ["commitID": commit.id.uuidString,
                "textSHA256": TextInputDiagnostics.hash(commit.text), "utf16Length": String(commit.text.utf16.count),
                "generation": String(commit.generation), "route": "clipboard-w3c-paste",
                "settleMS": String(duration.seconds * 1000 + duration.attoseconds / 1_000_000_000_000_000)])
            cont.yield(.text(commit, admission, receipt))
        case .rejected(let result):
            textDiagnostics.record("result", ["commitID": commit.id.uuidString, "outcome": String(describing: result.outcome)])
            receipt.yield(result); receipt.finish()
        }
        return stream
    }

    private static func diagnosticKey(_ code: KeyCode) -> String {
        if case .key(let key) = code {
            return key.count > 1 ? key : "<printable>"
        }
        return "<mapped>"
    }

    public func hostClipboardChanged(_ text: String) {
        cont.yield(.clipboard(textCoordinator.hostClipboardChanged(text)))
    }
    public func observeGuestClipboard(_ text: String) -> Bool { textCoordinator.observeGuestClipboard(text) }
    public func invalidateTextSession() { textCoordinator.invalidateSession() }
    public func pauseTextSubmissions() { textCoordinator.pause() }
    @discardableResult public func resumeTextSubmissions(acknowledgingUncertainty: Bool = false) -> Bool {
        let result = textCoordinator.resume(acknowledgingUncertainty: acknowledgingUncertainty)
        if let revision = result.hostRevision { cont.yield(.clipboard(revision)) }
        return result.resumed
    }
    /// 同一 consumer 的 barrier，供驗收與有序 shutdown 使用，不另開傳輸路徑。
    public func drained() async {
        let (stream, receipt) = AsyncStream.makeStream(of: Void.self)
        cont.yield(.barrier(receipt))
        for await _ in stream { break }
    }

    /// 送出不阻塞、不等待——`yield` 只是把命令排進串流。呼叫端（MainActor 上的輸入
    /// 事件處理）維持原本的「射後不理」語意，改變的只有到達順序的保證。
    public func key(_ code: KeyCode, down: Bool) {
        cont.yield(.key(code, down: down, queuedAt: latencyEnabled ? .now : nil))
    }

    public func touches(_ specs: [TouchSpec]) {
        cont.yield(.touches(specs, queuedAt: latencyEnabled ? .now : nil))
    }

    public func tap(nx: Double, ny: Double, down: Bool) {
        cont.yield(.tap(nx: nx, ny: ny, down: down, queuedAt: latencyEnabled ? .now : nil))
    }
}

/// 消費端純函式：只取佇列最前面、識別碼集合相同的連續純 move 批次。
/// viewer 只送有變化的手指；不同集合不能互相覆蓋，否則會丟掉另一根手指的最後座標。
/// nil 是排序屏障（本機快照、down/up/cancel、鍵盤、文字、tap、drained）。
enum InputMoveCoalescing {
    static func retainedIndices(_ moveIdentifiers: [Set<Int>?]) -> [Int] {
        var retained: [Int] = []
        for index in moveIdentifiers.indices {
            if let previous = retained.last, let ids = moveIdentifiers[index], !ids.isEmpty,
               moveIdentifiers[previous] == ids {
                retained[retained.count - 1] = index
            } else { retained.append(index) }
        }
        return retained
    }
}

/// AsyncStream 只負責喚醒；命令放在可同步取出的信箱，讓唯一 consumer 在 await RPC
/// 完成後看見累積內容。生產者只 append，合併與移除皆在 consumer 的 pop 進行。
final class InputCommandBuffer<Command: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Command] = []
    private let moveIdentifiers: @Sendable (Command) -> Set<Int>?
    private let continuation: AsyncStream<Void>.Continuation
    let wakeups: AsyncStream<Void>

    init(moveIdentifiers: @escaping @Sendable (Command) -> Set<Int>?) {
        self.moveIdentifiers = moveIdentifiers
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.wakeups = stream
        self.continuation = continuation
    }

    func yield(_ command: Command) {
        lock.lock()
        pending.append(command)
        lock.unlock()
        continuation.yield(())
    }

    func finish() { continuation.finish() }

    var firstIsMove: Bool {
        lock.lock(); defer { lock.unlock() }
        return pending.first.flatMap(moveIdentifiers) != nil
    }

    func pop() -> (command: Command, coalesced: Int)? {
        lock.lock(); defer { lock.unlock() }
        guard !pending.isEmpty else { return nil }
        // 只掃描前綴，不能跨過 key 或邊緣；避免反覆掃描整條混合佇列。
        var count = 1
        if let ids = moveIdentifiers(pending[0]) {
            while count < pending.count, moveIdentifiers(pending[count]) == ids { count += 1 }
        }
        let candidates = pending.prefix(count).map(moveIdentifiers)
        let index = InputMoveCoalescing.retainedIndices(candidates).first ?? 0
        let command = pending[index]
        pending.removeFirst(index + 1)
        return (command, index)
    }
}

/// 累計實際 consumer 呼叫 sendTouches 的次數；每個 stats 訂閱者自行取差值，互不 reset。
public final class InputStatistics: @unchecked Sendable {
    public struct Snapshot: Sendable, Equatable {
        public let rpcs: Int
        public let coalesced: Int

        public func rpcsPerSecond(since previous: Self, interval: Duration) -> Double {
            let parts = interval.components
            let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
            return seconds > 0 ? Double(rpcs - previous.rpcs) / seconds : 0
        }
    }
    private let lock = NSLock()
    private var rpcs = 0
    private var coalesced = 0

    func recordRPC(coalesced count: Int) {
        lock.lock(); defer { lock.unlock() }
        rpcs += 1
        coalesced += count
    }

    public func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(rpcs: rpcs, coalesced: coalesced)
    }
}
