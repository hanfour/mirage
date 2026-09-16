import Foundation

/// 音訊沒有 keyframe 恢復點，背壓時保留最新樣本，避免延遲持續增加。
/// 與影像佇列相同，以值型別讓 core 在鎖內替換狀態；已交給 TCP 的訊息不計入丟棄數。
public struct RemoteAudioQueue: Sendable, Equatable {
    public static let defaultLimit = 10

    public let limit: Int
    public let pending: [RemoteAudioMessage]
    public let dropped: Int

    public init(limit: Int = defaultLimit) {
        precondition(limit >= 1, "RemoteAudioQueue limit 必須至少為 1")
        self.init(limit: limit, pending: [], dropped: 0)
    }

    private init(limit: Int, pending: [RemoteAudioMessage], dropped: Int) {
        self.limit = limit
        self.pending = pending
        self.dropped = dropped
    }

    public func offering(_ entry: RemoteAudioMessage) -> RemoteAudioQueue {
        var pending = self.pending
        var dropped = self.dropped
        if pending.count >= limit {
            pending.removeFirst()
            dropped += 1
        }
        pending.append(entry)
        return RemoteAudioQueue(limit: limit, pending: pending, dropped: dropped)
    }

    public func popping() -> (queue: RemoteAudioQueue, entry: RemoteAudioMessage?) {
        guard let first = pending.first else { return (self, nil) }
        return (RemoteAudioQueue(limit: limit, pending: Array(pending.dropFirst()), dropped: dropped), first)
    }
}
