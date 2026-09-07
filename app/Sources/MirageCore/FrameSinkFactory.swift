/// 依環境變數選擇幀接收端。
public enum FrameSinkFactory {
    /// `MIRAGE_FRAME_QUEUE` 未設、不是整數或小於 2 時維持既有 latest-wins 行為。
    public static func make(from environment: [String: String]) -> any FrameSink {
        guard let rawDepth = environment["MIRAGE_FRAME_QUEUE"],
              let depth = Int(rawDepth),
              depth >= 2 else {
            return LatestFrameBox()
        }
        return FrameQueue(depth: depth)
    }

    /// 回傳供啟動診斷 log 使用的 sink 名稱。
    public static func label(for sink: any FrameSink) -> String {
        if let queue = sink as? FrameQueue {
            return "queue depth=\(queue.depth)"
        }
        return "latest"
    }
}
