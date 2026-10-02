/// 這次啟動的幀接收端來源，不隨執行中的設定變更。
public enum FrameSinkSource: Equatable, Sendable {
    case setting
    case environment
}

/// 依環境變數與使用者設定選擇幀接收端。
public enum FrameSinkFactory {
    /// 有效整數優先於設定；無效值回退到設定，並交由呼叫端印出警告。
    public static func make(environment: [String: String], smoothFrames: Bool)
        -> (sink: any FrameSink, source: FrameSinkSource, warning: String?) {
        var warning: String?
        if let rawDepth = environment["MIRAGE_FRAME_QUEUE"] {
            if let depth = Int(rawDepth) {
                if depth >= 2 {
                    return (FrameQueue(depth: depth), .environment, nil)
                }
                return (LatestFrameBox(), .environment, nil)
            }
            warning = "MIRAGE_FRAME_QUEUE=\(rawDepth) 不是整數，改用設定"
        }
        if smoothFrames {
            return (FrameQueue(depth: 2), .setting, warning)
        }
        return (LatestFrameBox(), .setting, warning)
    }

    /// 回傳供啟動診斷 log 使用的 sink 名稱。
    public static func label(for sink: any FrameSink) -> String {
        if let queue = sink as? FrameQueue {
            return "queue depth=\(queue.depth)"
        }
        return "latest"
    }
}
