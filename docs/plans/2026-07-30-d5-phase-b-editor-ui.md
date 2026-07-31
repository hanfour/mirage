# D5 階段 B：抽屜 UI ＋ 拖曳 ＋ 半徑／靈敏度 實作計畫

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 讓使用者能把 starter 版面拖到自己要的位置、調整搖桿半徑與視角靈敏度並存檔——D5 的字面範圍到此完成。

**Architecture:** 幾何換算與編輯狀態轉移全部下沉成 `MirageCore` 純函式（`EditorGeometry`、`EditorSession`），SwiftUI 只做手勢與繪製。座標一律以 **letterbox 後的內容矩形**為基準，不是整個視窗。

**Tech Stack:** Swift 6.2（語言模式 v5、`-strict-concurrency=complete`）、swift-testing、SwiftUI/AppKit。

## Global Constraints

- 測試框架用 `swift-testing`（`@Test` / `@Suite` / `#expect`），**不是** XCTest。
- 測試裡禁止 `guard … else { return }` 早退——`ci.sh` 閘門 3 會擋。
- 等待一律用無預算閘門（`CountGate` / `StateRecorder`），**禁止**新增 `waitUntil` 式輪詢。
- shell 腳本裡變數後接全形標點一律 `${VAR}`——`ci.sh` 閘門 4 會擋。
- 測試**不得**在使用者真實的 `~/Library/Application Support` 底下建立或寫入任何東西——用 `AppModel(store:starterBindings:)` 注入暫存 store。
- 註解寫**為什麼**，不是寫**做了什麼**。
- commit 訊息用 conventional commits，**繁體中文**。
- 不可變優先：`EditorSession` 的所有變換回傳新值，不就地改寫。
- 每個 task 結束前 `cd app && swift test`；全計畫結束 `./scripts/ci.sh`（須 `CI_EXIT=0`）。

---

## 檔案結構

| 檔案 | 責任 | 動作 |
|---|---|---|
| `app/Sources/MirageCore/Keymap/EditorGeometry.swift` | 正規化座標 ↔ 內容矩形內的視圖座標（純函式） | **新增** |
| `app/Sources/MirageCore/Keymap/EditorSession.swift` | 編輯階段的 binding 清單、選取、變換、髒污旗標（純值型別） | **新增** |
| `app/Sources/MirageShell/AppModel.swift` | 持有 `frameSize`／`editorSession`／離開提示狀態 | 修改 |
| `app/Sources/MirageShell/AppModel+FullScreen.swift` | `NSApp` 保護 | 修改 |
| `app/Sources/MirageShell/MirrorView.swift` | 幀尺寸往上傳 | 修改 |
| `app/Sources/MirageShell/Keymap/KeymapOverlay.swift` | 標記改用內容矩形定位；編輯時顯示把手 | 修改 |
| `app/Sources/MirageShell/Keymap/EditorDrawer.swift` | 底部抽屜（清單＋參數） | **新增** |
| `app/Sources/MirageShell/Keymap/OverlayEditorView.swift` | 組合 overlay ＋ 抽屜 | 改寫 |
| `app/Sources/MirageShell/MirageScene.swift` | 接線 | 修改 |

**八個 task。** Task 1–2 是前置，見下一節的相依表。

---

## Task 1：補完 `NSApp` 的 Optional 保護（D34 (c)）

**Files:**
- Modify: `app/Sources/MirageShell/AppModel.swift:340`、`:362`
- Modify: `app/Sources/MirageShell/AppModel+FullScreen.swift:13`
- Test: `app/Tests/MirageShellTests/AppModelEditingTests.swift`

**Interfaces:**
- Produces: 無新 API。純防禦性改動。

**背景（實作者必讀）：** `NSApp` 的型別是 `NSApplication!`（IUO）。headless 的 `swift test` 行程若沒人先碰過 `NSApplication.shared`，它就是 nil，直接解包會讓**整個 test run** 以 `signal 5` 死掉，而錯誤訊息完全不指向 `NSApp`。階段 A 已經修掉 `shouldCapture` 那一處並實測過這個崩法；剩下三處在 `startLifecycle()`／`wake()`／選單列回呼裡，階段 B 的測試會開始碰到它們。

- [ ] **Step 1: 寫失敗測試**

加到 `AppModelEditingTests` 的 suite 內：

```swift
    /// D34 (c)：`startLifecycle()` 會碰 `NSApp.windows`，headless 測試行程裡 `NSApp` 是 nil。
    /// 這條測試的價值不在斷言，而在**它能跑完**——硬解包會讓整個 test run 收到 signal 5。
    @Test func startLifecycleSurvivesNilNSApp() {
        let (store, dir) = Self.tempStore("lifecycle")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(store: store,
                             starterBindings: { [.tap(key: .key("q"), at: NormPoint(x: 0.3, y: 0.3))] })

        model.startLifecycle()

        #expect(model.lifecycle != nil)
        #expect(model.menuBar != nil)
    }
```

- [ ] **Step 2: 跑測試確認它紅**

```bash
cd app && swift test --filter startLifecycleSurvivesNilNSApp
```

Expected: 整個 run 以 `Fatal error: Unexpectedly found nil while implicitly unwrapping an Optional value` ＋ `Exited with unexpected signal code 5` 死掉。**這就是預期的 RED**，如實記錄那段輸出。

> 註：`startLifecycle()` 內的 `NSApp.windows.first` 在一個 `Task { await MainActor.run { … } }` 裡，可能要等一輪 run loop 才炸。若第一次跑沒炸，在斷言前加 `try? await Task.sleep(for: .milliseconds(50))` 並把測試改成 `async`，再跑一次確認它真的紅。

- [ ] **Step 3: 三處都加保護**

`AppModel.swift:340`：

```swift
                // `NSApp` 是 IUO，headless 測試行程裡是 nil——硬解包會帶著整個 test run
                // 一起死，而錯誤訊息不指向這裡。理由同 `shouldCapture`（見該處註解）。
                (NSApp as NSApplication?)?.windows.first?.delegate = self?.lifecycle
```

`AppModel.swift:362`：

```swift
        let window = (NSApp as NSApplication?)?.windows.first
```

`AppModel+FullScreen.swift:13`：

```swift
        menuBar?.onToggleFullScreen = { (NSApp as NSApplication?)?.keyWindow?.toggleFullScreen(nil) }
```

- [ ] **Step 4: 跑測試確認全綠**

```bash
cd app && swift test
```

Expected: 262 條全過（261 ＋ 新增 1），且 run 能跑完。

- [ ] **Step 5: Commit**

```bash
git add app/Sources/MirageShell/AppModel.swift \
        app/Sources/MirageShell/AppModel+FullScreen.swift \
        app/Tests/MirageShellTests/AppModelEditingTests.swift
git commit -m "fix: D34(c) 補完 NSApp 的 Optional 保護，headless 測試不再整組炸掉"
```

---

## Task 2：`EditorGeometry`（純函式）

**Files:**
- Create: `app/Sources/MirageCore/Keymap/EditorGeometry.swift`
- Test: `app/Tests/MirageCoreTests/EditorGeometryTests.swift`

**Interfaces:**
- Consumes: `ViewportFit.FitRect`（既有，`Sources/MirageCore/Viewport/ViewportFit.swift`，欄位 `x/y/width/height` 皆為 `Int`）、`NormPoint`
- Produces:
  - `EditorGeometry.viewPoint(for: NormPoint, in: FitRect) -> (x: Double, y: Double)`
  - `EditorGeometry.normPoint(x: Double, y: Double, in: FitRect) -> NormPoint?`
  - `EditorGeometry.radiusInPoints(_ radius: Double, in: FitRect) -> Double`
  - `EditorGeometry.radius(fromPoints: Double, in: FitRect) -> Double?`

**這個 task 修的是什麼：** `KeymapOverlay` 目前用 `GeometryReader` 的**整個視窗尺寸**換算標記位置（`at.x * geo.size.width`），但 guest 畫面實際被 `MirrorContainerView` letterbox 進 `ViewportFit.fit(...)` 的內容矩形。只要有黑邊，標記畫的位置就與真正的觸點位置不一致。視窗模式下 `contentAspectRatio` 把黑邊壓到接近 0 所以看不太出來，**但全螢幕時 macOS 忽略那個設定、黑邊是真的**，而編輯器分支沒有 `!isFullScreen` 的 guard。拖曳一上線，這就從「畫得有點歪」變成「你拖到看見的位置，觸點落在別處」。

`radius` 的正規化基準是**寬度**（沿用 `KeymapOverlay` 既有慣例：圓的直徑用 `radius * size.width * 2` 同時當寬與高），不要改成對角線或高度。

- [ ] **Step 1: 寫失敗測試**

Create `app/Tests/MirageCoreTests/EditorGeometryTests.swift`:

```swift
import Testing
@testable import MirageCore

@Suite struct EditorGeometryTests {
    /// 內容矩形有黑邊時，正規化座標必須落在**內容矩形內**，不是整個視窗。
    /// 這是本 task 的本體：舊寫法用視窗尺寸換算，有黑邊就對不上。
    @Test func viewPointIsRelativeToContentRectNotWindow() {
        // 1000x1000 視窗裡塞 9:20 直向幀 → 左右黑邊，內容矩形 x=275 width=450
        let rect = ViewportFit.fit(frame: (w: 9, h: 20), in: (w: 1000, h: 1000))
        #expect(rect == FitRect(x: 275, y: 0, width: 450, height: 1000))

        let mid = EditorGeometry.viewPoint(for: NormPoint(x: 0.5, y: 0.5), in: rect)
        #expect(mid.x == 500)      // 275 + 450*0.5
        #expect(mid.y == 500)

        let topLeft = EditorGeometry.viewPoint(for: NormPoint(x: 0, y: 0), in: rect)
        #expect(topLeft.x == 275)  // **不是 0**——0 是黑邊，不是 guest 的左緣
        #expect(topLeft.y == 0)
    }

    /// 反向換算是正向的逆。
    @Test func normPointRoundTripsThroughViewPoint() {
        let rect = ViewportFit.fit(frame: (w: 9, h: 20), in: (w: 1000, h: 1000))
        let original = NormPoint(x: 0.25, y: 0.8)
        let v = EditorGeometry.viewPoint(for: original, in: rect)
        let back = EditorGeometry.normPoint(x: v.x, y: v.y, in: rect)
        #expect(back != nil)
        #expect(abs((back?.x ?? -1) - original.x) < 0.0001)
        #expect(abs((back?.y ?? -1) - original.y) < 0.0001)
    }

    /// 拖到黑邊上必須夾回 0…1，不能產生越界座標——與 D7／D12 同一條立場：
    /// 送越界座標比不送更糟（畫面有反應但點在錯的地方）。
    @Test func normPointClampsPointsInTheLetterbox() {
        let rect = ViewportFit.fit(frame: (w: 9, h: 20), in: (w: 1000, h: 1000))
        let left = EditorGeometry.normPoint(x: 10, y: 500, in: rect)     // 落在左黑邊
        #expect(left?.x == 0)
        #expect(left?.isValid == true)
        let right = EditorGeometry.normPoint(x: 990, y: 500, in: rect)   // 落在右黑邊
        #expect(right?.x == 1)
        #expect(right?.isValid == true)
    }

    /// 退化矩形（尚未收到任何幀）→ nil，呼叫端據此不換算。
    @Test func normPointRejectsDegenerateRect() {
        #expect(EditorGeometry.normPoint(x: 1, y: 1, in: .zero) == nil)
        #expect(EditorGeometry.radius(fromPoints: 10, in: .zero) == nil)
    }

    /// radius 的正規化基準是**寬度**（沿用 KeymapOverlay 既有慣例），不是高度也不是對角線。
    @Test func radiusIsNormalisedAgainstWidth() {
        let rect = ViewportFit.fit(frame: (w: 9, h: 20), in: (w: 1000, h: 1000))
        #expect(EditorGeometry.radiusInPoints(0.12, in: rect) == 54)     // 450 * 0.12
        let back = EditorGeometry.radius(fromPoints: 54, in: rect)
        #expect(abs((back ?? -1) - 0.12) < 0.0001)
    }
}
```

- [ ] **Step 2: 跑測試確認它紅**

```bash
cd app && swift test --filter EditorGeometryTests
```

Expected: 編譯失敗 `cannot find 'EditorGeometry' in scope`。

- [ ] **Step 3: 實作**

Create `app/Sources/MirageCore/Keymap/EditorGeometry.swift`:

```swift
import Foundation

/// 正規化座標（0–1，對齊 guest 畫面）↔ **letterbox 後內容矩形內**的視圖座標。
///
/// **為什麼不能用整個視窗的尺寸換算**：guest 畫面被 `MirrorContainerView` 依
/// `ViewportFit.fit(...)` 置中進內容矩形，黑邊不屬於 guest。用視窗尺寸換算，只要有黑邊
/// 標記就與真正的觸點位置錯開——視窗模式下 `contentAspectRatio` 把黑邊壓到接近 0 所以
/// 看不太出來，但**全螢幕時 macOS 忽略 `contentAspectRatio`，黑邊是真的**。
///
/// 純函式放這裡的理由同 `KeyTranslate`／`StreamSize`／`ViewportFit`：算術逐條測試，
/// SwiftUI 那層只負責手勢與繪製。
public enum EditorGeometry {
    /// 正規化座標 → 視圖座標（相對於**容器**，已含內容矩形的偏移）。
    public static func viewPoint(for p: NormPoint, in rect: FitRect) -> (x: Double, y: Double) {
        (x: Double(rect.x) + p.x * Double(rect.width),
         y: Double(rect.y) + p.y * Double(rect.height))
    }

    /// 視圖座標 → 正規化座標，**夾在 0…1**。矩形退化（尚未收到幀）時回 nil。
    ///
    /// 夾取而非拒絕，理由同 D7：拖到黑邊上仍要得到一個合法座標，
    /// 送越界座標比不送更糟——畫面會有反應但點在錯的地方。
    public static func normPoint(x: Double, y: Double, in rect: FitRect) -> NormPoint? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        return NormPoint.clamped(x: (x - Double(rect.x)) / Double(rect.width),
                                 y: (y - Double(rect.y)) / Double(rect.height))
    }

    /// 搖桿半徑 → 點數。**基準是寬度**，沿用 `KeymapOverlay` 既有慣例
    /// （圓的直徑用 `radius * width * 2` 同時當寬與高）。改成高度或對角線會讓既有
    /// profile 的搖桿在畫面上換一個大小。
    public static func radiusInPoints(_ radius: Double, in rect: FitRect) -> Double {
        radius * Double(rect.width)
    }

    /// 點數 → 搖桿半徑。矩形退化時回 nil。
    public static func radius(fromPoints d: Double, in rect: FitRect) -> Double? {
        guard rect.width > 0 else { return nil }
        return d / Double(rect.width)
    }
}
```

- [ ] **Step 4: 跑測試確認全綠**

```bash
cd app && swift test
```

- [ ] **Step 5: Commit**

```bash
git add app/Sources/MirageCore/Keymap/EditorGeometry.swift \
        app/Tests/MirageCoreTests/EditorGeometryTests.swift
git commit -m "feat: D5-B EditorGeometry——座標一律對齊 letterbox 內容矩形而非整個視窗"
```

---

## Task 順序與相依

| # | 內容 | 為什麼在這個位置 |
|---|---|---|
| 1 | `NSApp` 保護 | **前置**。不修的話 Task 5–8 的測試（會建帶引擎的 `AppModel`）把整個 test run 以 signal 5 打死，錯誤訊息完全不指向成因 |
| 2 | `EditorGeometry` | **前置**。座標基準錯了，後面所有拖曳都建立在錯的換算上 |
| 3 | `EditorSession` | 純值型別，無相依 |
| 4 | 幀尺寸 ＋ overlay 對齊 | 需要 2；做完唯讀 overlay 就已修正對齊，尚無互動 |
| 5 | 抽屜 ＋ session 生命週期 | 需要 3、4 |
| 6 | 拖曳移動 | 需要 2、3、5 |
| 7 | 半徑與靈敏度 | 需要 6（共用 `applyToSession`）。與 6 拆開是因為**拖曳與調參數是兩種手勢、兩組測試**，混在一起審查者無法只否決其中一半 |
| 8 | 未存變更與離開提示 | 需要 5–7 才有「變更」可談 |

---

## Task 3：`EditorSession`（純值型別）

**Files:**
- Create: `app/Sources/MirageCore/Keymap/EditorSession.swift`
- Test: `app/Tests/MirageCoreTests/EditorSessionTests.swift`

**Interfaces:**
- Consumes: `KeymapProfile`、`Binding`、`NormPoint`（皆既有）
- Produces:
  - `EditorSession.Item`（`id: UUID`、`binding: Binding`、`Identifiable`、`Equatable`、`Sendable`）
  - `EditorSession.init(profile: KeymapProfile)`
  - `EditorSession.items: [Item]`、`.selectedID: UUID?`、`.isDirty: Bool`、`.gameId: String`
  - `EditorSession.selecting(_ id: UUID?) -> EditorSession`
  - `EditorSession.movingSelected(to p: NormPoint) -> EditorSession`
  - `EditorSession.settingSelectedRadius(_ r: Double) -> EditorSession`
  - `EditorSession.settingSelectedSensitivity(_ s: Double) -> EditorSession`
  - `EditorSession.profile() -> KeymapProfile`

**設計理由（實作者必讀）：**
- **身分留在編輯階段、不進 JSON**（設計文件 §3.1）。`Binding` 是裸 enum 存在陣列裡，
  `KeymapOverlay` 原本用陣列索引當識別——編輯器要選取／之後要刪除，索引當身分必壞
  （刪掉第 1 筆，第 2 筆的索引變成 1，選取跳到錯的東西上）。把 `UUID` 留在 session 裡、
  存檔時攤平回 `[Binding]`，就不必為 profile 的檔案格式多一套版本遷移。
- **不提供重排**（§3.2）。`KeymapEngine` 對 joystick/look 採一對一 id 模型，觸點
  identifier 由**陣列順序**決定（既有測試註解：「搖桿是第一個 binding → identifier 1」）。
  重排會改變送給 guest 的 touch identifier。要支援排序得連 `KeymapEngine` 的 id 模型
  一起重新設計，那是另一輪的事。
- **全部變換回傳新值**，不就地改寫（專案的不可變規範）。
- **`isDirty` 只由變換設定**，`selecting` 不算變更——只是選取，沒動資料。
  這條很重要：否則使用者只是點了一下清單，離開時就會被問「要不要存檔」。
- **`profile()` 的 version 是 `baseVersion + 1`**，`gameId` 沿用建構時那份的，不從別處取。

- [ ] **Step 1: 寫失敗測試**

Create `app/Tests/MirageCoreTests/EditorSessionTests.swift`:

```swift
import Testing
@testable import MirageCore

@Suite struct EditorSessionTests {
    private func sample() -> KeymapProfile {
        KeymapProfile(gameId: "com.game.a", version: 3, bindings: [
            .joystick(up: .key("w"), down: .key("s"), left: .key("a"), right: .key("d"),
                      center: NormPoint(x: 0.2, y: 0.75), radius: 0.12),
            .tap(key: .key("j"), at: NormPoint(x: 0.85, y: 0.82)),
            .look(activation: nil, sensitivity: 1.5),
        ])
    }

    /// 建構時每個 binding 拿到一個穩定身分，順序照舊（順序決定 touch identifier）。
    @Test func initAssignsStableIdentityAndKeepsOrder() {
        let s = EditorSession(profile: sample())
        #expect(s.items.count == 3)
        #expect(s.items.map(\.binding) == sample().bindings)
        #expect(Set(s.items.map(\.id)).count == 3)   // 身分互不相同
        #expect(s.selectedID == nil)
        #expect(!s.isDirty)
        #expect(s.gameId == "com.game.a")
    }

    /// 選取不算變更——否則點一下清單，離開時就會被問要不要存檔。
    @Test func selectingDoesNotMarkDirty() {
        let s = EditorSession(profile: sample())
        let picked = s.selecting(s.items[1].id)
        #expect(picked.selectedID == s.items[1].id)
        #expect(!picked.isDirty)
        #expect(picked.items == s.items)
    }

    /// 移動選中的 tap：只有那一筆改變，其餘原封不動，且標記為髒。
    @Test func movingSelectedTapChangesOnlyThatBinding() {
        let s = EditorSession(profile: sample()).selecting(EditorSession(profile: sample()).items[1].id)
        let target = s.items[1].id
        let moved = s.selecting(target).movingSelected(to: NormPoint(x: 0.1, y: 0.2))
        #expect(moved.isDirty)
        if case .tap(let key, let at) = moved.items[1].binding {
            #expect(key == .key("j"))                 // 鍵沒被動到
            #expect(at == NormPoint(x: 0.1, y: 0.2))
        } else {
            Issue.record("期待 .tap，實得 \(moved.items[1].binding)")
        }
        #expect(moved.items[0].binding == s.items[0].binding)
        #expect(moved.items[2].binding == s.items[2].binding)
        #expect(moved.items.map(\.id) == s.items.map(\.id))   // 身分不隨變換改變
    }

    /// 移動選中的搖桿改的是圓心，半徑與四顆鍵都不動。
    @Test func movingSelectedJoystickMovesCentreOnly() {
        let base = EditorSession(profile: sample())
        let moved = base.selecting(base.items[0].id).movingSelected(to: NormPoint(x: 0.4, y: 0.4))
        if case .joystick(let u, _, _, _, let c, let r) = moved.items[0].binding {
            #expect(u == .key("w"))
            #expect(c == NormPoint(x: 0.4, y: 0.4))
            #expect(r == 0.12)
        } else {
            Issue.record("期待 .joystick，實得 \(moved.items[0].binding)")
        }
    }

    /// `.look` 沒有位置可移——移動它必須是 no-op，且**不得**標記為髒
    /// （否則使用者選到視角、隨手拖一下，離開時就被問要不要存一個什麼都沒改的變更）。
    @Test func movingSelectedLookIsNoOp() {
        let base = EditorSession(profile: sample())
        let moved = base.selecting(base.items[2].id).movingSelected(to: NormPoint(x: 0.4, y: 0.4))
        #expect(moved.items == base.items)
        #expect(!moved.isDirty)
    }

    /// 沒有選取時，任何變換都是 no-op。
    @Test func mutationsWithoutSelectionAreNoOps() {
        let base = EditorSession(profile: sample())
        #expect(base.movingSelected(to: NormPoint(x: 0.4, y: 0.4)).items == base.items)
        #expect(!base.movingSelected(to: NormPoint(x: 0.4, y: 0.4)).isDirty)
        #expect(base.settingSelectedRadius(0.3).items == base.items)
        #expect(base.settingSelectedSensitivity(2.0).items == base.items)
    }

    /// 半徑只作用在搖桿上；作用在 tap 上是 no-op。
    @Test func settingRadiusAppliesOnlyToJoystick() {
        let base = EditorSession(profile: sample())
        let widened = base.selecting(base.items[0].id).settingSelectedRadius(0.3)
        if case .joystick(_, _, _, _, _, let r) = widened.items[0].binding { #expect(r == 0.3) }
        else { Issue.record("期待 .joystick") }
        #expect(widened.isDirty)

        let onTap = base.selecting(base.items[1].id).settingSelectedRadius(0.3)
        #expect(onTap.items == base.items)
        #expect(!onTap.isDirty)
    }

    /// 靈敏度只作用在 look 上；作用在搖桿上是 no-op。
    @Test func settingSensitivityAppliesOnlyToLook() {
        let base = EditorSession(profile: sample())
        let faster = base.selecting(base.items[2].id).settingSelectedSensitivity(2.5)
        if case .look(let act, let s) = faster.items[2].binding {
            #expect(act == nil)
            #expect(s == 2.5)
        } else { Issue.record("期待 .look") }
        #expect(faster.isDirty)

        let onStick = base.selecting(base.items[0].id).settingSelectedSensitivity(2.5)
        #expect(onStick.items == base.items)
        #expect(!onStick.isDirty)
    }

    /// 存檔用的 profile：gameId 沿用、version+1、順序與內容照 items。
    @Test func profileBumpsVersionAndKeepsGameIdAndOrder() {
        let base = EditorSession(profile: sample())
        let edited = base.selecting(base.items[1].id).movingSelected(to: NormPoint(x: 0.1, y: 0.2))
        let p = edited.profile()
        #expect(p.gameId == "com.game.a")
        #expect(p.version == 4)                       // 3 + 1
        #expect(p.bindings == edited.items.map(\.binding))
        #expect(try! p.validated() == p)              // 產出的 profile 必須是合法的
    }

    /// 產出的 profile 能再餵回 session，形成可重複的編輯循環。
    @Test func profileRoundTripsBackIntoASession() {
        let base = EditorSession(profile: sample())
        let again = EditorSession(profile: base.profile())
        #expect(again.items.map(\.binding) == base.items.map(\.binding))
        #expect(!again.isDirty)
        #expect(again.selectedID == nil)              // 新 session 從未選取起算
    }
}
```

- [ ] **Step 2: 跑測試確認它紅**

```bash
cd app && swift test --filter EditorSessionTests
```

Expected: 編譯失敗 `cannot find 'EditorSession' in scope`。

- [ ] **Step 3: 實作**

Create `app/Sources/MirageCore/Keymap/EditorSession.swift`:

```swift
import Foundation

/// 編輯階段的 binding 清單與選取狀態。**不可變值型別**：所有變換回傳新的 session。
///
/// **為什麼身分留在這裡、不寫進 JSON**（設計文件 §3.1）：`Binding` 是裸 enum 存在陣列裡，
/// 而編輯器要選取（之後階段 C 還要刪除），用陣列索引當身分必壞——刪掉第 1 筆，第 2 筆的
/// 索引變成 1，選取就跳到錯的東西上。身分是**編輯階段的概念**，不是 profile 的屬性；
/// 寫進 JSON 只會多一套版本遷移，換不到任何東西。
///
/// **刻意不提供重排**（§3.2）：`KeymapEngine` 對 joystick/look 採一對一 id 模型，觸點
/// identifier 由**陣列順序**決定。重排會改變送給 guest 的 identifier，要支援得連引擎的
/// id 模型一起重新設計。
public struct EditorSession: Equatable, Sendable {
    public struct Item: Equatable, Sendable, Identifiable {
        public let id: UUID
        public var binding: Binding
    }

    public private(set) var items: [Item]
    public private(set) var selectedID: UUID?
    /// 有沒有**實際改過資料**。選取不算——否則使用者點一下清單，離開時就會被問要不要存檔。
    public private(set) var isDirty: Bool
    public let gameId: String
    private let baseVersion: Int

    public init(profile: KeymapProfile) {
        items = profile.bindings.map { Item(id: UUID(), binding: $0) }
        selectedID = nil
        isDirty = false
        gameId = profile.gameId
        baseVersion = profile.version
    }

    public func selecting(_ id: UUID?) -> EditorSession {
        var copy = self
        copy.selectedID = id
        return copy                     // isDirty 不動：選取不是變更
    }

    public func movingSelected(to p: NormPoint) -> EditorSession {
        mutatingSelected { binding in
            switch binding {
            case .tap(let key, _):
                return .tap(key: key, at: p)
            case .joystick(let u, let d, let l, let r, _, let radius):
                return .joystick(up: u, down: d, left: l, right: r, center: p, radius: radius)
            case .look:
                // 視角不是螢幕上的一個點——沒有位置可移。回 nil 表示「沒有改變」，
                // 呼叫端因此也不會被標記為髒（見 `mutatingSelected`）。
                return nil
            }
        }
    }

    public func settingSelectedRadius(_ r: Double) -> EditorSession {
        mutatingSelected { binding in
            guard case .joystick(let u, let d, let l, let ri, let c, _) = binding else { return nil }
            return .joystick(up: u, down: d, left: l, right: ri, center: c, radius: r)
        }
    }

    public func settingSelectedSensitivity(_ s: Double) -> EditorSession {
        mutatingSelected { binding in
            guard case .look(let activation, _) = binding else { return nil }
            return .look(activation: activation, sensitivity: s)
        }
    }

    /// 存檔用。`gameId` 沿用建構時那份、`version` 加一、順序與內容照 `items`。
    public func profile() -> KeymapProfile {
        KeymapProfile(gameId: gameId, version: baseVersion + 1, bindings: items.map(\.binding))
    }

    /// 對選中的那一筆套用 `transform`。`transform` 回 nil 代表「這種 binding 不吃這個操作」
    /// ——此時整個 session 原封不動，**包含 `isDirty`**。把「不適用」與「改了」分開，
    /// 是為了不讓「選到視角、隨手拖一下」變成一筆假的未存變更。
    private func mutatingSelected(_ transform: (Binding) -> Binding?) -> EditorSession {
        guard let selectedID,
              let index = items.firstIndex(where: { $0.id == selectedID }),
              let updated = transform(items[index].binding),
              updated != items[index].binding
        else { return self }

        var copy = self
        copy.items[index].binding = updated
        copy.isDirty = true
        return copy
    }
}
```

- [ ] **Step 4: 跑測試確認全綠**

```bash
cd app && swift test
```

Expected: 全過。既有測試不得變紅（本 task 只新增檔案）。

- [ ] **Step 5: Commit**

```bash
git add app/Sources/MirageCore/Keymap/EditorSession.swift \
        app/Tests/MirageCoreTests/EditorSessionTests.swift
git commit -m "feat: D5-B EditorSession——編輯階段的身分與變換，全部回傳新值"
```

---

## Task 4：幀尺寸上傳 ＋ `KeymapOverlay` 改用內容矩形

**Files:**
- Modify: `app/Sources/MirageShell/AppModel.swift`（加 `frameSize`）
- Modify: `app/Sources/MirageShell/MirrorView.swift`（`onFrameSize` 往上傳）
- Modify: `app/Sources/MirageShell/MirageScene.swift`（接線）
- Modify: `app/Sources/MirageShell/Keymap/KeymapOverlay.swift`（改用內容矩形定位）
- Test: `app/Tests/MirageShellTests/AppModelEditingTests.swift`

**Interfaces:**
- Consumes: `EditorGeometry.viewPoint(for:in:)`、`EditorGeometry.radiusInPoints(_:in:)`（Task 2）、
  `ViewportFit.fit(frame:in:)`（既有）
- Produces: `AppModel.frameSize: (w: Int, h: Int)`（預設 `(0, 0)`）、
  `MirrorView.onFrameSize: (Int, Int) -> Void`

**這個 task 結束時，唯讀 overlay 的對齊就已經修好了**——還沒有任何互動，但全螢幕下的標記
從此畫在正確的位置上。拖曳（Task 6）建立在這之上。

**目前的資料流：** `Renderer.onFrameSize` →（`MirrorView.makeNSView` 的閉包）→
`container.frameSize`。`AppModel` 拿不到幀尺寸，所以 Scene 層的 overlay 無從得知內容矩形。
這個 task 讓同一個回呼**多餵一個出口**，不改既有的那條。

**誠實說明涵蓋範圍：** `KeymapOverlay` 是 SwiftUI view，本計畫**不為它寫 view 層測試**。
自動化涵蓋來自兩處：(a) 定位算術在 `EditorGeometry`／`ViewportFit`，已逐條測試；
(b) `frameSize` 的接線有下面這條測試。「兩者組合起來畫對了」由驗收條件 4（全螢幕手動檢查）
負責。這是取捨，不是遺漏——ImageRenderer 式的像素比對成本遠高於它擋掉的風險。

- [ ] **Step 1: 寫失敗測試**

加到 `AppModelEditingTests` 的 suite 內：

```swift
    /// 幀尺寸要流得到 `AppModel`——Scene 層的 overlay 靠它算 letterbox 內容矩形。
    /// 預設 (0, 0) 代表「還沒收到任何幀」，此時 `ViewportFit.fit` 回 `.zero`，overlay 不畫。
    @Test func frameSizeStartsUnknownAndIsSettable() {
        let (store, dir) = Self.tempStore("framesize")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(store: store,
                             starterBindings: { [.tap(key: .key("q"), at: NormPoint(x: 0.3, y: 0.3))] })

        #expect(model.frameSize.w == 0)
        #expect(model.frameSize.h == 0)
        #expect(ViewportFit.fit(frame: model.frameSize, in: (w: 1000, h: 1000)) == .zero)

        model.frameSize = (w: 1080, h: 2400)
        #expect(ViewportFit.fit(frame: model.frameSize, in: (w: 1000, h: 1000))
                == FitRect(x: 275, y: 0, width: 450, height: 1000))
    }
```

- [ ] **Step 2: 跑測試確認它紅**

```bash
cd app && swift test --filter frameSizeStartsUnknownAndIsSettable
```

Expected: 編譯失敗 `value of type 'AppModel' has no member 'frameSize'`。

- [ ] **Step 3: 加欄位並接線**

`AppModel.swift`，在 `var isFullScreen = false` 那一行**下方**加：

```swift
    /// 目前解碼幀的尺寸。`(0, 0)` 代表尚未收到任何幀。
    ///
    /// **為什麼 `AppModel` 需要知道它**：keymap overlay 畫在 Scene 層的 ZStack 上，而
    /// guest 畫面被 `MirrorContainerView` letterbox 進 `ViewportFit.fit(...)` 的內容矩形。
    /// 沒有幀尺寸就算不出那個矩形，標記只能用整個視窗換算——一有黑邊就與真正的觸點錯開。
    /// 資料流是 `Renderer.onFrameSize` → `MirrorView` →（這裡）＋ `MirrorContainerView`，
    /// 同一個回呼餵兩個出口，既有那條不動。
    var frameSize: (w: Int, h: Int) = (0, 0)
```

`MirrorView.swift`，在 `var isEditing: Bool` 下方加屬性：

```swift
    /// Task 4：幀尺寸同時餵給容器（佈局用）與 `AppModel`（overlay 算內容矩形用）。
    let onFrameSize: (Int, Int) -> Void
```

`MirrorView.makeNSView` 裡既有的 `renderer?.onFrameSize` 閉包改成：

```swift
        renderer?.onFrameSize = { [weak container] w, h in
            container?.frameSize = (w: w, h: h)
            onFrameSize(w, h)
        }
```

`MirageScene.swift` 的 `MirrorView(...)` 呼叫加參數：

```swift
                MirrorView(client: model.client, box: model.box,
                           controller: model.keymap, isEditing: model.editing,
                           queue: model.inputQueue,
                           onFrameSize: { w, h in model.frameSize = (w: w, h: h) })
```

- [ ] **Step 4: `KeymapOverlay` 改用內容矩形**

把 `KeymapOverlay.swift` 整個換成：

```swift
import MirageCore
import SwiftUI

/// 非編輯模式：半透明 binding 提示（tap=圓點+鍵標、joystick=圓環、look=不顯示標記）。
/// `allowsHitTesting(false)`——純視覺提示，不可攔截底下 MirrorView 的滑鼠事件。
///
/// **座標基準是 letterbox 後的內容矩形，不是整個視窗**（2026-07-30，階段 B Task 2/4）。
/// 原本用 `GeometryReader` 的整個視窗尺寸換算（`at.x * geo.size.width`），但 guest 畫面被
/// `MirrorContainerView` 依 `ViewportFit.fit(...)` 置中進內容矩形——黑邊不屬於 guest。
/// 視窗模式下 `contentAspectRatio` 把黑邊壓到接近 0 所以看不太出來，**全螢幕時 macOS
/// 忽略那個設定、黑邊是真的**，標記就會整體偏移。
struct KeymapOverlay: View {
    let profile: KeymapProfile?
    /// 目前解碼幀尺寸，用來算內容矩形。`(0, 0)`＝尚未收到幀 → `fit` 回 `.zero` → 不畫。
    let frameSize: (w: Int, h: Int)

    var body: some View {
        GeometryReader { geo in
            let rect = ViewportFit.fit(frame: frameSize,
                                       in: (w: Int(geo.size.width), h: Int(geo.size.height)))
            if let profile, rect.width > 0, rect.height > 0 {
                ForEach(Array(profile.bindings.enumerated()), id: \.offset) { _, b in
                    marker(for: b, in: rect)
                }
            }
        }
        .allowsHitTesting(false)
    }

    // 明確寫模組名：MirageCore.Binding（keymap 綁定列舉）跟 SwiftUI.Binding（雙向繫結）
    // 撞名，兩個 import 同時出現時裸寫 `Binding` 會 ambiguous。
    @ViewBuilder
    private func marker(for b: MirageCore.Binding, in rect: FitRect) -> some View {
        switch b {
        case .tap(let key, let at):
            let p = EditorGeometry.viewPoint(for: at, in: rect)
            Circle().stroke(.white.opacity(0.5)).frame(width: 44, height: 44)
                .position(x: p.x, y: p.y)
                .overlay(
                    Text(label(key)).font(.caption).foregroundStyle(.white)
                        .position(x: p.x, y: p.y)
                )
        case .joystick(_, _, _, _, let center, let radius):
            let p = EditorGeometry.viewPoint(for: center, in: rect)
            let d = EditorGeometry.radiusInPoints(radius, in: rect) * 2
            Circle().stroke(.white.opacity(0.4))
                .frame(width: d, height: d)
                .position(x: p.x, y: p.y)
        case .look:
            // 視角不是螢幕上的一個點——硬畫一個圈只會讓人以為那裡有東西可按。
            // 它只活在編輯器的抽屜清單裡（設計文件 §4.3）。
            EmptyView()
        }
    }

    private func label(_ k: KeyCode) -> String {
        if case .key(let s) = k { return s } else { return "•" }
    }
}
```

`MirageScene.swift` 的 `keymapOverlayLayer` 裡 `KeymapOverlay(profile: model.profile)` 改成：

```swift
            KeymapOverlay(profile: model.profile, frameSize: model.frameSize)
```

- [ ] **Step 5: 跑測試確認全綠**

```bash
cd app && swift test
```

Expected: 全過。`ShellSmokeTests.containerLetterboxesMirrorIntoFitRect` 必須維持綠色
（它驗的是容器佈局，與本改動正交）。

- [ ] **Step 6: Commit**

```bash
git add app/Sources/MirageShell/AppModel.swift \
        app/Sources/MirageShell/MirrorView.swift \
        app/Sources/MirageShell/MirageScene.swift \
        app/Sources/MirageShell/Keymap/KeymapOverlay.swift \
        app/Tests/MirageShellTests/AppModelEditingTests.swift
git commit -m "fix: D5-B overlay 座標改對齊 letterbox 內容矩形，幀尺寸接到 AppModel"
```

---

## Task 5：`AppModel` 持有 `EditorSession` ＋ 底部抽屜

**Files:**
- Modify: `app/Sources/MirageShell/AppModel.swift`（`editorSession` 的生命週期）
- Create: `app/Sources/MirageShell/Keymap/EditorDrawer.swift`
- Modify: `app/Sources/MirageShell/Keymap/OverlayEditorView.swift`（改寫成 overlay ＋ 抽屜的組合）
- Modify: `app/Sources/MirageShell/MirageScene.swift`（接線）
- Test: `app/Tests/MirageShellTests/AppModelEditingTests.swift`

**Interfaces:**
- Consumes: `EditorSession`（Task 3）、`AppModel.frameSize`（Task 4）
- Produces:
  - `AppModel.editorSession: EditorSession?`（編輯中才非 nil）
  - `AppModel.selectBinding(_ id: UUID?)`
  - `AppModel.saveEditorSession()`
  - `EditorDrawer`（SwiftUI view）

**為什麼 session 由 `AppModel` 持有而不是 view 的 `@State`：** 抽屜與 overlay 是**兩個**
view，要共用同一份選取狀態；而且 ⌘E 離開（Task 7 要檢查髒污）發生在 `AppModel` 這一層。
放進 view 的 `@State` 會讓兩邊各持一份，遲早不同步。

**版面決策（設計文件 §3）**：底部抽屜，不是側欄。理由：視窗是 9:20 手機比例，側欄會吃掉
超過一半寬度、鏡像被壓窄後「所見即所得」失真；而且 `.look` 在畫面上**本來就沒有標記**，
純直接操作沒有任何地方碰得到它——抽屜的清單是它唯一的棲身之處。

**階段 B 的抽屜不含**「＋新增」「刪除」「改鍵」——那是階段 C。這個 task 的抽屜只有：
清單（可選取）、選中項的參數區（Task 6 填入滑桿）、存檔、完成 ⌘E。

- [ ] **Step 1: 寫失敗測試**

加到 `AppModelEditingTests` 的 suite 內：

```swift
    /// 進編輯 → 建立 session；離開 → 清掉。session 的內容要對應當下的 profile。
    @Test func editorSessionLifecycleFollowsEditingMode() {
        let (store, dir) = Self.tempStore("session")
        defer { try? FileManager.default.removeItem(at: dir) }
        let starter: [Binding] = [
            .joystick(up: .key("w"), down: .key("s"), left: .key("a"), right: .key("d"),
                      center: NormPoint(x: 0.2, y: 0.75), radius: 0.12),
            .tap(key: .key("j"), at: NormPoint(x: 0.85, y: 0.82)),
        ]
        let model = AppModel(store: store, starterBindings: { starter })
        model.currentPackage = "com.game.session"
        #expect(model.editorSession == nil)

        model.toggleEditing()
        #expect(model.editorSession?.items.map(\.binding) == starter)
        #expect(model.editorSession?.gameId == "com.game.session")
        #expect(model.editorSession?.isDirty == false)

        model.toggleEditing()
        #expect(model.editorSession == nil)          // 離開就收掉，不留殘影
    }

    /// 選取經由 `AppModel` 走，overlay 與抽屜因此看到同一份狀態。
    @Test func selectBindingUpdatesTheSession() {
        let (store, dir) = Self.tempStore("select")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(store: store,
                             starterBindings: { [.tap(key: .key("j"), at: NormPoint(x: 0.8, y: 0.8))] })
        model.currentPackage = "com.game.select"
        model.toggleEditing()
        let id = try! #require(model.editorSession?.items.first?.id)

        model.selectBinding(id)
        #expect(model.editorSession?.selectedID == id)
        #expect(model.editorSession?.isDirty == false)   // 選取不是變更

        model.selectBinding(nil)
        #expect(model.editorSession?.selectedID == nil)
    }

    /// 存檔：寫進注入的 store、version+1、引擎立即套用，且 session 重置為不髒。
    @Test func savingEditorSessionWritesAndReloads() throws {
        let (store, dir) = Self.tempStore("save")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(store: store,
                             starterBindings: { [.tap(key: .key("j"), at: NormPoint(x: 0.8, y: 0.8))] })
        model.currentPackage = "com.game.save"
        model.loadKeymap()
        model.toggleEditing()

        model.saveEditorSession()

        let saved = try store.load(gameId: "com.game.save")
        #expect(saved.gameId == "com.game.save")
        #expect(saved.version == 2)                       // starter 是 version 1
        #expect(model.profile == saved)
        #expect(model.editorSession?.isDirty == false)
        #expect(model.keymap?.hasProfile == true)
    }
```

- [ ] **Step 2: 跑測試確認它紅**

```bash
cd app && swift test --filter "editorSessionLifecycleFollowsEditingMode|selectBindingUpdatesTheSession|savingEditorSessionWritesAndReloads"
```

Expected: 編譯失敗 `value of type 'AppModel' has no member 'editorSession'`。

- [ ] **Step 3: `AppModel` 加 session 生命週期**

在 `var editing = false` 下方加：

```swift
    /// 編輯中的 binding 清單與選取狀態。非編輯時為 nil。
    ///
    /// **由 `AppModel` 持有而不是 view 的 `@State`**：抽屜與 overlay 是兩個 view，要共用
    /// 同一份選取；而且 ⌘E 離開時要檢查未存變更，那件事發生在這一層。放進 view 各持一份
    /// 遲早不同步。
    var editorSession: EditorSession?
```

`toggleEditing()` 的兩個分支各加一行——`.leave` 分支在 `editing = false` **之後**、
`applyActivation()` **之前**：

```swift
        case .leave:
            editing = false
            editorSession = nil        // 離開就收掉，不留殘影
            applyActivation()
```

`.enter` 分支在 `editing = true` 之後：

```swift
        case .enter(let p):
            profile = p
            keymap?.reload(p)
            editing = true
            editorSession = EditorSession(profile: p)
```

在 `saveProfile(_:)` 下方加兩個方法：

```swift
    /// overlay 與抽屜共用的選取入口。兩邊都呼叫這裡，狀態因此只有一份。
    func selectBinding(_ id: UUID?) {
        editorSession = editorSession?.selecting(id)
    }

    /// 抽屜「存檔」呼叫這裡。寫檔 → 引擎立即套用 → session 以存下的那份重建（`isDirty` 歸零）。
    ///
    /// **重建而不是只清旗標**：存完之後的「基準版本」已經變了（version+1），下一次存檔要
    /// 從新的基準再加一。用存下的 profile 重建 session 讓那件事自然成立，不必額外記帳。
    /// 代價是選取會被清掉——可接受，且比一份版本號對不上的 session 安全。
    func saveEditorSession() {
        guard let session = editorSession else { return }
        let p = session.profile()
        saveProfile(p)
        editorSession = EditorSession(profile: p)
    }
```

- [ ] **Step 4: 建立抽屜**

Create `app/Sources/MirageShell/Keymap/EditorDrawer.swift`:

```swift
import MirageCore
import SwiftUI

/// 底部抽屜：binding 清單 ＋ 選中項的參數區 ＋ 存檔。
///
/// **為什麼是底部抽屜不是側欄**（設計文件 §3）：Mirage 的視窗是 9:20 手機比例，側欄會吃掉
/// 超過一半寬度，鏡像被壓窄後拖出來的位置不準——**吃高度比吃寬度便宜**。而且 `.look`
/// 在畫面上沒有任何視覺標記（`KeymapOverlay` 對它畫 `EmptyView`），純直接操作碰不到它，
/// 清單是它唯一的棲身之處。
///
/// 階段 B **不含**「＋新增」「刪除」「改鍵」——那是階段 C。
struct EditorDrawer: View {
    let session: EditorSession
    let onSelect: (UUID?) -> Void
    let onSave: () -> Void
    /// 選中項的參數區。階段 B 由 Task 7 填入半徑／靈敏度滑桿；此刻先留空插槽，
    /// 讓清單與參數區的版面關係在這個 task 就定下來。
    ///
    /// **不加 `@ViewBuilder`**：這個屬性已經明確回傳 `AnyView`，加了只會讓讀的人
    /// 以為可以寫多語句的 view builder，實際上型別擋著。
    let inspector: () -> AnyView

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("BINDING · \(session.items.count)")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("存檔", action: onSave)
                    .disabled(!session.isDirty)
                Text("完成 ⌘E").font(.caption2).foregroundStyle(.secondary)
            }
            Divider()
            ForEach(session.items) { item in
                Button {
                    // 再點一次已選中的項目＝取消選取，讓使用者有辦法回到「沒選任何東西」。
                    onSelect(session.selectedID == item.id ? nil : item.id)
                } label: {
                    HStack {
                        Text(Self.rowLabel(item.binding)).font(.caption)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
                .background(session.selectedID == item.id
                            ? Color.accentColor.opacity(0.25) : Color.clear)
                .cornerRadius(3)
            }
            if session.selectedID != nil {
                Divider()
                inspector()
            }
        }
        .padding(8)
        .background(.black.opacity(0.85))
        .cornerRadius(8)
    }

    /// 清單每一列的文字。`.look` 在畫面上沒有標記，所以這裡是使用者唯一看得到它的地方
    /// ——標籤要說清楚它是什麼，不能只寫「binding 3」。
    static func rowLabel(_ b: MirageCore.Binding) -> String {
        switch b {
        case .joystick(let u, let d, let l, let r, _, _):
            return "◎ 搖桿　\(key(u)) \(key(l)) \(key(d)) \(key(r))"
        case .tap(let k, _):
            return "● 點擊　\(key(k))"
        case .look:
            return "↗ 視角　滑鼠"
        }
    }

    private static func key(_ k: KeyCode) -> String {
        if case .key(let s) = k { return s.uppercased() } else { return "•" }
    }
}
```

- [ ] **Step 5: 改寫 `OverlayEditorView` 並接線**

把 `OverlayEditorView.swift` 整個換成：

```swift
import MirageCore
import SwiftUI

/// 編輯模式的組合層：上半是可互動的 overlay（Task 6 加把手），下半是抽屜。
///
/// 這個型別本身**不持有狀態**——`EditorSession` 由 `AppModel` 持有，因為 overlay 與抽屜
/// 要共用同一份選取，而且 ⌘E 離開時的未存變更檢查發生在 `AppModel` 那一層。
struct OverlayEditorView: View {
    let session: EditorSession
    let frameSize: (w: Int, h: Int)
    let onSelect: (UUID?) -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 階段 B Task 6 會把這裡換成可拖曳的 overlay（Task 7 再填 inspector 內容）；此刻先沿用唯讀標記，
            // 版面與座標基準（letterbox 內容矩形）在 Task 4 就已經正確。
            KeymapOverlay(profile: session.profile(), frameSize: frameSize)
            EditorDrawer(session: session, onSelect: onSelect, onSave: onSave) {
                AnyView(EmptyView())      // Task 7 填入半徑／靈敏度
            }
        }
    }
}
```

`MirageScene.swift` 的 `keymapOverlayLayer` 改成：

```swift
    @MainActor
    @ViewBuilder
    private var keymapOverlayLayer: some View {
        if model.editing, let session = model.editorSession {
            OverlayEditorView(session: session,
                              frameSize: model.frameSize,
                              onSelect: { model.selectBinding($0) },
                              onSave: { model.saveEditorSession() })
        } else if !model.isFullScreen {
            // P1-e 遊戲模式：全螢幕時隱藏唯讀提示標記（純視覺噪音）。ConnectionBanner
            // 與 InstallBanner 刻意保留——前者是必須知道的異常，後者是使用者主動觸發的回饋。
            KeymapOverlay(profile: model.profile, frameSize: model.frameSize)
        }
    }
```

- [ ] **Step 6: 跑測試確認全綠**

```bash
cd app && swift test
```

- [ ] **Step 7: Commit**

```bash
git add app/Sources/MirageShell/AppModel.swift \
        app/Sources/MirageShell/Keymap/EditorDrawer.swift \
        app/Sources/MirageShell/Keymap/OverlayEditorView.swift \
        app/Sources/MirageShell/MirageScene.swift \
        app/Tests/MirageShellTests/AppModelEditingTests.swift
git commit -m "feat: D5-B 底部抽屜與 EditorSession 生命週期，overlay 與清單共用同一份選取"
```

---

## Task 6：拖曳移動 binding

**Files:**
- Modify: `app/Sources/MirageShell/AppModel.swift`（`moveSelectedBinding(to:)`）
- Create: `app/Sources/MirageShell/Keymap/EditorOverlay.swift`
- Modify: `app/Sources/MirageShell/Keymap/OverlayEditorView.swift`（改用 `EditorOverlay`）
- Test: `app/Tests/MirageShellTests/AppModelEditingTests.swift`

**Interfaces:**
- Consumes: `EditorSession.movingSelected(to:)`（Task 3）、
  `EditorGeometry.normPoint(x:y:in:)`／`viewPoint(for:in:)`（Task 2）、
  `AppModel.editorSession`／`frameSize`（Task 4/5）
- Produces: `AppModel.moveSelectedBinding(to: NormPoint)`、`EditorOverlay`（SwiftUI view）

**為什麼另開 `EditorOverlay` 而不是給 `KeymapOverlay` 加旗標：** 唯讀 overlay 的硬性條件是
`allowsHitTesting(false)`（它絕不能攔截底下 `MirrorView` 的滑鼠事件），而編輯 overlay 的
存在理由**正是**要攔截。同一個型別用旗標切換兩種相反的命中測試行為，是把兩件事塞進一個
名字裡——階段 A 的 D22 就是這樣長出來的（`hasProfile` 一個述詞兩種語意）。分開兩個型別。

**編輯時 guest 收不到滑鼠**已由階段 A 保證（`Coordinator.isEditing` 一律不送），
所以這個 overlay 可以放心攔截手勢。

- [ ] **Step 1: 寫失敗測試**

加到 `AppModelEditingTests` 的 suite 內：

```swift
    /// 拖曳落點寫回 session，並**即時套用到引擎**——使用者要看到圈跟著手走。
    @Test func movingSelectedBindingUpdatesSessionAndEngine() throws {
        let (store, dir) = Self.tempStore("move")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(store: store,
                             starterBindings: { [.tap(key: .key("j"), at: NormPoint(x: 0.8, y: 0.8))] })
        model.currentPackage = "com.game.move"
        model.loadKeymap()
        model.toggleEditing()
        let id = try #require(model.editorSession?.items.first?.id)
        model.selectBinding(id)

        model.moveSelectedBinding(to: NormPoint(x: 0.25, y: 0.4))

        if case .tap(_, let at) = try #require(model.editorSession?.items.first?.binding) {
            #expect(at == NormPoint(x: 0.25, y: 0.4))
        } else {
            Issue.record("期待 .tap")
        }
        #expect(model.editorSession?.isDirty == true)
        // 即時套用：`profile` 與引擎都要看到新位置，否則離開編輯後才會突然跳位。
        if case .tap(_, let at) = try #require(model.profile?.bindings.first) {
            #expect(at == NormPoint(x: 0.25, y: 0.4))
        } else {
            Issue.record("期待 .tap")
        }
    }

    /// 沒有選取時拖曳是 no-op，不得憑空改到別的 binding。
    @Test func movingWithoutSelectionChangesNothing() throws {
        let (store, dir) = Self.tempStore("move-none")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(store: store,
                             starterBindings: { [.tap(key: .key("j"), at: NormPoint(x: 0.8, y: 0.8))] })
        model.currentPackage = "com.game.move.none"
        model.toggleEditing()
        let before = try #require(model.editorSession)

        model.moveSelectedBinding(to: NormPoint(x: 0.1, y: 0.1))

        #expect(model.editorSession == before)
        #expect(model.editorSession?.isDirty == false)
    }
```

- [ ] **Step 2: 跑測試確認它紅**

```bash
cd app && swift test --filter "movingSelectedBindingUpdatesSessionAndEngine|movingWithoutSelectionChangesNothing"
```

Expected: 編譯失敗 `value of type 'AppModel' has no member 'moveSelectedBinding'`。

- [ ] **Step 3: `AppModel` 加移動入口**

在 `selectBinding(_:)` 下方加：

```swift
    /// 拖曳落點寫回 session 並**即時套用**到 `profile` 與引擎。
    ///
    /// 即時套用是設計文件定的存檔語意的前半（「即時套用＋明確存檔」）：畫面上的圈要跟著
    /// 手走，否則使用者要等到存檔才看得到結果。`emit` 在編輯模式下本來就被擋，所以套用到
    /// 引擎不會有任何東西送到 guest。
    func moveSelectedBinding(to p: NormPoint) {
        applyToSession { $0.movingSelected(to: p) }
    }

    /// session 變換 → 同步 `profile` 與引擎。三個編輯入口（移動／半徑／靈敏度）共用它，
    /// 免得「改完忘了套用」在三個地方各犯一次。
    private func applyToSession(_ transform: (EditorSession) -> EditorSession) {
        guard let session = editorSession else { return }
        let updated = transform(session)
        guard updated != session else { return }
        editorSession = updated
        let p = updated.profile()
        profile = p
        keymap?.reload(p)
    }
```

> 註：`applyToSession` 產生的 `profile` 的 `version` 已經是 `baseVersion + 1`——那是給
> 存檔用的值，在記憶體階段無害（沒有人比對它），且讓「存檔」與「即時套用」用同一條路徑，
> 不必為記憶體版本另外算一次。

- [ ] **Step 4: 建立可拖曳的 overlay**

Create `app/Sources/MirageShell/Keymap/EditorOverlay.swift`:

```swift
import MirageCore
import SwiftUI

/// 編輯模式的 overlay：可點選、可拖曳。
///
/// **為什麼與 `KeymapOverlay` 分成兩個型別**：唯讀 overlay 的硬性條件是
/// `allowsHitTesting(false)`——它絕不能攔截底下 `MirrorView` 的滑鼠事件；而這個 overlay
/// 的存在理由**正是**要攔截。用一個旗標讓同一個型別切換兩種相反的命中測試行為，就是把
/// 兩件事塞進一個名字裡，而階段 A 的 D22 正是那樣長出來的（`hasProfile` 一個述詞兩種語意）。
///
/// 編輯時 guest 收不到滑鼠已由階段 A 保證（`MirrorView.Coordinator.isEditing` 一律不送），
/// 所以這裡可以放心吃掉手勢。
struct EditorOverlay: View {
    let session: EditorSession
    let frameSize: (w: Int, h: Int)
    let onSelect: (UUID?) -> Void
    let onMove: (NormPoint) -> Void

    var body: some View {
        GeometryReader { geo in
            let rect = ViewportFit.fit(frame: frameSize,
                                       in: (w: Int(geo.size.width), h: Int(geo.size.height)))
            if rect.width > 0, rect.height > 0 {
                ForEach(session.items) { item in
                    marker(for: item, in: rect)
                }
            }
        }
    }

    @ViewBuilder
    private func marker(for item: EditorSession.Item, in rect: FitRect) -> some View {
        let selected = session.selectedID == item.id
        switch item.binding {
        case .tap(let key, let at):
            let p = EditorGeometry.viewPoint(for: at, in: rect)
            Circle()
                .stroke(selected ? Color.accentColor : .white.opacity(0.5), lineWidth: selected ? 2 : 1)
                .frame(width: 44, height: 44)
                .overlay(Text(Self.label(key)).font(.caption).foregroundStyle(.white))
                .position(x: p.x, y: p.y)
                .opacity(selected ? 1 : 0.6)
                .gesture(dragGesture(item: item, rect: rect))

        case .joystick(_, _, _, _, let center, let radius):
            let p = EditorGeometry.viewPoint(for: center, in: rect)
            let d = EditorGeometry.radiusInPoints(radius, in: rect) * 2
            Circle()
                .stroke(selected ? Color.accentColor : .white.opacity(0.4), lineWidth: selected ? 2 : 1)
                .frame(width: d, height: d)
                .contentShape(Circle())
                .position(x: p.x, y: p.y)
                .opacity(selected ? 1 : 0.6)
                .gesture(dragGesture(item: item, rect: rect))

        case .look:
            // 視角不是螢幕上的一個點——它只活在抽屜清單裡（設計文件 §4.3）。
            EmptyView()
        }
    }

    /// 點一下＝選取；拖曳＝選取並移動。用同一個 `DragGesture(minimumDistance: 0)` 兼顧兩者，
    /// 不必再疊一個 `TapGesture` 去跟它搶手勢。
    private func dragGesture(item: EditorSession.Item, rect: FitRect) -> some Gesture {
        // **必須用具名座標空間**：手勢掛在經過 `.position()` 的標記上，`.local` 回報的是
        // 標記自己那 44×44 的框，不是 `GeometryReader` 的空間——而 `EditorGeometry.normPoint`
        // 期待的是與 `rect` 同一個空間。用 `.local` 會讓「點一下」就把標記彈到內容矩形左上角
        // （`minimumDistance: 0` 讓 onChanged 在按下瞬間就觸發，此時還沒有任何移動）。
        // GeometryReader 那側要配 `.coordinateSpace(name: "editorOverlay")`。
        DragGesture(minimumDistance: 0, coordinateSpace: .named("editorOverlay"))
            .onChanged { value in
                if session.selectedID != item.id { onSelect(item.id) }
                if let p = EditorGeometry.normPoint(x: value.location.x, y: value.location.y, in: rect) {
                    onMove(p)
                }
            }
    }

    private static func label(_ k: KeyCode) -> String {
        if case .key(let s) = k { return s } else { return "•" }
    }
}
```

- [ ] **Step 5: `OverlayEditorView` 改用它**

把 `OverlayEditorView` 的 `KeymapOverlay(...)` 那一行換成：

```swift
            EditorOverlay(session: session, frameSize: frameSize,
                          onSelect: onSelect, onMove: onMove)
```

並在 `OverlayEditorView` 加對應屬性 `let onMove: (NormPoint) -> Void`，
`MirageScene` 的呼叫加上 `onMove: { model.moveSelectedBinding(to: $0) }`。

- [ ] **Step 6: 跑測試確認全綠**

```bash
cd app && swift test
```

- [ ] **Step 7: Commit**

```bash
git add app/Sources/MirageShell/AppModel.swift \
        app/Sources/MirageShell/Keymap/EditorOverlay.swift \
        app/Sources/MirageShell/Keymap/OverlayEditorView.swift \
        app/Sources/MirageShell/MirageScene.swift \
        app/Tests/MirageShellTests/AppModelEditingTests.swift
git commit -m "feat: D5-B 可拖曳的編輯 overlay，落點即時套用到引擎"
```

---

## Task 7：半徑與靈敏度

**Files:**
- Modify: `app/Sources/MirageShell/AppModel.swift`（兩個入口）
- Create: `app/Sources/MirageShell/Keymap/EditorInspector.swift`
- Modify: `app/Sources/MirageShell/Keymap/OverlayEditorView.swift`（填入 inspector 插槽）
- Modify: `app/Sources/MirageShell/Keymap/EditorOverlay.swift`（搖桿加半徑把手）
- Modify: `app/Sources/MirageShell/MirageScene.swift`（接線）
- Test: `app/Tests/MirageShellTests/AppModelEditingTests.swift`

**Interfaces:**
- Consumes: `EditorSession.settingSelectedRadius(_:)`／`settingSelectedSensitivity(_:)`（Task 3）、
  `EditorGeometry.radius(fromPoints:in:)`（Task 2）、`AppModel.applyToSession`（Task 6，private）
- Produces: `AppModel.setSelectedRadius(_ r: Double)`、`AppModel.setSelectedSensitivity(_ s: Double)`、
  `EditorInspector`（SwiftUI view）

**設計文件 §4.3 的取捨：半徑有兩種改法**——畫面上拖橘方塊、抽屜裡拉滑桿——**改的是同一個值**，
不是兩套設定。直接操作快但不精確，滑桿精確但慢。實作上兩者都走
`AppModel.setSelectedRadius`，不會有兩條路徑各自為政。

**夾取範圍：** 半徑下限 `0.02`（再小畫面上點不到）、上限 `0.5`（正規化基準是寬度，
超過 0.5 圓就一定超出畫面）。靈敏度下限 `0.1`、上限 `5.0`。這些是 UI 層的滑桿範圍，
**不是**新的 schema 約束——`validated()` 只要求 `radius > 0`、`sensitivity > 0`，
既有 profile 若落在範圍外仍然合法可載入（Never break userspace）。

- [ ] **Step 1: 寫失敗測試**

加到 `AppModelEditingTests` 的 suite 內：

```swift
    /// 半徑寫回 session 並即時套用；作用在非搖桿上是 no-op。
    @Test func settingRadiusUpdatesJoystickOnly() throws {
        let (store, dir) = Self.tempStore("radius")
        defer { try? FileManager.default.removeItem(at: dir) }
        let starter: [Binding] = [
            .joystick(up: .key("w"), down: .key("s"), left: .key("a"), right: .key("d"),
                      center: NormPoint(x: 0.2, y: 0.75), radius: 0.12),
            .tap(key: .key("j"), at: NormPoint(x: 0.85, y: 0.82)),
        ]
        let model = AppModel(store: store, starterBindings: { starter })
        model.currentPackage = "com.game.radius"
        model.loadKeymap()
        model.toggleEditing()
        let stickID = try #require(model.editorSession?.items.first?.id)
        let tapID = try #require(model.editorSession?.items.last?.id)

        model.selectBinding(stickID)
        model.setSelectedRadius(0.25)
        if case .joystick(_, _, _, _, _, let r) = try #require(model.editorSession?.items.first?.binding) {
            #expect(r == 0.25)
        } else { Issue.record("期待 .joystick") }
        #expect(model.editorSession?.isDirty == true)
        // 即時套用：引擎那份也要跟上
        if case .joystick(_, _, _, _, _, let r) = try #require(model.profile?.bindings.first) {
            #expect(r == 0.25)
        } else { Issue.record("期待 .joystick") }

        // 選到 tap 再調半徑：不得改到任何東西
        let snapshot = try #require(model.editorSession)
        model.selectBinding(tapID)
        model.setSelectedRadius(0.4)
        #expect(model.editorSession?.items == snapshot.items)
    }

    /// 靈敏度寫回 session 並即時套用；作用在非 look 上是 no-op。
    @Test func settingSensitivityUpdatesLookOnly() throws {
        let (store, dir) = Self.tempStore("sens")
        defer { try? FileManager.default.removeItem(at: dir) }
        let starter: [Binding] = [
            .tap(key: .key("j"), at: NormPoint(x: 0.85, y: 0.82)),
            .look(activation: nil, sensitivity: 1.5),
        ]
        let model = AppModel(store: store, starterBindings: { starter })
        model.currentPackage = "com.game.sens"
        model.loadKeymap()
        model.toggleEditing()
        let tapID = try #require(model.editorSession?.items.first?.id)
        let lookID = try #require(model.editorSession?.items.last?.id)

        model.selectBinding(lookID)
        model.setSelectedSensitivity(3.0)
        if case .look(_, let s) = try #require(model.editorSession?.items.last?.binding) {
            #expect(s == 3.0)
        } else { Issue.record("期待 .look") }
        #expect(model.profile?.bindings.last == .look(activation: nil, sensitivity: 3.0))

        let snapshot = try #require(model.editorSession)
        model.selectBinding(tapID)
        model.setSelectedSensitivity(4.0)
        #expect(model.editorSession?.items == snapshot.items)
    }
```

- [ ] **Step 2: 跑測試確認它紅**

```bash
cd app && swift test --filter "settingRadiusUpdatesJoystickOnly|settingSensitivityUpdatesLookOnly"
```

Expected: 編譯失敗 `value of type 'AppModel' has no member 'setSelectedRadius'`。

- [ ] **Step 3: `AppModel` 加兩個入口**

在 `moveSelectedBinding(to:)` 下方加：

```swift
    /// 搖桿半徑。畫面上的橘方塊與抽屜的滑桿都走這裡——**同一個值，不是兩套設定**
    /// （設計文件 §4.3）。
    func setSelectedRadius(_ r: Double) {
        applyToSession { $0.settingSelectedRadius(r) }
    }

    /// 視角靈敏度。`.look` 在畫面上沒有標記，所以它只有抽屜這一個入口。
    func setSelectedSensitivity(_ s: Double) {
        applyToSession { $0.settingSelectedSensitivity(s) }
    }
```

- [ ] **Step 4: 建立 inspector**

Create `app/Sources/MirageShell/Keymap/EditorInspector.swift`:

```swift
import MirageCore
import SwiftUI

/// 抽屜下半的參數區：依選中的 binding 型別顯示對應滑桿。
///
/// 階段 B 只有半徑與靈敏度；改鍵與刪除是階段 C。選中的是 tap 時沒有可調參數，
/// 顯示一行說明而不是留白——留白會讓人以為壞掉了。
struct EditorInspector: View {
    let binding: MirageCore.Binding
    let onRadius: (Double) -> Void
    let onSensitivity: (Double) -> Void

    /// 滑桿範圍是 **UI 層的取捨，不是 schema 約束**：`validated()` 只要求
    /// `radius > 0`／`sensitivity > 0`，既有 profile 落在範圍外仍然合法可載入
    /// （Never break userspace）。下限 0.02 是「再小就點不到」，上限 0.5 是
    /// 「正規化基準是寬度，超過就一定出畫面」。
    private static let radiusRange: ClosedRange<Double> = 0.02...0.5
    private static let sensitivityRange: ClosedRange<Double> = 0.1...5.0

    var body: some View {
        switch binding {
        case .joystick(_, _, _, _, _, let radius):
            HStack {
                Text("半徑").font(.caption2).foregroundStyle(.secondary)
                Slider(value: Binding(get: { radius }, set: onRadius),
                       in: Self.radiusRange)
                Text(String(format: "%.2f", radius))
                    .font(.caption2).monospacedDigit().frame(width: 34, alignment: .trailing)
            }
        case .look(_, let sensitivity):
            HStack {
                Text("靈敏度").font(.caption2).foregroundStyle(.secondary)
                Slider(value: Binding(get: { sensitivity }, set: onSensitivity),
                       in: Self.sensitivityRange)
                Text(String(format: "%.1f", sensitivity))
                    .font(.caption2).monospacedDigit().frame(width: 34, alignment: .trailing)
            }
        case .tap:
            Text("點擊鍵只有位置可調——直接在畫面上拖它。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 5: 接進抽屜，並給搖桿加半徑把手**

`OverlayEditorView` 的 `EditorDrawer` 插槽改成：

```swift
            EditorDrawer(session: session, onSelect: onSelect, onSave: onSave) {
                if let id = session.selectedID,
                   let item = session.items.first(where: { $0.id == id }) {
                    AnyView(EditorInspector(binding: item.binding,
                                            onRadius: onRadius,
                                            onSensitivity: onSensitivity))
                } else {
                    AnyView(EmptyView())
                }
            }
```

`OverlayEditorView` 加兩個屬性 `let onRadius: (Double) -> Void`、
`let onSensitivity: (Double) -> Void`，`MirageScene` 接上
`onRadius: { model.setSelectedRadius($0) }`、`onSensitivity: { model.setSelectedSensitivity($0) }`。

`EditorOverlay` 的 `.joystick` 分支，在圓之後疊一個把手（只在選中時顯示）：

```swift
            if selected {
                // 橘方塊：拖它改半徑。放在圓的右緣——半徑就是圓心到它的水平距離，
                // 所見即所得，不必解釋。
                let handleX = p.x + EditorGeometry.radiusInPoints(radius, in: rect)
                Rectangle()
                    .fill(Color.orange)
                    .frame(width: 11, height: 11)
                    .position(x: handleX, y: p.y)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .local)
                            .onChanged { value in
                                let d = value.location.x - p.x
                                // **必須夾，而且下限不能是 0**：`radius(fromPoints: 0)` 回的是
                                // `0.0` 不是 nil，而 `radius: 0` 會通過 save（`ProfileStore.save`
                                // 不驗證）卻在下次 `load` 的 `validated()` 被拒——那個錯誤又被
                                // `applyActivation` 的 `try?` 吞掉，使用者只看到「keymap 就是不生效」，
                                // 而壞檔永久留在磁碟上、沒有 UI 路徑回得去。與滑桿共用同一組界線常數。
                                if let r = EditorGeometry.radius(fromPoints: max(d, 0), in: rect) {
                                    onRadius(min(max(r, radiusFloor), radiusCeiling))
                                }
                            }
                    )
            }
```

`EditorOverlay` 加屬性 `let onRadius: (Double) -> Void`，並由 `OverlayEditorView` 傳入。

- [ ] **Step 6: 跑測試確認全綠**

```bash
cd app && swift test
```

- [ ] **Step 7: Commit**

```bash
git add app/Sources/MirageShell/AppModel.swift \
        app/Sources/MirageShell/Keymap/EditorInspector.swift \
        app/Sources/MirageShell/Keymap/EditorOverlay.swift \
        app/Sources/MirageShell/Keymap/OverlayEditorView.swift \
        app/Sources/MirageShell/MirageScene.swift \
        app/Tests/MirageShellTests/AppModelEditingTests.swift
git commit -m "feat: D5-B 半徑與靈敏度——橘方塊與滑桿改同一個值"
```

---

## Task 8：未存變更與離開提示

**Files:**
- Modify: `app/Sources/MirageShell/AppModel.swift`（`toggleEditing` 加髒污攔截 ＋ 三個出口）
- Modify: `app/Sources/MirageShell/MirageScene.swift`（`.alert`）
- Test: `app/Tests/MirageShellTests/AppModelEditingTests.swift`

**Interfaces:**
- Consumes: `EditorSession.isDirty`（Task 3）、`AppModel.saveEditorSession()`（Task 5）
- Produces:
  - `AppModel.pendingLeaveConfirmation: Bool`
  - `AppModel.confirmLeaveSaving()` / `confirmLeaveDiscarding()` / `cancelLeave()`

**這個 task 是階段 B 的必要條件，不是加分項。** 階段 A 的 `.leave` 會呼叫
`applyActivation()`——從磁碟重新取真相，也就是**丟掉記憶體裡的 profile**。階段 A 那是
**對的**（使用者還不能改任何東西，沒東西可丟）；階段 B 一旦拖曳上線，同一行程式碼就變成
「按 ⌘E ＝靜默丟掉剛才調的所有東西」。設計文件把存檔語意定為「即時套用＋明確存檔」，
離開時的提示是那個語意的另一半，缺了它前半就會咬人。

**三個出口刻意都收在 `AppModel`**：Scene 的 `.alert` 只負責呈現與呼叫，不持有任何決策。

- [ ] **Step 1: 寫失敗測試**

加到 `AppModelEditingTests` 的 suite 內：

```swift
    /// 沒有未存變更時，⌘E 直接離開——不要為了「一致」而多跳一個沒必要的對話框。
    @Test func leavingCleanSessionDoesNotPrompt() throws {
        let (store, dir) = Self.tempStore("clean-leave")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(store: store,
                             starterBindings: { [.tap(key: .key("j"), at: NormPoint(x: 0.8, y: 0.8))] })
        model.currentPackage = "com.game.clean"
        model.toggleEditing()

        model.toggleEditing()

        #expect(!model.pendingLeaveConfirmation)
        #expect(!model.editing)
        #expect(model.editorSession == nil)
    }

    /// 有未存變更時，⌘E **不得**離開——先問。這是資料遺失的唯一防線。
    @Test func leavingDirtySessionPromptsInsteadOfDiscarding() throws {
        let (store, dir) = Self.tempStore("dirty-leave")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(store: store,
                             starterBindings: { [.tap(key: .key("j"), at: NormPoint(x: 0.8, y: 0.8))] })
        model.currentPackage = "com.game.dirty"
        model.loadKeymap()
        model.toggleEditing()
        let id = try #require(model.editorSession?.items.first?.id)
        model.selectBinding(id)
        model.moveSelectedBinding(to: NormPoint(x: 0.2, y: 0.2))

        model.toggleEditing()

        #expect(model.pendingLeaveConfirmation)
        #expect(model.editing)                        // **還在編輯模式**
        #expect(model.editorSession?.isDirty == true) // 變更還在
    }

    /// 「存檔」：寫檔、離開、清提示。
    @Test func confirmLeaveSavingWritesThenLeaves() throws {
        let (store, dir) = Self.tempStore("leave-save")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(store: store,
                             starterBindings: { [.tap(key: .key("j"), at: NormPoint(x: 0.8, y: 0.8))] })
        model.currentPackage = "com.game.leavesave"
        model.loadKeymap()
        model.toggleEditing()
        let id = try #require(model.editorSession?.items.first?.id)
        model.selectBinding(id)
        model.moveSelectedBinding(to: NormPoint(x: 0.2, y: 0.2))
        model.toggleEditing()

        model.confirmLeaveSaving()

        #expect(!model.pendingLeaveConfirmation)
        #expect(!model.editing)
        #expect(model.editorSession == nil)
        let saved = try store.load(gameId: "com.game.leavesave")
        if case .tap(_, let at) = try #require(saved.bindings.first) {
            #expect(at == NormPoint(x: 0.2, y: 0.2))
        } else { Issue.record("期待 .tap") }
        #expect(model.profile == saved)               // 存完之後生效的是存下的那份
    }

    /// 「捨棄」：不寫檔、離開、磁碟保持空的。
    @Test func confirmLeaveDiscardingWritesNothing() throws {
        let (store, dir) = Self.tempStore("leave-discard")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(store: store,
                             starterBindings: { [.tap(key: .key("j"), at: NormPoint(x: 0.8, y: 0.8))] })
        model.currentPackage = "com.game.discard"
        model.loadKeymap()
        model.toggleEditing()
        let id = try #require(model.editorSession?.items.first?.id)
        model.selectBinding(id)
        model.moveSelectedBinding(to: NormPoint(x: 0.2, y: 0.2))
        model.toggleEditing()

        // 先確認攔截真的發生了——否則下面的「目錄是空的」會因為「根本沒進編輯模式」而通過，
        // 那是綠得毫無意義（「捨棄」本來就不寫檔，所以目錄為空無法區分兩種情況）。
        #expect(model.pendingLeaveConfirmation)
        #expect(model.editorSession?.isDirty == true)

        model.confirmLeaveDiscarding()

        #expect(!model.pendingLeaveConfirmation)
        #expect(!model.editing)
        #expect(model.editorSession == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        #expect(model.profile == nil)                 // 回到磁碟的真相＝沒有 profile
        #expect(model.keymap?.hasProfile == false)    // 引擎也要清掉（C1 那條回歸）
    }

    /// 「繼續編輯」：留在編輯模式，變更原封不動。
    @Test func cancelLeaveKeepsEditingAndChanges() throws {
        let (store, dir) = Self.tempStore("leave-cancel")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(store: store,
                             starterBindings: { [.tap(key: .key("j"), at: NormPoint(x: 0.8, y: 0.8))] })
        model.currentPackage = "com.game.cancel"
        model.loadKeymap()
        model.toggleEditing()
        let id = try #require(model.editorSession?.items.first?.id)
        model.selectBinding(id)
        model.moveSelectedBinding(to: NormPoint(x: 0.2, y: 0.2))
        model.toggleEditing()

        model.cancelLeave()

        #expect(!model.pendingLeaveConfirmation)
        #expect(model.editing)
        #expect(model.editorSession?.isDirty == true)
        if case .tap(_, let at) = try #require(model.editorSession?.items.first?.binding) {
            #expect(at == NormPoint(x: 0.2, y: 0.2))
        } else { Issue.record("期待 .tap") }
    }
```

- [ ] **Step 2: 跑測試確認它紅**

```bash
cd app && swift test --filter "leavingDirtySessionPromptsInsteadOfDiscarding|confirmLeaveSavingWritesThenLeaves"
```

Expected: 編譯失敗 `value of type 'AppModel' has no member 'pendingLeaveConfirmation'`。

- [ ] **Step 3: 實作**

`AppModel` 在 `var editorSession: EditorSession?` 下方加：

```swift
    /// 有未存變更卻按了 ⌘E——Scene 據此跳「存檔／捨棄／繼續編輯」。
    ///
    /// **為什麼需要它**：`.leave` 會呼叫 `applyActivation()` 從磁碟重新取真相，也就是
    /// 丟掉記憶體裡的 profile。階段 A 那是對的（使用者還不能改任何東西）；階段 B 拖曳
    /// 上線之後，同一行就變成「按 ⌘E ＝靜默丟掉剛才調的所有東西」。
    var pendingLeaveConfirmation = false
```

`toggleEditing()` 的 `.leave` 分支改成：

```swift
        case .leave:
            // 有未存變更就先問，**不要**先離開再問——離開的動作本身就把變更丟了。
            if editorSession?.isDirty == true {
                pendingLeaveConfirmation = true
                return
            }
            leaveEditing()
            return          // ← 必須 return：`leaveEditing()` 自己已經呼叫過
                            //   `setEditing` 與 `updateCapture`，落到 switch 尾端
                            //   會重複呼叫一次。兩者雖然冪等，但重複呼叫代表
                            //   「誰負責這件事」沒有單一答案，下一個人會改錯地方。
```

在 `saveEditorSession()` 下方加：

```swift
    /// 離開編輯的唯一實作。三個出口與「沒有未存變更」那條路徑共用它。
    private func leaveEditing() {
        editing = false
        editorSession = nil
        // 離開編輯＝回到磁碟的真相（見 `toggleEditing` 的說明）。
        applyActivation()
        keymap?.setEditing(false)
        mouseCapture.updateCapture(shouldCapture: shouldCapture)
    }

    /// 提示的「存檔」：寫檔之後才離開。
    func confirmLeaveSaving() {
        pendingLeaveConfirmation = false
        saveEditorSession()
        leaveEditing()
    }

    /// 提示的「捨棄」：不寫檔直接離開。`leaveEditing()` 的 `applyActivation()` 會把
    /// 記憶體那份收掉、引擎清掉、游標放開——與 C1 修好的那條路徑同一條，不另開特例。
    func confirmLeaveDiscarding() {
        pendingLeaveConfirmation = false
        leaveEditing()
    }

    /// 提示的「繼續編輯」：什麼都不做，留在編輯模式。
    func cancelLeave() {
        pendingLeaveConfirmation = false
    }
```

> **注意**：`toggleEditing()` 尾端原本無條件執行的 `keymap?.setEditing(editing)` 與
> `mouseCapture.updateCapture(...)` 現在對 `.leave` 走的是 `leaveEditing()` 裡那份。
> 請確認 `.enter` 與 `.ignore` 兩條路徑的行為沒有因為這次重構而改變——`.ignore` 仍要
> 直接 return、不碰那兩行。

- [ ] **Step 4: Scene 接上 `.alert`**

`MirageScene.swift` 的 `ZStack` 之後（`.frame(minWidth:minHeight:)` 之前）加：

```swift
            .alert("有未存的鍵位變更", isPresented: Binding(
                get: { model.pendingLeaveConfirmation },
                set: { if !$0 { model.cancelLeave() } }
            )) {
                Button("存檔") { model.confirmLeaveSaving() }
                Button("捨棄", role: .destructive) { model.confirmLeaveDiscarding() }
                Button("繼續編輯", role: .cancel) { model.cancelLeave() }
            } message: {
                Text("離開編輯模式會丟掉這些變更。")
            }
```

- [ ] **Step 5: 跑測試確認全綠**

```bash
cd app && swift test
```

- [ ] **Step 6: 跑閘門**

```bash
cd app && ./scripts/ci.sh; echo "CI_EXIT=$?"
```

Expected: `CI_EXIT=0`，四道閘門全綠。

- [ ] **Step 7: Commit**

```bash
git add app/Sources/MirageShell/AppModel.swift \
        app/Sources/MirageShell/MirageScene.swift \
        app/Tests/MirageShellTests/AppModelEditingTests.swift
git commit -m "feat: D5-B 未存變更的離開提示——存檔／捨棄／繼續編輯"
```

---

## 手動驗收（需模擬器，全部 task 完成後執行）

```bash
"$HOME/Library/Android/sdk/emulator/emulator" -avd mirage-poc -no-window -grpc 8554 &
"$HOME/Library/Android/sdk/platform-tools/adb" -s emulator-5554 wait-for-device
cd app && APP=$(./scripts/package_app.sh /tmp/mirage_d5b 2>/dev/null) && "$APP/Contents/MacOS/MirageApp"
```

在模擬器上開任一 App，然後：

1. ⌘E → 看得到 starter 標記與底部抽屜。
2. 點畫面上的圈 → 清單對應那列高亮；點清單 → 畫面上的圈高亮。**雙向同步。**
3. 拖圈 → 位置跟著走。拖橘方塊 → 半徑跟著變，抽屜滑桿的數字同步。
4. **⌃⌘F 進全螢幕**（會出現黑邊）→ 標記與把手仍與 guest 畫面對齊（Task 2/4 的驗收線）。
5. 改一點東西 → ⌘E → 跳「存檔／捨棄／繼續編輯」；三個都各試一次。
6. 選「捨棄」之後檢查 `~/Library/Application Support/Mirage/profiles/` → 不得出現該 package 的 json。
7. 編輯模式下在鏡像上點幾下 → guest **不得**有反應（階段 A 的 D22 回歸）。

---

## 驗收條件（階段 B）

1. 拖曳搖桿圓心與技能鍵可改變位置，即時反映在 overlay。
2. 橘方塊可改變搖桿半徑；抽屜的滑桿改同一個值。
3. 視角靈敏度可在抽屜調整。
4. **全螢幕（有黑邊）時標記與把手仍與 guest 畫面對齊**——這是 Task 2 的驗收線。
5. 按「存檔」後以當前 gameId 寫入、version+1、引擎立即套用。
6. 有未存變更時按 ⌘E 跳「存檔／捨棄／繼續編輯」。
7. 編輯模式下滑鼠仍不會傳到 guest（階段 A 的 D22 回歸哨兵維持綠）。
8. `./scripts/ci.sh` 四道閘門全綠。
