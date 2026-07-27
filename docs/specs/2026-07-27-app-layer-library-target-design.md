# App 層 library target 抽取 設計文件

- **日期**：2026-07-27
- **狀態**：待核准
- **前置**：P1-a～P1-e 皆已合併（`main` @ `228116b`）

## 1. 目標

把目前全部塞在 `MirageApp` executable target 裡的 App 層程式碼（21 檔、1668 行）抽成一個可被測試 import 的 library target，讓 `AppModel`、`AudioPlayer`、`MirrorContainerView`、`KeymapController`、`AdbClient`、`GameDetector` 等**終於能被單元測試觸及**。

**這筆債已經跨三個階段被記錄**（P1-c 交接、P1-d 交接、P1-e 終審），每次都以「App 層無法 import，只能靠讀碼＋型別系統＋活體間接佐證」結案。P1-e 又往裡面加了 5 個檔案，債務加深。

**非目標**（明確不做）：

- **不補齊測試**。本階段只「開路」——把 target 邊界打通並用少量 smoke test 證明這條路真的通。實際為各元件補測試是**另一輪**的事。
- **不重構 `AppModel`**。388 行的 `MirageApp.swift` 與 `AppModel` 的職責拆分（連線、keymap、偵測、剪貼簿、安裝……）不在本階段範圍。
- **不改任何行為**。這是純粹的檔案位移 + target 設定，行為必須零改變。
- **不動 `MirageCore`**。它的邊界與「不得 import AppKit/SwiftUI/Metal/AVFoundation」約束維持不變。

## 2. 現況

```
Sources/MirageCore/    →  .target（library，有測試）
Sources/MirageApp/     →  .executableTarget（21 檔、1668 行，零測試覆蓋）
Tests/MirageCoreTests/ →  .testTarget（只依賴 MirageCore）
```

關鍵事實：**App 層 21 個檔案目前沒有任何 `public` 宣告**，全部是 `internal`。這讓重構成本遠低於直覺——`@testable import` 就能觸及 internal，所以幾乎不需要改可見度。

只有 `MirageApp.swift` 帶 `@main`（`struct MirageApp: App`），同檔還住著 `AppModel`（388 行）與 `AppDelegate`。

## 3. 架構

```
MirageCore      不變
    ↑
MirageShell     新 library：Sources/MirageApp/ 的 21 檔原封搬入
    ↑
MirageApp       executable，只剩一個檔案
```

**命名**：`MirageShell` 沿用專案自己的詞彙——母計畫 §4.1 從第一天就稱它為「Swift 原生殼」。

**executable target 名稱維持 `MirageApp`**：`app/README.md`、`scripts/verify_reconnect.sh`、`scripts/coverage.sh` 都寫死了 `./.build/release/MirageApp`，改名會無聲打斷它們。

### 3.1 公開介面：只有一個函式

executable 的全部內容（新檔 `Sources/MirageApp/Main.swift`）：

```swift
import MirageShell

@main
struct Main {
    static func main() { MirageEntry.main() }
}
```

library 側唯一的公開宣告：

```swift
public enum MirageEntry {
    public static func main() { MirageScene.main() }
}
```

`App` 協定的 extension 自帶 `public static func main()`，所以 `@main` 可以掛在一個轉呼叫的空殼上。由此：

- `struct MirageApp: App` 改名 `MirageScene`，**留在 library 保持 internal**
- `@NSApplicationDelegateAdaptor` 與 `AppDelegate` 一併留在 library，**保持 internal**
- 其餘 21 檔的可見度**一行都不改**
- 測試用 `@testable import MirageShell` 觸及全部 internal 宣告

**R1（必須第一步就驗）**：`App.main()` 從非 `@main` 位置呼叫是合法但少見的用法。若行不通，退路是把 `MirageScene` 與 `AppDelegate` 改 `public`，executable 寫成正常的 `@main struct Main: App { @NSApplicationDelegateAdaptor(AppDelegate.self) …; var body: some Scene { MirageScene() } }`——公開介面變 2 個型別，仍可接受。**這個驗證不可延後到最後**。

### 3.2 檔案配置

搬移（內容不動）：`Sources/MirageApp/*.swift`（含 `Audio/`、`Detect/`、`Install/`、`Keymap/`、`Lifecycle/` 子目錄）→ `Sources/MirageShell/` 對應位置。

唯一需要動刀的檔案是 `MirageApp.swift`：

| 內容 | 去處 |
|---|---|
| `struct MirageApp: App`（含 `body`、`keymapOverlayLayer`） | 改名 `MirageScene`，留 `Sources/MirageShell/MirageScene.swift` |
| `AppModel`（class 本體與所有成員） | 原樣留在 library |
| `AppDelegate` | 原樣留在 library |
| 新增 `MirageEntry` | `Sources/MirageShell/MirageEntry.swift`（唯一 public） |

拆完後 `MirageScene.swift` 與 `AppModel.swift` 各自都遠低於 400 行約束——順帶解掉那個從 P1-e 起就一直在 400 行邊緣掙扎的檔案。

### 3.3 Package.swift

```swift
.target(
    name: "MirageShell",
    dependencies: ["MirageCore"],
    swiftSettings: strict
),
.executableTarget(
    name: "MirageApp",
    dependencies: ["MirageShell"],
    swiftSettings: strict
),
.testTarget(
    name: "MirageShellTests",
    dependencies: ["MirageShell", .product(name: "Testing", package: "swift-testing")],
    swiftSettings: strict
),
```

`MirageCoreTests` 不動。新增獨立的 `MirageShellTests` 而非塞進 `MirageCoreTests`——後者的名字會變成謊話。SwiftPM 在 macOS 會把兩個測試 target 打進同一個 `MiragePackageTests.xctest`，故 `coverage.sh` 的 bundle 路徑不受影響。

## 4. 覆蓋率的陷阱（本設計最重要的一節）

`MirageShell` 一旦成為正式 target，就會出現在 `llvm-cov` 報告裡。App 層目前**幾乎零覆蓋**（1668 行），TOTAL line 會從 ~95.6% 掉到大約 60% 出頭。

**這不是回歸**——那 1668 行的覆蓋率一直是 0，只是先前根本沒被算進來（`RESULTS-p1e.md` 已明載 App 層「結構上被排除在覆蓋率報告之外」）。但下一個人跑 `coverage.sh` 看到「95% → 60%」必然誤判。這正是本專案踩過一次的坑（`RESULTS-p1a.md` 曾把不當數字當證據、後被撤回）。

**修法**：`coverage.sh` 改成**分兩段報告**——

| 段 | 意義 |
|---|---|
| `MirageCore` | 既有 ~94% 基準線，**判定用這一段** |
| `MirageShell` | 新的，從接近 0 起算，是**進度指標不是門檻** |

合併的 TOTAL 不再作為判定依據。腳本輸出必須寫明這個區分與理由，不能只是換個數字。

## 5. Smoke test：只證明路通

三個，刻意最小：

| 測項 | 為何選它 |
|---|---|
| `MirrorContainerView` 的 letterbox 佈局 | **最有價值**：直接驗證 P1-e 全螢幕的核心前提——容器確實把 `MirrorMTKView` 擺在 `ViewportFit` 算出的內容矩形上。`NSView.layout()` 不需要視窗，headless 可跑。這條先前只能靠讀碼相信 |
| `AudioPlayer.setMuted` 的狀態切換 | 證明**碰 AVFoundation 的程式碼**也在可測範圍（不啟動 engine，只驗 `isMuted` 狀態） |
| `InstallState` / `InstallItem` | 純值型別，證明最基本的 import 路徑通 |

**刻意不測 `MouseCapture`**：它的 `capture()` 會呼叫 `CGAssociateMouseAndMouseCursorPosition(0)` 與 `NSCursor.hide()`——那是**全域副作用**，在測試裡動它有機會把開發機的游標狀態搞壞。要測它得先設計注入點，屬於「鋪路」那一輪。

## 6. 錯誤處理

本階段不新增任何執行期錯誤路徑（純檔案位移 + target 設定）。既有的錯誤處理（`AudioPlayer` 啟動失敗降級為無音訊、`AdbClient` 不可用時靜默不偵測、`ViewportFit` 退化輸入回 `.zero`）原樣保留。

## 7. 驗證

每一步都必須跑，且貼真實輸出：

1. `swift build` 成功
2. `swift test` — **既有 137 個一個都不能少**，新增的另計
3. `swift build -c release` 零非-deprecation 警告
4. `./scripts/coverage.sh` — 兩段數字皆有輸出，`MirageCore` 段不低於 ~94%
5. **App 仍能啟動**：`./.build/release/MirageApp` 行程起得來且維持存活。螢幕鎖定時只能驗到這一步（`.task` 不觸發、無輸出，見 `RESULTS-p1e.md`），但這正好足以抓出 R1（`App.main()` 那條路是否行得通）

## 8. 驗收線

1. `swift test` 全綠，既有 137 個 `@Test` 不回歸
2. 新增 3 個 smoke test 通過，且證明 `@testable import MirageShell` 可觸及 internal 宣告
3. `swift build -c release` 零非-deprecation 警告
4. `coverage.sh` 分兩段輸出；`MirageCore` 段 ≥ ~94% 基準
5. `MirageShell` 的公開宣告**只有 `MirageEntry`**（可用 `grep -c "^public" Sources/MirageShell/` 佐證；若走 R1 退路則為 `MirageScene` + `AppDelegate` 兩個型別，須在 RESULTS 說明）
6. App 行程可啟動並存活 ≥5 秒
7. `MirageScene.swift`、`AppModel.swift` 各自 < 400 行

## 9. 風險

| # | 風險 | 對策 |
|---|---|---|
| R1 | `App.main()` 從非 `@main` 位置呼叫不如預期 | **第一步就驗**；退路是 2 個型別改 public（見 §3.1） |
| R2 | 21 檔搬移途中漏檔或 import 沒補 | 搬移與改寫**分成兩個 commit**，中間必須建置通過 |
| R3 | 覆蓋率數字被誤判成回歸 | `coverage.sh` 分兩段 + 腳本內寫明理由 + RESULTS 記錄（§4） |
| R4 | 新測試 target 打亂既有測試計數 | 驗收線 1 要求「既有 137 個一個不少」，新增的另計 |
| R5 | `strict-concurrency` 在跨模組邊界產生新警告（internal → 跨 module 的 Sendable 檢查較嚴） | 每步建置都檢查警告數；若出現，屬真實問題不得用 `@unchecked` 硬壓，回報裁決 |

## 10. 與既有階段的整合面

- **`MirageCore`**：零改動。邊界與 import 約束不變。
- **既有測試**：`MirageCoreTests` 零改動。
- **腳本**：`coverage.sh` 需改（§4）；`verify_*.sh` 皆不改（executable 名稱與路徑不變）。
- **文件**：`app/README.md` 需補 target 結構說明與新的覆蓋率判讀方式。
