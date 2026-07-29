import Foundation
import Testing
@testable import MirageCore
@testable import MirageShell

/// 記錄呼叫的假注入端。比照 `MockAudioTransport.cancelCount` 的既有慣例：
/// 用 NSLock 保護計數，@unchecked Sendable。
private final class SpyInjector: InputInjecting, @unchecked Sendable {
    private let lock = NSLock()
    private var _touchCalls = 0
    private var _keyCalls: [(KeyCode, Bool)] = []

    var touchCalls: Int { lock.lock(); defer { lock.unlock() }; return _touchCalls }
    var keyCalls: [(KeyCode, Bool)] { lock.lock(); defer { lock.unlock() }; return _keyCalls }

    func sendTouches(_ touches: [TouchSpec]) async {
        lock.lock(); _touchCalls += 1; lock.unlock()
    }
    func sendKey(_ code: KeyCode, down: Bool) async {
        lock.lock(); _keyCalls.append((code, down)); lock.unlock()
    }
}

private func profileWithWAndJ() -> KeymapProfile {
    KeymapProfile(gameId: "g", version: 1, bindings: [
        .joystick(up: .key("w"), down: .key("s"), left: .key("a"), right: .key("d"),
                  center: NormPoint(x: 0.2, y: 0.75), radius: 0.1),
        .tap(key: .key("j"), at: NormPoint(x: 0.85, y: 0.8)),
    ])
}

/// 輪詢直到條件成立或逾時（比照 `EmulatorClientReconnectTests.waitUntil` 的既有慣例），
/// 回傳是否在期限內達成；逾時回傳 false，呼叫端用 `#expect` 斷言。
///
/// **只用在肯定斷言**。`route()` 內走直通路徑時是 `Task { await client.sendKey(...) }`——
/// 一個 unstructured Task，何時真正執行不受呼叫端控制。swift-testing 預設並行跑測試，
/// MainActor 負載高時不保證固定 100ms 內排到那個 Task；這正是本檔案原本半數機率紅燈
/// 的根因。輪詢把「等固定多久」換成「等到條件成立為止（最多 2 秒）」，消除的是機率本身，
/// 不是把機率壓低到看不見。
private func waitUntil(
    attempts: Int = 100,
    interval: Duration = .milliseconds(20),
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if await condition() { return true }
        try? await Task.sleep(for: interval)
    }
    return false
}

@MainActor
@Suite struct KeymapControllerRoutingTests {
    /// 綁到的鍵走觸控路徑，**不**產生 sendKey——否則遊戲會同時收到觸控與鍵盤事件。
    @Test func boundKeyGoesToTouchesNotKeyboard() async throws {
        let spy = SpyInjector()
        let c = KeymapController(client: spy, profile: profileWithWAndJ())
        c.handleKeyDown(.key("w"))
        #expect(await waitUntil { spy.touchCalls >= 1 })
        // 否定斷言不輪詢：bound key 在 route() 裡只會走 emit 分支，sendKey 那條路徑
        // 這次呼叫根本不會被排進佇列——不是「還沒發生」，是「永遠不會發生」。輪詢一個
        // 永遠不成立的條件只會空等到逾時再回 false，沒有意義；固定等一小段時間只是給
        // 任何意外延遲一個浮現的機會，驗的是「即使等了也沒發生」。
        try await Task.sleep(for: .milliseconds(100))
        #expect(spy.keyCalls.isEmpty)
    }

    /// 沒綁到的鍵直通鍵盤，**不**產生觸控。
    @Test func unboundKeyGoesToKeyboard() async throws {
        let spy = SpyInjector()
        let c = KeymapController(client: spy, profile: profileWithWAndJ())
        c.handleKeyDown(.key("k"))
        c.handleKeyUp(.key("k"))
        #expect(await waitUntil { spy.keyCalls.count == 2 })
        #expect(spy.keyCalls.first?.0 == .key("k"))
        #expect(spy.keyCalls.first?.1 == true)
        #expect(spy.keyCalls.last?.1 == false)
        // 同上的不對稱理由：unbound key 只會走 sendKey 分支，sendTouches 這條路徑
        // 不會被排進去，固定等待驗的是「即使等了也沒發生」，不是拿它當計時器。
        try await Task.sleep(for: .milliseconds(100))
        #expect(spy.touchCalls == 0)
    }

    /// 完全沒有 profile 時每顆鍵都直通——這是 D2 最初被回報的情境。
    @Test func withoutProfileEveryKeyPassesThrough() async throws {
        let spy = SpyInjector()
        let c = KeymapController(client: spy, profile: nil)
        c.handleKeyDown(.key("a"))
        #expect(await waitUntil { spy.keyCalls.count == 1 })
        #expect(spy.keyCalls.first?.0 == .key("a"))
    }

    /// 編輯模式（⌘E）不得把按鍵送進 guest——使用者正在改鍵位，不是在玩。
    ///
    /// 這條兩個斷言都是否定（`keyCalls.isEmpty`、`touchCalls == 0`），沒有任何「應該
    /// 發生」的事件可以輪詢等待，所以維持固定等待——輪詢一個永遠不該成立的條件只會
    /// 空等到逾時，沒有意義；固定等待驗的是「即使等了也沒發生」。
    @Test func editingModeSuppressesPassthrough() async throws {
        let spy = SpyInjector()
        let c = KeymapController(client: spy, profile: profileWithWAndJ())
        c.setEditing(true)
        c.handleKeyDown(.key("k"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(spy.keyCalls.isEmpty)
        #expect(spy.touchCalls == 0)
    }
}
