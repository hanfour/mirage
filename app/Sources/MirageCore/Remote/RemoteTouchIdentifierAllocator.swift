public struct RemoteActiveTouch: Sendable, Equatable {
    public let identifier: Int
    public let point: NormPoint

    public init(identifier: Int, point: NormPoint) {
        self.identifier = identifier
        self.point = point
    }
}

public enum RemoteTouchRejection: Error, Sendable, Equatable {
    case tooManyFingers
    case unknownPointer
}

public enum RemoteTouchOutcome: Sendable, Equatable {
    case emit(TouchSpec)
    case rejected(RemoteTouchRejection)
}

/// 手機 pointerId → 模擬器觸控識別碼（spec 第 2 節設計決定 2）。
///
/// 識別碼固定在 64 到 79：Mac 端 `sendTap` 用 0、keymap 從 1 起（`KeymapEngine.init`），
/// 整合端仍須確保 keymap 避開此區間，既有 KeymapEngine 沒有識別碼上限。
/// 此 allocator 最多接受 10 根手機手指；跨 Mac／手機的總並發限制由整合端協調。
/// 值型別：`apply` 回傳新的 allocator，持有者（`RemoteServerCore`）在鎖內替換。
public struct RemoteTouchIdentifierAllocator: Sendable, Equatable {
    public static let identifierRange = 64...79
    public static let maxActive = 10

    public let active: [Int: RemoteActiveTouch]

    public init() {
        active = [:]
    }

    private init(active: [Int: RemoteActiveTouch]) {
        self.active = active
    }

    public func apply(_ message: RemoteTouchMessage)
        -> (allocator: RemoteTouchIdentifierAllocator, outcome: RemoteTouchOutcome)
    {
        if let existing = active[message.pointerId] {
            return update(pointerId: message.pointerId, identifier: existing.identifier, message: message)
        }
        guard message.phase == .down else { return (self, .rejected(.unknownPointer)) }
        guard active.count < Self.maxActive, let identifier = lowestFreeIdentifier() else {
            return (self, .rejected(.tooManyFingers))
        }
        return update(pointerId: message.pointerId, identifier: identifier, message: message)
    }

    /// 交易式配置：任何一點失敗都回復原 allocator，不洩漏識別碼或部分按下。
    public func applyBatch(_ messages: [RemoteTouchMessage])
        -> Result<(allocator: Self, specs: [TouchSpec]), RemoteTouchRejection> {
        var next = self
        var specs: [TouchSpec] = []
        for message in messages {
            let (candidate, outcome) = next.apply(message)
            switch outcome {
            case .rejected(let reason): return .failure(reason)
            case .emit(let spec):
                specs.append(TouchSpec(identifier: spec.identifier, point: spec.point,
                                       down: spec.down, isRemoteMove: message.phase == .move))
                next = candidate
            }
        }
        return .success((next, specs))
    }

    public func releaseAll() -> (allocator: RemoteTouchIdentifierAllocator, released: [TouchSpec]) {
        let released = active.values
            .sorted { $0.identifier < $1.identifier }
            .map { TouchSpec(identifier: $0.identifier, point: $0.point, down: false) }
        return (RemoteTouchIdentifierAllocator(), released)
    }

    private func update(pointerId: Int, identifier: Int, message: RemoteTouchMessage)
        -> (allocator: RemoteTouchIdentifierAllocator, outcome: RemoteTouchOutcome)
    {
        var next = active
        if message.isDown {
            next[pointerId] = RemoteActiveTouch(identifier: identifier, point: message.point)
        } else {
            next[pointerId] = nil
        }
        let spec = TouchSpec(identifier: identifier, point: message.point, down: message.isDown)
        return (RemoteTouchIdentifierAllocator(active: next), .emit(spec))
    }

    private func lowestFreeIdentifier() -> Int? {
        let used = Set(active.values.map(\.identifier))
        return Self.identifierRange.first { !used.contains($0) }
    }
}
