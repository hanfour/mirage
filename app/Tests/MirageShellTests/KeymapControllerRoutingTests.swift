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
    private var _tapCalls: [(Double, Double, Bool)] = []

    /// D24：等待改用計數閘門，不再輪詢。見 `CountGate` 的說明。
    let keyGate = CountGate()
    let touchGate = CountGate()
    let tapGate = CountGate()

    var touchCalls: Int { lock.lock(); defer { lock.unlock() }; return _touchFrames.count }
    /// 存下每一幀的內容（不只計數）：要斷言「引擎狀態沒被編輯模式弄髒」就得看觸點本身，
    /// 光數次數看不出搖桿停在哪裡、是不是 down。
    var touchFrames: [[TouchSpec]] { lock.lock(); defer { lock.unlock() }; return _touchFrames }
    var keyCalls: [(KeyCode, Bool)] { lock.lock(); defer { lock.unlock() }; return _keyCalls }
    var tapCalls: [(Double, Double, Bool)] { lock.lock(); defer { lock.unlock() }; return _tapCalls }

    func sendTouches(_ touches: [TouchSpec]) async {
        lock.lock(); _touchFrames.append(touches); lock.unlock()
        touchGate.increment()
    }
    func sendKey(_ code: KeyCode, down: Bool) async {
        lock.lock(); _keyCalls.append((code, down)); lock.unlock()
        keyGate.increment()
    }
    /// D6 起 `sendTap` 也在 `InputInjecting` 裡（見該協定的說明）。本檔的斷言都不看
    /// tap，但仍如實記錄——回傳空實作等於在假件裡埋一個「送出去卻查不到」的盲區。
    func sendTap(nx: Double, ny: Double, down: Bool) async {
        lock.lock(); _tapCalls.append((nx, ny, down)); lock.unlock()
        tapGate.increment()
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

@MainActor
@Suite(.timeLimit(.minutes(1))) struct KeymapControllerRoutingTests {
    /// 綁到的鍵走觸控路徑，**不**產生 sendKey——否則遊戲會同時收到觸控與鍵盤事件。
    @Test func boundKeyGoesToTouchesNotKeyboard() async throws {
        let spy = SpyInjector()
        let c = KeymapController(queue: InputQueue(injector: spy), profile: profileWithWAndJ())
        c.handleKeyDown(.key("w"))
        await spy.touchGate.wait(for: 1)
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
        let c = KeymapController(queue: InputQueue(injector: spy), profile: profileWithWAndJ())
        c.handleKeyDown(.key("k"))
        c.handleKeyUp(.key("k"))
        await spy.keyGate.wait(for: 2)
        #expect(spy.keyCalls.first?.0 == .key("k"))
        #expect(try #require(spy.keyCalls.first).1)
        #expect(try !#require(spy.keyCalls.last).1)
        // 同上的不對稱理由：unbound key 只會走 sendKey 分支，sendTouches 這條路徑
        // 不會被排進去，固定等待驗的是「即使等了也沒發生」，不是拿它當計時器。
        try await Task.sleep(for: .milliseconds(100))
        #expect(spy.touchCalls == 0)
    }

    /// 完全沒有 profile 時每顆鍵都直通——這是 D2 最初被回報的情境。
    @Test func withoutProfileEveryKeyPassesThrough() async throws {
        let spy = SpyInjector()
        let c = KeymapController(queue: InputQueue(injector: spy), profile: nil)
        c.handleKeyDown(.key("a"))
        await spy.keyGate.wait(for: 1)
        #expect(spy.keyCalls.first?.0 == .key("a"))
    }

    /// 沒有 profile 時文字模式幾乎一直開著，手把的每幀推進不能被它擋住，
    /// 否則十字鍵捲動只有按下沒有移動（2026-10-01 實機查到）。方向：十字鍵下手指往上（y 變小）。
    @Test func gamepadScrollAdvancesWhileTextModeIsOn() async throws {
        let spy = SpyInjector()
        let c = KeymapController(queue: InputQueue(injector: spy), profile: nil)
        c.setTextMode(true)
        c.handleGamepadSnapshot(GamepadSnapshot(buttons: [.dpadDown]))
        c.tickGamepad(dt: 0.1)
        // 有上限的等待：swift-testing 的 .timeLimit 在這個工具鏈不生效，用 gate.wait 的話
        // 錯誤版本只會送一個 tap，測試會永遠卡住而不是變紅。
        for _ in 0..<200 where spy.tapGate.current < 2 { try await Task.sleep(for: .milliseconds(10)) }

        let taps = spy.tapCalls
        let pressedTwice = taps.count >= 2 && taps[0].2 && taps[1].2
        let movedUp = taps.count >= 2 && taps[1].1 < taps[0].1
        #expect(pressedTwice)
        #expect(movedUp)
    }

    @Test func emptyProfileUsesBasicGamepadAndroidActions() async throws {
        let spy = SpyInjector()
        let emptyProfile = KeymapProfile(gameId: "g", version: 1, bindings: [])
        let c = KeymapController(queue: InputQueue(injector: spy), profile: emptyProfile)
        c.handleGamepadSnapshot(GamepadSnapshot(buttons: [.b]))
        await spy.keyGate.wait(for: 2)

        // 空 profile 仍算有 profile（滑鼠不直通，既有行為），但沒有綁定，手把用基本操作。
        #expect(c.hasProfile)
        #expect(spy.keyCalls.map { $0.0 } == [.key("GoBack"), .key("GoBack")])
        #expect(spy.keyCalls.map { $0.1 } == [true, false])
    }

    /// 編輯模式（⌘E）不得把**新的** down 送進 guest——使用者正在改鍵位，不是在玩。
    ///
    /// **柵欄是 positive control，不是計時器。** 這條原本兩個斷言都是否定的
    /// （`keyCalls.isEmpty`／`touchCalls == 0`）而只等固定 100ms——正是本分支實測過
    /// 「穩定 50% 不夠用」的那個時長。拿掉 `route()` 的 editing guard 之後它有可觀機率
    /// 仍然綠。
    ///
    /// **更正（2026-07-30，D6）**：原本這裡有一整段「柵欄的強度，誠實地說」，論證
    /// 「送 `z` 之後等它到達，就代表 `k` 若有送出一定已經跑完」**不是**因果保證只是
    /// 機率——理由是 `Task { await client.sendKey(...) }` 跳到 global concurrent
    /// executor 之後就不再受 MainActor 排隊保護。
    ///
    /// **那個弱點已經沒有了。** `KeymapController` 改走 `InputQueue`（單一消費者依序
    /// 送出）之後，`z` 抵達就**因果上**代表任何更早送出的事件已經抵達。
    ///
    /// 即使如此，下面仍保留「先固定等一段時間再切換編輯模式」的寫法——不是因為柵欄
    /// 不夠強，而是這條要驗的是「`k` 在**編輯模式期間**沒被送出」，時序上必須讓它有
    /// 機會在 `setEditing(false)` 之前現形。這是斷言的語意需求，不是對排程的不信任。
    @Test func editingModeSuppressesPassthrough() async throws {
        let spy = SpyInjector()
        let c = KeymapController(queue: InputQueue(injector: spy), profile: profileWithWAndJ())
        c.setEditing(true)
        c.handleKeyDown(.key("k"))
        // 否定訊號用固定等待抓，不借 z 的到達反推——理由見上方 doc comment。
        try await Task.sleep(for: .milliseconds(100))
        c.setEditing(false)
        c.handleKeyDown(.key("z"))
        await spy.keyGate.wait(for: 1)
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
        let c = KeymapController(queue: InputQueue(injector: spy), profile: profileWithWAndJ())
        c.handleFlagsChanged(try flagsChangedEvent([.command]))            // 按住 ⌘
        c.handleFlagsChanged(try flagsChangedEvent([.command, .shift]))    // 再加 ⇧
        c.handleFlagsChanged(try flagsChangedEvent([.shift]))              // 放開 ⌘
        c.handleFlagsChanged(try flagsChangedEvent([]))                    // 放開 ⇧
        // 柵欄：送一顆確定會直通的鍵，等它到達。修飾鍵若有送出，一定排在 `z` 前面。
        // D6 之後這是因果保證（單一消費者依序送出），不再是「機率上大概已經跑完」。
        c.handleKeyDown(.key("z"))
        await spy.keyGate.wait(for: 1)
        #expect(spy.keyCalls.map(\.0) == [.key("z")])
    }

    /// 不變式：**只對「送過 down 且尚未送 up」的鍵送 up**——一個也不能少，一個也不能多。
    ///
    /// 少了會卡鍵：按住 `k`（直通已送 down）→ ⌘E 進編輯模式 → 放開 `k`，若編輯模式
    /// 一律不送，guest 的 `k` 就永遠按著。多了同樣是 bug：進編輯模式已經補送過 up，
    /// 使用者實際放開時不該再送第二個。
    @Test func editingReleasesInFlightKeysExactlyOnce() async throws {
        let spy = SpyInjector()
        let c = KeymapController(queue: InputQueue(injector: spy), profile: profileWithWAndJ())
        c.handleKeyDown(.key("k"))
        await spy.keyGate.wait(for: 1)
        c.setEditing(true)                       // ⌘E：必須把 in-flight 的 k 補送 up
        await spy.keyGate.wait(for: 2)
        c.handleKeyUp(.key("k"))                 // 使用者實際放開：不得再送第二個 up
        c.setEditing(false)
        c.handleKeyDown(.key("z"))               // 柵欄
        await spy.keyGate.wait(for: 3)
        #expect(spy.keyCalls.map(\.0) == [.key("k"), .key("k"), .key("z")])
        #expect(spy.keyCalls.map(\.1) == [true, false, true])
    }

    /// 同一條不變式的另一個觸發路徑：按住期間換 profile（編輯器存檔／偵測到別款遊戲），
    /// 那顆鍵從「沒綁」翻成「已綁」。up 仍然要走直通送出去，不能被引擎吃掉。
    @Test func profileReloadWhileKeyHeldStillReleasesGuestKey() async throws {
        let spy = SpyInjector()
        let c = KeymapController(queue: InputQueue(injector: spy), profile: nil)   // 起初全部直通
        c.handleKeyDown(.key("w"))
        await spy.keyGate.wait(for: 1)
        c.reload(profileWithWAndJ())                          // w 現在被搖桿綁走
        c.handleKeyUp(.key("w"))
        await spy.keyGate.wait(for: 2)
        #expect(spy.keyCalls.map(\.0) == [.key("w"), .key("w")])
        #expect(spy.keyCalls.map(\.1) == [true, false])
    }

    /// D23：移除 profile 之前必須送出舊搖桿的 up。
    @Test func removingProfileReleasesHeldJoystick() async throws {
        let spy = SpyInjector()
        let c = KeymapController(queue: InputQueue(injector: spy), profile: profileWithWAndJ())
        c.handleKeyDown(.key("w"))
        c.reload(nil)
        c.handleKeyDown(.key("z")) // 單一消費者的柵欄：更早的觸點已全部抵達。
        await spy.keyGate.wait(for: 1)
        #expect(spy.touchCalls == 2)
        let pressed = try #require(spy.touchFrames.first?.first { $0.identifier == 1 })
        let released = try #require(spy.touchFrames.last?.first { $0.identifier == 1 })
        #expect(pressed.down)
        #expect(!released.down)
        #expect(!c.hasProfile)
    }

    /// D23：先釋放舊 profile，再從乾淨狀態開始使用新 profile。
    @Test func replacingProfileReleasesHeldJoystickAndStartsClean() async throws {
        let spy = SpyInjector()
        let c = KeymapController(queue: InputQueue(injector: spy), profile: profileWithWAndJ())
        let replacement = KeymapProfile(gameId: "other", version: 1, bindings: [
            .tap(key: .key("j"), at: NormPoint(x: 0.6, y: 0.4)),
            .joystick(up: .key("w"), down: .key("s"), left: .key("a"), right: .key("d"),
                      center: NormPoint(x: 0.3, y: 0.7), radius: 0.1),
        ])
        c.handleKeyDown(.key("w"))
        c.reload(replacement)
        c.handleKeyDown(.key("j"))
        c.handleKeyDown(.key("z"))
        await spy.keyGate.wait(for: 1)
        let frames = spy.touchFrames
        #expect(frames.count == 3)
        let releasedFrame = try #require(frames.dropFirst().first)
        let released = try #require(releasedFrame.first { $0.identifier == 1 })
        #expect(!released.down)
        let stick = try #require(frames.last?.first { $0.identifier == 2 })
        let tap = try #require(frames.last?.first { $0.identifier == 1 })
        #expect(!stick.down)
        #expect(stick.point == NormPoint(x: 0.3, y: 0.7))
        #expect(tap.down)
        #expect(tap.point == NormPoint(x: 0.6, y: 0.4))
    }

    /// D11：沒有後續 keyUp，失焦也必須同時放開綁定觸點與直通鍵。
    @Test func losingFocusReleasesTouchesAndPassthroughKeys() async throws {
        let spy = SpyInjector()
        let queue = InputQueue(injector: spy)
        let c = KeymapController(queue: queue, profile: profileWithWAndJ())
        c.handleKeyDown(.key("w"))
        c.handleKeyDown(.key("j"))
        c.handleKeyDown(.key("k"))
        c.loseFocus()
        // 兩個固定柵欄，缺少 k up 時也能前進到斷言，不等待不存在的釋放事件。
        queue.key(.key("z"), down: true)
        queue.key(.key("z"), down: false)
        await spy.keyGate.wait(for: 3)
        #expect(spy.touchCalls == 3)
        let released = try #require(spy.touchFrames.last)
        #expect(released.map(\.identifier) == [1, 2])
        #expect(released.allSatisfy { !$0.down })
        let kCalls = spy.keyCalls.filter { $0.0 == .key("k") }
        #expect(kCalls.count == 2)
        #expect(try #require(kCalls.first).1)
        #expect(try !#require(kCalls.last).1)
    }

    /// 編輯器拖動造成 reload 時，不得多送釋放快照到 guest。
    @Test func editingReloadDoesNotSendTouchFrames() async {
        let spy = SpyInjector()
        let queue = InputQueue(injector: spy)
        let c = KeymapController(queue: queue, profile: profileWithWAndJ())
        c.setEditing(true)
        let before = spy.touchCalls
        c.reload(profileWithWAndJ())
        queue.key(.key("z"), down: true) // 排在 reload 後的柵欄，不必離開編輯模式。
        await spy.keyGate.wait(for: 1)
        #expect(spy.touchCalls == before)
    }

    /// 編輯模式期間，引擎的 `pressed` 仍必須追得上實體鍵狀態。
    ///
    /// 擋點只能是 `emit`（不送出去），不能是 `route` 提早 return（引擎看不到事件）。
    /// 後者的症狀是幽靈搖桿：按住 `w` → ⌘E → 放開 `w` → 離開編輯模式，引擎裡 `w`
    /// 還按著，之後按 `s` 會與 `w` 相消成「沒有方向」，使用者看到搖桿不動。
    @Test func editingDoesNotDesyncEngineState() async throws {
        let spy = SpyInjector()
        let c = KeymapController(queue: InputQueue(injector: spy), profile: profileWithWAndJ())
        c.handleKeyDown(.key("w"))
        await spy.touchGate.wait(for: 1)
        c.setEditing(true)
        c.handleKeyUp(.key("w"))     // emit 被擋，但引擎必須看到這個 up
        c.setEditing(false)
        c.handleKeyDown(.key("s"))
        await spy.touchGate.wait(for: 2)
        // profileWithWAndJ 的搖桿是第一個 binding → identifier 1，圓心 y=0.75、半徑 0.1。
        let stick = try #require(spy.touchFrames.last?.first { $0.identifier == 1 })
        #expect(stick.down)                              // w 若殘留 → 相消 → down=false
        #expect(abs(stick.point.y - 0.85) < 0.0001)      // 純 s = 向下滿舵
    }

    /// D6：直通鍵的 down/up 到達 guest 的順序必須等於按放順序，即使 down 那次比較慢。
    ///
    /// 對調就是**永久卡鍵**——guest 那顆鍵從此一直按著，而且汙染的是整個 guest 鍵盤
    /// 輸入，不只當下那款遊戲。快照有下一幀可以自癒，邊緣事件沒有。
    @Test(.timeLimit(.minutes(1)))
    func passthroughKeysReachGuestInPressOrder() async {
        let probe = OrderProbe { $0.hasSuffix("down") ? .milliseconds(60) : .milliseconds(10) }
        let c = KeymapController(queue: InputQueue(injector: probe), profile: nil)
        c.handleKeyDown(.key("k"))
        c.handleKeyUp(.key("k"))
        await probe.waitForArrivals(2)
        #expect(probe.arrivals == ["k down", "k up"])
    }

    /// D6 的另一半：綁定鍵走觸控快照，晚到的舊快照會覆蓋新狀態（幽靈觸點／吃掉動作）。
    ///
    /// 按下 `w` 產生「搖桿 down」的快照、放開產生「搖桿 up」的快照。兩者對調，guest
    /// 端就停在按著的狀態。
    @Test(.timeLimit(.minutes(1)))
    func touchSnapshotsReachGuestInEventOrder() async {
        let probe = OrderProbe { $0 == "touch [1]" ? .milliseconds(60) : .milliseconds(10) }
        let c = KeymapController(queue: InputQueue(injector: probe), profile: profileWithWAndJ())
        c.handleKeyDown(.key("w"))
        c.handleKeyUp(.key("w"))
        await probe.waitForArrivals(2)
        #expect(probe.arrivals == ["touch [1]", "touch []"])
    }
}

@MainActor @Suite struct IMEKeymapSuspensionTests {
    @Test func textModeReleasesThenSuspendsEntireMapping() async throws {
        let spy = SpyInjector()
        let queue = InputQueue(injector: spy)
        let controller = KeymapController(queue: queue, profile: profileWithWAndJ())
        controller.handleKeyDown(.key("w"))
        controller.handleKeyDown(.key("q"))
        controller.setTextMode(true)
        await queue.drained()
        let count = spy.touchCalls
        let keys = spy.keyCalls.count
        let last = try #require(spy.keyCalls.last)
        #expect(last.0 == .key("q") && !last.1)
        controller.handleKeyDown(.key("w"))
        controller.handleKeyDown(.key("q"))
        controller.handleMouseMoved(dx: 1, dy: 2)
        controller.handleFlagsChanged(try flagsChangedEvent(.shift))
        await queue.drained()
        #expect(spy.touchCalls == count)
        #expect(spy.keyCalls.count == keys)
        controller.setTextMode(false)
        controller.handleKeyDown(.key("q"))
        await queue.drained()
        #expect(spy.keyCalls.count == keys + 1)
    }
}
