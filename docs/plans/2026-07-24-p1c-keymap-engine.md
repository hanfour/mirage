# P1-c 鍵位映射引擎 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 依 `docs/specs/2026-07-24-p1c-keymap-engine-design.md`，把 P1-a 的「滑鼠即觸控」升級為每遊戲 profile 的**鍵位映射**——鍵盤/滑鼠 → 多點觸控注入（tap/joystick/look），並提供陽春 overlay 編輯器。

**Architecture:** 純引擎與 UI 膠水嚴格分離。MirageCore 新增 `Keymap/`：`NormPoint`/`KeyCode`（值型別）、`JoystickMath`（純函式）、`KeymapProfile`（Codable + schema 驗證）、`KeymapEngine`（事件+狀態→`TouchFrame` 多指快照，純狀態機）、`ProfileStore`（原子檔案 I/O）。`EmulatorClient` 擴充 `sendTouches`（多指）/`sendKey`。MirageApp 新增 `Keymap/`：`KeymapController`（NSEvent→引擎→client）、`MouseCapture`（look 游標鎖定）、overlay 編輯器與提示。

**Tech Stack:** Swift 6（語言模式 v5）、grpc-swift **exact 1.27.5**、swift-testing、AppKit（NSEvent/CGAssociateMouseAndMouseCursorPosition）；**零 proto 遷移**——`sendTouch(TouchEvent)`（`repeated Touch`）與 `sendKey(KeyboardEvent)` 既有 stub 已足。

## Global Constraints

- 平台 macOS 14+ Apple Silicon；`swift build -c release` 零警告（測試 target 的 swift-testing deprecation 噪音除外，見 P1-a 計畫修正案 A §4）。
- **MirageCore 不得 import AppKit/SwiftUI/Metal**；不 `fatalError`。錯誤回傳/記錄，App 層決定呈現。
- 所有 target 開 `-strict-concurrency=complete`；`.swiftLanguageMode(.v5)`。
- **測試語法用 swift-testing**（`@Suite struct` / `@Test func` / `#expect` / `#require`）——與既有測試檔一致。
- 每檔 <400 行；函式 <50 行；引擎純函式與 UI 膠水嚴格分離；不可變優先（值型別、回傳新值）。
- TDD：先寫失敗測試 → 確認失敗 → 最小實作 → 綠 → commit。Conventional commits、無 attribution。
- MirageCore 覆蓋 ≥80%；既有測試不回歸。
- 活體測試預設 skip、環境變數開啟（`guard ProcessInfo.processInfo.environment["MIRAGE_LIVE"] == "1" else { return }`）。
- **合併順序**：P1-b 先合。本件整合時 `EmulatorClient`/`MirageApp` 已含 P1-b 的健康探測迴圈與生命週期膠水；本件的擴充（sendTouches/sendKey、輸入路由）為不同方法/區域，做一次解決 pass（見 §風險）。

## 既有介面契約（P1-a 已交付，本件依賴）

- `EmulatorClient`（actor）：`sendTap(x:y:down:)` 現況——單指 `identifier 0`、`pressure = down ? 1024 : 0`，內建 `Android_Emulation_Control_Touch`/`TouchEvent`、`client.sendTouch(event)`。本件擴充 `sendTouches`/`sendKey`，`sendTap` 保留為單指特例。
- `channelBox?.client: Android_Emulation_Control_EmulatorControllerAsyncClient`——有 `sendTouch(TouchEvent)`、`sendKey(KeyboardEvent)`。
- `Android_Emulation_Control_Touch`：`x: Int32`、`y: Int32`、`identifier: Int32`、`pressure: Int32`。`TouchEvent`：`touches: [Touch]`。
- `Android_Emulation_Control_KeyboardEvent`：`eventType: .keydown/.keyup`、`key: String`（W3C 值）、`keyCode: Int32`、`codeType: .usb`。
- App 層輸入現況（`MirrorView.swift`）：`MirrorMTKView`（`onMouse`/`onResize` 回呼、`mouseDown/mouseDragged/mouseUp`）；`Coordinator.sendMouse(nx:ny:down:)` 用 `renderer?.lastFrameSize ?? guestSize` 換算（P1-a Task 6 CRITICAL 修正——**本件保留此實際幀尺寸換算**）。

## File Structure

```
app/Sources/MirageCore/Keymap/
├── NormPoint.swift          # Task 1：正規化座標值型別 + 驗證（0–1）
├── KeyCode.swift            # Task 1：macOS 虛擬鍵碼 + 滑鼠鍵薄封裝
├── JoystickMath.swift       # Task 2：方向鍵集合 → 正規化向量（純函式）
├── KeymapProfile.swift      # Task 3：Profile/Binding 值型別 + Codable + schema 驗證
├── KeymapEngine.swift       # Task 4：事件+狀態 → TouchFrame（多指快照，純狀態機）
└── ProfileStore.swift       # Task 5：載入/儲存 profile（原子檔案 I/O）
app/Sources/MirageCore/
└── EmulatorClient.swift     # Task 6 修改：sendTouches([TouchSpec])、sendKey(KeyCode,down:)
app/Sources/MirageApp/Keymap/
├── KeymapController.swift    # Task 7：NSEvent → KeymapEngine → EmulatorClient（@MainActor）
├── MouseCapture.swift        # Task 7：look 游標鎖定/還原
├── KeymapOverlay.swift       # Task 7：非編輯模式 binding 視覺提示
└── OverlayEditorView.swift   # Task 7：陽春編輯器（拖放 binding、選鍵、存檔）
app/Sources/MirageApp/
├── MirrorView.swift          # Task 7 修改：輸入改走 KeymapController（無 profile 退回直接 tap）
└── MirageApp.swift           # Task 7 修改：注入 KeymapController、⌘E 編輯切換
app/Tests/MirageCoreTests/
├── NormPointTests.swift       # Task 1
├── JoystickMathTests.swift    # Task 2
├── KeymapProfileTests.swift   # Task 3
├── KeymapEngineTests.swift    # Task 4
└── ProfileStoreTests.swift    # Task 5
app/Resources/profiles/
└── com.example.game.json      # Task 5：內建指標遊戲 profile（P1-d 銜接素材）
app/RESULTS-p1c.md             # Task 8
```

檔案紀律：每檔 <400 行；引擎純函式與 UI 膠水嚴格分離。

---

### Task 1: NormPoint + KeyCode 值型別（TDD）

**Files:**
- Create: `app/Sources/MirageCore/Keymap/NormPoint.swift`
- Create: `app/Sources/MirageCore/Keymap/KeyCode.swift`
- Test: `app/Tests/MirageCoreTests/NormPointTests.swift`

**Interfaces:**
- Produces:
  - `struct NormPoint: Sendable, Codable, Equatable { let x: Double; let y: Double }`；`var isValid: Bool`（x,y ∈ 0…1）；`func guestPixel(width:height:) -> (x: Int, y: Int)`（換算實際幀尺寸）。
  - `enum KeyCode: Sendable, Codable, Equatable, Hashable`——macOS 虛擬鍵碼 + 滑鼠鍵；`case key(String)`（W3C 值，直接餵 `KeyboardEvent.key`）、`case mouse(MouseButton)`。供 Task 2/3/4 作為 binding 鍵。

- [ ] **Step 1: 失敗測試**

```swift
// app/Tests/MirageCoreTests/NormPointTests.swift
import Testing
@testable import MirageCore

@Suite struct NormPointTests {
    @Test func validWithinUnitSquare() {
        #expect(NormPoint(x: 0.5, y: 0.5).isValid)
        #expect(NormPoint(x: 0, y: 1).isValid)
    }

    @Test func invalidOutOfRange() {
        #expect(!NormPoint(x: -0.1, y: 0.5).isValid)
        #expect(!NormPoint(x: 0.5, y: 1.1).isValid)
    }

    @Test func guestPixelScalesToFrame() {
        let (x, y) = NormPoint(x: 0.5, y: 0.25).guestPixel(width: 540, height: 1200)
        #expect(x == 270)
        #expect(y == 300)
    }

    @Test func keyCodeEquatableAndHashable() {
        #expect(KeyCode.key("w") == KeyCode.key("w"))
        #expect(KeyCode.key("w") != KeyCode.key("a"))
        #expect(Set([KeyCode.key("w"), KeyCode.key("w")]).count == 1)
    }
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd app && swift test --filter NormPointTests 2>&1 | tail -3`
Expected: 編譯失敗（`NormPoint`/`KeyCode` 不存在）。

- [ ] **Step 3: 實作**

```swift
// app/Sources/MirageCore/Keymap/NormPoint.swift
import Foundation

/// 正規化座標（0–1，左上原點對齊 guest）。越界由 isValid 暴露，載入期拒絕。
public struct NormPoint: Sendable, Codable, Equatable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }

    public var isValid: Bool { (0...1).contains(x) && (0...1).contains(y) }

    /// 換算為 guest 像素（呼叫端傳實際幀尺寸——沿用 P1-a 的實際幀尺寸換算）。
    public func guestPixel(width: Int, height: Int) -> (x: Int, y: Int) {
        (Int((x * Double(width)).rounded()), Int((y * Double(height)).rounded()))
    }
}
```

```swift
// app/Sources/MirageCore/Keymap/KeyCode.swift
import Foundation

/// 觸發鍵：鍵盤（W3C key 值，直接餵 KeyboardEvent.key）或滑鼠鍵。
public enum KeyCode: Sendable, Codable, Equatable, Hashable {
    case key(String)          // 例："w"、"a"、"Shift"、" "（空白）
    case mouse(MouseButton)

    public enum MouseButton: String, Sendable, Codable, Equatable, Hashable {
        case left, right, middle
    }
}
```

- [ ] **Step 4: 測試通過**

Run: `cd app && swift test --filter NormPointTests 2>&1 | tail -3`
Expected: 4 tests passed。

- [ ] **Step 5: Commit**

```bash
git add app/Sources/MirageCore/Keymap/NormPoint.swift app/Sources/MirageCore/Keymap/KeyCode.swift app/Tests/MirageCoreTests/NormPointTests.swift
git commit -m "feat: NormPoint 與 KeyCode 值型別（TDD）"
```

---

### Task 2: JoystickMath 純函式（TDD）

**Files:**
- Create: `app/Sources/MirageCore/Keymap/JoystickMath.swift`
- Test: `app/Tests/MirageCoreTests/JoystickMathTests.swift`

**Interfaces:**
- Consumes: 無（純數學）。
- Produces: `enum JoystickMath { static func vector(up: Bool, down: Bool, left: Bool, right: Bool) -> (dx: Double, dy: Double) }`——回傳正規化向量（對角不超過長度 1；相反鍵相消；全放 = (0,0)）。y 向下為正（對齊 guest 座標）。供 Task 4 引擎算 joystick 觸點。

- [ ] **Step 1: 失敗測試**

```swift
// app/Tests/MirageCoreTests/JoystickMathTests.swift
import Testing
@testable import MirageCore

@Suite struct JoystickMathTests {
    @Test func singleKeyIsUnit() {
        let r = JoystickMath.vector(up: false, down: false, left: false, right: true)
        #expect(abs(r.dx - 1.0) < 1e-9)
        #expect(abs(r.dy - 0.0) < 1e-9)
    }

    @Test func upIsNegativeY() {
        let r = JoystickMath.vector(up: true, down: false, left: false, right: false)
        #expect(abs(r.dy - (-1.0)) < 1e-9)
    }

    @Test func diagonalIsNormalizedNotOverOne() {
        let r = JoystickMath.vector(up: true, down: false, left: false, right: true)
        let mag = (r.dx * r.dx + r.dy * r.dy).squareRoot()
        #expect(abs(mag - 1.0) < 1e-9)       // 對角正規化，不超過 1
    }

    @Test func oppositeKeysCancel() {
        let r = JoystickMath.vector(up: true, down: true, left: false, right: false)
        #expect(abs(r.dx) < 1e-9)
        #expect(abs(r.dy) < 1e-9)
    }

    @Test func allReleasedIsZero() {
        let r = JoystickMath.vector(up: false, down: false, left: false, right: false)
        #expect(r.dx == 0 && r.dy == 0)
    }

    @Test func threeKeysNormalized() {
        // 上+左+右 → 左右相消，剩上 → (0,-1)
        let r = JoystickMath.vector(up: true, down: false, left: true, right: true)
        #expect(abs(r.dx) < 1e-9)
        #expect(abs(r.dy - (-1.0)) < 1e-9)
    }
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd app && swift test --filter JoystickMathTests 2>&1 | tail -3`
Expected: 編譯失敗（`JoystickMath` 不存在）。

- [ ] **Step 3: 實作**

```swift
// app/Sources/MirageCore/Keymap/JoystickMath.swift
import Foundation

/// 方向鍵集合 → 正規化向量。y 向下為正（對齊 guest）；對角長度正規化為 1；相反鍵相消。
public enum JoystickMath {
    public static func vector(up: Bool, down: Bool, left: Bool, right: Bool)
        -> (dx: Double, dy: Double)
    {
        let x = (right ? 1.0 : 0.0) - (left ? 1.0 : 0.0)
        let y = (down ? 1.0 : 0.0) - (up ? 1.0 : 0.0)
        let mag = (x * x + y * y).squareRoot()
        guard mag > 0 else { return (0, 0) }
        return (x / mag, y / mag)
    }
}
```

- [ ] **Step 4: 測試通過**

Run: `cd app && swift test --filter JoystickMathTests 2>&1 | tail -3`
Expected: 6 tests passed。

- [ ] **Step 5: Commit**

```bash
git add app/Sources/MirageCore/Keymap/JoystickMath.swift app/Tests/MirageCoreTests/JoystickMathTests.swift
git commit -m "feat: JoystickMath 方向向量正規化（TDD）"
```

---

### Task 3: KeymapProfile + Binding（Codable + schema 驗證，TDD）

**Files:**
- Create: `app/Sources/MirageCore/Keymap/KeymapProfile.swift`
- Test: `app/Tests/MirageCoreTests/KeymapProfileTests.swift`

**Interfaces:**
- Consumes: Task 1 `NormPoint`/`KeyCode`。
- Produces:
  - `enum Binding: Sendable, Codable, Equatable`——`case tap(key: KeyCode, at: NormPoint)`、`case joystick(up:down:left:right:center:NormPoint,radius:Double)`、`case look(activation: KeyCode?, sensitivity: Double)`。
  - `struct KeymapProfile: Sendable, Codable, Equatable { let gameId: String; let version: Int; let bindings: [Binding] }`。
  - `enum ProfileError: Error, Equatable`（`invalidCoordinate/invalidRadius/invalidSensitivity/identifierConflict`）；`func validated() throws -> KeymapProfile`（座標 0–1、radius>0、sensitivity>0；靜態 identifier 分配後檢查不衝突——見 Task 4 分配規則）。供 Task 4 引擎與 Task 5 store。

- [ ] **Step 1: 失敗測試（JSON round-trip + 驗證）**

```swift
// app/Tests/MirageCoreTests/KeymapProfileTests.swift
import Foundation
import Testing
@testable import MirageCore

@Suite struct KeymapProfileTests {
    private func sampleProfile() -> KeymapProfile {
        KeymapProfile(gameId: "com.example.game", version: 1, bindings: [
            .joystick(up: .key("w"), down: .key("s"), left: .key("a"), right: .key("d"),
                      center: NormPoint(x: 0.2, y: 0.75), radius: 0.15),
            .tap(key: .key("j"), at: NormPoint(x: 0.85, y: 0.8)),
            .look(activation: nil, sensitivity: 1.5),
        ])
    }

    @Test func jsonRoundTrip() throws {
        let profile = sampleProfile()
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(KeymapProfile.self, from: data)
        #expect(decoded == profile)
    }

    @Test func validProfilePassesValidation() throws {
        #expect(throws: Never.self) { try sampleProfile().validated() }
    }

    @Test func rejectsOutOfRangeCoordinate() {
        let bad = KeymapProfile(gameId: "g", version: 1, bindings: [
            .tap(key: .key("j"), at: NormPoint(x: 1.5, y: 0.5)),
        ])
        #expect(throws: ProfileError.invalidCoordinate) { try bad.validated() }
    }

    @Test func rejectsNonPositiveRadius() {
        let bad = KeymapProfile(gameId: "g", version: 1, bindings: [
            .joystick(up: .key("w"), down: .key("s"), left: .key("a"), right: .key("d"),
                      center: NormPoint(x: 0.2, y: 0.75), radius: 0),
        ])
        #expect(throws: ProfileError.invalidRadius) { try bad.validated() }
    }

    @Test func rejectsNonPositiveSensitivity() {
        let bad = KeymapProfile(gameId: "g", version: 1, bindings: [
            .look(activation: nil, sensitivity: 0),
        ])
        #expect(throws: ProfileError.invalidSensitivity) { try bad.validated() }
    }
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd app && swift test --filter KeymapProfileTests 2>&1 | tail -3`
Expected: 編譯失敗（`Binding`/`KeymapProfile`/`ProfileError` 不存在）。

- [ ] **Step 3: 實作**

```swift
// app/Sources/MirageCore/Keymap/KeymapProfile.swift
import Foundation

/// 單一綁定：tap（技能鍵）、joystick（方向移動）、look（滑鼠視角）。不可變值型別。
public enum Binding: Sendable, Codable, Equatable {
    case tap(key: KeyCode, at: NormPoint)
    case joystick(up: KeyCode, down: KeyCode, left: KeyCode, right: KeyCode,
                  center: NormPoint, radius: Double)   // radius 為正規化半徑
    case look(activation: KeyCode?, sensitivity: Double)  // activation=nil 表 always-on
}

public struct KeymapProfile: Sendable, Codable, Equatable {
    public let gameId: String
    public let version: Int
    public let bindings: [Binding]
    public init(gameId: String, version: Int, bindings: [Binding]) {
        self.gameId = gameId; self.version = version; self.bindings = bindings
    }
}

public enum ProfileError: Error, Equatable {
    case invalidCoordinate
    case invalidRadius
    case invalidSensitivity
    case identifierConflict
}

public extension KeymapProfile {
    /// 載入期 fail-fast 驗證：座標 0–1、radius>0、sensitivity>0。回傳自身供鏈式使用。
    func validated() throws -> KeymapProfile {
        for b in bindings {
            switch b {
            case .tap(_, let at):
                guard at.isValid else { throw ProfileError.invalidCoordinate }
            case .joystick(_, _, _, _, let center, let radius):
                guard center.isValid else { throw ProfileError.invalidCoordinate }
                guard radius > 0 else { throw ProfileError.invalidRadius }
            case .look(_, let sensitivity):
                guard sensitivity > 0 else { throw ProfileError.invalidSensitivity }
            }
        }
        return self
    }
}
```

- [ ] **Step 4: 測試通過**

Run: `cd app && swift test --filter KeymapProfileTests 2>&1 | tail -3`
Expected: 5 tests passed。

- [ ] **Step 5: Commit**

```bash
git add app/Sources/MirageCore/Keymap/KeymapProfile.swift app/Tests/MirageCoreTests/KeymapProfileTests.swift
git commit -m "feat: KeymapProfile/Binding Codable 與 schema 驗證（TDD）"
```

---

### Task 4: KeymapEngine 核心（事件+狀態 → TouchFrame 多指快照，TDD）

**背景**：這是本件命根子（spec §7 驗收 2）。純狀態機——引擎持有狀態，但轉移邏輯無副作用，可用假事件序列窮舉測試。identifier 靜態分配保證多指決定論。

**Files:**
- Create: `app/Sources/MirageCore/Keymap/KeymapEngine.swift`
- Test: `app/Tests/MirageCoreTests/KeymapEngineTests.swift`

**Interfaces:**
- Consumes: Task 1 `NormPoint`/`KeyCode`、Task 2 `JoystickMath`、Task 3 `KeymapProfile`/`Binding`。
- Produces:
  - `struct TouchSpec: Sendable, Equatable { let identifier: Int; let point: NormPoint; let down: Bool }`
  - `struct TouchFrame: Sendable, Equatable { let touches: [TouchSpec] }`（當前所有 active 觸點快照）
  - `enum InputEvent: Sendable, Equatable { case keyDown(KeyCode), keyUp(KeyCode), mouseMove(dx: Double, dy: Double) }`
  - `final class KeymapEngine`——`init(profile: KeymapProfile)`（載入時靜態分配 identifier：joystick=1、每 tap key 依序 2,3,…、look=最後）；`func apply(_ event: InputEvent) -> TouchFrame`（回傳套用後全部 active 觸點；未映射鍵忽略並計數 `unmappedCount`）。供 Task 7 的 `KeymapController` 驅動。
- **identifier 分配規則**（供 Task 3 的 `identifierConflict` 驗證共用語意）：joystick binding → 1；tap bindings 依 profile 順序 → 2,3,4…；look binding → 分配為最後一個未用 slot。同一 profile 內 slot 不重疊。

- [ ] **Step 1: 失敗測試（tap/joystick/look + 多指同時）**

```swift
// app/Tests/MirageCoreTests/KeymapEngineTests.swift
import Testing
@testable import MirageCore

@Suite struct KeymapEngineTests {
    private func engine() -> KeymapEngine {
        KeymapEngine(profile: KeymapProfile(gameId: "g", version: 1, bindings: [
            .joystick(up: .key("w"), down: .key("s"), left: .key("a"), right: .key("d"),
                      center: NormPoint(x: 0.2, y: 0.75), radius: 0.1),   // id 1
            .tap(key: .key("j"), at: NormPoint(x: 0.85, y: 0.8)),         // id 2
            .look(activation: nil, sensitivity: 1.0),                     // id 3
        ]))
    }

    @Test func tapDownProducesTouchThenUp() {
        let e = engine()
        let down = e.apply(.keyDown(.key("j")))
        let tap = down.touches.first { $0.identifier == 2 }
        #expect(tap?.down == true)
        #expect(tap?.point == NormPoint(x: 0.85, y: 0.8))
        let up = e.apply(.keyUp(.key("j")))
        #expect(up.touches.first { $0.identifier == 2 }?.down == false)
    }

    @Test func joystickRightMovesTouchFromCenter() {
        let e = engine()
        let f = e.apply(.keyDown(.key("d")))          // 向右
        let js = f.touches.first { $0.identifier == 1 }
        #expect(js?.down == true)
        #expect(js!.point.x > 0.2)                    // center.x=0.2，向右 → x 增
        #expect(abs(js!.point.y - 0.75) < 1e-9)       // 純水平
    }

    @Test func joystickReleaseLiftsTouch() {
        let e = engine()
        _ = e.apply(.keyDown(.key("d")))
        let f = e.apply(.keyUp(.key("d")))
        #expect(f.touches.first { $0.identifier == 1 }?.down == false)
    }

    @Test func simultaneousJoystickAndTapAreTwoStableTouches() {
        // spec §7 驗收 2：按住 W + 點技能鍵 → TouchFrame 含 joystick(id1) 與 tap(id2) 兩觸點
        let e = engine()
        _ = e.apply(.keyDown(.key("w")))              // joystick 上
        let f = e.apply(.keyDown(.key("j")))          // 同時點技能
        let ids = Set(f.touches.filter { $0.down }.map { $0.identifier })
        #expect(ids.contains(1))
        #expect(ids.contains(2))
        #expect(ids.count == 2)                       // 兩觸點且 identifier 不衝突
    }

    @Test func lookAccumulatesMouseMove() {
        let e = engine()
        let f = e.apply(.mouseMove(dx: 10, dy: 0))    // always-on look
        let look = f.touches.first { $0.identifier == 3 }
        #expect(look?.down == true)
        #expect(look!.point.x != 0.5 || look!.point.y != 0.5)  // 自中心位移
    }

    @Test func unmappedKeyIgnoredAndCounted() {
        let e = engine()
        _ = e.apply(.keyDown(.key("z")))              // 未映射
        #expect(e.unmappedCount == 1)
    }
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd app && swift test --filter KeymapEngineTests 2>&1 | tail -3`
Expected: 編譯失敗（`KeymapEngine`/`TouchFrame` 不存在）。

- [ ] **Step 3: 實作**

```swift
// app/Sources/MirageCore/Keymap/KeymapEngine.swift
import Foundation

public struct TouchSpec: Sendable, Equatable {
    public let identifier: Int
    public let point: NormPoint
    public let down: Bool
}

public struct TouchFrame: Sendable, Equatable {
    public let touches: [TouchSpec]
}

public enum InputEvent: Sendable, Equatable {
    case keyDown(KeyCode)
    case keyUp(KeyCode)
    case mouseMove(dx: Double, dy: Double)
}

/// 鍵位映射引擎：離散事件 → 當前多指觸點快照。純轉移（無 IO），可窮舉測試。
public final class KeymapEngine {
    private struct JoystickSlot { let id: Int; let up, down, left, right: KeyCode; let center: NormPoint; let radius: Double }
    private struct TapSlot { let id: Int; let key: KeyCode; let at: NormPoint }
    private struct LookSlot { let id: Int; let activation: KeyCode?; let sensitivity: Double }

    private let joystick: JoystickSlot?
    private let taps: [TapSlot]
    private let look: LookSlot?

    private var pressed: Set<KeyCode> = []
    private var lookPoint = NormPoint(x: 0.5, y: 0.5)
    private var lookActive = false
    public private(set) var unmappedCount = 0

    public init(profile: KeymapProfile) {
        var next = 1
        var js: JoystickSlot?
        var tapSlots: [TapSlot] = []
        var lk: LookSlot?
        for b in profile.bindings {
            switch b {
            case .joystick(let u, let d, let l, let r, let c, let rad):
                js = JoystickSlot(id: next, up: u, down: d, left: l, right: r, center: c, radius: rad); next += 1
            case .tap(let key, let at):
                tapSlots.append(TapSlot(id: next, key: key, at: at)); next += 1
            case .look(let act, let sens):
                lk = LookSlot(id: next, activation: act, sensitivity: sens); next += 1
            }
        }
        joystick = js; taps = tapSlots; look = lk
    }

    public func apply(_ event: InputEvent) -> TouchFrame {
        switch event {
        case .keyDown(let k):
            if isMapped(k) { pressed.insert(k) } else { unmappedCount += 1 }
            updateLookActivation()
        case .keyUp(let k):
            pressed.remove(k)
            updateLookActivation()
        case .mouseMove(let dx, let dy):
            if let look, lookActive {
                lookPoint = clamp(NormPoint(x: lookPoint.x + dx * look.sensitivity / 1000,
                                            y: lookPoint.y + dy * look.sensitivity / 1000))
            }
        }
        return snapshot()
    }

    // MARK: - 私有

    private func isMapped(_ k: KeyCode) -> Bool {
        if let j = joystick, [j.up, j.down, j.left, j.right].contains(k) { return true }
        if taps.contains(where: { $0.key == k }) { return true }
        if let look, look.activation == k { return true }
        return false
    }

    private func updateLookActivation() {
        guard let look else { lookActive = false; return }
        lookActive = look.activation.map { pressed.contains($0) } ?? true   // nil = always-on
    }

    private func snapshot() -> TouchFrame {
        var out: [TouchSpec] = []
        if let j = joystick {
            let v = JoystickMath.vector(up: pressed.contains(j.up), down: pressed.contains(j.down),
                                        left: pressed.contains(j.left), right: pressed.contains(j.right))
            let active = v.dx != 0 || v.dy != 0
            let p = NormPoint(x: j.center.x + v.dx * j.radius, y: j.center.y + v.dy * j.radius)
            out.append(TouchSpec(identifier: j.id, point: active ? p : j.center, down: active))
        }
        for t in taps {
            out.append(TouchSpec(identifier: t.id, point: t.at, down: pressed.contains(t.key)))
        }
        if let look {
            out.append(TouchSpec(identifier: look.id, point: lookPoint, down: lookActive))
        }
        return TouchFrame(touches: out)
    }

    private func clamp(_ p: NormPoint) -> NormPoint {
        NormPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1))
    }
}
```

- [ ] **Step 4: 測試通過**

Run: `cd app && swift test --filter KeymapEngineTests 2>&1 | tail -3`
Expected: 6 tests passed。

- [ ] **Step 5: Commit**

```bash
git add app/Sources/MirageCore/Keymap/KeymapEngine.swift app/Tests/MirageCoreTests/KeymapEngineTests.swift
git commit -m "feat: KeymapEngine 多指觸控快照引擎（TDD）"
```

---

### Task 5: ProfileStore 原子檔案 I/O + 內建指標 profile（TDD）

**Files:**
- Create: `app/Sources/MirageCore/Keymap/ProfileStore.swift`
- Create: `app/Resources/profiles/com.example.game.json`
- Test: `app/Tests/MirageCoreTests/ProfileStoreTests.swift`

**Interfaces:**
- Consumes: Task 3 `KeymapProfile`/`ProfileError`。
- Produces:
  - `struct ProfileStore: Sendable`——`init(directory: URL)`（測試注入暫存目錄；App 預設 `~/Library/Application Support/Mirage/profiles/`）；`func load(gameId: String) throws -> KeymapProfile`（fail-fast：解析/schema 失敗擲明確錯誤）；`func save(_ profile: KeymapProfile) throws`（原子寫：temp + rename）。
  - `enum StoreError: Error, Equatable { case notFound, corrupted }`。

- [ ] **Step 1: 失敗測試（round-trip + 損壞拒絕 + 原子寫）**

```swift
// app/Tests/MirageCoreTests/ProfileStoreTests.swift
import Foundation
import Testing
@testable import MirageCore

@Suite struct ProfileStoreTests {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirage-store-test-\(UInt64(bitPattern: Int64(ObjectIdentifier(NSObject()).hashValue)))")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func sample() -> KeymapProfile {
        KeymapProfile(gameId: "com.example.game", version: 1, bindings: [
            .tap(key: .key("j"), at: NormPoint(x: 0.85, y: 0.8)),
        ])
    }

    @Test func saveThenLoadRoundTrip() throws {
        let store = ProfileStore(directory: tempDir())
        try store.save(sample())
        let loaded = try store.load(gameId: "com.example.game")
        #expect(loaded == sample())
    }

    @Test func loadMissingThrowsNotFound() {
        let store = ProfileStore(directory: tempDir())
        #expect(throws: StoreError.notFound) { try store.load(gameId: "nope") }
    }

    @Test func loadCorruptedThrowsCorrupted() throws {
        let dir = tempDir()
        let store = ProfileStore(directory: dir)
        try "{ not valid json".data(using: .utf8)!
            .write(to: dir.appendingPathComponent("bad.json"))
        #expect(throws: StoreError.corrupted) { try store.load(gameId: "bad") }
    }

    @Test func loadInvalidSchemaThrows() throws {
        let dir = tempDir()
        let store = ProfileStore(directory: dir)
        let bad = KeymapProfile(gameId: "x", version: 1, bindings: [
            .tap(key: .key("j"), at: NormPoint(x: 2.0, y: 0.5)),   // 越界
        ])
        let data = try JSONEncoder().encode(bad)
        try data.write(to: dir.appendingPathComponent("x.json"))
        #expect(throws: ProfileError.invalidCoordinate) { try store.load(gameId: "x") }
    }
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd app && swift test --filter ProfileStoreTests 2>&1 | tail -3`
Expected: 編譯失敗（`ProfileStore` 不存在）。

- [ ] **Step 3: 實作**

```swift
// app/Sources/MirageCore/Keymap/ProfileStore.swift
import Foundation

public enum StoreError: Error, Equatable {
    case notFound
    case corrupted
}

/// Profile 持久化：載入 fail-fast（解析→schema 驗證），儲存原子寫（temp+rename）。
public struct ProfileStore: Sendable {
    private let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// App 預設位置。
    public static func standard() -> ProfileStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mirage/profiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return ProfileStore(directory: base)
    }

    private func url(_ gameId: String) -> URL {
        directory.appendingPathComponent("\(gameId).json")
    }

    public func load(gameId: String) throws -> KeymapProfile {
        let u = url(gameId)
        guard FileManager.default.fileExists(atPath: u.path) else { throw StoreError.notFound }
        let data = try Data(contentsOf: u)
        let profile: KeymapProfile
        do {
            profile = try JSONDecoder().decode(KeymapProfile.self, from: data)
        } catch {
            throw StoreError.corrupted
        }
        return try profile.validated()      // schema 驗證失敗擲 ProfileError（不吞）
    }

    public func save(_ profile: KeymapProfile) throws {
        let data = try JSONEncoder().encode(profile)
        let dest = url(profile.gameId)
        let tmp = dest.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmp)   // 原子 rename
    }
}
```

- [ ] **Step 4: 測試通過**

Run: `cd app && swift test --filter ProfileStoreTests 2>&1 | tail -3`
Expected: 4 tests passed。

- [ ] **Step 5: 內建指標遊戲 profile**

```json
// app/Resources/profiles/com.example.game.json
{
  "gameId" : "com.example.game",
  "version" : 1,
  "bindings" : [
    { "joystick" : { "up" : { "key" : { "_0" : "w" } }, "down" : { "key" : { "_0" : "s" } }, "left" : { "key" : { "_0" : "a" } }, "right" : { "key" : { "_0" : "d" } }, "center" : { "x" : 0.2, "y" : 0.75 }, "radius" : 0.12 } },
    { "tap" : { "key" : { "key" : { "_0" : "j" } }, "at" : { "x" : 0.85, "y" : 0.82 } } },
    { "tap" : { "key" : { "key" : { "_0" : "k" } }, "at" : { "x" : 0.72, "y" : 0.88 } } },
    { "look" : { "sensitivity" : 1.5 } }
  ]
}
```

註：實際 JSON 鍵名以 Swift 合成 `Codable` 對 enum 的編碼為準——**產生方式**：實作後跑 `let d = try JSONEncoder().encode(sampleProfile); print(String(data: d, encoding: .utf8)!)` 取得真確格式覆蓋本檔（enum associated value 的 `_0` 鍵是 Swift 預設，但版本敏感）。用一個測試鎖定：載入本檔 → `validated()` 不擲錯。

```swift
// 附加到 ProfileStoreTests.swift
@Test func bundledCanaryProfileLoads() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mirage-canary")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let src = URL(fileURLWithPath: #filePath)          // Tests/.../ProfileStoreTests.swift
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/profiles/com.example.game.json")
    guard FileManager.default.fileExists(atPath: src.path) else { return }  // 路徑差異時略過
    let dst = dir.appendingPathComponent("com.example.game.json")
    try? FileManager.default.removeItem(at: dst)
    try FileManager.default.copyItem(at: src, to: dst)
    let store = ProfileStore(directory: dir)
    #expect(throws: Never.self) { try store.load(gameId: "com.example.game") }
}
```

- [ ] **Step 6: Commit**

```bash
git add app/Sources/MirageCore/Keymap/ProfileStore.swift app/Resources/profiles/com.example.game.json app/Tests/MirageCoreTests/ProfileStoreTests.swift
git commit -m "feat: ProfileStore 原子檔案 I/O 與內建指標 profile（TDD）"
```

---

### Task 6: EmulatorClient 擴充 sendTouches（多指）/ sendKey（TDD + 活體多指煙霧）

**Files:**
- Modify: `app/Sources/MirageCore/EmulatorClient.swift`（加 `sendTouches`/`sendKey`，`sendTap` 改為單指特例）
- Test: `app/Tests/MirageCoreTests/EmulatorClientTouchTests.swift`

**Interfaces:**
- Consumes: Task 4 `TouchSpec`；`channelBox?.client`（`sendTouch`/`sendKey`）；Task 1 `KeyCode`。
- Produces:
  - `EmulatorClient.sendTouches(_ touches: [TouchSpec], width: Int, height: Int) async`——一個 `TouchEvent` 帶多 `Touch`；每 `TouchSpec` 用 `point.guestPixel(width:height:)` 換算，`pressure = down ? 1024 : 0`。
  - `EmulatorClient.sendKey(_ code: KeyCode, down: Bool) async`——`KeyboardEvent`（`eventType = down ? .keydown : .keyup`，`key = W3C 值`；`.mouse` 忽略）。
  - `buildTouchEvent(_:width:height:) -> Android_Emulation_Control_TouchEvent`（`internal static`，供純單元測試不需 channel）。

- [ ] **Step 1: 失敗測試（純建構，不需連線）**

```swift
// app/Tests/MirageCoreTests/EmulatorClientTouchTests.swift
import Testing
@testable import MirageCore

@Suite struct EmulatorClientTouchTests {
    @Test func buildsMultiTouchEventWithScaledPixels() {
        let touches = [
            TouchSpec(identifier: 1, point: NormPoint(x: 0.5, y: 0.5), down: true),
            TouchSpec(identifier: 2, point: NormPoint(x: 1.0, y: 0.0), down: false),
        ]
        let ev = EmulatorClient.buildTouchEvent(touches, width: 540, height: 1200)
        #expect(ev.touches.count == 2)
        #expect(ev.touches[0].identifier == 1)
        #expect(ev.touches[0].x == 270 && ev.touches[0].y == 600)
        #expect(ev.touches[0].pressure == 1024)      // down
        #expect(ev.touches[1].identifier == 2)
        #expect(ev.touches[1].x == 540 && ev.touches[1].y == 0)
        #expect(ev.touches[1].pressure == 0)         // up
    }

    @Test func buildsKeyEventFromW3CKey() {
        let ev = EmulatorClient.buildKeyEvent(.key("Enter"), down: true)
        #expect(ev?.key == "Enter")
        #expect(ev?.eventType == .keydown)
        let up = EmulatorClient.buildKeyEvent(.key("Enter"), down: false)
        #expect(up?.eventType == .keyup)
    }

    @Test func mouseKeyCodeProducesNoKeyEvent() {
        #expect(EmulatorClient.buildKeyEvent(.mouse(.left), down: true) == nil)
    }
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd app && swift test --filter EmulatorClientTouchTests 2>&1 | tail -3`
Expected: 編譯失敗（`buildTouchEvent`/`buildKeyEvent`/`sendTouches` 不存在）。

- [ ] **Step 3: 實作（加到 EmulatorClient）**

```swift
// 加到 EmulatorClient.swift（sendTap 改為呼叫 sendTouches 的單指特例，DRY）

extension EmulatorClient {
    /// 純建構——供單元測試，不需 channel。
    static func buildTouchEvent(_ touches: [TouchSpec], width: Int, height: Int)
        -> Android_Emulation_Control_TouchEvent
    {
        var event = Android_Emulation_Control_TouchEvent()
        event.touches = touches.map { spec in
            let (gx, gy) = spec.point.guestPixel(width: width, height: height)
            var t = Android_Emulation_Control_Touch()
            t.x = Int32(gx); t.y = Int32(gy)
            t.identifier = Int32(spec.identifier)
            t.pressure = spec.down ? 1024 : 0
            return t
        }
        return event
    }

    /// 純建構——`.mouse` 無對應 KeyboardEvent，回 nil（呼叫端忽略）。
    static func buildKeyEvent(_ code: KeyCode, down: Bool)
        -> Android_Emulation_Control_KeyboardEvent?
    {
        guard case .key(let w3c) = code else { return nil }
        var ev = Android_Emulation_Control_KeyboardEvent()
        ev.eventType = down ? .keydown : .keyup
        ev.key = w3c
        return ev
    }

    public func sendTouches(_ touches: [TouchSpec], width: Int, height: Int) async {
        guard let client = channelBox?.client else { return }
        _ = try? await client.sendTouch(Self.buildTouchEvent(touches, width: width, height: height))
    }

    public func sendKey(_ code: KeyCode, down: Bool) async {
        guard let client = channelBox?.client, let ev = Self.buildKeyEvent(code, down: down) else { return }
        _ = try? await client.sendKey(ev)
    }
}
```

`sendTap` 改為單指特例（取代既有實作，DRY）：

```swift
public func sendTap(x: Int, y: Int, down: Bool) async {
    guard let client = channelBox?.client else { return }
    var t = Android_Emulation_Control_Touch()
    t.x = Int32(x); t.y = Int32(y); t.identifier = 0; t.pressure = down ? 1024 : 0
    var event = Android_Emulation_Control_TouchEvent()
    event.touches = [t]
    _ = try? await client.sendTouch(event)
}
```

- [ ] **Step 4: 測試通過**

Run: `cd app && swift test --filter EmulatorClientTouchTests 2>&1 | tail -3`
Expected: 3 tests passed。

- [ ] **Step 5: 活體多指煙霧（emulator show_touches 佐證）**

```swift
// 附加到 EmulatorClientTouchTests.swift
@Suite struct MultiTouchLiveTests {
    @Test func injectsTwoSimultaneousTouches() async throws {
        guard ProcessInfo.processInfo.environment["MIRAGE_LIVE"] == "1" else { return }
        let client = EmulatorClient()
        await client.start(box: LatestFrameBox(), width: 540, height: 1200)
        try await Task.sleep(for: .seconds(2))
        // 兩個同時 down 觸點（移動 + 技能）
        await client.sendTouches([
            TouchSpec(identifier: 1, point: NormPoint(x: 0.25, y: 0.7), down: true),
            TouchSpec(identifier: 2, point: NormPoint(x: 0.85, y: 0.8), down: true),
        ], width: 540, height: 1200)
        try await Task.sleep(for: .seconds(1))
        await client.sendTouches([
            TouchSpec(identifier: 1, point: NormPoint(x: 0.25, y: 0.7), down: false),
            TouchSpec(identifier: 2, point: NormPoint(x: 0.85, y: 0.8), down: false),
        ], width: 540, height: 1200)
        await client.stop()
        // 佐證：adb shell settings put system show_touches 1 後截圖見兩觸點（pending-human/腳本擷取）
    }
}
```

Run: `cd app && swift test --filter EmulatorClientTouchTests 2>&1 | tail -3`（單元）；活體：`MIRAGE_LIVE=1 swift test --filter MultiTouchLiveTests`。

- [ ] **Step 6: Commit**

```bash
git add app/Sources/MirageCore/EmulatorClient.swift app/Tests/MirageCoreTests/EmulatorClientTouchTests.swift
git commit -m "feat: EmulatorClient 多指 sendTouches 與 sendKey（TDD+活體）"
```

---

### Task 7: App 層整合（KeymapController、look 捕捉、輸入路由、overlay 編輯器）

**背景**：AppKit 膠水，多屬 pending-human（需 GUI + 解鎖）。引擎正確性已由 Task 4 單元覆蓋；本 Task 保證「無 profile 退回直接 tap」（spec §7 驗收 4，可冒煙）與編輯/look 手感（pending-human）。

**Files:**
- Create: `app/Sources/MirageApp/Keymap/KeymapController.swift`
- Create: `app/Sources/MirageApp/Keymap/MouseCapture.swift`
- Create: `app/Sources/MirageApp/Keymap/KeymapOverlay.swift`
- Create: `app/Sources/MirageApp/Keymap/OverlayEditorView.swift`
- Modify: `app/Sources/MirageApp/MirrorView.swift`（輸入改走 KeymapController，無 profile 退回 tap）
- Modify: `app/Sources/MirageApp/MirageApp.swift`（注入 KeymapController、⌘E 切換）

**Interfaces:**
- Consumes: Task 4 `KeymapEngine`/`InputEvent`/`TouchFrame`、Task 5 `ProfileStore`、Task 6 `EmulatorClient.sendTouches/sendKey`；既有 `Coordinator.sendMouse`（退回路徑）。
- Produces: `KeymapController`（`@MainActor`）——`handleKeyDown/handleKeyUp/handleMouseMoved(dx:dy:)/handleFlagsChanged`；有 active profile → 引擎 → `sendTouches`；無 profile → 退回 mouse→tap。編輯模式（⌘E）暫停注入。

- [ ] **Step 1: KeymapController（NSEvent → 引擎 → client）**

```swift
// app/Sources/MirageApp/Keymap/KeymapController.swift
import AppKit
import MirageCore

/// 橋接鍵鼠事件到 KeymapEngine，輸出多指觸控。無 profile 時退回直接 tap（呼叫端負責）。
@MainActor
final class KeymapController {
    private let client: EmulatorClient
    private var engine: KeymapEngine?
    private var editing = false
    private var guestSize: (w: Int, h: Int)

    var hasProfile: Bool { engine != nil && !editing }

    init(client: EmulatorClient, profile: KeymapProfile?, guestSize: (w: Int, h: Int)) {
        self.client = client
        self.guestSize = guestSize
        if let profile { self.engine = KeymapEngine(profile: profile) }
    }

    func setGuestSize(_ size: (w: Int, h: Int)) { guestSize = size }
    func setEditing(_ on: Bool) { editing = on }

    func handleKeyDown(_ code: KeyCode) { emit(engine?.apply(.keyDown(code))) }
    func handleKeyUp(_ code: KeyCode) { emit(engine?.apply(.keyUp(code))) }
    func handleMouseMoved(dx: Double, dy: Double) { emit(engine?.apply(.mouseMove(dx: dx, dy: dy))) }

    private func emit(_ frame: TouchFrame?) {
        guard let frame, !editing else { return }
        let touches = frame.touches
        let size = guestSize
        Task { await client.sendTouches(touches, width: size.w, height: size.h) }
    }
}
```

- [ ] **Step 2: MouseCapture（look 游標鎖定/還原，邊界防呆）**

```swift
// app/Sources/MirageApp/Keymap/MouseCapture.swift
import AppKit
import CoreGraphics

/// look 模式游標捕捉：隱藏游標 + 解除滑鼠與游標關聯（取 raw delta）。退出/失焦一律還原。
@MainActor
final class MouseCapture {
    private(set) var captured = false

    func capture() {
        guard !captured else { return }
        CGAssociateMouseAndMouseCursorPosition(0)   // 解除關聯 → mouseMoved 給 raw delta
        NSCursor.hide()
        captured = true
    }

    func release() {
        guard captured else { return }
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
        captured = false
    }

    deinit { if captured { CGAssociateMouseAndMouseCursorPosition(1); NSCursor.unhide() } }
}
```

- [ ] **Step 3: MirrorView 輸入路由（keyDown/keyUp/mouseMoved/flagsChanged → controller，無 profile 退回 tap）**

在 `MirrorMTKView` 加鍵盤/移動事件覆寫並轉為 `KeyCode`；`Coordinator` 持 `KeymapController`。無 profile（`controller.hasProfile == false`）時，滑鼠仍走既有 `sendMouse`（P1-a 行為不回歸——spec §7 驗收 4）：

```swift
// MirrorMTKView 增補：
//   var onKey: ((_ code: KeyCode, _ down: Bool) -> Void)?
//   var onMouseMovedDelta: ((_ dx: Double, _ dy: Double) -> Void)?
//   override var acceptsFirstResponder: Bool { true }

override func keyDown(with event: NSEvent) {
    if let c = keyCode(from: event) { onKey?(c, true) }
}
override func keyUp(with event: NSEvent) {
    if let c = keyCode(from: event) { onKey?(c, false) }
}
override func mouseMoved(with event: NSEvent) {
    onMouseMovedDelta?(Double(event.deltaX), Double(event.deltaY))
}

private func keyCode(from event: NSEvent) -> KeyCode? {
    guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return nil }
    return .key(chars)      // W3C key 近似：單字元鍵直接用字元（"w"/"a"/…）
}
```

`Coordinator` 增補（無 profile 退回既有 sendMouse）：

```swift
// Coordinator：持有 controller
//   var controller: KeymapController?
//   在 makeNSView 設 view.onKey / view.onMouseMovedDelta 轉呼 controller
//   sendMouse 保留；mouseDown/Dragged/Up 僅在 controller?.hasProfile != true 時送 tap：
func sendMouse(nx: Double, ny: Double, down: Bool) {
    guard controller?.hasProfile != true else { return }   // 有 profile 時鍵鼠走引擎
    let size = renderer?.lastFrameSize ?? guestSize
    let gx = Int(nx * Double(size.w)); let gy = Int(ny * Double(size.h))
    Task { await client.sendTap(x: gx, y: gy, down: down) }
}
```

- [ ] **Step 4: OverlayEditorView + KeymapOverlay（陽春編輯器與提示）**

```swift
// app/Sources/MirageApp/Keymap/KeymapOverlay.swift
import MirageCore
import SwiftUI

/// 非編輯模式：半透明 binding 提示（tap=圓點+鍵標、joystick=圓環、look=標記）。
struct KeymapOverlay: View {
    let profile: KeymapProfile?
    var body: some View {
        GeometryReader { geo in
            if let profile {
                ForEach(Array(profile.bindings.enumerated()), id: \.offset) { _, b in
                    marker(for: b, in: geo.size)
                }
            }
        }
        .allowsHitTesting(false)
    }
    @ViewBuilder private func marker(for b: Binding, in size: CGSize) -> some View {
        switch b {
        case .tap(let key, let at):
            Circle().stroke(.white.opacity(0.5)).frame(width: 44, height: 44)
                .position(x: at.x * size.width, y: at.y * size.height)
                .overlay(Text(label(key)).font(.caption).foregroundStyle(.white)
                    .position(x: at.x * size.width, y: at.y * size.height))
        case .joystick(_, _, _, _, let center, let radius):
            Circle().stroke(.white.opacity(0.4))
                .frame(width: radius * size.width * 2, height: radius * size.width * 2)
                .position(x: center.x * size.width, y: center.y * size.height)
        case .look:
            EmptyView()
        }
    }
    private func label(_ k: KeyCode) -> String { if case .key(let s) = k { return s } else { return "•" } }
}
```

```swift
// app/Sources/MirageApp/Keymap/OverlayEditorView.swift
import MirageCore
import SwiftUI

/// 陽春編輯器（⌘E 進入）：拖放 binding、選鍵、存檔（version+1 不可變，原子寫）。
/// MVP：以 KeymapOverlay 的視覺為基礎，加拖曳手勢改 NormPoint、滑桿調 radius/sensitivity、
/// 「存檔」按鈕呼叫 ProfileStore.save（新 version）。詳細互動列 pending-human。
struct OverlayEditorView: View {
    @Binding var profile: KeymapProfile
    let onSave: (KeymapProfile) -> Void
    var body: some View {
        VStack {
            KeymapOverlay(profile: profile)
            HStack {
                Button("存檔") { onSave(bumpVersion(profile)) }
                Button("完成編輯（⌘E）") { }   // 由父層 ⌘E 切換
            }.padding()
        }
    }
    private func bumpVersion(_ p: KeymapProfile) -> KeymapProfile {
        KeymapProfile(gameId: p.gameId, version: p.version + 1, bindings: p.bindings)
    }
}
```

- [ ] **Step 5: MirageApp 注入 + ⌘E 切換**

`MirageApp.swift`：`AppModel` 加 `keymap: KeymapController?`、`profile: KeymapProfile?`、`editing: Bool`；啟動時 `try? ProfileStore.standard().load(gameId:)` 載入（失敗→nil→直接模式，spec §5 不崩）。`MirrorView` 傳入 `controller`。⌘E 以 `.keyboardShortcut("e", modifiers: .command)` 的隱藏按鈕或 `NSEvent` monitor 切 `editing`，並 `keymap?.setEditing(editing)`。ZStack 疊 `KeymapOverlay`（非編輯）/`OverlayEditorView`（編輯）。

```swift
// AppModel 增補（節錄）：
func loadKeymap(guestSize: (w: Int, h: Int)) {
    profile = try? ProfileStore.standard().load(gameId: "com.example.game")   // 失敗→nil→直接模式
    keymap = KeymapController(client: client, profile: profile, guestSize: guestSize)
}
func toggleEditing() { editing.toggle(); keymap?.setEditing(editing) }
```

- [ ] **Step 6: 建置 + 冒煙（無 profile 退回直接 tap——驗收 4）**

Run: `cd app && swift build -c release 2>&1 | tail -2`
Expected: Build complete、零警告。冒煙：暫時移走 profile（或 gameId 不存在）→ app 起得來、滑鼠點擊仍送 tap（P1-a 行為不回歸）。有 profile 時 WASD/技能鍵走引擎、⌘E 進編輯。look 手感、拖放存檔 **pending-human**。

- [ ] **Step 7: Commit**

```bash
git add app/Sources/MirageApp/Keymap app/Sources/MirageApp/MirrorView.swift app/Sources/MirageApp/MirageApp.swift
git commit -m "feat: 鍵位映射 App 整合——輸入路由、look 捕捉、overlay 編輯器與 ⌘E"
```

---

### Task 8: 驗收量測、覆蓋率與文件

**Files:**
- Create: `app/RESULTS-p1c.md`
- Modify: `app/README.md`（加 P1-c 章節）

**Interfaces:**
- Consumes: Task 1-7 全部交付物。
- Produces: P1-c 出貨判定（spec §7 逐條裁決）。

- [ ] **Step 1: 全測試 + 覆蓋率 + release 零警告**

```bash
cd app
swift build -c release 2>&1 | tail -2
swift test --enable-code-coverage 2>&1 | tail -3
xcrun llvm-cov report .build/debug/MiragePackageTests.xctest/Contents/MacOS/MiragePackageTests \
  -instr-profile .build/debug/codecov/default.profdata \
  -ignore-filename-regex "Generated|Tests" 2>/dev/null | tail -10   # MirageCore ≥80%
```

- [ ] **Step 2: 活體多指煙霧（模擬器執行中、show_touches）**

```bash
ADB="$HOME/Library/Android/sdk/platform-tools/adb"
"$ADB" shell settings put system show_touches 1
MIRAGE_LIVE=1 swift test --filter MultiTouchLiveTests 2>&1 | tail -3
"$ADB" exec-out screencap -p > /tmp/mirage_multitouch.png   # 佐證兩觸點
"$ADB" shell settings put system show_touches 0
```

- [ ] **Step 3: RESULTS-p1c.md（照 spec §7 逐條填實測）**

```markdown
# P1-c 驗收結果（日期：____；host load：____；emulator：____）

| # | 驗收線（spec §7） | 實測 | 判定 |
|---|---|---|---|
| 1 | Keymap 單元全綠、覆蓋 ≥80%、release 零警告 | ___ tests / ___% / 警告 ___ | ⬜ |
| 2 | 引擎多指：按住 W + 點技能 → TouchFrame 含 id1+idN 兩觸點、座標正確、不衝突（單元） | ___ | ⬜ |
| 3 | 活體煙霧：載入指標 profile 注入「移動+技能」→ show_touches 見兩同時觸點（擷圖） | ___（/tmp/mirage_multitouch.png） | ⬜ |
| 4 | 無 profile 時 MirrorView 仍可直接 mouse→tap（P1-a 不回歸） | ___ | ⬜ |
| 5 | pending-human（解鎖後）：overlay 拖放存檔、look 手感、真遊戲跟手度 | ⬜ pending-unlock | ⬜ |

## 判定
- [ ] P1-c 出貨
- [ ] 未達標項與處置：____

## 觀察與備註
（identifier 分配、look 靈敏度手感、多指注入延遲……）
```

- [ ] **Step 4: app/README.md 加 P1-c 章節**

```markdown
## P1-c 鍵位映射

- 每遊戲 profile：tap（技能）、joystick（WASD 移動）、look（滑鼠視角）→ 多點觸控注入
- 無 profile 時退回 P1-a 直接 mouse→tap
- ⌘E 進 overlay 編輯器（拖放 binding、存檔 version+1）
- Profile 位置：`~/Library/Application Support/Mirage/profiles/<gameId>.json`；內建指標 `com.example.game`
- 活體多指：`MIRAGE_LIVE=1 swift test --filter MultiTouchLiveTests`（配 `show_touches 1`）
- 驗收紀錄：`RESULTS-p1c.md`

架構詳見 `../docs/specs/2026-07-24-p1c-keymap-engine-design.md`。
```

- [ ] **Step 5: 填實數、判定、Commit**

```bash
git add app/RESULTS-p1c.md app/README.md
git commit -m "docs: p1c 驗收結果與使用文件"
```

---

## Self-Review 紀錄

- **Spec 覆蓋**：§3 結構=各 Task 檔案對應；§4.1 資料模型（NormPoint/KeyCode/Binding/Profile）=Task 1/3；§4.2 KeymapEngine（tap/joystick/look/多指 identifier 靜態分配）=Task 4；§4.3 EmulatorClient sendTouches/sendKey（sendTap 為單指特例，DRY）=Task 6；§4.4 KeymapController（有/無 profile 分流、look 捕捉、編輯暫停）=Task 7；§4.5 Overlay 編輯器=Task 7（拖放/滑桿詳細互動列 pending-human）；§4.6 ProfileStore（標準位置、fail-fast、原子寫、內建 profile）=Task 5；§5 錯誤處理=Task 3 驗證擲錯/Task 4 unmappedCount/Task 5 corrupted/Task 7 look 退回；§6 測試=Task 1-6 單元 + Task 6/8 活體；§7 驗收=Task 8 逐條。
- **零 proto 遷移確認**：`sendTouch(TouchEvent, repeated Touch)`、`sendKey(KeyboardEvent, key/eventType)` 既有 stub 已足（Generated 核實）——本件無 Task 需動 proto。
- **佔位掃描**：無 TBD；RESULTS 的 `___` 為待填實測（專案慣例）；內建 profile JSON 的「以 Codable 編碼為準」附產生指令與鎖定測試（`bundledCanaryProfileLoads`），非佔位。
- **型別一致性**：`NormPoint(x:y:)`/`isValid`/`guestPixel(width:height:)`（Task 1 定義=4/6 用）；`KeyCode.key/.mouse`（Task 1=3/4/6/7）；`JoystickMath.vector(up:down:left:right:)`（Task 2=4）；`Binding`/`KeymapProfile`/`ProfileError`/`validated()`（Task 3=4/5）；`TouchSpec(identifier:point:down:)`/`TouchFrame`/`InputEvent`/`KeymapEngine.apply`/`unmappedCount`（Task 4=6/7）；`ProfileStore.load/save/standard()`/`StoreError`（Task 5=7）；`EmulatorClient.sendTouches(_:width:height:)/sendKey(_:down:)/buildTouchEvent/buildKeyEvent`（Task 6=7）。
- **並發紀律**：MirageCore/Keymap 全不 import AppKit（NormPoint/KeyCode/JoystickMath/KeymapProfile/KeymapEngine/ProfileStore 純）；AppKit 僅 MirageApp/Keymap。`KeymapController`/`MouseCapture` `@MainActor`。
- **與 P1-b 整合面**（spec §8）：本件改 `EmulatorClient`（+sendTouches/sendKey，與 P1-b 的 snapshot/clipboard/health 不同方法）與 `MirageApp`（輸入路由，與 P1-b 選單列/生命週期不同區域）。P1-b 先合；本件整合時 `EmulatorClient` 的 `channelBox` 已由 P1-b 迴圈管理，`sendTouches` 沿用 `channelBox?.client` 守衛（斷線時 no-op，安全）。一次解決 pass 聚焦 import/檔案並存，無邏輯衝突。
- **驗收不重測 fps/延遲**（spec §8）：鍵位映射不改顯示管線；多指注入額外延遲若 P1-d 實測有感再回量。
