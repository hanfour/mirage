struct LifecyclePolicy {
    static let terminateAfterLastWindowClosed = false
    private(set) var suspended = false

    /// 關視窗要不要 suspend。手機遙控有 viewer 連著時不 suspend（spec 第 6 節）：視窗只是
    /// 隱藏，串流照常，所以也不記成 suspended——否則下次喚醒會多呼叫一次 `client.wake()`。
    /// 回傳值讓呼叫端不必再讀 `suspended` 猜這次有沒有變。
    @discardableResult
    mutating func didHide(remoteViewerActive: Bool) -> Bool {
        guard !remoteViewerActive else { return false }
        suspended = true
        return true
    }

    mutating func didHide() { didHide(remoteViewerActive: false) }

    mutating func consumeResume() -> Bool {
        let resume = suspended
        suspended = false
        return resume
    }
}
