import Foundation

/// 計數閘門：等到計數達到門檻為止，**沒有等待預算**（D24）。
///
/// **取代的是什麼**：原本的 `waitUntil(attempts: 100, interval: 20ms)`＝2 秒上限的輪詢。
/// 那個上限在這台機器的日常負載下會讓**完全正確的樹**被判定為壞的——已重現四次，最嚴重
/// 一次是 `KeymapControllerRoutingTests` 8 條裡 7 條同時紅，7 筆全是 `waitUntil` 逾時。
/// 「紅的是哪一條會變」正是它不是真 bug 的指紋：失敗的是**等待預算**，不是被等的行為。
/// 而「高負載」在這台機器上就是常態（兩台 headless AVD ＋ ccusage ＋ OrbStack，1 分鐘
/// load average 地板約 10–12），所以那個閘門在它唯一實際執行的環境裡本來就靠近臨界。
///
/// **為什麼不用 `AsyncStream`**（`OrderProbe.waitForArrivals` 用的那招）：同一個測試會
/// 連續等好幾次門檻（例如 `>= 1` 之後再等 `>= 2`、`>= 3`），而 `AsyncStream` 只支援單一
/// 迭代器，重複 `for await` 的語意沒有保證。改用 continuation 明確喚醒，沒有這層疑慮。
///
/// **逾時交給 `.timeLimit`**（掛在 @Suite 上，粒度是分鐘）。真的卡住時仍會紅，只是不會
/// 被日常負載誤觸——這正是與 2 秒預算的差別：60 秒不是「更寬鬆的預算」，而是「只有真的
/// 死掉才會踩到」的量級。
///
/// 跨 test target 不能共用（`MirageCoreTests` 有一份對應的複本），比照本專案 `waitUntil`
/// 原本就有的重複慣例。
final class CountGate: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var waiters: [(threshold: Int, cont: CheckedContinuation<Void, Never>)] = []

    var current: Int { lock.lock(); defer { lock.unlock() }; return count }

    /// 由被觀測的假件在每次呼叫後叫一次。**同步方法**：`NSLock.lock()` 不可在 async
    /// 情境下呼叫，而且這裡本來就不該在持鎖期間 await。
    func increment() {
        lock.lock()
        count += 1
        let now = count
        let ready = waiters.filter { $0.threshold <= now }
        waiters.removeAll { $0.threshold <= now }
        lock.unlock()
        // 在鎖外 resume：resume 會讓等待方繼續執行，持鎖時做這件事等於把鎖的作用域
        // 擴大到別人的程式碼上。
        for w in ready { w.cont.resume() }
    }

    /// 等到計數 ≥ `threshold`。已達成則立即返回（計數只增不減，所以先檢查現值是安全的）。
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
