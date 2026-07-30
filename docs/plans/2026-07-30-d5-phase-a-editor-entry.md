# D5 階段 A：編輯器進得去 實作計畫

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 讓真實遊戲按 ⌘E 能打開編輯器並看到 starter 版面（未存檔不落檔），
同時修掉會讓拖曳無法開發的兩筆既有債：D22（編輯模式滑鼠打進 guest）、D12（搖桿座標越界）。

**Architecture:** 決策與算術下沉到 `MirageCore` 純函式（比照既有的 `ActivationDecider`／
`KeyTranslate`／`StreamSize`），App 層只做接線。階段 A **不含任何新 UI**——抽屜、拖曳、
新增／刪除、按鍵擷取都是階段 B/C。

**Tech Stack:** Swift 6.2 toolchain（語言模式 v5、`-strict-concurrency=complete`）、
swift-testing、SwiftUI/AppKit。

## Global Constraints

- 測試框架用 `swift-testing`（`@Test` / `@Suite` / `#expect`），**不是** XCTest。
- 活體測試一律 `@Test(.enabled(if:))`，**禁止** `guard … else { return }` 早退——`ci.sh` 閘門 3 會擋。
- 等待一律用無預算閘門（`CountGate` / `StateRecorder`），**禁止**新增 `waitUntil` 式輪詢（D24）。
- shell 腳本裡變數後接全形標點一律 `${VAR}`——`ci.sh` 閘門 4 會擋。
- 每個 task 結束前跑 `cd app && swift test`；全計畫結束跑 `./scripts/ci.sh`（須 `CI_EXIT=0`）。
- 註解寫**為什麼**，不是寫**做了什麼**——對齊本 repo 既有風格。
- commit 訊息用 conventional commits，繁體中文。

---

## 檔案結構

| 檔案 | 責任 | 動作 |
|---|---|---|
| `app/Sources/MirageCore/Keymap/NormPoint.swift` | 正規化座標與夾取 | 修改：抽出 `clamped(x:y:)` |
| `app/Sources/MirageCore/Keymap/KeymapEngine.swift` | 事件→觸點快照 | 修改：搖桿點夾取（D12） |
| `app/Sources/MirageCore/Keymap/BuiltInProfiles.swift` | 內建 profile | 修改：加 `starterBindings` |
| `app/Sources/MirageCore/Keymap/EditorEntryDecider.swift` | ⌘E 進入決策（純函式） | **新增** |
| `app/Sources/MirageShell/Keymap/KeymapController.swift` | 鍵鼠→引擎橋接 | 修改：`hasProfile` 語意（D22） |
| `app/Sources/MirageShell/MirrorView.swift` | 鏡像視圖與滑鼠 | 修改：Coordinator 收 `isEditing`（D22） |
| `app/Sources/MirageShell/MirageScene.swift` | Scene 接線 | 修改：傳 `isEditing` |
| `app/Sources/MirageShell/AppModel.swift` | App 狀態 | 修改：`toggleEditing` 走 decider |

---

## 一處對設計文件的刻意偏離（實作前先讀）

設計文件 §3.5 寫「夾取在純函式裡完成，**並補進 `validated()`**」。

**本計畫不做後半，理由是「Never break userspace」**：`validated()` 是**載入期** fail-fast，
在那裡新增「`center ± radius` 不得越界」的檢查，會讓使用者手上**既有的** profile 突然載入失敗
——他的鍵位當場消失，而且沒有任何修復路徑。夾取（Task 1）已經讓越界座標不可能送到 guest；
「不要一開始就產生越界值」則由階段 B 的拖曳邊界負責。

在載入期拒絕舊資料，換到的只是「更早報錯」，付出的是使用者資料不可用。不值得。

---

## Task 1：搖桿座標夾取（D12）

**Files:**
- Modify: `app/Sources/MirageCore/Keymap/NormPoint.swift`（抽出 `clamped`）
- Modify: `app/Sources/MirageCore/Keymap/KeymapEngine.swift:105`
- Test: `app/Tests/MirageCoreTests/KeymapEngineTests.swift`

**Interfaces:**
- Produces: `NormPoint.clamped(x: Double, y: Double) -> NormPoint`（Task 無其他消費端，但階段 B 會用）

- [ ] **Step 1: 寫失敗測試**

加到 `app/Tests/MirageCoreTests/KeymapEngineTests.swift` 的 suite 內：

```swift
    /// D12：搖桿圓心貼邊時，`center ± radius` 會算出越界座標。
    ///
    /// 送越界座標比不送更糟——畫面有反應但點在錯的地方，使用者會以為是遊戲的問題
    /// （D7 已確立這個立場）。
    @Test func joystickAtEdgeStaysInsideUnitSquare() {
        let profile = KeymapProfile(gameId: "g", version: 1, bindings: [
            .joystick(up: .key("w"), down: .key("s"), left: .key("a"), right: .key("d"),
                      center: NormPoint(x: 0.05, y: 0.95), radius: 0.3),
        ])
        let engine = KeymapEngine(profile: profile)
        let frame = engine.apply(.keyDown(.key("a")))       // 向左：x = 0.05 - 0.3 = -0.25
        let stick = frame.touches.first { $0.identifier == 1 }
        #expect(stick?.point.x == 0)
        #expect(stick?.point.isValid == true)

        let down = engine.apply(.keyDown(.key("s")))        // 再加向下：y 會超過 1
        let stick2 = down.touches.first { $0.identifier == 1 }
        #expect(stick2?.point.isValid == true)
    }
```

- [ ] **Step 2: 跑測試確認它紅**

```bash
cd app && swift test --filter joystickAtEdgeStaysInsideUnitSquare
```

Expected: FAIL —`stick?.point.x` 會是 `-0.25` 而不是 `0`。

- [ ] **Step 3: 抽出 `clamped` 並在兩處使用**

在 `NormPoint.swift` 的 `fromViewPoint` **上方**加：

```swift
    /// 夾進 0…1。`fromViewPoint` 與 `KeymapEngine` 的搖桿換算共用它——同一個「不得越界」
    /// 的規則寫兩次遲早漂移，而這個 repo 剛因為 `EmulatorEndpoint` 有兩份解析吃過虧。
    public static func clamped(x: Double, y: Double) -> NormPoint {
        NormPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }
```

把 `fromViewPoint` 的回傳改成用它：

```swift
        guard width > 0, height > 0 else { return nil }
        return clamped(x: x / width, y: 1.0 - y / height)
```

`KeymapEngine.swift:105` 改成：

```swift
            // D12：`center ± radius` 會越界（圓心貼邊 + 大半徑）。夾取放在這裡而不是
            // `validated()`：載入期拒絕會讓使用者既有的 profile 突然消失（見計畫的偏離說明）。
            let p = NormPoint.clamped(x: j.center.x + v.dx * j.radius,
                                      y: j.center.y + v.dy * j.radius)
```

- [ ] **Step 4: 跑測試確認全綠**

```bash
cd app && swift test
```

Expected: PASS，且既有 `KeymapEngineTests` / `NormPointTests` 不得變紅。

- [ ] **Step 5: Commit**

```bash
git add app/Sources/MirageCore/Keymap/NormPoint.swift \
        app/Sources/MirageCore/Keymap/KeymapEngine.swift \
        app/Tests/MirageCoreTests/KeymapEngineTests.swift
git commit -m "fix: D12 搖桿座標夾進 0-1，換算規則抽成 NormPoint.clamped"
```

---

## Task 2：編輯模式不得把滑鼠送進 guest（D22）

**Files:**
- Modify: `app/Sources/MirageShell/Keymap/KeymapController.swift:32`
- Modify: `app/Sources/MirageShell/MirrorView.swift`（Coordinator 加 `isEditing`）
- Modify: `app/Sources/MirageShell/MirageScene.swift`（傳 `isEditing`）
- Test: `app/Tests/MirageShellTests/MirrorCoordinatorTests.swift`

**Interfaces:**
- Consumes: `OrderProbe`（既有，`Tests/MirageShellTests/OrderProbe.swift`）
- Produces: `MirrorView.Coordinator.isEditing: Bool`；`KeymapController.hasProfile` 語意改為「引擎存在」

**背景（實作者必讀）：** `hasProfile` 目前是 `engine != nil && !editing`，一進編輯模式就變 false；
而 `Coordinator.sendMouse` 用 `guard controller?.hasProfile != true else { return }` 決定要不要
退回直接 tap——**於是編輯模式反而讓滑鼠點擊直接打進 guest**。
`AppModel.shouldCapture` 已經自己寫了 `&& !editing`，所以把 `!editing` 從 `hasProfile` 拿掉
**不會改變游標捕捉行為**。

- [ ] **Step 1: 寫失敗測試**

加到 `MirrorCoordinatorTests` 的 suite 內：

```swift
    /// D22：編輯模式下滑鼠一律不得送到 guest——不管有沒有 profile。
    ///
    /// 使用者在編輯器裡拖鍵位，等於在遊戲畫面上亂點。這是階段 B 拖曳功能的前置條件：
    /// 不先修掉，拖曳一上線就是在髒環境上開發。
    @Test(.timeLimit(.minutes(1)))
    func editingModeSendsNoTapEvenWithoutProfile() async {
        let probe = OrderProbe { _ in .zero }
        let coordinator = MirrorView.Coordinator(
            client: EmulatorClient(), queue: InputQueue(injector: probe))
        coordinator.isEditing = true

        coordinator.sendMouse(nx: 0.5, ny: 0.5, down: true)
        coordinator.sendMouse(nx: 0.5, ny: 0.5, down: false)

        // 否定斷言用固定等待：這條路徑若有送出，事件會在幾毫秒內抵達探針。
        try? await Task.sleep(for: .milliseconds(150))
        #expect(probe.arrivals.isEmpty)
    }
```

- [ ] **Step 2: 跑測試確認它紅**

```bash
cd app && swift test --filter editingModeSendsNoTapEvenWithoutProfile
```

Expected: FAIL —`probe.arrivals` 會是 `["tap 0.5 down", "tap 0.5 up"]`（編譯錯誤 `isEditing` 不存在時，
先做 Step 3 的 Coordinator 部分再回來跑，直到看到**斷言失敗**而不是編譯失敗）。

- [ ] **Step 3: 拆開述詞並接線**

`KeymapController.swift:32`：

```swift
    /// true = 有作用中 profile。**不含編輯模式**（2026-07-30，D22）。
    ///
    /// 原本是 `engine != nil && !editing`，把兩個語意不同的判斷擠在一個述詞裡：
    /// 「該不該把滑鼠交給引擎」與「該不該把事件送出去」。呼叫端
    /// `MirrorView.Coordinator.sendMouse` 讀它來決定要不要退回直接 tap，於是編輯模式
    /// 反而讓滑鼠直接打進 guest。現在只表達前者，後者由 `Coordinator.isEditing` 負責。
    ///
    /// `AppModel.shouldCapture` 本來就自己寫了 `&& !editing`，游標捕捉行為不受影響。
    var hasProfile: Bool { engine != nil }
```

`MirrorView.swift` 的 `Coordinator`——加欄位：

```swift
        /// D22：編輯模式下一律不送滑鼠事件。與 `hasProfile` 是**兩件事**：
        /// 前者問「該不該交給引擎」，這個問「該不該送出去」。
        var isEditing = false
```

`sendMouse` 改成：

```swift
        func sendMouse(nx: Double, ny: Double, down: Bool) {
            // D22：編輯中一律不送。使用者正在拖鍵位，不是在玩。
            guard !isEditing else { return }
            // 有作用中 profile 時鍵鼠改走 KeymapController → KeymapEngine，這裡不再重複送 tap。
            guard controller?.hasProfile != true else { return }
            queue.tap(nx: nx, ny: ny, down: down)
        }
```

`MirrorView` struct 加參數並同步進 Coordinator：

```swift
    var controller: KeymapController?
    /// D22：由 `AppModel.editing` 驅動，透過 `updateNSView` 逐次同步進 Coordinator。
    var isEditing: Bool
    let queue: InputQueue
```

`updateNSView` 改成：

```swift
    func updateNSView(_ view: MirrorContainerView, context: Context) {
        context.coordinator.controller = controller
        context.coordinator.isEditing = isEditing
    }
```

`makeNSView` 內 `context.coordinator.controller = controller` 那行後面加一行：

```swift
        context.coordinator.isEditing = isEditing
```

`MirageScene.swift` 的 `MirrorView(...)` 呼叫加參數：

```swift
                MirrorView(client: model.client, box: model.box,
                           controller: model.keymap, isEditing: model.editing,
                           queue: model.inputQueue)
```

- [ ] **Step 4: 跑測試確認全綠**

```bash
cd app && swift test
```

Expected: PASS。既有 `MirrorCoordinatorTests.tapsReachGuestInPressOrder` 仍須綠
（它沒設 `isEditing`，預設 false）。

- [ ] **Step 5: Commit**

```bash
git add app/Sources/MirageShell/Keymap/KeymapController.swift \
        app/Sources/MirageShell/MirrorView.swift \
        app/Sources/MirageShell/MirageScene.swift \
        app/Tests/MirageShellTests/MirrorCoordinatorTests.swift
git commit -m "fix: D22 編輯模式不得把滑鼠送進 guest，拆開 hasProfile 的兩個語意"
```

---

## Task 3：starter 版面（純函式）

**Files:**
- Modify: `app/Sources/MirageCore/Keymap/BuiltInProfiles.swift`
- Test: `app/Tests/MirageCoreTests/BuiltInProfilesTests.swift`

**Interfaces:**
- Produces:
  - `BuiltInProfiles.starterBindings(from sources: [URL]) -> [Binding]`
  - `BuiltInProfiles.starterBindings() -> [Binding]`（轉呼叫，餵 `bundledSources()`）
  - `BuiltInProfiles.fallbackStarterBindings: [Binding]`（`static let`）

**設計理由：** 拆成「吃 sources 的純函式」＋「餵 bundle 的薄轉呼叫」，比照既有的
`seed(into:from:)` / `bundledSources()` 分法——`Bundle.module` 是本型別唯一不可單元測試的
部分，讓不可測的面積縮到最小。

- [ ] **Step 1: 寫失敗測試**

加到 `BuiltInProfilesTests` 的 suite 內：

```swift
    /// starter 借的是**版面**，不是 gameId——借了 gameId 就會存回那個佔位檔（D5 §1 的死路）。
    @Test func starterBindingsComeFromTheFirstReadableSource() throws {
        let dir = tempDir("starter-ok")
        let json = """
        {"gameId":"whatever","version":9,"bindings":[
          {"tap":{"at":{"x":0.5,"y":0.5},"key":{"key":{"_0":"z"}}}}
        ]}
        """
        let src = try writeSource(dir, name: "a.json", body: json)
        let bindings = BuiltInProfiles.starterBindings(from: [src])
        #expect(bindings.count == 1)
        if case .tap(let key, _) = bindings[0] { #expect(key == .key("z")) }
        else { Issue.record("期待 .tap，實得 \(bindings[0])") }
    }

    /// 沒有來源（bundle 壞掉，見 D25）時退回寫死的 starter——編輯器不該因為資源問題
    /// 而完全打不開。
    @Test func starterBindingsFallBackWhenNoSourceIsReadable() {
        let bindings = BuiltInProfiles.starterBindings(from: [])
        #expect(bindings == BuiltInProfiles.fallbackStarterBindings)
        #expect(!bindings.isEmpty)
    }

    /// 來源存在但內容壞掉，也要退回 fallback，不能回空陣列——空的 starter 等於空白畫布，
    /// 而那是我們明確否決掉的起點。
    @Test func starterBindingsFallBackWhenSourceIsCorrupt() throws {
        let dir = tempDir("starter-corrupt")
        let src = try writeSource(dir, name: "bad.json", body: "{ not json")
        #expect(BuiltInProfiles.starterBindings(from: [src]) == BuiltInProfiles.fallbackStarterBindings)
    }

    /// fallback 本身必須是一份合法 profile 的 bindings。
    @Test func fallbackStarterIsValid() throws {
        let p = KeymapProfile(gameId: "g", version: 1,
                              bindings: BuiltInProfiles.fallbackStarterBindings)
        _ = try p.validated()
    }
```

- [ ] **Step 2: 跑測試確認它紅**

```bash
cd app && swift test --filter starterBindings
```

Expected: 編譯失敗 `type 'BuiltInProfiles' has no member 'starterBindings'`。

- [ ] **Step 3: 實作**

在 `BuiltInProfiles.swift` 的 `bundledSources()` **下方**加：

```swift
    /// 寫死的 starter 版面：搖桿（WASD）＋兩顆點擊鍵＋視角。
    ///
    /// 存在的理由是「編輯器不該因為資源問題而打不開」。bundle 讀不到時（D25 的情境）
    /// 退回這一份，而不是回空陣列——空的 starter 等於空白畫布，那是設計時明確否決的起點。
    public static let fallbackStarterBindings: [Binding] = [
        .joystick(up: .key("w"), down: .key("s"), left: .key("a"), right: .key("d"),
                  center: NormPoint(x: 0.2, y: 0.75), radius: 0.12),
        .tap(key: .key("j"), at: NormPoint(x: 0.85, y: 0.82)),
        .tap(key: .key("k"), at: NormPoint(x: 0.72, y: 0.88)),
        .look(activation: nil, sensitivity: 1.5),
    ]

    /// 從內建 profile 借**版面**（不借 gameId、不借 version）。
    ///
    /// 借 gameId 會讓編輯後的存檔寫回那個佔位檔，正是 D5 §1 描述的死路。
    /// 任一來源解不出來就換下一個；全部失敗才退回 `fallbackStarterBindings`。
    public static func starterBindings(from sources: [URL]) -> [Binding] {
        for source in sources {
            guard let data = try? Data(contentsOf: source),
                  let profile = try? JSONDecoder().decode(KeymapProfile.self, from: data),
                  !profile.bindings.isEmpty
            else { continue }
            return profile.bindings
        }
        return fallbackStarterBindings
    }

    /// 產品呼叫端用這個。`Bundle.module` 不可單元測試，所以這裡只做轉呼叫，
    /// 判斷全在上面那個吃 `sources` 的純函式裡。
    public static func starterBindings() -> [Binding] {
        starterBindings(from: bundledSources())
    }
```

- [ ] **Step 4: 跑測試確認全綠**

```bash
cd app && swift test
```

Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add app/Sources/MirageCore/Keymap/BuiltInProfiles.swift \
        app/Tests/MirageCoreTests/BuiltInProfilesTests.swift
git commit -m "feat: D5-A starter 版面（借版面不借 gameId，資源讀不到時退回寫死版本）"
```

---

## Task 4：⌘E 進入決策（純函式）

**Files:**
- Create: `app/Sources/MirageCore/Keymap/EditorEntryDecider.swift`
- Test: `app/Tests/MirageCoreTests/EditorEntryDeciderTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum EditorEntry: Sendable, Equatable {
      case ignore
      case leave
      case enter(KeymapProfile)
  }
  public enum EditorEntryDecider {
      public static func decide(editing: Bool,
                               profile: KeymapProfile?,
                               currentPackage: String?,
                               starterBindings: [Binding]) -> EditorEntry
  }
  ```

**設計理由：** 比照既有的 `ActivationDecider`——把「純決策」與「I/O 與副作用」分開，
決策才測得到。`AppModel` 沒有注入縫（`client`／`store` 都是寫死的欄位），
把邏輯留在那裡等於零涵蓋。

- [ ] **Step 1: 寫失敗測試**

Create `app/Tests/MirageCoreTests/EditorEntryDeciderTests.swift`:

```swift
import Testing
@testable import MirageCore

@Suite struct EditorEntryDeciderTests {
    private let starter: [Binding] = [
        .tap(key: .key("j"), at: NormPoint(x: 0.8, y: 0.8)),
    ]
    private func profile(_ gameId: String) -> KeymapProfile {
        KeymapProfile(gameId: gameId, version: 3, bindings: [
            .tap(key: .key("z"), at: NormPoint(x: 0.1, y: 0.1)),
        ])
    }

    /// 已在編輯模式時，⌘E 永遠允許離開——即使途中偵測把遊戲切成 .inactive
    /// 導致 profile 變 nil，也不能卡死在編輯模式出不來。
    @Test func editingAlwaysAllowsLeaving() {
        #expect(EditorEntryDecider.decide(editing: true, profile: nil,
                                          currentPackage: nil, starterBindings: starter) == .leave)
    }

    /// 有 profile 就直接編它。
    @Test func existingProfileEntersDirectly() {
        let p = profile("com.game.a")
        #expect(EditorEntryDecider.decide(editing: false, profile: p,
                                          currentPackage: "com.game.a",
                                          starterBindings: starter) == .enter(p))
    }

    /// **本階段的重點**：沒有 profile 但知道當前遊戲 → 用 starter 版面建一份，
    /// gameId 是**當前遊戲**、version 從 1 起算。
    @Test func noProfileButKnownGameEntersWithStarter() {
        let decision = EditorEntryDecider.decide(editing: false, profile: nil,
                                                 currentPackage: "com.loomgames.pixelflow",
                                                 starterBindings: starter)
        #expect(decision == .enter(KeymapProfile(gameId: "com.loomgames.pixelflow",
                                                 version: 1, bindings: starter)))
    }

    /// 不知道在玩什麼（沒有 adb／沒有前景遊戲）就沒有 gameId 可以掛，只能不動作。
    @Test func noProfileAndNoPackageIsIgnored() {
        #expect(EditorEntryDecider.decide(editing: false, profile: nil,
                                          currentPackage: nil,
                                          starterBindings: starter) == .ignore)
    }

    /// starter 為空（理論上不會發生，`starterBindings` 有 fallback）也不建空 profile
    /// ——空白畫布是明確否決的起點。
    @Test func emptyStarterIsIgnored() {
        #expect(EditorEntryDecider.decide(editing: false, profile: nil,
                                          currentPackage: "com.game.a",
                                          starterBindings: []) == .ignore)
    }
}
```

- [ ] **Step 2: 跑測試確認它紅**

```bash
cd app && swift test --filter EditorEntryDeciderTests
```

Expected: 編譯失敗 `cannot find 'EditorEntryDecider' in scope`。

- [ ] **Step 3: 實作**

Create `app/Sources/MirageCore/Keymap/EditorEntryDecider.swift`:

```swift
import Foundation

/// ⌘E 按下之後該發生什麼。
public enum EditorEntry: Sendable, Equatable {
    /// 不動作（沒有可編的東西，也沒有 gameId 可以掛）。
    case ignore
    /// 離開編輯模式。
    case leave
    /// 進入編輯模式，帶著這份 profile（可能是既有的，也可能是剛用 starter 建出來的）。
    case enter(KeymapProfile)
}

/// ⌘E 的**純決策**。比照 `ActivationDecider`：決策與 I/O 分開，決策才測得到。
///
/// **為什麼需要它**：原本 `AppModel.toggleEditing` 的 guard 是
/// `guard editing || profile != nil else { return }`，而玩真實遊戲時 `profile` 永遠是 nil
/// （唯一的內建 profile 是佔位 gameId `com.example.game`），所以 **⌘E 完全沒有反應**。
/// 見設計文件 `docs/specs/2026-07-30-d5-keymap-editor-design.md` §1。
public enum EditorEntryDecider {
    /// - Parameters:
    ///   - editing: 目前是否已在編輯模式。
    ///   - profile: 目前作用中的 profile（`AppModel.profile`）。
    ///   - currentPackage: 偵測到的前景 package；無 adb／無前景遊戲時為 nil。
    ///   - starterBindings: 沒有 profile 時要用的起始版面（見 `BuiltInProfiles.starterBindings`）。
    public static func decide(editing: Bool,
                              profile: KeymapProfile?,
                              currentPackage: String?,
                              starterBindings: [Binding]) -> EditorEntry
    {
        // 已在編輯模式就一定放行離開——途中偵測可能把 profile 收成 nil，
        // 若這裡跟著擋掉，使用者會卡死在編輯模式出不來。
        if editing { return .leave }
        if let profile { return .enter(profile) }
        // 沒有 profile：要有 gameId 才掛得住，也要有版面才編得動。
        guard let gameId = currentPackage, !starterBindings.isEmpty else { return .ignore }
        return .enter(KeymapProfile(gameId: gameId, version: 1, bindings: starterBindings))
    }
}
```

- [ ] **Step 4: 跑測試確認全綠**

```bash
cd app && swift test
```

Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add app/Sources/MirageCore/Keymap/EditorEntryDecider.swift \
        app/Tests/MirageCoreTests/EditorEntryDeciderTests.swift
git commit -m "feat: D5-A ⌘E 進入決策抽成純函式 EditorEntryDecider"
```

---

## Task 5：接線並驗收

**Files:**
- Modify: `app/Sources/MirageShell/AppModel.swift`（`toggleEditing`）

**Interfaces:**
- Consumes: `EditorEntryDecider.decide(...)`、`BuiltInProfiles.starterBindings()`（Task 3、4）

**注意：** `AppModel` 沒有注入縫，這個 task **沒有單元測試**——判斷邏輯的涵蓋在 Task 4，
這裡只有接線。這是刻意的取捨，不是遺漏；驗收靠 Step 3 的手動確認。

- [ ] **Step 1: 改 `toggleEditing`**

把 `AppModel.swift` 的 `toggleEditing()` 整個換成：

```swift
    /// ⌘E：切換編輯模式。決策在 `EditorEntryDecider`（純函式、逐條測試），這裡只做副作用。
    ///
    /// **行為改變（2026-07-30，D5 階段 A）**：原本的 guard 是
    /// `guard editing || profile != nil else { return }`，而玩真實遊戲時 `profile` 永遠是 nil
    /// ——唯一的內建 profile 是佔位 gameId，載不到當前遊戲的檔——所以 ⌘E 完全沒有反應。
    /// 現在沒有 profile 時會用 starter 版面**在記憶體裡**建一份。
    ///
    /// **不落檔是刻意的**：檔案要按下「存檔」才出現。否則不小心按到 ⌘E 就會憑空生出一個檔案。
    func toggleEditing() {
        let starter = BuiltInProfiles.starterBindings()
        switch EditorEntryDecider.decide(editing: editing, profile: profile,
                                         currentPackage: currentPackage,
                                         starterBindings: starter) {
        case .ignore:
            return
        case .leave:
            editing = false
        case .enter(let p):
            // 即時套用：overlay 與引擎都看得到這份 profile。`emit` 在編輯模式下本來就被擋，
            // 所以套用不會有任何東西送到 guest。
            profile = p
            keymap?.reload(p)
            editing = true
        }
        keymap?.setEditing(editing)
        mouseCapture.updateCapture(shouldCapture: shouldCapture)
    }
```

- [ ] **Step 2: 跑完整測試**

```bash
cd app && swift test
```

Expected: 240+ 條全過（既有測試不得變紅）。

- [ ] **Step 3: 手動驗收（需模擬器）**

```bash
# 開模擬器
"$HOME/Library/Android/sdk/emulator/emulator" -avd mirage-poc -no-window -grpc 8554 &
# 等開機
"$HOME/Library/Android/sdk/platform-tools/adb" -s emulator-5554 wait-for-device
# 打包並啟動
cd app && APP=$(./scripts/package_app.sh /tmp/mirage_d5a 2>/dev/null) && "$APP/Contents/MacOS/MirageApp"
```

在模擬器上開任一 App（讓 `currentPackage` 非 nil），然後：

1. 按 ⌘E → **編輯器要打得開**，畫面上看得到 starter 的搖桿圈與兩顆技能鍵標記。
2. 檢查 `~/Library/Application Support/Mirage/profiles/` → **不得**出現當前 package 的 json
   （未存檔不落檔）。
3. 編輯模式下在鏡像畫面上點幾下 → guest **不得**有任何反應（D22）。
4. 按 ⌘E 離開 → 回到正常鏡像。

- [ ] **Step 4: 跑閘門**

```bash
cd app && ./scripts/ci.sh; echo "CI_EXIT=$?"
```

Expected: `CI_EXIT=0`，四道閘門全綠。

- [ ] **Step 5: Commit**

```bash
git add app/Sources/MirageShell/AppModel.swift
git commit -m "feat: D5-A ⌘E 在沒有 profile 時用 starter 版面進入編輯器（不落檔）"
```

---

## 階段 A 完成後的狀態

- 真實遊戲按 ⌘E 打得開編輯器，看得到 starter 版面，未存檔不留下任何檔案。
- 編輯模式下滑鼠不會打進 guest（D22 關閉）。
- 搖桿座標不會越界（D12 關閉）。
- **還不能拖、不能改參數、不能新增刪除**——那是階段 B/C。
  使用者此時能做的只有「看到版面」與「按既有的存檔按鈕存下 starter」。

**階段 A 不關閉 D5**（D5 要到階段 B 才算補上字面範圍）。債務表更新留到階段 B 結束。
