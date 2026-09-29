import Foundation

enum WatchdogOutcome<T: Equatable & Sendable>: Equatable, Sendable {
    case finished(T)
    case watchdogFired
}

func awaitWithWatchdog<T: Equatable & Sendable>(
    _ limit: Duration, _ operation: @escaping @Sendable () async -> T
) async -> WatchdogOutcome<T> {
    let once = ShellWatchdogOnce<T>()
    return await withCheckedContinuation { continuation in
        once.set(continuation)
        Task { once.resume(.finished(await operation())) }
        Task {
            try? await Task.sleep(for: limit)
            once.resume(.watchdogFired)
        }
    }
}

private final class ShellWatchdogOnce<T: Equatable & Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<WatchdogOutcome<T>, Never>?
    private var first: WatchdogOutcome<T>?

    func set(_ continuation: CheckedContinuation<WatchdogOutcome<T>, Never>) {
        lock.lock()
        let early = first
        if early == nil { self.continuation = continuation }
        lock.unlock()
        if let early { continuation.resume(returning: early) }
    }

    func resume(_ outcome: WatchdogOutcome<T>) {
        lock.lock()
        let isFirst = first == nil
        if isFirst { first = outcome }
        let waiting = isFirst ? continuation : nil
        if isFirst { continuation = nil }
        lock.unlock()
        waiting?.resume(returning: outcome)
    }
}
