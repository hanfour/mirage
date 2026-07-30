import Foundation
@testable import MirageCore

/// 計數閘門：等到計數達到門檻為止，**沒有等待預算**（D24）。
///
/// 取代的是 `waitUntil(attempts: 100, interval: 20ms)`＝2 秒上限的輪詢。那個上限在這台
/// 機器的日常負載下會讓**完全正確的樹**被判成壞的（已重現四次，最嚴重一次 7 條同時紅、
/// 全是逾時）。失敗的是等待預算，不是被等的行為。逾時改交給掛在 @Suite 上的 `.timeLimit`
/// ——粒度是分鐘，只有真的死掉才會踩到，不會被日常負載誤觸。
///
/// `Tests/MirageShellTests/CountGate.swift` 有一份對應複本（跨 test target 不能共用，
/// 比照本專案 `waitUntil` 原本就有的重複慣例）。
final class CountGate: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var waiters: [(threshold: Int, cont: CheckedContinuation<Void, Never>)] = []

    var current: Int { lock.lock(); defer { lock.unlock() }; return count }

    func increment() {
        lock.lock()
        count += 1
        let now = count
        let ready = waiters.filter { $0.threshold <= now }
        waiters.removeAll { $0.threshold <= now }
        lock.unlock()
        for w in ready { w.cont.resume() }
    }

    func wait(for threshold: Int) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if count >= threshold {
                lock.unlock()
                cont.resume()
                return
            }
            waiters.append((threshold, cont))
            lock.unlock()
        }
    }
}

/// 記錄狀態轉移並可等待某個條件成立，**沒有等待預算**（D24）。
///
/// 原本是 `ConnStateRecorder`／`PowerStateRecorder` 兩個幾乎一模一樣的 actor，各自只有
/// `items` 與 `record`；等待靠外部的 `waitUntil` 輪詢它們。合成一個泛型並把等待收進來，
/// 是因為「什麼時候算等到了」本來就該由持有資料的一方決定——輪詢一個 actor 的內部狀態
/// 只是把時序問題推給呼叫端。
actor StateRecorder<T: Sendable> {
    private(set) var items: [T] = []
    private var waiters: [(predicate: @Sendable ([T]) -> Bool,
                           cont: CheckedContinuation<Void, Never>)] = []

    func record(_ value: T) {
        items.append(value)
        wake()
    }

    /// 等到 `predicate(items)` 成立。已成立則立即返回。
    func wait(until predicate: @escaping @Sendable ([T]) -> Bool) async {
        if predicate(items) { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append((predicate, cont))
        }
    }

    private func wake() {
        let snapshot = items
        var pending: [(predicate: @Sendable ([T]) -> Bool,
                       cont: CheckedContinuation<Void, Never>)] = []
        var ready: [CheckedContinuation<Void, Never>] = []
        for waiter in waiters {
            if waiter.predicate(snapshot) { ready.append(waiter.cont) } else { pending.append(waiter) }
        }
        waiters = pending
        for cont in ready { cont.resume() }
    }
}

typealias ConnStateRecorder = StateRecorder<ConnState>
typealias PowerStateRecorder = StateRecorder<PowerState>
