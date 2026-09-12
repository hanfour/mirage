struct LifecyclePolicy {
    static let terminateAfterLastWindowClosed = false
    private(set) var suspended = false
    private(set) var isHidden = false

    /// 關視窗要不要 suspend。手機遙控有 viewer 連著時不 suspend（spec 第 6 節）：視窗只是
    /// 隱藏，串流照常，所以也不記成 suspended——否則下次喚醒會多呼叫一次 `client.wake()`。
    /// 回傳值讓呼叫端不必再讀 `suspended` 猜這次有沒有變。
    @discardableResult
    mutating func didHide(remoteViewerActive: Bool) -> Bool {
        isHidden = true
        guard !remoteViewerActive else { return false }
        return suspendIfHidden()
    }

    mutating func didHide() { didHide(remoteViewerActive: false) }

    /// 手機失去 video 後，隱藏視窗原本延後的休眠現在才可執行。
    mutating func remoteViewerDisconnected() -> Bool { suspendIfHidden() }

    private mutating func suspendIfHidden() -> Bool {
        guard isHidden, !suspended else { return false }
        suspended = true
        return true
    }

    mutating func consumeResume() -> Bool {
        isHidden = false
        let resume = suspended
        suspended = false
        return resume
    }
}
