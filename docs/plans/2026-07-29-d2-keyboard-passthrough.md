# D2 鍵盤直通 實作計畫

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 讓使用者在鏡像視窗裡按鍵能送到 guest——keymap profile 沒綁的鍵走 `sendKey` 直通，綁到的維持現行觸控路徑。

**Architecture:** NSEvent 的欄位經 `KeyTranslate`（MirageCore 純函式）換算成 W3C key；`KeymapController` 依 `KeymapEngine.handles(_:)` 分流到觸控或 `sendKey`。傳輸只走 `KeyboardEvent.key` 這條路（已實測十個鍵全通）。

**Tech Stack:** Swift 6.2（語言模式 v5，`-strict-concurrency=complete`）、swift-testing、grpc-swift 1.27.5、AppKit。

## Global Constraints

- 設計依據：`docs/specs/2026-07-29-d2-keyboard-passthrough-design.md`。有衝突以設計文件為準。
- **只用 `KeyboardEvent.key`**，不得引入 `keyCode`／`codeType`／`text` 路徑（設計 §2：`.mac` 送不出字母 `a`，因為 mac 虛擬鍵碼 0 在 proto3 是預設值不會序列化）。
- **帶 ⌘ 的組合鍵一律不直通**。
- 純邏輯一律放 `MirageCore`（可單元測試），AppKit 相依留在 `MirageShell`。
- 測試框架用 swift-testing（`@Suite` / `@Test` / `#expect`），**不得**用 `guard <env> else { return }` 做 skip——要用 `@Test(.enabled(if:))` 搭 `LiveGate`（`app/Tests/MirageCoreTests/LiveGate.swift`）。
- 每個 task 結束前跑 `cd app && swift test`，全綠才 commit。
- 全部完成後跑 `cd app && ./scripts/ci.sh`，三道閘門皆須通過。

## File Structure

| 檔案 | 動作 | 責任 |
|---|---|---|
| `app/Sources/MirageCore/Keymap/KeyTranslate.swift` | 建立 | NSEvent 欄位 → W3C `KeyCode?`。純函式，無 AppKit |
| `app/Tests/MirageCoreTests/KeyTranslateTests.swift` | 建立 | 上者的逐行單元測試 |
| `app/Sources/MirageCore/Keymap/KeymapEngine.swift` | 修改 | `isMapped` → `public func handles(_:)` |
| `app/Tests/MirageCoreTests/KeymapEngineTests.swift` | 修改 | 補 `handles` 的測試 |
| `app/Sources/MirageCore/InputInjecting.swift` | 建立 | 注入縫：`sendTouches` + `sendKey`，讓 controller 可測 |
| `app/Sources/MirageShell/Keymap/KeymapController.swift` | 修改 | 分流：`handles` → 觸控，否則 → `sendKey` |
| `app/Tests/MirageShellTests/KeymapControllerRoutingTests.swift` | 建立 | 分流測試（假 injector 記錄呼叫） |
| `app/Sources/MirageShell/MirrorView.swift` | 修改 | `keyCode(from:)` 改呼叫 `KeyTranslate` |
| `app/Sources/MirageShell/Lifecycle/MenuBarController.swift` | 修改 | 加「返回／主畫面／最近任務」三項 |
| `app/Sources/MirageShell/AppModel.swift` | 修改 | 綁定上述三個回呼 |
| `app/scripts/verify_keyboard.sh` | 建立 | 活體驗證：getevent 當儀器，有真斷言 |
| `app/README.md`、`docs/specs/2026-07-29-project-review.md` | 修改 | 交付紀錄與債務表 |

---

### Task 1: `KeyTranslate` 純函式

**Files:**
- Create: `app/Sources/MirageCore/Keymap/KeyTranslate.swift`
- Test: `app/Tests/MirageCoreTests/KeyTranslateTests.swift`

**Interfaces:**
- Consumes: 既有的 `KeyCode`（`app/Sources/MirageCore/Keymap/KeyCode.swift`，`case key(String)` / `case mouse(MouseButton)`）。
- Produces: `KeyTranslate.w3c(virtualKey: UInt16, characters: String?, hasCommand: Bool) -> KeyCode?`，Task 4 的 `MirrorMTKView` 會呼叫它。

- [ ] **Step 1: 寫失敗測試**

建立 `app/Tests/MirageCoreTests/KeyTranslateTests.swift`：

```swift
import Testing
@testable import MirageCore

@Suite struct KeyTranslateTests {
    /// 一般可列印字元走字元路徑——要版面感知（Shift+2 在美式版面是 "@"）。
    @Test func printableCharacterPassesThrough() {
        #expect(KeyTranslate.w3c(virtualKey: 0, characters: "a", hasCommand: false) == .key("a"))
        #expect(KeyTranslate.w3c(virtualKey: 19, characters: "@", hasCommand: false) == .key("@"))
        #expect(KeyTranslate.w3c(virtualKey: 49, characters: " ", hasCommand: false) == .key(" "))
    }

    /// 特殊鍵走虛擬鍵碼路徑——charactersIgnoringModifiers 對 Enter 給 "\r"、
    /// 對方向鍵給私用區字元，都不是 emulator 認得的 W3C 值。
    @Test func specialKeysMapByVirtualKeyCode() {
        #expect(KeyTranslate.w3c(virtualKey: 36, characters: "\r", hasCommand: false) == .key("Enter"))
        #expect(KeyTranslate.w3c(virtualKey: 51, characters: "\u{7f}", hasCommand: false) == .key("Backspace"))
        #expect(KeyTranslate.w3c(virtualKey: 48, characters: "\t", hasCommand: false) == .key("Tab"))
        #expect(KeyTranslate.w3c(virtualKey: 123, characters: nil, hasCommand: false) == .key("ArrowLeft"))
        #expect(KeyTranslate.w3c(virtualKey: 124, characters: nil, hasCommand: false) == .key("ArrowRight"))
        #expect(KeyTranslate.w3c(virtualKey: 125, characters: nil, hasCommand: false) == .key("ArrowDown"))
        #expect(KeyTranslate.w3c(virtualKey: 126, characters: nil, hasCommand: false) == .key("ArrowUp"))
    }

    /// Esc 送 GoBack 而非 Escape：設計 D-4，兌現 P1-e 設計文件「Esc 在 guest 是返回鍵」。
    /// 兩者實測都送得到（KEY_ESC / KEY_BACK），這是刻意的產品選擇不是技術限制。
    @Test func escapeBecomesAndroidBack() {
        #expect(KeyTranslate.w3c(virtualKey: 53, characters: "\u{1b}", hasCommand: false) == .key("GoBack"))
    }

    /// ⌘ 組合一律不直通：Android 沒有 ⌘，且 ⌘C/⌘V 已有剪貼簿橋接負責，
    /// 送過去會貼兩次。特殊鍵也一樣擋——⌘Enter 不該變成 guest 的 Enter。
    @Test func commandCombinationsAreNeverForwarded() {
        #expect(KeyTranslate.w3c(virtualKey: 8, characters: "c", hasCommand: true) == nil)
        #expect(KeyTranslate.w3c(virtualKey: 36, characters: "\r", hasCommand: true) == nil)
    }

    /// 沒有字元又不是已知特殊鍵 → nil，不猜。
    @Test func unknownKeyWithoutCharactersIsDropped() {
        #expect(KeyTranslate.w3c(virtualKey: 999, characters: nil, hasCommand: false) == nil)
        #expect(KeyTranslate.w3c(virtualKey: 999, characters: "", hasCommand: false) == nil)
    }
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd app && swift test --filter KeyTranslateTests 2>&1 | tail -20`
Expected: 編譯失敗，`cannot find 'KeyTranslate' in scope`。

- [ ] **Step 3: 寫實作**

建立 `app/Sources/MirageCore/Keymap/KeyTranslate.swift`：

```swift
import Foundation

/// NSEvent 的欄位 → 要送給 guest 的 W3C key。純函式，刻意不吃 `NSEvent`——
/// AppKit 型別無法在 MirageCore 單元測試，而「哪顆鍵該送什麼」正是唯一值得測的部分。
/// 比照 `ForegroundParser`／`ActivationDecider`／`StreamSize` 的既有慣例。
///
/// 傳輸端只走 `KeyboardEvent.key`（W3C 字串）。2026-07-29 在活模擬器上用
/// `adb shell getevent -l` 實測：a／Enter／Backspace／Tab／Escape／方向鍵／
/// GoBack／GoHome／AppSwitch 十個鍵全部送達，推翻 proto 自己「只保證可列印 ASCII」
/// 的保守說法。完整數據見 `docs/specs/2026-07-29-d2-keyboard-passthrough-design.md` §2。
public enum KeyTranslate {
    /// macOS 虛擬鍵碼 → W3C key。**用鍵碼不用字元**：字元隨鍵盤版面變，
    /// 而「哪顆實體鍵」不變；且 `charactersIgnoringModifiers` 對這些鍵給的是
    /// 控制字元或私用區字元（Enter → "\r"、方向鍵 → U+F700 區段），emulator 不認得。
    ///
    /// 空白鍵**刻意不列入**：它的字元 " " 本身就是合法的 W3C key（實測送達），
    /// 走一般字元路徑即可，多一個表項只是多一個要維護的地方。
    ///
    /// 鍵碼來源：Carbon HIToolbox `Events.h` 的 `kVK_*`。
    static let specialKeys: [UInt16: String] = [
        36: "Enter",        // kVK_Return
        48: "Tab",          // kVK_Tab
        51: "Backspace",    // kVK_Delete（macOS 的 Delete 鍵是退格）
        53: "GoBack",       // kVK_Escape → Android 返回鍵（設計 D-4）
        123: "ArrowLeft",
        124: "ArrowRight",
        125: "ArrowDown",
        126: "ArrowUp",
    ]

    /// - Parameters:
    ///   - virtualKey: `NSEvent.keyCode`
    ///   - characters: `NSEvent.charactersIgnoringModifiers`
    ///   - hasCommand: `NSEvent.modifierFlags.contains(.command)`
    /// - Returns: 要直通的鍵；`nil` 代表不送（⌘ 組合，或無法辨識）。
    public static func w3c(virtualKey: UInt16,
                           characters: String?,
                           hasCommand: Bool) -> KeyCode? {
        // ⌘ 一律不送。放在最前面：即使是已知特殊鍵也擋，⌘Enter 不該變成 guest 的 Enter。
        if hasCommand { return nil }
        if let special = specialKeys[virtualKey] { return .key(special) }
        guard let characters, !characters.isEmpty else { return nil }
        return .key(characters)
    }
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `cd app && swift test --filter KeyTranslateTests 2>&1 | grep -E '✔|✘|Test run'`
Expected: `Test run with 5 tests passed`。

- [ ] **Step 5: Commit**

```bash
cd /Users/hanfourhuang/Projects/mirage
git add app/Sources/MirageCore/Keymap/KeyTranslate.swift app/Tests/MirageCoreTests/KeyTranslateTests.swift
git commit -m "feat: KeyTranslate 把 NSEvent 欄位換算成 W3C key

純函式放 MirageCore，比照 ForegroundParser/StreamSize 的慣例——AppKit 型別
無法單元測試，但「哪顆鍵該送什麼」正是唯一值得測的部分。

特殊鍵用虛擬鍵碼查表而非字元：charactersIgnoringModifiers 對 Enter 給 \"\\r\"、
對方向鍵給私用區字元，emulator 都不認得。可列印字元仍走字元路徑以保持版面感知。

Esc 映到 GoBack 而非 Escape——實測兩者都送得到，這是產品選擇（兌現 P1-e 設計
文件寫明的「Esc 在 guest 是返回鍵」），不是技術限制。"
```

---

### Task 2: `KeymapEngine.handles(_:)`

**Files:**
- Modify: `app/Sources/MirageCore/Keymap/KeymapEngine.swift:71-76`（`isMapped`）
- Test: `app/Tests/MirageCoreTests/KeymapEngineTests.swift`（在既有 `@Suite` 內新增）

**Interfaces:**
- Consumes: 無新相依。
- Produces: `public func handles(_ code: KeyCode) -> Bool`，Task 3 的 `KeymapController` 會呼叫它。

- [ ] **Step 1: 寫失敗測試**

在 `app/Tests/MirageCoreTests/KeymapEngineTests.swift` 的 `KeymapEngineTests` suite 內、`tapDownProducesTouchThenUp` 之前插入：

```swift
    /// 分流的判定式：綁到的鍵走觸控，沒綁到的由呼叫端直通給 guest 鍵盤（D2）。
    /// 測試用的 profile 綁了 w/a/s/d（joystick）與 j（tap），look 的 activation 是 nil。
    @Test func handlesReportsBoundKeysOnly() {
        let e = engine()
        #expect(e.handles(.key("w")) == true)      // joystick
        #expect(e.handles(.key("d")) == true)
        #expect(e.handles(.key("j")) == true)      // tap
        #expect(e.handles(.key("k")) == false)     // 沒綁 → 直通
        #expect(e.handles(.key("Enter")) == false)
        #expect(e.handles(.mouse(.left)) == false)
    }
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd app && swift test --filter handlesReportsBoundKeysOnly 2>&1 | tail -15`
Expected: 編譯失敗，`value of type 'KeymapEngine' has no member 'handles'`。

- [ ] **Step 3: 寫實作**

在 `app/Sources/MirageCore/Keymap/KeymapEngine.swift` 中，把 private 的 `isMapped` 改為公開的 `handles`。原始碼是：

```swift
    private func isMapped(_ k: KeyCode) -> Bool {
        if let j = joystick, [j.up, j.down, j.left, j.right].contains(k) { return true }
        if taps.contains(where: { $0.key == k }) { return true }
        if let look, look.activation == k { return true }
        return false
    }
```

改成：

```swift
    /// 這顆鍵有沒有被 profile 綁住。
    ///
    /// 公開是為了讓 `KeymapController` 能分流：綁到的走觸控，沒綁到的直通給 guest
    /// 鍵盤（D2）。刻意**不改 `apply` 的簽章**去回傳「有沒有吃掉」——那會動到所有既有
    /// 引擎測試，而這裡要的只是一個布林值，述詞本來就已經存在。
    ///
    /// 命名從 `isMapped` 改為 `handles`：呼叫端讀起來是問句
    /// （`engine.handles(code)`），比 `isMapped` 更貼近它在分流點的角色。
    public func handles(_ k: KeyCode) -> Bool {
        if let j = joystick, [j.up, j.down, j.left, j.right].contains(k) { return true }
        if taps.contains(where: { $0.key == k }) { return true }
        if let look, look.activation == k { return true }
        return false
    }
```

同檔 `apply(_:)` 內唯一的呼叫端（第 55 行）也要改：

```swift
            if isMapped(k) { pressed.insert(k) } else { unmappedCount += 1 }
```

改成：

```swift
            if handles(k) { pressed.insert(k) } else { unmappedCount += 1 }
```

- [ ] **Step 4: 跑測試確認通過**

Run: `cd app && swift test --filter KeymapEngineTests 2>&1 | grep -E '✘|Test run'`
Expected: 全部通過，測試數比先前多 1。

- [ ] **Step 5: Commit**

```bash
cd /Users/hanfourhuang/Projects/mirage
git add app/Sources/MirageCore/Keymap/KeymapEngine.swift app/Tests/MirageCoreTests/KeymapEngineTests.swift
git commit -m "refactor: KeymapEngine 的 isMapped 公開為 handles

D2 的分流需要問引擎「這顆鍵你吃不吃」。述詞本來就存在（isMapped），只是 private。

刻意不改 apply 的簽章去回傳 .consumed/.passthrough——型別上更精確，但會動到所有
既有引擎測試，而這裡要的只是一個布林值。行為零改變。"
```

---

### Task 3: 注入縫 `InputInjecting` 與 `KeymapController` 分流

**Files:**
- Create: `app/Sources/MirageCore/InputInjecting.swift`
- Modify: `app/Sources/MirageShell/Keymap/KeymapController.swift:8, 26-29, 40-42, 63-66`
- Test: `app/Tests/MirageShellTests/KeymapControllerRoutingTests.swift`

**Interfaces:**
- Consumes: `KeymapEngine.handles(_:)`（Task 2）、既有 `KeyCode`／`TouchSpec`。
- Produces: `public protocol InputInjecting: Sendable`，含 `func sendTouches(_ touches: [TouchSpec]) async` 與 `func sendKey(_ code: KeyCode, down: Bool) async`；`KeymapController.init(client: any InputInjecting, profile: KeymapProfile?)`。

**為什麼需要這個協定**：`KeymapController` 目前吃具體型別 `EmulatorClient`（actor），沒有測試縫，
設計 §7 要求的「假 client 記錄 sendKey 呼叫」做不到。`EmulatorClient` 已有的兩個方法簽章
與協定完全吻合，所以 conformance 是空的、零行為改變。這也部分回應債務 D13 記載的
「`KeymapController` 吃具體型別，App 層行為只能靠讀碼驗證」。

- [ ] **Step 1: 寫失敗測試**

建立 `app/Tests/MirageShellTests/KeymapControllerRoutingTests.swift`：

```swift
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
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd app && swift test --filter KeymapControllerRoutingTests 2>&1 | tail -20`
Expected: 編譯失敗，`cannot find type 'InputInjecting' in scope`。

- [ ] **Step 3: 建立協定**

建立 `app/Sources/MirageCore/InputInjecting.swift`：

```swift
import Foundation

/// 輸入注入的注入縫。`EmulatorClient` 是唯一的產品實作，且它既有的兩個方法簽章
/// 與本協定完全吻合，所以 conformance 是空的、零行為改變。
///
/// **存在的理由**：`KeymapController` 原本吃具體型別 `EmulatorClient`（actor），
/// 沒有任何辦法在不建真 gRPC channel 的情況下觀察它送出了什麼——App 層的分流行為
/// 因此只能靠讀碼驗證（債務 D13 記載的問題之一）。有了這個協定，分流邏輯可以用
/// 記錄呼叫的假件逐條測試。
public protocol InputInjecting: Sendable {
    func sendTouches(_ touches: [TouchSpec]) async
    func sendKey(_ code: KeyCode, down: Bool) async
}

extension EmulatorClient: InputInjecting {}
```

- [ ] **Step 4: 改 `KeymapController` 吃協定並加分流**

在 `app/Sources/MirageShell/Keymap/KeymapController.swift`：

第 8 行 `private let client: EmulatorClient` 改成：

```swift
    private let client: any InputInjecting
```

第 26 行 `init(client: EmulatorClient, profile: KeymapProfile?) {` 改成：

```swift
    init(client: any InputInjecting, profile: KeymapProfile?) {
```

第 40-42 行的三個 handler：

```swift
    func handleKeyDown(_ code: KeyCode) { emit(engine?.apply(.keyDown(code))) }
    func handleKeyUp(_ code: KeyCode) { emit(engine?.apply(.keyUp(code))) }
    func handleMouseMoved(dx: Double, dy: Double) { emit(engine?.apply(.mouseMove(dx: dx, dy: dy))) }
```

改成：

```swift
    /// 分流（D2）：profile 綁到的鍵走觸控，沒綁到的直通給 guest 鍵盤。
    ///
    /// **為什麼不是「有 profile 就全走觸控」**：指標遊戲幾乎都會有 profile，那樣使用者
    /// 就永遠不能在遊戲的聊天框打字。分流之後 WASD 仍走搖桿，其餘鍵照常送到 guest。
    func handleKeyDown(_ code: KeyCode) { route(code, down: true) }
    func handleKeyUp(_ code: KeyCode) { route(code, down: false) }
    func handleMouseMoved(dx: Double, dy: Double) { emit(engine?.apply(.mouseMove(dx: dx, dy: dy))) }

    private func route(_ code: KeyCode, down: Bool) {
        // 編輯模式一律不送：使用者正在改鍵位，不是在玩。既有的 emit 也有同樣的 guard，
        // 這裡再擋一次是因為直通路徑不經過 emit。
        guard !editing else { return }
        if engine?.handles(code) == true {
            emit(engine?.apply(down ? .keyDown(code) : .keyUp(code)))
        } else {
            Task { [client] in await client.sendKey(code, down: down) }
        }
    }
```

- [ ] **Step 5: 跑測試確認通過**

Run: `cd app && swift test --filter KeymapControllerRoutingTests 2>&1 | grep -E '✔|✘|Test run'`
Expected: `Test run with 4 tests passed`。

- [ ] **Step 6: 跑完整套件確認無回歸**

Run: `cd app && swift test 2>&1 | grep -E '✘ Test|Test run with'`
Expected: 全綠，只有既有的 skipped 項目。

- [ ] **Step 7: Commit**

```bash
cd /Users/hanfourhuang/Projects/mirage
git add app/Sources/MirageCore/InputInjecting.swift app/Sources/MirageShell/Keymap/KeymapController.swift app/Tests/MirageShellTests/KeymapControllerRoutingTests.swift
git commit -m "feat: KeymapController 分流——profile 沒綁的鍵直通 guest 鍵盤

D2 的核心。原本 engine 回 nil 時 emit 什麼都不做，按鍵就在這裡被丟棄；
無 profile 時整條 optional chain 更是直接斷掉。

順帶加了 InputInjecting 協定當注入縫。KeymapController 原本吃具體型別
EmulatorClient（actor），沒辦法在不建真 gRPC channel 的情況下觀察它送出了什麼，
分流行為只能靠讀碼驗證。EmulatorClient 既有簽章與協定完全吻合，conformance 是空的。
這也部分回應 D13 記載的問題。"
```

---

### Task 4: `MirrorMTKView` 改用 `KeyTranslate`

**Files:**
- Modify: `app/Sources/MirageShell/MirrorView.swift:58-71`

**Interfaces:**
- Consumes: `KeyTranslate.w3c(virtualKey:characters:hasCommand:)`（Task 1）。
- Produces: 無新介面。`AppModel.swift:100` 的 `KeymapController(client: client, profile: profile)`
  **不需要改**——`EmulatorClient` 已透過 Task 3 的 extension 符合 `InputInjecting`，
  傳給 `any InputInjecting` 參數是隱式轉換。

**本 task 沒有單元測試**：`NSEvent` 無法在測試中合成得夠真實（`keyCode`／
`charactersIgnoringModifiers` 都是唯讀屬性），而所有值得測的判斷已經在 Task 1 的
`KeyTranslate` 裡逐行覆蓋了。這裡剩下的只是三行取值＋一次呼叫，肉眼可驗。
真實路徑由 Task 6 的活體驗證涵蓋。

- [ ] **Step 1: 改 `keyCode(from:)`**

原始碼（第 68-71 行）：

```swift
    private func keyCode(from event: NSEvent) -> KeyCode? {
        guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return nil }
        return .key(chars)      // W3C key 近似：單字元鍵直接用字元（"w"/"a"/…）
    }
```

改成：

```swift
    /// 換算邏輯本身在 `MirageCore.KeyTranslate`（純函式、逐行單元測試）——這裡只負責
    /// 從 `NSEvent` 取欄位。原本這個函式直接回 `.key(chars)`，那對 Enter 會送 "\r"、
    /// 對方向鍵會送私用區字元，emulator 都不認得；而且沒有擋 ⌘ 組合。
    private func keyCode(from event: NSEvent) -> KeyCode? {
        KeyTranslate.w3c(virtualKey: event.keyCode,
                         characters: event.charactersIgnoringModifiers,
                         hasCommand: event.modifierFlags.contains(.command))
    }
```

- [ ] **Step 2: 確認 `MirageCore` 已被 import**

Run: `head -5 app/Sources/MirageShell/MirrorView.swift`
Expected: 看到 `import MirageCore`。若沒有就加上（同檔已使用 `KeyCode`／`EmulatorClient`，理論上一定有）。

- [ ] **Step 3: 建置**

Run: `cd app && swift build 2>&1 | grep -E 'error|Build complete'`
Expected: `Build complete!`

- [ ] **Step 4: 跑完整套件確認無回歸**

Run: `cd app && swift test 2>&1 | grep -E '✘ Test|Test run with'`
Expected: 全綠。

- [ ] **Step 5: Commit**

```bash
cd /Users/hanfourhuang/Projects/mirage
git add app/Sources/MirageShell/MirrorView.swift
git commit -m "feat: MirrorMTKView 的按鍵換算改走 KeyTranslate

原本直接回 .key(charactersIgnoringModifiers)，對 Enter 會送 \"\\r\"、對方向鍵會送
私用區字元——emulator 都不認得；而且完全沒擋 ⌘ 組合。

換算邏輯留在 MirageCore 的純函式裡，這裡只負責從 NSEvent 取三個欄位。
本檔無單元測試：NSEvent 的 keyCode/charactersIgnoringModifiers 是唯讀屬性、
無法合成得夠真實，而值得測的判斷都已在 KeyTranslateTests 覆蓋。"
```

---

### Task 5: 選單列的「返回／主畫面／最近任務」

**Files:**
- Modify: `app/Sources/MirageShell/Lifecycle/MenuBarController.swift`
- Modify: `app/Sources/MirageShell/AppModel.swift`

**Interfaces:**
- Consumes: `EmulatorClient.sendKey(_:down:)`（既有）。
- Produces: `MenuBarController.onAndroidKey: ((String) -> Void)?`，由 `AppModel` 綁定。

**為什麼走選單列而不綁快速鍵**（設計 D-5）：⌘ 組合已在 Task 1 全面排除；F1–F3 在 macOS
預設是亮度／音量（除非使用者改過系統設定）；⌃A／⌃E 在文字欄位有既有語意。
選單列零衝突，而且可被發現——沒有人會自己猜到 ⌃⌥H 是 Home。

- [ ] **Step 1: 加回呼屬性與三個選單項**

在 `MenuBarController` 的回呼區（第 24 行 `var onToggleMute: (() -> Void)?` 之後）加入：

```swift
    /// D2：Android 實體鍵。參數是 W3C key 字串（"GoBack"／"GoHome"／"AppSwitch"），
    /// 由 AppModel 綁定到 `client.sendKey`。
    ///
    /// 走選單列而不綁快速鍵是刻意的：⌘ 組合一律不直通給 guest（見 KeyTranslate），
    /// F1–F3 在 macOS 預設是亮度／音量，⌃A／⌃E 在文字欄位有既有語意——每個候選鍵
    /// 都有衝突。選單列零衝突且可被發現。Esc→GoBack 另外由 KeyTranslate 直接處理。
    var onAndroidKey: ((String) -> Void)?
```

在 `init` 裡，「靜音」那一項之後、第一個 `.separator()` 之前（第 47-48 行之間）插入：

```swift
        menu.addItem(.separator())
        menu.addItem(withTitle: "返回", action: #selector(backTapped), keyEquivalent: "").target = self
        menu.addItem(withTitle: "主畫面", action: #selector(homeTapped), keyEquivalent: "").target = self
        menu.addItem(withTitle: "最近任務", action: #selector(recentsTapped), keyEquivalent: "").target = self
```

在 `@objc private func muteTapped()`（第 87 行）之後加入：

```swift
    @objc private func backTapped() { onAndroidKey?("GoBack") }
    @objc private func homeTapped() { onAndroidKey?("GoHome") }
    @objc private func recentsTapped() { onAndroidKey?("AppSwitch") }
```

- [ ] **Step 2: 在 `AppModel` 綁定回呼**

在 `app/Sources/MirageShell/AppModel.swift` 建立 menuBar 之後（第 216 行
`menuBar?.updateStatus(Self.label(connState))` 附近，與其他回呼綁定同區）加入：

```swift
        // D2：選單列的 Android 實體鍵。down 之後緊接 up——guest 收到的是一次完整按放，
        // 不是按住不放。sendKey 在未連線時靜默不送（與 sendTap/sendTouches 一致）。
        menuBar?.onAndroidKey = { [client] w3c in
            Task {
                await client.sendKey(.key(w3c), down: true)
                await client.sendKey(.key(w3c), down: false)
            }
        }
```

- [ ] **Step 3: 建置**

Run: `cd app && swift build 2>&1 | grep -E 'error|Build complete'`
Expected: `Build complete!`

- [ ] **Step 4: 跑完整套件**

Run: `cd app && swift test 2>&1 | grep -E '✘ Test|Test run with'`
Expected: 全綠。

- [ ] **Step 5: Commit**

```bash
cd /Users/hanfourhuang/Projects/mirage
git add app/Sources/MirageShell/Lifecycle/MenuBarController.swift app/Sources/MirageShell/AppModel.swift
git commit -m "feat: 選單列加「返回／主畫面／最近任務」

D2 的 Android 實體鍵部分。走選單列而不綁快速鍵是刻意的——⌘ 組合一律不直通、
F1–F3 在 macOS 預設是亮度音量、⌃A/⌃E 在文字欄位有既有語意，每個候選鍵都有衝突。
選單列零衝突且可被發現（沒有人會自己猜到 ⌃⌥H 是 Home）。

Esc→GoBack 由 KeyTranslate 直接處理，不重複走這條路。"
```

---

### Task 6: 活體驗證（getevent 當儀器，有真斷言）

**Files:**
- Create: `app/Tests/MirageCoreTests/KeyboardLiveTests.swift`
- Create: `app/scripts/verify_keyboard.sh`

**Interfaces:**
- Consumes: `EmulatorClient.sendKey(_:down:)`、`LiveGate.live`（`app/Tests/MirageCoreTests/LiveGate.swift`）。
- Produces: 無程式介面。腳本的退出碼即驗收訊號。

**職責切分要講清楚**：Swift 測試**只負責送鍵，不做任何斷言**——它看不到 guest 的
evdev 事件流。斷言全部在腳本裡（比對 `getevent` 的輸出）。這個切分是刻意的，
但也代表**那條 Swift 測試自己的綠燈什麼都不證明**，必須透過腳本跑。
測試的 doc comment 要寫明這件事，否則它就是下一個「回報 passed 但零斷言」。

**儀器選擇**：`adb shell getevent -l` 直接讀 guest kernel 的 evdev 事件流，
不是「開文字框打字看有沒有字」——後者是代理指標，沒出現字可能是鍵沒送到、
焦點不在輸入框、或輸入法沒起來，三種原因看起來一模一樣。

- [ ] **Step 1: 建立送鍵用的活體測試**

建立 `app/Tests/MirageCoreTests/KeyboardLiveTests.swift`：

```swift
import Foundation
import Testing
@testable import MirageCore

/// D2 活體：把一組固定的鍵送給 guest。
///
/// ⚠️ **本測試自己不做任何斷言，它的綠燈什麼都不證明。**
/// 它看不到 guest 收到什麼——判定在 `scripts/verify_keyboard.sh`，那支腳本一邊跑
/// `adb shell getevent -l` 一邊呼叫本測試，然後比對 evdev 事件。
/// **請跑 `./scripts/verify_keyboard.sh`，不要單獨跑這條測試。**
///
/// 之所以這樣切：Swift 這端沒有便宜的方法讀 guest 的 evdev 流，而
/// 「開個文字框打字看有沒有字」是代理指標——沒出現字可能是鍵沒送到、
/// 焦點不在輸入框、或輸入法沒起來，三種原因看起來一模一樣。
@Suite struct KeyboardLiveTests {
    /// 與 verify_keyboard.sh 的期待清單一一對應。改這裡要同步改那裡。
    static let sequence: [KeyCode] = [
        .key("a"), .key("Enter"), .key("Backspace"), .key("GoBack"),
    ]

    @Test(.enabled(if: LiveGate.live,
                   "需 MIRAGE_LIVE=1 與真模擬器；**請跑 scripts/verify_keyboard.sh**——單獨跑本測試不會驗證任何事"))
    func sendsKeySequenceToGuest() async throws {
        let client = EmulatorClient()
        await client.start(box: LatestFrameBox(), width: 540, height: 1200)
        try await Task.sleep(for: .seconds(2))          // 等連線與健康探測
        for code in Self.sequence {
            await client.sendKey(code, down: true)
            await client.sendKey(code, down: false)
            try await Task.sleep(for: .milliseconds(120))
        }
        try await Task.sleep(for: .milliseconds(300))
        await client.stop()
    }
}
```

- [ ] **Step 2: 建立驗證腳本**

建立 `app/scripts/verify_keyboard.sh`：

```bash
#!/usr/bin/env bash
# D2 鍵盤直通的活體驗證。
#
# **儀器**：adb shell getevent -l，直接讀 guest kernel 的 evdev 事件流。
# 不用「開文字框打字看有沒有字」——那是代理指標，沒出現字可能是鍵沒送到、
# 焦點不在輸入框、或輸入法沒起來，三種原因看起來一模一樣。
#
# **職責**：斷言全部在本腳本。`KeyboardLiveTests` 只負責送鍵、自己不斷言，
# 它的綠燈什麼都不證明（該檔 doc comment 已寫明）。
#
# **不是零斷言腳本**：每個期待的 evdev 鍵都會被檢查，缺一個就退出碼非零。
# （D9 記載 verify_snapshot.sh 是「11 行零斷言、只存 PNG 印字」——不重蹈。）
set -uo pipefail

TARGET_SERIAL="${MIRAGE_ADB_SERIAL:-emulator-5554}"
TARGET_PORT="${MIRAGE_PORT:-8554}"
ADB="$HOME/Library/Android/sdk/platform-tools/adb"

# 與 KeyboardLiveTests.sequence 一一對應。改一邊要同步改另一邊。
EXPECTED=(KEY_A KEY_ENTER KEY_BACKSPACE KEY_BACK)

cd "$(dirname "$0")/.." || exit 1
FAILURES=0

if [ ! -x "$ADB" ]; then
    echo "❌ 找不到可執行的 adb：$ADB"; exit 1
fi
if [ "$("$ADB" -s "$TARGET_SERIAL" get-state 2>/dev/null)" != "device" ]; then
    echo "❌ $TARGET_SERIAL 不在線。設 MIRAGE_ADB_SERIAL / MIRAGE_PORT 指定機器。"
    exit 1
fi
echo "✅ 目標：$TARGET_SERIAL（gRPC $TARGET_PORT）"

LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT

echo "=== 開始擷取 evdev 事件並送鍵 ==="
"$ADB" -s "$TARGET_SERIAL" shell getevent -l > "$LOG" 2>/dev/null &
GE_PID=$!
sleep 1                       # 暖機。實測 0.4 秒太短會產生假陰性

MIRAGE_LIVE=1 MIRAGE_PORT="$TARGET_PORT" \
    swift test --filter KeyboardLiveTests 2>&1 | tail -3

sleep 1
kill "$GE_PID" 2>/dev/null; wait "$GE_PID" 2>/dev/null

echo ""
echo "=== 判定 ==="
for key in "${EXPECTED[@]}"; do
    n=$(grep -c " $key " "$LOG" 2>/dev/null || true)
    if [ "${n:-0}" -ge 2 ]; then          # 一次按放 = DOWN + UP 兩行
        echo "✅ $key（$n 行）"
    else
        echo "❌ $key 只看到 ${n:-0} 行，期待 ≥2（DOWN + UP）"
        FAILURES=$((FAILURES + 1))
    fi
done

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "全部通過：${#EXPECTED[@]} 個鍵都送達 guest"
    exit 0
fi
echo "$FAILURES 個鍵沒送達"
exit 1
```

- [ ] **Step 3: 加執行權限並檢查語法**

Run: `cd app && chmod +x scripts/verify_keyboard.sh && bash -n scripts/verify_keyboard.sh && echo "語法 OK"`
Expected: `語法 OK`

- [ ] **Step 4: 確認未設 env 時測試如實顯示 skipped**

Run: `cd app && swift test --filter KeyboardLiveTests 2>&1 | grep -E 'skipped|Test run'`
Expected: 看到 `skipped:` 與那句「請跑 scripts/verify_keyboard.sh」。**不得**顯示 passed。

- [ ] **Step 5: 跑真正的活體驗證**

Run: `cd app && ./scripts/verify_keyboard.sh`
Expected: 四個鍵皆 ✅，退出碼 0。

若某個鍵 ❌，**先確認是不是量測問題再改產品碼**：暖機時間夠不夠、evdev 名稱猜對沒有
（設計 §2 記載這兩種假陰性各發生過一次）。用
`grep KEY_ "$LOG"` 看實際出現了什麼，不要假設。

- [ ] **Step 6: Commit**

```bash
cd /Users/hanfourhuang/Projects/mirage
git add app/Tests/MirageCoreTests/KeyboardLiveTests.swift app/scripts/verify_keyboard.sh
git commit -m "test: D2 活體驗證——getevent 當儀器，斷言在腳本裡

儀器用 adb shell getevent -l 直接讀 guest kernel 的 evdev 流，不用「開文字框打字
看有沒有字」——後者是代理指標，沒出現字可能是鍵沒送到、焦點不在輸入框、或輸入法
沒起來，三種原因看起來一模一樣。

職責切分：Swift 測試只送鍵、自己不斷言（它看不到 evdev），斷言全在腳本。
測試的 doc comment 明寫「本測試自己的綠燈什麼都不證明，請跑 verify_keyboard.sh」
——否則它就是下一個『回報 passed 但零斷言』。

腳本每個期待的鍵都檢查、缺一個就退出碼非零。D9 記載 verify_snapshot.sh 是
11 行零斷言只存 PNG 印字，不重蹈。"
```

---

### Task 7: 文件與債務表更新

**Files:**
- Modify: `app/README.md`（P1-c 段的多指注入條目、已知限制）
- Modify: `docs/specs/2026-07-29-project-review.md`（債務表 D2 那列、§8 A 節）

**Interfaces:** 無。

- [ ] **Step 1: 更新 README 的 `sendKey` 條目**

`app/README.md` 目前有這段（D15 那輪加的）：

```markdown
- **`sendKey`**：API 存在（`EmulatorClient.sendKey(_:down:)`），但**目前全碼庫零呼叫端**——
  鍵盤直通尚未接線，使用者在視窗裡打字 guest 收不到。見債務清單 D2。
```

改成：

```markdown
- **鍵盤直通（D2，2026-07-29）**：keymap profile **沒綁到**的鍵直接送給 guest 鍵盤
  （`EmulatorClient.sendKey`），綁到的維持觸控路徑——使用者可以一邊用搖桿一邊在遊戲
  聊天框打字。換算在 `MirageCore.KeyTranslate`（純函式、逐行單元測試）：特殊鍵用
  macOS 虛擬鍵碼查表（`charactersIgnoringModifiers` 對 Enter 給 `"\r"`、對方向鍵給
  私用區字元，emulator 不認得），可列印字元仍走字元路徑以保持版面感知。
  **帶 ⌘ 的組合一律不直通**（Android 沒有 ⌘；⌘C/⌘V 已有剪貼簿橋接，送了會貼兩次）。
  Esc → Android 返回鍵；主畫面／最近任務在選單列。
  傳輸只用 `KeyboardEvent.key`——實測十個鍵全通，見設計文件 §2。
  活體驗證：`./scripts/verify_keyboard.sh`（儀器是 `getevent`，不是目視）。
```

- [ ] **Step 2: 更新債務表**

在 `docs/specs/2026-07-29-project-review.md` 把 D2 那列：

```markdown
| **D2** | **鍵盤直通零實作**——`sendKey` 無呼叫端，無 profile 時按鍵直接丟棄 | 母計畫 Phase-1 交付項；使用者在視窗裡打字 guest 收不到 | 半天 | **P0** |
```

改成：

```markdown
| ~~**D2**~~ | ~~**鍵盤直通零實作**~~ | **✅ 已修（2026-07-29）**。`KeymapController` 依 `KeymapEngine.handles(_:)` 分流：profile 沒綁的鍵走 `sendKey` 直通。換算抽成 `MirageCore.KeyTranslate` 純函式；⌘ 組合不直通；Esc→GoBack；主畫面／最近任務走選單列。傳輸路徑由活體實測選定（`key` 十個鍵全通，`.mac` 送不出字母 a——proto3 的 0 是預設值不序列化）。驗證用 `getevent` 當儀器 | 實際約半天 | — |
```

- [ ] **Step 3: 更新 §8 A 節**

在 §8 A 節（根本沒做）的表格中，「鍵盤直通 `sendKey`」那列的「實際」欄位末尾加上：

```markdown
**✅ 已於 2026-07-29 實作（D2）**
```

- [ ] **Step 4: 跑完整閘門**

Run: `cd app && ./scripts/ci.sh`
Expected: 三道閘門全過，退出碼 0。

- [ ] **Step 5: Commit**

```bash
cd /Users/hanfourhuang/Projects/mirage
git add app/README.md docs/specs/2026-07-29-project-review.md
git commit -m "docs: D2 完成，更新交付紀錄與債務表

README 的 sendKey 條目原本寫「API 存在但全碼庫零呼叫端」——現在接上了，
連同換算規則、⌘ 過濾、Esc→GoBack、選單列項目與活體驗證方式一併寫清楚。

債務表 D2 標記完成，§8 A 節（根本沒做）那列同步更新——那一節正是靠結構性檢查
（公開 API 有沒有呼叫端）才找到這筆債的地方。"
```

---

## Self-Review

**規格涵蓋**：設計 §3 的七個決定對應 —— D-1 Task 3、D-2 Task 1+5、D-3 Task 1、
D-4 Task 1、D-5 Task 5、D-6 Task 2、D-7 Task 1。設計 §4.1–4.5 分別對應
Task 1／2／3／4／5。§7 測試策略對應 Task 1、2、3、6。§9 驗收條目 1–3 由
Task 1–3 涵蓋，條目 4 由 Task 6，條目 5 由 Task 7 Step 4。

**型別一致性**：`KeyTranslate.w3c(virtualKey:characters:hasCommand:)` 在 Task 1 定義、
Task 4 呼叫，簽章相同。`KeymapEngine.handles(_:)` 在 Task 2 定義、Task 3 呼叫。
`InputInjecting` 的兩個方法簽章與 `EmulatorClient+Input.swift:44,50` 逐字相同
（`sendTouches(_ touches: [TouchSpec]) async`、`sendKey(_ code: KeyCode, down: Bool) async`），
所以 extension 可以是空的。`MenuBarController.onAndroidKey` 在 Task 5 定義並在同 task 綁定。

**已知的順序相依**：Task 3 必須在 Task 2 之後（用到 `handles`）；Task 4 必須在
Task 1 之後（用到 `KeyTranslate`）；Task 6 必須在 Task 3、4 之後（活體要走完整路徑）。
Task 5 只依賴既有的 `sendKey`，可與 Task 1–4 並行。
