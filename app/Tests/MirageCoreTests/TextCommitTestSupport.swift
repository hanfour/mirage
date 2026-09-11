import Foundation
@testable import MirageCore

final class AdvancingTextClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Duration = .zero
    var clock: TextCommitClock {
        TextCommitClock(now: { self.now }, sleep: { self.advance($0) })
    }
    var now: Duration { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ amount: Duration) { lock.lock(); value += amount; lock.unlock() }
}

actor RecordingTextTransport: TextCommitTransport {
    var events: [String] = []
    var timeouts: [Duration] = []
    var clipboard = ""
    let readOverride: String?
    var failEvent: String?
    let afterRead: @Sendable () -> Void
    init(readOverride: String? = nil, failEvent: String? = nil,
         afterRead: @escaping @Sendable () -> Void = {}) {
        self.readOverride = readOverride; self.failEvent = failEvent; self.afterRead = afterRead
    }
    private func record(_ event: String, timeout: Duration) throws {
        events.append(event); timeouts.append(timeout)
        if failEvent == event { failEvent = nil; throw TextCommitIssue.transport("injected") }
    }
    func writeTextClipboard(_ text: String, timeout: Duration) async throws {
        try record("write:\(text)", timeout: timeout); clipboard = text
    }
    func readTextClipboard(timeout: Duration) async throws -> String {
        try record("read", timeout: timeout); afterRead(); return readOverride ?? clipboard
    }
    func sendTextKey(_ key: String, down: Bool, timeout: Duration) async throws {
        try record("key:\(key):\(down ? "down" : "up")", timeout: timeout)
    }
}
