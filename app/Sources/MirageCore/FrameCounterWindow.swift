public struct FrameCounterWindow: Sendable, Equatable {
    public let arrived: Int
    public let dropped: Int
    public let presented: Int

    public init(before: FrameCounterSnapshot, after: FrameCounterSnapshot, presented: Int) {
        self.arrived = Self.nonNegativeDelta(from: before.arrived, to: after.arrived)
        self.dropped = Self.nonNegativeDelta(from: before.dropped, to: after.dropped)
        self.presented = max(0, presented)
    }

    private static func nonNegativeDelta(from before: Int, to after: Int) -> Int {
        guard after >= before else { return 0 }
        return after - before
    }
}
