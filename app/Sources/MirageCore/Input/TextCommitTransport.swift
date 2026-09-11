import Foundation

/// 實作必須將 timeout 傳到實際 RPC；回覆不是目標欄位消費 ACK。
public protocol TextCommitTransport: Sendable {
    func writeTextClipboard(_ text: String, timeout: Duration) async throws
    func readTextClipboard(timeout: Duration) async throws -> String
    func sendTextKey(_ key: String, down: Bool, timeout: Duration) async throws
}

public struct TextCommitClock: Sendable {
    public let now: @Sendable () -> Duration
    public let sleep: @Sendable (Duration) async throws -> Void
    public init(now: @escaping @Sendable () -> Duration,
                sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.now = now; self.sleep = sleep
    }
    public static var continuous: Self {
        let clock = ContinuousClock()
        let origin = clock.now
        return Self(now: { origin.duration(to: clock.now) }, sleep: { try await Task.sleep(for: $0) })
    }
}
