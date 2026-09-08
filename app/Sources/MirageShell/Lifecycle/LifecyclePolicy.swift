struct LifecyclePolicy {
    static let terminateAfterLastWindowClosed = false
    private(set) var suspended = false

    mutating func didHide() { suspended = true }

    mutating func consumeResume() -> Bool {
        let resume = suspended
        suspended = false
        return resume
    }
}
