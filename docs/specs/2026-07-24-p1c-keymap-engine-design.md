# P1-c 鍵位映射引擎 — 設計文件

- **日期**：2026-07-24
- **狀態**：已核准（brainstorming 流程）
- **上游文件**：`2026-07-22-mirage-project-plan.md` §6；建於已合併的 P1-a（`app/` MirageCore + MirageApp）
- **並行對象**：P1-b（生命週期，`2026-07-24-p1b-lifecycle-design.md`）——合併順序 **P1-b 先、P1-c 隨後整合**。

## 1. 目標

把 P1-a 的「滑鼠即觸控」升級為**遊戲鍵位映射**：鍵盤/滑鼠事件經每遊戲 profile
轉譯成**多點觸控**注入，支援 tap（技能鍵）、joystick（WASD 移動）、look（滑鼠自由視角），
並提供陽春 overlay 編輯器讓玩家自訂。這是遊戲模擬器的命根子（專案 spec §6）。

**非目標（YAGNI）**：手把支援（P2）、profile 社群分享（P2）、連招/巨集（P2）、
IME 文字輸入（走 P1-b 剪貼簿橋，不在本件）、gamepad 震動。

## 2. 背景約束

- 建於 P1-a：`EmulatorClient`（actor）目前只有 `sendTap(x:y:down:)`（單指 identifier 0）。
  本件需擴充 `sendTouches`（多指）與 `sendKey`（硬體鍵）。
- P1-a 的輸入路徑：`MirrorView.Coordinator.sendMouse(nx:ny:down:)` → `client.sendTap`，
  座標用 `renderer.lastFrameSize`（實際幀尺寸，P1-a Task 6 CRITICAL 修正）。本件保留此
  正規化→實際尺寸換算，只是把「送什麼」換成鍵位映射結果。
- emulator TouchEvent 支援多點：`repeated Touch touches`，每 Touch 有 `identifier`。
  多指同時（移動+技能）靠不同 identifier。sendKey 用 `KeyboardEvent`（Generated stub 已有）。
- 併發：`-strict-concurrency=complete`；MirageCore 不 import AppKit/SwiftUI/Metal。
- 開發環境無 Xcode：測試用 swift-testing（`cd app && swift test`）。

## 3. 專案結構

```
app/Sources/MirageCore/Keymap/
├── KeyCode.swift             # macOS 虛擬鍵碼的薄封裝（Sendable enum/struct）
├── NormPoint.swift           # 正規化座標值型別 + 驗證（0–1）
├── KeymapProfile.swift       # Profile/Binding 值型別 + JSON Codable + schema 驗證
├── KeymapEngine.swift        # 純邏輯：事件+狀態 → TouchFrame（多指快照）
├── JoystickMath.swift        # 方向鍵集合 → 正規化向量（純函式，重測）
└── ProfileStore.swift        # 載入/儲存 profile（檔案 I/O，邊界驗證）
app/Sources/MirageCore/
└── EmulatorClient.swift      # 擴充：sendTouches([TouchSpec])、sendKey(code:down:)
app/Sources/MirageApp/Keymap/
├── KeymapController.swift     # 橋接 NSEvent → KeymapEngine → EmulatorClient（@MainActor）
├── MouseCapture.swift         # look 模式的滑鼠捕捉（CGAssociateMouseAndMouseCursorPosition）
├── OverlayEditorView.swift    # 陽春編輯器：拖放 binding、選鍵、存檔
└── KeymapOverlay.swift        # 非編輯模式下的 binding 視覺提示（半透明）
app/Sources/MirageApp/
├── MirrorView.swift           # 修改：輸入事件改走 KeymapController（無 profile 退回直接 tap）
└── MirageApp.swift            # 修改：注入 KeymapController、編輯模式切換（⌘E）
app/Tests/MirageCoreTests/
├── JoystickMathTests.swift
├── KeymapProfileTests.swift   # JSON round-trip + 驗證
├── KeymapEngineTests.swift    # tap/joystick/look 生命週期 + 多指 identifier
└── ProfileStoreTests.swift
```

檔案紀律：每檔 <400 行；引擎純函式與 UI 膠水嚴格分離。

## 4. 核心設計

### 4.1 資料模型（不可變）

```swift
struct NormPoint: Sendable, Codable, Equatable { let x: Double; let y: Double }  // 0–1，越界拒絕
enum KeyCode: Sendable, Codable, Equatable { /* macOS 虛擬鍵碼 + 滑鼠鍵 */ }

enum Binding: Sendable, Codable, Equatable {
    case tap(key: KeyCode, at: NormPoint)
    case joystick(up: KeyCode, down: KeyCode, left: KeyCode, right: KeyCode,
                  center: NormPoint, radius: Double)          // radius 為正規化半徑
    case look(activation: KeyCode?, sensitivity: Double)      // activation=nil 表always-on
}

struct KeymapProfile: Sendable, Codable, Equatable {
    let gameId: String
    let version: Int
    let bindings: [Binding]
    // 載入時驗證：座標 0–1、radius>0、identifier 不衝突、sensitivity>0
}
```

### 4.2 KeymapEngine（純邏輯，狀態機）

**輸入**：離散事件 `KeyEvent(.down/.up, KeyCode)`、`MouseMove(dx, dy)`（look 用）。
**狀態**：目前按住的鍵集、joystick 累積、look 累積位移。
**輸出**：`TouchFrame`——當前所有 active 觸點的多指快照 `[TouchSpec(identifier, x, y, down)]`。

- **identifier 靜態分配**（決定論、可測）：每個 binding 在 profile 載入時分到固定 slot——
  joystick=1、每個 tap key 依序 2,3,4…、look=最後一個。同時按不互搶。
- **tap**：keyDown → 該 identifier 觸點 down 於 `at`；keyUp → up。
- **joystick**：任一方向鍵狀態變化 → `JoystickMath.vector(pressed:)` 算正規化向量（含對角
  正規化，不超過 1）→ 觸點 = center + vector*radius；全放開 → up。持續按住=drag（保持 down、
  座標隨向量變）。
- **look**：activation 按住（或 always-on）期間，MouseMove 累積 → 從 center 拖曳一個 look 觸點；
  停止移動一段時間或放開 activation → up 並回中。sensitivity 縮放位移。
- **純函式核心**：`func apply(_ event: InputEvent) -> TouchFrame`（引擎持有狀態，但轉移邏輯
  無副作用、可用假事件序列窮舉測試）。

### 4.3 EmulatorClient 擴充

```swift
struct TouchSpec: Sendable { let identifier: Int; let x: Int; let y: Int; let down: Bool }

extension EmulatorClient {
    func sendTouches(_ touches: [TouchSpec]) async   // 一個 TouchEvent 帶多 Touch
    func sendKey(_ code: KeyCode, down: Bool) async   // KeyboardEvent（保留給 profile 未映射的直通鍵）
}
```

- 與 P1-a 的 `sendTap` 並存（sendTap = sendTouches 的單指特例，可內部轉呼叫，DRY）。
- 座標為 guest 像素（呼叫端已用實際幀尺寸換算）。

### 4.4 KeymapController（@MainActor 膠水）

- 訂閱 MirrorView 的 keyDown/keyUp/mouseMoved/flagsChanged。
- 有 active profile：事件 → `engine.apply` → `TouchFrame` → 換算 guest 像素 → `client.sendTouches`。
- 無 profile 或「直接模式」：退回 P1-a 的 mouse→sendTap（保證無設定檔也能操作）。
- look 模式：透過 `MouseCapture` 隱藏並鎖定游標，取 raw delta；退出還原。
- 編輯模式（⌘E）：暫停注入，切到 `OverlayEditorView`。

### 4.5 Overlay 編輯器（陽春）

- 半透明疊在鏡像上；binding 顯示為可拖曳控制項（tap=圓點+鍵標、joystick=圓環、look=標記）。
- 操作：新增（選鍵→點畫面放座標）、拖曳移動、刪除、調整 joystick 半徑/look 靈敏度（滑桿）。
- 存檔：產生新版 profile（version+1，不可變）寫入 `ProfileStore`；可一鍵回滾上一版。

### 4.6 ProfileStore

- 位置：`~/Library/Application Support/Mirage/profiles/<gameId>.json`。
- 載入 fail fast（schema 驗證失敗回明確錯誤，不吞）；儲存原子寫（temp+rename）。
- 內建 1 份 hand-authored 指標遊戲 profile 作為 P1-d 銜接與煙霧素材。

## 5. 錯誤處理

- Profile 載入：JSON 解析/schema 驗證失敗 → 明確 error，UI 提示，退回直接模式（不崩、不吞）。
- 引擎：未知鍵碼 → 忽略並計數（暴露，不靜默）；identifier 衝突於載入期即拒絕該 profile。
- sendTouches：gRPC 錯誤沿用 P1-a transport 分類；look 捕捉失敗 → 退回非捕捉並提示。

## 6. 測試策略

- **單元（MirageCoreTests，TDD，目標 ≥80%）**：
  - `JoystickMath`：單鍵/雙鍵對角/三鍵/相反鍵相消/全放，向量正規化不超 1。
  - `KeymapProfile`：JSON round-trip、越界座標拒絕、identifier 衝突拒絕、radius/sensitivity 驗證。
  - `KeymapEngine`：tap down/up、joystick drag 序列、look 累積、**多指同時**（移動中按技能 →
    TouchFrame 含 2 觸點且 identifier 穩定）、放開順序。
  - `ProfileStore`：載入/儲存 round-trip、損壞檔拒絕、原子寫。
- **整合/pending-human**：overlay 編輯器拖放、look 滑鼠捕捉手感、真遊戲多指落點——需 GUI
  與解鎖螢幕，標記 pending-human（延續 P1-a 的誠實驗收慣例）。

## 7. 驗收標準（P1-c 出貨線）

1. MirageCore Keymap 單元測試全綠、覆蓋 ≥80%；`swift build -c release` 零警告。
2. 引擎多指正確性：假事件序列「按住 W + 點技能鍵」→ TouchFrame 含 joystick(id 1) 與
   tap(id N) 兩觸點、座標正確、identifier 不衝突（單元測試證明）。
3. 活體煙霧（模擬器執行中）：載入指標遊戲 profile，程式化注入一段「移動+技能」序列，
   emulator 端 `show_touches` 可見兩個同時觸點（腳本化擷取截圖佐證，非人工目視）。
4. 無 profile 時 MirrorView 仍可用直接 mouse→tap（P1-a 行為不回歸）。
5. **pending-human（解鎖後）**：overlay 編輯器實際拖放存檔、look 手感、真遊戲操作跟手度。

## 8. 風險與備註

- **look 滑鼠捕捉**是 AppKit 私有感較重的一段（CGAssociateMouseAndMouseCursorPosition +
  warp + 隱藏游標 + 退出還原）；計畫中須把捕捉/還原的邊界情況（失焦、退出編輯、崩潰）定死。
- 多指 identifier 與 emulator 的實際多點行為需活體驗證（Generated stub 有欄位，但 canary
  行為以實測為準）——列為 Task 早期煙霧。
- 與 P1-b 共用 `EmulatorClient`/`MirageApp`：本件的 EmulatorClient 擴充為新方法（sendTouches/
  sendKey），與 P1-b 的 snapshot/clipboard/health-probe 不同方法，合併衝突面小；MirageApp 的
  輸入路由（本件）與選單列/生命週期（P1-b）為不同區域。P1-b 先合，本件整合時做一次解決 pass。
- 驗收 fps/延遲不在本件重測（P1-a 已建基線，鍵位映射不改顯示管線）；但多指注入的
  額外延遲若 P1-d 實測有感，回頭量。
