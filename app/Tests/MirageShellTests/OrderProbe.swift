import Foundation
import MirageCore

/// 量「到達順序」的假注入端（D6）。延遲依**事件內容**決定而非進入順序——依進入順序
/// 給延遲的話，兩個 Task 的進入順序自己翻了延遲也跟著翻，測試會偶然變綠，RED 就不再
/// 是確定的。
///
/// 延遲模擬的是真實成因：兩個獨立的 unary RPC 走 HTTP/2 不同 stream，服務端逐 stream
/// 處理，到達順序本來就不保證。這裡把那件事從「機率」變成「必然」，好讓 RED 可重現。
///
/// `MirageCoreTests/InputQueueTests.swift` 有一份同型的探針驗 `InputQueue` 型別本身；
/// 這一份驗的是**產品路徑**——呼叫端完全可能繞過佇列自己再開一個 Task，那正是這個 bug
/// 的原始形狀，型別層的測試抓不到。兩份不能共用是因為跨 test target（比照 `waitUntil`
/// 在本專案既有的重複慣例）。
final class OrderProbe: InputInjecting, @unchecked Sendable {
    private let lock = NSLock()
    private let delay: @Sendable (String) -> Duration
    private var _arrivals: [String] = []
    private let stream: AsyncStream<Int>
    private let cont: AsyncStream<Int>.Continuation

    init(delay: @escaping @Sendable (String) -> Duration) {
        self.delay = delay
        (stream, cont) = AsyncStream.makeStream(of: Int.self)
    }

    var arrivals: [String] { lock.lock(); defer { lock.unlock() }; return _arrivals }

    /// 等到第 `n` 筆抵達。**刻意不是 `waitUntil` 那種輪詢**：`for await` 在元素出現前
    /// 就是掛著，沒有「等待預算」這種東西可以在高負載下爆掉——那正是 D24 的失敗模式，
    /// 這個 repo 已經為它付過四次假紅燈的學費。逾時交給 `.timeLimit` 兜底，它的粒度是
    /// 分鐘，不會被日常負載誤觸。
    func waitForArrivals(_ n: Int) async {
        if arrivals.count >= n { return }
        for await count in stream where count >= n { return }
    }

    /// 同步方法：`NSLock.lock()` 在 async 情境下不可用（Swift 6 語言模式是 error），
    /// 而且本來就不該在持鎖期間 await。
    private func append(_ label: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        _arrivals.append(label)
        return _arrivals.count
    }

    private func record(_ label: String) async {
        let d = delay(label)
        if d > .zero { try? await Task.sleep(for: d) }
        cont.yield(append(label))
    }

    func sendTouches(_ touches: [TouchSpec]) async {
        await record("touch \(touches.filter(\.down).map(\.identifier))")
    }

    func sendKey(_ code: KeyCode, down: Bool) async {
        await record("\(Self.label(code)) \(down ? "down" : "up")")
    }

    /// 窮舉而非 `guard case .key … else { return }`。
    ///
    /// 早退版本會讓 `.mouse` 形式的 `KeyCode` 被探針**靜默丟掉**：斷言等不到那一筆，
    /// 測試就掛在 `waitForArrivals` 直到 `.timeLimit` 才紅，而訊息會指向「順序不對」
    /// 而不是「這種事件根本沒被記錄」。`ci.sh` 閘門 3 正是為了攔這種形狀。
    private static func label(_ code: KeyCode) -> String {
        switch code {
        case .key(let name):       name
        case .mouse(let button):   "mouse:\(button.rawValue)"
        }
    }

    func sendTap(nx: Double, ny: Double, down: Bool) async {
        await record("tap \(nx) \(down ? "down" : "up")")
    }
}
