import AppKit
import Foundation
import Testing
@testable import MirageCore
@testable import MirageShell

/// 記錄呼叫的假注入端。比照 `MockAudioTransport.cancelCount` 的既有慣例：
/// 用 NSLock 保護計數，@unchecked Sendable。
private final class SpyInjector: InputInjecting, @unchecked Sendable {
    private let lock = NSLock()
    private var _touchFrames: [[TouchSpec]] = []
    private var _keyCalls: [(KeyCode, Bool)] = []

    var touchCalls: Int { lock.lock(); defer { lock.unlock() }; return _touchFrames.count }
    /// 存下每一幀的內容（不只計數）：要斷言「引擎狀態沒被編輯模式弄髒」就得看觸點本身，
    /// 光數次數看不出搖桿停在哪裡、是不是 down。
    var touchFrames: [[TouchSpec]] { lock.lock(); defer { lock.unlock() }; return _touchFrames }
    var keyCalls: [(KeyCode, Bool)] { lock.lock(); defer { lock.unlock() }; return _keyCalls }

    func sendTouches(_ touches: [TouchSpec]) async {
        lock.lock(); _touchFrames.append(touches); lock.unlock()
    }
    func sendKey(_ code: KeyCode, down: Bool) async {
        lock.lock(); _keyCalls.append((code, down)); lock.unlock()
    }
}

/// 合成一個 `.flagsChanged` 事件。`handleFlagsChanged` 只讀 `event.modifierFlags`
/// 一個欄位，所以其餘參數填什麼都不影響被測邏輯。
///
/// 這個 public factory 在 headless（`swift test`，無視窗、無 `NSApplication.run`）下
/// 實測可用——2026-07-29 以 `swiftc` 直接跑過確認：回傳非 nil，且
/// `modifierFlags` 原樣保留（`flags=0x100000` 恰為 `.command`）。
/// 失敗時用 `#require` 讓測試紅，不用 `!`——強制解包會炸成 crash，讀起來像環境壞了
/// 而不是斷言失敗。
private func flagsChangedEvent(_ flags: NSEvent.ModifierFlags) throws -> NSEvent {
    try #require(NSEvent.keyEvent(
        with: .flagsChanged, location: .zero, modifierFlags: flags,
        timestamp: 0, windowNumber: 0, context: nil,
        characters: "", charactersIgnoringModifiers: "",
        isARepeat: false, keyCode: 55))          // 55 = kVK_Command
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

    /// 編輯模式（⌘E）不得把**新的** down 送進 guest——使用者正在改鍵位，不是在玩。
    ///
    /// **柵欄是 positive control，不是計時器。** 這條原本兩個斷言都是否定的
    /// （`keyCalls.isEmpty`／`touchCalls == 0`）而只等固定 100ms——正是本分支實測過
    /// 「穩定 50% 不夠用」的那個時長。拿掉 `route()` 的 editing guard 之後它有可觀機率
    /// 仍然綠。現在改成：編輯模式送 `k` → 離開編輯模式 → 送 `z` → 等 `z` 到達。
    /// 兩個直通 Task 都在同一個 MainActor 上依序排隊，`z` 到得了就代表 `k` 若有送出
    /// 一定已經排在它前面——「什麼都沒送」因此變成因果順序保證。
    @Test func editingModeSuppressesPassthrough() async throws {
        let spy = SpyInjector()
        let c = KeymapController(client: spy, profile: profileWithWAndJ())
        c.setEditing(true)
        c.handleKeyDown(.key("k"))
        c.setEditing(false)
        c.handleKeyDown(.key("z"))
        #expect(await waitUntil { spy.keyCalls.count >= 1 })
        #expect(spy.keyCalls.map(\.0) == [.key("z")])
        #expect(spy.touchCalls == 0)
    }

    /// 修飾鍵不得直通給 guest（設計 §4.3、README「帶 ⌘ 的組合一律不直通」）。
    ///
    /// 這條守的是一個實際發生過的回歸：`handleFlagsChanged` 原本呼叫
    /// `handleKeyDown`/`handleKeyUp`，而分流上線後那兩個函式改成走 `route()`——
    /// 引擎不認識 `.key("Meta")`，於是 ⌘ 從這條旁路整顆被送給 guest。
    /// Android 的 Meta 是搜尋鍵、長按叫出快速鍵浮層，按 ⌘Tab／⌘Q 都會被 guest 吃到。
    /// `KeyTranslate` 只擋得住字元那半邊，⌘ 鍵本身只有這裡能擋。
    @Test func modifierKeysNeverPassThroughToGuest() async throws {
        let spy = SpyInjector()
        let c = KeymapController(client: spy, profile: profileWithWAndJ())
        c.handleFlagsChanged(try flagsChangedEvent([.command]))            // 按住 ⌘
        c.handleFlagsChanged(try flagsChangedEvent([.command, .shift]))    // 再加 ⇧
        c.handleFlagsChanged(try flagsChangedEvent([.shift]))              // 放開 ⌘
        c.handleFlagsChanged(try flagsChangedEvent([]))                    // 放開 ⇧
        // 同上的柵欄：送一顆確定會直通的鍵，等它到達。修飾鍵若有送出，
        // 它們的 Task 一定已經排在 `z` 前面跑完。
        c.handleKeyDown(.key("z"))
        #expect(await waitUntil { spy.keyCalls.count >= 1 })
        #expect(spy.keyCalls.map(\.0) == [.key("z")])
    }

    /// 不變式：**只對「送過 down 且尚未送 up」的鍵送 up**——一個也不能少，一個也不能多。
    ///
    /// 少了會卡鍵：按住 `k`（直通已送 down）→ ⌘E 進編輯模式 → 放開 `k`，若編輯模式
    /// 一律不送，guest 的 `k` 就永遠按著。多了同樣是 bug：進編輯模式已經補送過 up，
    /// 使用者實際放開時不該再送第二個。
    @Test func editingReleasesInFlightKeysExactlyOnce() async throws {
        let spy = SpyInjector()
        let c = KeymapController(client: spy, profile: profileWithWAndJ())
        c.handleKeyDown(.key("k"))
        #expect(await waitUntil { spy.keyCalls.count >= 1 })
        c.setEditing(true)                       // ⌘E：必須把 in-flight 的 k 補送 up
        #expect(await waitUntil { spy.keyCalls.count >= 2 })
        c.handleKeyUp(.key("k"))                 // 使用者實際放開：不得再送第二個 up
        c.setEditing(false)
        c.handleKeyDown(.key("z"))               // 柵欄
        #expect(await waitUntil { spy.keyCalls.count >= 3 })
        #expect(spy.keyCalls.map(\.0) == [.key("k"), .key("k"), .key("z")])
        #expect(spy.keyCalls.map(\.1) == [true, false, true])
    }

    /// 同一條不變式的另一個觸發路徑：按住期間換 profile（編輯器存檔／偵測到別款遊戲），
    /// 那顆鍵從「沒綁」翻成「已綁」。up 仍然要走直通送出去，不能被引擎吃掉。
    @Test func profileReloadWhileKeyHeldStillReleasesGuestKey() async throws {
        let spy = SpyInjector()
        let c = KeymapController(client: spy, profile: nil)   // 起初全部直通
        c.handleKeyDown(.key("w"))
        #expect(await waitUntil { spy.keyCalls.count >= 1 })
        c.reload(profileWithWAndJ())                          // w 現在被搖桿綁走
        c.handleKeyUp(.key("w"))
        #expect(await waitUntil { spy.keyCalls.count >= 2 })
        #expect(spy.keyCalls.map(\.0) == [.key("w"), .key("w")])
        #expect(spy.keyCalls.map(\.1) == [true, false])
    }

    /// 編輯模式期間，引擎的 `pressed` 仍必須追得上實體鍵狀態。
    ///
    /// 擋點只能是 `emit`（不送出去），不能是 `route` 提早 return（引擎看不到事件）。
    /// 後者的症狀是幽靈搖桿：按住 `w` → ⌘E → 放開 `w` → 離開編輯模式，引擎裡 `w`
    /// 還按著，之後按 `s` 會與 `w` 相消成「沒有方向」，使用者看到搖桿不動。
    @Test func editingDoesNotDesyncEngineState() async throws {
        let spy = SpyInjector()
        let c = KeymapController(client: spy, profile: profileWithWAndJ())
        c.handleKeyDown(.key("w"))
        #expect(await waitUntil { spy.touchCalls >= 1 })
        c.setEditing(true)
        c.handleKeyUp(.key("w"))     // emit 被擋，但引擎必須看到這個 up
        c.setEditing(false)
        c.handleKeyDown(.key("s"))
        #expect(await waitUntil { spy.touchCalls >= 2 })
        // profileWithWAndJ 的搖桿是第一個 binding → identifier 1，圓心 y=0.75、半徑 0.1。
        let stick = try #require(spy.touchFrames.last?.first { $0.identifier == 1 })
        #expect(stick.down)                              // w 若殘留 → 相消 → down=false
        #expect(abs(stick.point.y - 0.85) < 0.0001)      // 純 s = 向下滿舵
    }
}
