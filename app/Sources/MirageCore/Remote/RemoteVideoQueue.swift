import Foundation

/// 單一 viewer 的送出佇列（spec 第 4 節背壓規則）。移植自 spike 的 `GOPQueue`。
///
/// 滿了就丟掉全部未送出的幀、回到等 keyframe：丟單一 P 幀會讓後面的 P 幀參考不到，
/// 手機端會花得更多。`dropped` 只計本佇列丟的幀；已交給 TCP 的那一幀收不回來，不算。
/// 值型別：`RemoteServerCore` 在鎖內以 `offering`／`popping` 的回傳值替換自己那一份。
public struct RemoteVideoQueue: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let sequence: UInt32
        public let isKeyframe: Bool
        public let accessUnit: Data

        public init(sequence: UInt32, isKeyframe: Bool, accessUnit: Data) {
            self.sequence = sequence
            self.isKeyframe = isKeyframe
            self.accessUnit = accessUnit
        }
    }

    public static let defaultLimit = 3

    public let limit: Int
    public let pending: [Entry]
    public let waitingForKeyframe: Bool
    public let dropped: Int

    public init(limit: Int = defaultLimit) {
        precondition(limit >= 1, "RemoteVideoQueue limit 必須至少為 1")
        self.init(limit: limit, pending: [], waitingForKeyframe: true, dropped: 0)
    }

    private init(limit: Int, pending: [Entry], waitingForKeyframe: Bool, dropped: Int) {
        self.limit = limit
        self.pending = pending
        self.waitingForKeyframe = waitingForKeyframe
        self.dropped = dropped
    }

    public func offering(_ entry: Entry) -> (queue: RemoteVideoQueue, accepted: Bool) {
        var pending = self.pending
        var waiting = waitingForKeyframe
        var dropped = self.dropped
        if pending.count >= limit {
            dropped += pending.count
            pending.removeAll()
            waiting = true
        }
        if waiting, !entry.isKeyframe {
            return (RemoteVideoQueue(limit: limit, pending: pending, waitingForKeyframe: true, dropped: dropped + 1), false)
        }
        pending.append(entry)
        return (RemoteVideoQueue(limit: limit, pending: pending, waitingForKeyframe: false, dropped: dropped), true)
    }

    public func popping() -> (queue: RemoteVideoQueue, entry: Entry?) {
        guard let first = pending.first else { return (self, nil) }
        let rest = Array(pending.dropFirst())
        return (RemoteVideoQueue(limit: limit, pending: rest, waitingForKeyframe: waitingForKeyframe, dropped: dropped), first)
    }
}
