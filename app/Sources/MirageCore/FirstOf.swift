import Foundation

private final class FirstOfRace<Value: Sendable>: @unchecked Sendable {
    enum Winner {
        case operation
        case timeout
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, Never>?
    private var isResolved = false
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    init(continuation: CheckedContinuation<Value?, Never>) {
        self.continuation = continuation
    }

    func setOperationTask(_ task: Task<Void, Never>) {
        lock.lock()
        let cancel = isResolved
        if !cancel { operationTask = task }
        lock.unlock()
        if cancel { task.cancel() }
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        lock.lock()
        let cancel = isResolved
        if !cancel { timeoutTask = task }
        lock.unlock()
        if cancel { task.cancel() }
    }

    func resolve(_ value: Value?, winner: Winner) {
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            return
        }

        isResolved = true
        let continuation = self.continuation
        self.continuation = nil
        let losingTask = switch winner {
        case .operation: timeoutTask
        case .timeout: operationTask
        }
        operationTask = nil
        timeoutTask = nil
        lock.unlock()

        losingTask?.cancel()
        continuation?.resume(returning: value)
    }
}

func firstOf<Value: Sendable>(
    timeout: Duration,
    operation: @escaping @Sendable () async -> Value?
) async -> Value? {
    await withCheckedContinuation { continuation in
        let race = FirstOfRace(continuation: continuation)
        let operationTask = Task {
            race.resolve(await operation(), winner: .operation)
        }
        race.setOperationTask(operationTask)

        let timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
                race.resolve(nil, winner: .timeout)
            } catch {
                // The operation completed first.
            }
        }
        race.setTimeoutTask(timeoutTask)
    }
}
