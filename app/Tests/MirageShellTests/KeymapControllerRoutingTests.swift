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

@MainActor
@Suite struct KeymapControllerRoutingTests {
    /// 綁到的鍵走觸控路徑，**不**產生 sendKey——否則遊戲會同時收到觸控與鍵盤事件。
    @Test func boundKeyGoesToTouchesNotKeyboard() async throws {
        let spy = SpyInjector()
        let c = KeymapController(client: spy, profile: profileWithWAndJ())
        c.handleKeyDown(.key("w"))
        try await Task.sleep(for: .milliseconds(100))   // emit 內部用 Task 送出
        #expect(spy.touchCalls >= 1)
        #expect(spy.keyCalls.isEmpty)
    }

    /// 沒綁到的鍵直通鍵盤，**不**產生觸控。
    @Test func unboundKeyGoesToKeyboard() async throws {
        let spy = SpyInjector()
        let c = KeymapController(client: spy, profile: profileWithWAndJ())
        c.handleKeyDown(.key("k"))
        c.handleKeyUp(.key("k"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(spy.keyCalls.count == 2)
        #expect(spy.keyCalls.first?.0 == .key("k"))
        #expect(spy.keyCalls.first?.1 == true)
        #expect(spy.keyCalls.last?.1 == false)
        #expect(spy.touchCalls == 0)
    }

    /// 完全沒有 profile 時每顆鍵都直通——這是 D2 最初被回報的情境。
    @Test func withoutProfileEveryKeyPassesThrough() async throws {
        let spy = SpyInjector()
        let c = KeymapController(client: spy, profile: nil)
        c.handleKeyDown(.key("a"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(spy.keyCalls.count == 1)
        #expect(spy.keyCalls.first?.0 == .key("a"))
    }

    /// 編輯模式（⌘E）不得把按鍵送進 guest——使用者正在改鍵位，不是在玩。
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
