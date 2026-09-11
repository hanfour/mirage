import Foundation

/// 工程候選設定；任何正的 settle 值都不是 guest 消費 ACK。
public struct TextSubmissionPolicy: Sendable, Equatable {
    public static let candidateSettleMilliseconds = 250
    public let settleDelay: Duration
    public let rpcTimeout: Duration
    public let readbackTimeout: Duration
    public let queueTimeout: Duration
    public let maxPending: Int

    public init(settleMilliseconds: Int = candidateSettleMilliseconds,
                rpcTimeoutMilliseconds: Int = 2_000, readbackTimeoutMilliseconds: Int = 2_000,
                queueTimeoutMilliseconds: Int = 10_000, maxPending: Int = 32) throws {
        // 60s 是資源／取消延遲的工程上限，不是經驗證的安全節流區間。
        for (name, value) in [("settle", settleMilliseconds), ("rpcTimeout", rpcTimeoutMilliseconds),
                              ("readbackTimeout", readbackTimeoutMilliseconds), ("queueTimeout", queueTimeoutMilliseconds)] {
            guard (1...60_000).contains(value) else { throw TextCommitIssue.invalidPolicy(name) }
        }
        guard maxPending > 0 else { throw TextCommitIssue.invalidPolicy("maxPending") }
        settleDelay = .milliseconds(settleMilliseconds)
        rpcTimeout = .milliseconds(rpcTimeoutMilliseconds)
        readbackTimeout = .milliseconds(readbackTimeoutMilliseconds)
        queueTimeout = .milliseconds(queueTimeoutMilliseconds)
        self.maxPending = maxPending
    }

    public static func from(environment: [String: String]) throws -> Self {
        guard let raw = environment["MIRAGE_TEXT_SETTLE_MS"] else { return try Self() }
        guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }), let value = Int(raw) else {
            throw TextCommitIssue.invalidPolicy("MIRAGE_TEXT_SETTLE_MS")
        }
        return try Self(settleMilliseconds: value)
    }
}
