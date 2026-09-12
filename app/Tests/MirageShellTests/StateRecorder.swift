/// `MirageCoreTests/TestGates.swift:50-79` 的複本；跨 test target 不能共用。
actor StateRecorder<T: Sendable> {
    private(set) var items: [T] = []
    private var waiters: [(predicate: @Sendable ([T]) -> Bool, cont: CheckedContinuation<Void, Never>)] = []

    func record(_ value: T) {
        items.append(value)
        let snapshot = items
        var pending: [(predicate: @Sendable ([T]) -> Bool, cont: CheckedContinuation<Void, Never>)] = []
        var ready: [CheckedContinuation<Void, Never>] = []
        for waiter in waiters {
            if waiter.predicate(snapshot) { ready.append(waiter.cont) } else { pending.append(waiter) }
        }
        waiters = pending
        for cont in ready { cont.resume() }
    }

    func wait(until predicate: @escaping @Sendable ([T]) -> Bool) async {
        if predicate(items) { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append((predicate, cont))
        }
    }
}
