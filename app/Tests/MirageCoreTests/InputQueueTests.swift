import Foundation
import Testing
@testable import MirageCore

/// 假注入器：量「有沒有被並行呼叫」與「到達順序」。
///
/// `delay` 依**事件內容**決定要慢多久（不是依進入順序）。這是刻意的：依進入順序給延遲
/// 的話，一旦兩個 Task 的進入順序自己就翻了，延遲也跟著翻，測試會**偶然變綠**——RED
/// 就不再是確定的。依內容給延遲則不管誰先進來都成立。
///
/// 延遲模擬的是真實成因：兩個獨立的 unary RPC 走 HTTP/2 不同 stream，服務端逐 stream
/// 處理，到達順序本來就不保證。這裡把那件事從「機率」變成「必然」，好讓 RED 可重現。
private final class ProbeInjector: InputInjecting, @unchecked Sendable {
    private let lock = NSLock()
    private let delay: @Sendable (String) -> Duration
    private var _inFlight = 0
    private var _maxInFlight = 0
    private var _arrivals: [String] = []
    private let stream: AsyncStream<Int>
    private let cont: AsyncStream<Int>.Continuation

    init(delay: @escaping @Sendable (String) -> Duration = { _ in .zero }) {
        self.delay = delay
        (stream, cont) = AsyncStream.makeStream(of: Int.self)
    }

    var maxInFlight: Int { lock.lock(); defer { lock.unlock() }; return _maxInFlight }
    var arrivals: [String] { lock.lock(); defer { lock.unlock() }; return _arrivals }

    /// 等到第 `n` 筆抵達。**刻意不是輪詢**：`for await` 在元素出現前就是掛著，沒有
    /// 「等待預算」這種東西可以在高負載下爆掉——那正是 D24 那個 2 秒 `waitUntil` 的
    /// 失敗模式，而這個 repo 已經為它付過四次假紅燈的學費。逾時交給 `.timeLimit` 當
    /// 最後防線，它的粒度是分鐘，不會被日常負載誤觸。
    func waitForArrivals(_ n: Int) async {
        if arrivals.count >= n { return }
        for await count in stream where count >= n { return }
    }

    /// 進入／離開拆成同步方法：`NSLock.lock()` 在 async 情境下不可用（Swift 6 語言模式
    /// 直接是 error），而且這裡本來就不該在持鎖期間 await。
    private func enter() {
        lock.lock(); defer { lock.unlock() }
        _inFlight += 1
        _maxInFlight = max(_maxInFlight, _inFlight)
    }

    private func leave(_ label: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        _inFlight -= 1
        _arrivals.append(label)
        return _arrivals.count
    }

    private func record(_ label: String) async {
        enter()
        let d = delay(label)
        if d > .zero { try? await Task.sleep(for: d) }
        cont.yield(leave(label))
    }

    func sendKey(_ code: KeyCode, down: Bool) async {
        await record("key \(String(describing: code)) \(down ? "down" : "up")")
    }

    func sendTouches(_ touches: [TouchSpec]) async {
        await record("touches \(touches.map(\.identifier))")
    }

    func sendTap(nx: Double, ny: Double, down: Bool) async {
        await record("tap \(nx),\(ny) \(down ? "down" : "up")")
    }
}

@Suite struct InputQueueTests {
    /// 注入器永遠不會被並行呼叫。
    ///
    /// 這是「順序保證」的結構性前提：同一時刻只有一個呼叫在飛，就沒有任何東西可以
    /// 互相超車。**刻意不去重現一次亂序**——重現 race 會做出第二個 D24（間歇紅、
    /// 負載一高就說謊）。這條的失敗方向恰好相反：機器越忙、重疊窗口越明顯，違規越
    /// 容易被抓到；修好之後 `maxInFlight` 在結構上不可能大於 1，與負載無關。
    @Test(.timeLimit(.minutes(1)))
    func injectorIsNeverCalledConcurrently() async {
        let probe = ProbeInjector { _ in .milliseconds(10) }
        let queue = InputQueue(injector: probe)
        for i in 0..<10 { queue.key(.key("k"), down: i.isMultiple(of: 2)) }
        await probe.waitForArrivals(10)
        #expect(probe.maxInFlight == 1)
    }

    /// 慢的事件不會被後面快的事件超車。
    ///
    /// 每事件各開一個 Task 時，慢的 down 會被快的 up 超車，guest 端就剩一顆**永遠按著
    /// 的鍵**——D6 說的「邊緣事件沒有自癒路徑」。觸控快照還有下一幀可以蓋掉錯誤狀態，
    /// 鍵盤沒有，而且它汙染的是整個 guest 鍵盤輸入，不只當下那款遊戲。
    @Test(.timeLimit(.minutes(1)))
    func slowEventIsNotOvertakenByFastFollower() async {
        let probe = ProbeInjector { $0.hasSuffix("down") ? .milliseconds(60) : .milliseconds(10) }
        let queue = InputQueue(injector: probe)
        queue.key(.key("w"), down: true)
        queue.key(.key("w"), down: false)
        await probe.waitForArrivals(2)
        #expect(probe.arrivals == [#"key key("w") down"#, #"key key("w") up"#])
    }

    /// **跨種類**也是同一個順序：tap、鍵盤、觸控快照共用一條佇列。
    ///
    /// 這條是「一台 guest 一條佇列」這個設計決定的斷言。每個呼叫端各自持有一條佇列的話，
    /// 每條內部有序、彼此之間仍然沒有順序——切換 profile 的瞬間 tap 與觸控快照就可能
    /// 對調，等於沒修。
    @Test(.timeLimit(.minutes(1)))
    func differentEventKindsShareOneOrder() async {
        let probe = ProbeInjector { $0.hasPrefix("tap") ? .milliseconds(60) : .milliseconds(10) }
        let queue = InputQueue(injector: probe)
        queue.tap(nx: 0.5, ny: 0.5, down: true)
        queue.key(.key("j"), down: true)
        queue.touches([TouchSpec(identifier: 3, point: NormPoint(x: 0.1, y: 0.1), down: true)])
        await probe.waitForArrivals(3)
        #expect(probe.arrivals == ["tap 0.5,0.5 down", #"key key("j") down"#, "touches [3]"])
    }

    /// 觸控快照同樣不得亂序：晚到的舊快照會覆蓋新狀態，症狀是「遊戲沒反應」。
    @Test(.timeLimit(.minutes(1)))
    func touchFramesArriveInSubmissionOrder() async {
        let probe = ProbeInjector { $0.contains("[1]") ? .milliseconds(60) : .milliseconds(10) }
        let queue = InputQueue(injector: probe)
        queue.touches([TouchSpec(identifier: 1, point: NormPoint(x: 0.5, y: 0.5), down: true)])
        queue.touches([TouchSpec(identifier: 2, point: NormPoint(x: 0.5, y: 0.5), down: false)])
        await probe.waitForArrivals(2)
        #expect(probe.arrivals == ["touches [1]", "touches [2]"])
    }
}
