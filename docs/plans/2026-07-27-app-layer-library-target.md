# App 層 library target 抽取 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 21 檔、1668 行的 App 層程式碼從 `MirageApp` executable target 抽成可被測試 `@testable import` 的 `MirageShell` library target，讓 `AppModel`／`AudioPlayer`／`MirrorContainerView`／`KeymapController`／`AdbClient`／`GameDetector` 終於能被單元測試觸及。

**Architecture:** executable 只剩一個轉呼叫的 `@main`；`App` 協定自帶 `static func main()`，所以 `MirageScene` 與 `AppDelegate` 都能留在 library 保持 internal，**公開介面只有 `MirageEntry.main()` 一個函式**。App 層 21 檔目前零 `public` 宣告，`@testable import` 就能觸及 internal——因此這是**檔案位移 + target 設定**，不是改寫。

**Tech Stack:** Swift 6 toolchain（`.swiftLanguageMode(.v5)`）、SwiftPM、SwiftUI + AppKit + MetalKit + AVFoundation、swift-testing。

**設計依據：** `docs/specs/2026-07-27-app-layer-library-target-design.md`（authoritative）。

## Global Constraints

- 平台 macOS 14+ Apple Silicon；`swift build -c release` 零非-deprecation 警告
- **`MirageCore` 不得 import AppKit / SwiftUI / Metal / AVFoundation**（`MirageShell` 是 App 層，可用）；不 `fatalError`
- 所有 target 開 `-strict-concurrency=complete`；`.swiftLanguageMode(.v5)`
- 測試語法用 swift-testing（`@Suite` / `@Test` / `#expect`），非 XCTest
- 每檔 <400 行、函式 <50 行；不可變優先
- Conventional commits，**不得含任何 attribution / Co-Authored-By**
- 既有 **170 個 `@Test`** 不得回歸（本計畫會新增 3 個 smoke test）
- **行為必須零改變**——這是純重構
- **`MirageCore` 零改動**
- **executable target 名稱維持 `MirageApp`**（`README.md`、`scripts/verify_reconnect.sh`、`scripts/coverage.sh` 都寫死 `./.build/release/MirageApp`）
- 工作目錄一律 `app/`

## 環境地雷（動手前必讀）

- 這個專案有一筆**既有的 NIO teardown 架構債**：`swift test` 偶爾會整個卡死（0% CPU，stack 停在 `semaphore_wait_trap`）。與本計畫無關。**測試在前景跑；超過 90 秒沒結束就 `pkill -f MiragePackageTests` 重跑；連兩次卡死就回報 DONE_WITH_CONCERNS，不要無限等待。**
- `localhost:8554` 的模擬器是**共享資源**：不得殺／重啟／`loadSnapshot`。本計畫只有 Task 5 會用到它（`coverage.sh`）。
- 本機螢幕可能鎖定；螢幕鎖定時 SwiftUI `WindowGroup` 的 `.task` 不觸發，App 會 0 輸出。判定方式：`ioreg -n Root -d1 -a | grep -A1 CGSSessionScreenIsLocked`。

---

## File Structure

新增：

| 檔案 | 職責 |
|---|---|
| `Sources/MirageApp/Main.swift` | executable 的全部內容——`@main`，轉呼叫 `MirageEntry.main()` |
| `Sources/MirageShell/MirageEntry.swift` | library 唯一的 `public` 宣告 |
| `Sources/MirageShell/MirageScene.swift` | 原 `struct MirageApp: App` 改名，含 `body` 與 `keymapOverlayLayer` |
| `Sources/MirageShell/AppModel.swift` | 原 `MirageApp.swift` 裡的 `AppModel` 本體 |
| `Sources/MirageShell/AppDelegate.swift` | 原 `MirageApp.swift` 裡的 `AppDelegate` |
| `Tests/MirageShellTests/ShellSmokeTests.swift` | 3 個 smoke test，證明 `@testable import MirageShell` 這條路真的通 |

搬移（**內容不動**）：`Sources/MirageApp/` 下除 `MirageApp.swift` 外的 20 檔 → `Sources/MirageShell/` 對應位置（保留 `Audio/`、`Detect/`、`Install/`、`Keymap/`、`Lifecycle/` 子目錄）。

修改：

| 檔案 | 改動 |
|---|---|
| `Package.swift` | 新增 `MirageShell` target 與 `MirageShellTests` testTarget；`MirageApp` 改依賴 `MirageShell` |
| `scripts/coverage.sh` | 改成分兩段報告（`MirageCore` / `MirageShell`） |
| `README.md` | target 結構與新的覆蓋率判讀方式 |

刪除：`Sources/MirageApp/MirageApp.swift`（其內容分拆進上表三個新檔）

---

## Task 1: R1 驗證——`App.main()` 從非 `@main` 位置呼叫是否可行

**Files:**
- 全部在拋棄式 spike 目錄，**不動專案任何檔案**

**Interfaces:**
- Consumes: 無
- Produces: 一個結論（R1 成立／不成立），寫進報告

> **這是整個計畫的前提，必須第一步就驗。** 設計的「公開介面只有一個函式」完全建立在「`@main` 可以掛在轉呼叫的空殼上」這個假設。若不成立，退路是 `MirageScene` 與 `AppDelegate` 改 `public`、executable 寫成正常的 `@main struct Main: App`（公開介面變 2 個型別，仍可接受），**但那要在動任何真檔案之前就知道**。
>
> 用**專案外的拋棄式 spike** 驗，不碰真的 package——這樣失敗零成本。

- [ ] **Step 1: 建立 spike package**

```bash
SPIKE=$(mktemp -d)/r1spike && mkdir -p "$SPIKE/Sources/SpikeLib" "$SPIKE/Sources/SpikeApp"
cd "$SPIKE"
cat > Package.swift <<'EOF'
// swift-tools-version:6.0
import PackageDescription
let package = Package(
    name: "r1spike",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SpikeLib"),
        .executableTarget(name: "SpikeApp", dependencies: ["SpikeLib"]),
    ]
)
EOF
cat > Sources/SpikeLib/Scene.swift <<'EOF'
import SwiftUI

// 刻意 internal——這正是要驗的：非 public 的 App 型別能否經由 public wrapper 啟動。
struct SpikeScene: App {
    var body: some Scene {
        WindowGroup { Text("r1") }
    }
}

public enum SpikeEntry {
    public static func main() { SpikeScene.main() }
}
EOF
cat > Sources/SpikeApp/Main.swift <<'EOF'
import SpikeLib

@main
struct Main {
    static func main() { SpikeEntry.main() }
}
EOF
```

- [ ] **Step 2: 建置 spike**

Run: `cd "$SPIKE" && swift build 2>&1 | tail -5`
Expected: `Build complete!`

若這一步就編譯失敗（例如 `'main()' is inaccessible` 或 `@main` 相關錯誤），**R1 不成立**——直接跳到 Step 4 記錄結論。

- [ ] **Step 3: 執行 spike，確認行程起得來**

```bash
cd "$SPIKE" && (./.build/debug/SpikeApp > /tmp/r1spike.log 2>&1 &) ; sleep 5
pgrep -f SpikeApp >/dev/null && echo "R1 PASS：行程存活" || echo "R1 FAIL：行程未存活"
cat /tmp/r1spike.log
pkill -f SpikeApp
```

Expected（R1 成立時）：印出 `R1 PASS：行程存活`。

**注意**：螢幕鎖定時 SwiftUI 視窗不會出現，但**行程仍應存活**——這一步驗的是「能不能啟動」，不是「有沒有畫面」。若行程立刻死掉並在 log 留下錯誤，那才是 R1 不成立。

- [ ] **Step 4: 記錄結論並清除 spike**

```bash
rm -rf "$(dirname "$SPIKE")"
```

把結論寫進報告：**R1 成立**（後續照 spec §3.1 走）或 **R1 不成立**（附完整錯誤訊息，後續任務改走退路：`MirageScene` 與 `AppDelegate` 改 `public`）。

- [ ] **Step 5: 不 commit**

本任務不改動專案任何檔案，故**不產生 commit**。確認 `cd /Users/hanfourhuang/Projects/mirage && git status --short` 為空。

---

## Task 2: 建立 MirageShell target 並搬入全部 App 層程式碼

**Files:**
- Modify: `app/Package.swift`
- Move: `app/Sources/MirageApp/` 下 20 檔（除 `MirageApp.swift`）→ `app/Sources/MirageShell/`
- Move+Modify: `app/Sources/MirageApp/MirageApp.swift` → `app/Sources/MirageShell/MirageScene.swift`
- Create: `app/Sources/MirageShell/MirageEntry.swift`
- Create: `app/Sources/MirageApp/Main.swift`

**Interfaces:**
- Consumes: Task 1 的 R1 結論
- Produces:
  - target `MirageShell`（library，依賴 `MirageCore`）
  - `public enum MirageEntry { public static func main() }`
  - `struct MirageScene: App`（internal，原 `MirageApp` 改名）

> **這一步是原子的**——中途沒有任何能編譯的中間狀態（executable 需要 `@main`，而 `@main` 只能有一個）。所以 20 檔搬移、`MirageApp.swift` 改寫、`Main.swift` 新增必須在同一個 commit 完成。
>
> `AppModel` 與 `AppDelegate` **這一步原樣留在 `MirageScene.swift` 裡**，拆檔是 Task 3 的事——那樣 Task 3 的 diff 才是純粹的檔案切分，好審。

- [ ] **Step 1: 搬移 20 檔（用 `git mv` 保留歷史）**

```bash
cd app
mkdir -p Sources/MirageShell/{Audio,Detect,Install,Keymap,Lifecycle}
for f in AppModel+Audio.swift AppModel+Focus.swift AppModel+FullScreen.swift AppModel+Install.swift \
         ConnectionBanner.swift MirrorContainerView.swift MirrorView.swift Renderer.swift; do
  git mv "Sources/MirageApp/$f" "Sources/MirageShell/$f"
done
git mv Sources/MirageApp/Audio/AudioPlayer.swift        Sources/MirageShell/Audio/
git mv Sources/MirageApp/Detect/AdbClient.swift         Sources/MirageShell/Detect/
git mv Sources/MirageApp/Detect/GameDetector.swift      Sources/MirageShell/Detect/
git mv Sources/MirageApp/Install/InstallBanner.swift    Sources/MirageShell/Install/
git mv Sources/MirageApp/Install/InstallState.swift     Sources/MirageShell/Install/
git mv Sources/MirageApp/Keymap/KeymapController.swift  Sources/MirageShell/Keymap/
git mv Sources/MirageApp/Keymap/KeymapOverlay.swift     Sources/MirageShell/Keymap/
git mv Sources/MirageApp/Keymap/MouseCapture.swift      Sources/MirageShell/Keymap/
git mv Sources/MirageApp/Keymap/OverlayEditorView.swift Sources/MirageShell/Keymap/
git mv Sources/MirageApp/Lifecycle/AppLifecycle.swift     Sources/MirageShell/Lifecycle/
git mv Sources/MirageApp/Lifecycle/ClipboardWatcher.swift  Sources/MirageShell/Lifecycle/
git mv Sources/MirageApp/Lifecycle/MenuBarController.swift Sources/MirageShell/Lifecycle/
```

驗證搬了 20 個：`find Sources/MirageShell -name "*.swift" | wc -l` → `20`

- [ ] **Step 2: 把 `MirageApp.swift` 改名搬走並去掉 `@main`**

```bash
git mv Sources/MirageApp/MirageApp.swift Sources/MirageShell/MirageScene.swift
```

然後編輯 `Sources/MirageShell/MirageScene.swift`：

- 刪掉第 5 行的 `@main`
- 把第 6 行 `struct MirageApp: App {` 改成 `struct MirageScene: App {`
- 檔頭加一段說明（放在 `import` 之後、`struct` 之前）：

```swift
/// SwiftUI 的 App 進入點。
///
/// **刻意保持 internal**：executable target 只有一個轉呼叫的 `@main`（見
/// `Sources/MirageApp/Main.swift`），實際啟動經由 `MirageEntry.main()`。`App` 協定的
/// extension 自帶 `public static func main()`，所以這個型別與 `AppDelegate` 都不必公開——
/// `MirageShell` 的公開介面因此只有 `MirageEntry` 一個函式，其餘 21 檔的可見度一行未改，
/// 測試用 `@testable import MirageShell` 即可觸及。
```

**其餘內容一行都不要動**（`AppModel`、`AppDelegate` 都原樣留著，Task 3 才拆）。

- [ ] **Step 3: 建立 `MirageEntry.swift`**

建立 `app/Sources/MirageShell/MirageEntry.swift`：

```swift
/// `MirageShell` 唯一的公開宣告——executable 的 `@main` 只呼叫這一個函式。
///
/// 這樣設計的理由：App 層 21 檔全部是 internal，測試靠 `@testable import` 觸及即可，
/// 沒有任何型別需要跨 module 公開。把公開面壓到一個函式，就不會有人為了「讓
/// executable 看得見」而逐步把內部型別改成 `public`。
public enum MirageEntry {
    public static func main() { MirageScene.main() }
}
```

- [ ] **Step 4: 建立 executable 的唯一檔案**

建立 `app/Sources/MirageApp/Main.swift`：

```swift
import MirageShell

/// executable 的全部內容。實作全在 `MirageShell` library，這裡只負責 `@main` 這個
/// 語言層的進入點——library target 不能帶 `@main`，而 App 層需要能被測試 import，
/// 兩個需求只能這樣拆。
@main
struct Main {
    static func main() { MirageEntry.main() }
}
```

- [ ] **Step 5: 更新 `Package.swift`**

把 `MirageApp` 的 `.executableTarget(...)` 那段替換成：

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
```

`MirageCore` 與 `MirageCoreTests` 兩段**完全不動**。

- [ ] **Step 6: 建置**

Run: `cd app && swift build 2>&1 | tail -20`
Expected: `Build complete!`

**若出現 strict-concurrency 的新警告或錯誤**（跨 module 邊界的 Sendable 檢查較嚴）：**不得用 `@unchecked` 或 `nonisolated(unsafe)` 硬壓過去**。停下來回報 BLOCKED，附完整訊息。

- [ ] **Step 7: 既有測試零回歸**

Run: `cd app && swift test 2>&1 | tail -3`
Expected: `Test run with 170 tests passed`。

- [ ] **Step 8: release 零警告**

Run: `cd app && swift build -c release 2>&1 | grep -i warning | grep -v deprecat`
Expected: 無輸出。

- [ ] **Step 9: App 仍能啟動（R1 的真實驗證）**

```bash
cd app
(./.build/release/MirageApp > /tmp/mirage_launch.log 2>&1 &) ; sleep 6
pgrep -f "release/MirageApp" >/dev/null && echo "PASS：行程存活" || echo "FAIL：行程未存活"
head -5 /tmp/mirage_launch.log
pkill -f "release/MirageApp"
ioreg -n Root -d1 -a 2>/dev/null | grep -A1 CGSSessionScreenIsLocked | head -2
```

Expected: `PASS：行程存活`。螢幕鎖定時 log 可能是空的（`.task` 不觸發），**那不算失敗**——本步驟驗的是「起得來」。把螢幕鎖定狀態一併記錄進報告。

- [ ] **Step 10: Commit**

```bash
cd app && git add -A
git commit -m "refactor: App 層抽成 MirageShell library target

executable 只剩一個轉呼叫的 @main；App 協定自帶 static main()，故 MirageScene
與 AppDelegate 都留在 library 保持 internal，公開介面只有 MirageEntry 一個函式。
21 檔可見度一行未改——測試靠 @testable import 觸及即可。

executable target 名稱維持 MirageApp（README 與多支 verify 腳本寫死了
./.build/release/MirageApp）。AppModel/AppDelegate 這一步原樣留在 MirageScene.swift，
拆檔留給下一個 commit，讓那個 diff 是純粹的檔案切分。"
```

---

## Task 3: 把 `MirageScene.swift` 拆成三個檔

**Files:**
- Modify: `app/Sources/MirageShell/MirageScene.swift`（只留 `MirageScene`）
- Create: `app/Sources/MirageShell/AppModel.swift`
- Create: `app/Sources/MirageShell/AppDelegate.swift`

**Interfaces:**
- Consumes: Task 2 產出的 `MirageScene.swift`（388 行，含三個型別）
- Produces: 三個聚焦的檔案，型別與成員簽章**完全不變**

> **純檔案切分，零行為改變。** Task 2 之後 `MirageScene.swift` 有 388 行、住了三個型別（`MirageScene` / `AppModel` / `AppDelegate`）——那正是這個專案從 P1-e 起就一直在 400 行邊緣掙扎的檔案。

- [ ] **Step 1: 確認切分邊界**

Run: `cd app && grep -nE "^struct MirageScene|^@MainActor|^@Observable|^final class AppModel|^final class AppDelegate|^// AUTHORIZED ADDITION" Sources/MirageShell/MirageScene.swift`

三個型別的起訖行號記下來。`AppModel` 前面有 `@MainActor` 與 `@Observable` 兩個屬性標註，`AppDelegate` 前面有一大段 `// AUTHORIZED ADDITION（Task 4 review: NIO teardown race）` 註解——**那段註解屬於 `AppDelegate`，要跟著搬**。

- [ ] **Step 2: 建立 `AppModel.swift`**

把 `MirageScene.swift` 裡從 `@MainActor` / `@Observable` / `final class AppModel {` 開始、到該 class 結束的 `}` 為止（含其上方所有 doc 註解），**原封不動**剪到新檔 `app/Sources/MirageShell/AppModel.swift`。

檔頭補：

```swift
import AppKit
import MirageCore
import SwiftUI
```

（實際需要哪些 import 以編譯結果為準——若少了會編譯失敗，多了會出現未使用警告，兩者都會被後面的驗證步驟抓到。）

- [ ] **Step 3: 建立 `AppDelegate.swift`**

把 `final class AppDelegate: NSObject, NSApplicationDelegate { ... }` 連同其上方那整段 `// AUTHORIZED ADDITION（Task 4 review: NIO teardown race）` 註解，**原封不動**剪到新檔 `app/Sources/MirageShell/AppDelegate.swift`。

檔頭補 `import AppKit`。

- [ ] **Step 4: 建置**

Run: `cd app && swift build 2>&1 | tail -10`
Expected: `Build complete!`，且**無未使用 import 的警告**。若有，把多餘的 import 拿掉。

- [ ] **Step 5: 確認三個檔案的行數**

Run: `cd app && wc -l Sources/MirageShell/MirageScene.swift Sources/MirageShell/AppModel.swift Sources/MirageShell/AppDelegate.swift`
Expected: 三者皆 **< 400**，且加總約等於原本的 388 加上新增的 import 行。

- [ ] **Step 6: 確認是純位移（沒有順手改東西）**

Run: `cd app && git diff --stat`

三個檔案的增減行數應該互相對得起來。**若你在搬移途中「順手」改了任何邏輯、命名或註解，現在把它改回去**——這一步的價值就在於 diff 乾淨到可以一眼看出沒有行為改變。

- [ ] **Step 7: 測試零回歸 + release 零警告**

Run: `cd app && swift test 2>&1 | tail -3 && swift build -c release 2>&1 | grep -i warning | grep -v deprecat`
Expected: `Test run with 170 tests passed`；warning grep 無輸出。

- [ ] **Step 8: Commit**

```bash
cd app && git add -A
git commit -m "refactor: MirageScene.swift 拆成 MirageScene / AppModel / AppDelegate 三檔

純檔案切分、零行為改變。這個檔案從 P1-e 起就一直在 400 行邊緣掙扎，
三個型別（SwiftUI 進入點、應用狀態、NSApplicationDelegate）本來就沒有理由同居。"
```

---

## Task 4: `MirageShellTests` target 與 3 個 smoke test

**Files:**
- Modify: `app/Package.swift`
- Create: `app/Tests/MirageShellTests/ShellSmokeTests.swift`

**Interfaces:**
- Consumes: `MirageShell` target（Task 2）、`MirrorContainerView`／`AudioPlayer`／`InstallState`／`InstallItem`（皆 internal，靠 `@testable import` 觸及）
- Produces: 新 testTarget `MirageShellTests`

> **這是整個計畫的意義所在**——證明 App 層真的可以被測了。三個 smoke test 刻意最小：只證明路通，不是補齊測試（那是另一輪）。
>
> **刻意不測 `MouseCapture`**：它的 `capture()` 會呼叫 `CGAssociateMouseAndMouseCursorPosition(0)` 與 `NSCursor.hide()`，那是**全域副作用**，在測試裡動它有機會把開發機的游標狀態搞壞。要測它得先設計注入點。

- [ ] **Step 1: 新增 testTarget**

在 `app/Package.swift` 的 `targets` 陣列末尾（`MirageCoreTests` 之後）加入：

```swift
        .testTarget(
            name: "MirageShellTests",
            dependencies: [
                "MirageShell",
                "MirageCore",   // 測試會直接用 ViewportFit / AudioRingBuffer 等公開型別
                .product(name: "Testing", package: "swift-testing"),
            ],
            swiftSettings: strict
        ),
```

- [ ] **Step 2: 寫測試**

建立 `app/Tests/MirageShellTests/ShellSmokeTests.swift`：

```swift
import AppKit
import MirageCore          // ViewportFit / AudioRingBuffer / InstallResult 皆為 public，不需 @testable
import Testing
@testable import MirageShell

/// App 層 smoke test——本階段的意義是**證明 `@testable import MirageShell` 這條路真的通**，
/// 不是補齊測試覆蓋（那是另一輪）。三個測項刻意挑不同性質的目標：AppKit view 佈局、
/// 碰 AVFoundation 的型別、純值型別。
@Suite struct ShellSmokeTests {
    /// 最有價值的一條：直接驗證 P1-e 全螢幕的核心前提——容器確實把 `MirrorMTKView`
    /// 擺在 `ViewportFit` 算出的內容矩形上。這條先前只能靠讀碼相信。
    /// `NSView.layout()` 不需要視窗，headless 可跑。
    @MainActor
    @Test func containerLetterboxesMirrorIntoFitRect() {
        let container = MirrorContainerView(frame: NSRect(x: 0, y: 0, width: 1000, height: 1000))
        container.frameSize = (w: 1920, h: 1080)      // 橫向幀塞進正方形 bounds → 上下黑邊
        container.layout()

        let expected = ViewportFit.fit(frame: (w: 1920, h: 1080), in: (w: 1000, h: 1000))
        #expect(Int(container.mirror.frame.width) == expected.width)
        #expect(Int(container.mirror.frame.height) == expected.height)
        #expect(Int(container.mirror.frame.origin.x) == expected.x)
        #expect(Int(container.mirror.frame.origin.y) == expected.y)
        #expect(expected.height < 1000)               // 確實有黑邊，不是退化成滿版
    }

    /// 證明碰 AVFoundation 的型別也在可測範圍內（不啟動 engine，只驗狀態切換）。
    @MainActor
    @Test func audioPlayerMuteTogglesState() {
        let player = AudioPlayer(ring: AudioRingBuffer(capacitySamples: 64))
        #expect(!player.isMuted)
        player.setMuted(true)
        #expect(player.isMuted)
        player.setMuted(false)
        #expect(!player.isMuted)
    }

    /// 純值型別，證明最基本的 import 路徑通（`InstallItem` 內含 MirageCore 的 `InstallResult`，
    /// 順帶驗證兩個 module 的型別可以在測試裡一起用）。
    @Test func installStateFinishedCarriesItems() {
        let state = InstallState.finished([
            InstallItem(name: "ok.apk", result: .success),
            InstallItem(name: "bad.apk", result: .failure("INSTALL_FAILED_OLDER_SDK")),
        ])
        guard case .finished(let items) = state else {
            Issue.record("預期 .finished，實得 \(state)")
            return
        }
        #expect(items.count == 2)
        #expect(items[0].name == "ok.apk")
        #expect(items[0].result == .success)
        #expect(items[1].result == .failure("INSTALL_FAILED_OLDER_SDK"))
    }
}
```

- [ ] **Step 3: 執行新測試**

Run: `cd app && swift test --filter ShellSmokeTests 2>&1 | tail -8`
Expected: 3 個測項全綠。

**若 `MirrorContainerView` 的測試失敗**：先確認失敗的是哪一條斷言。若是 origin/size 對不上，**不要調整期望值去迎合實作**——那條測試的價值就在於它獨立於實作重算了一次 `ViewportFit`。停下來回報，附實際值與期望值。

- [ ] **Step 4: 確認測試真的觸及了 internal 宣告**

Run: `cd app && grep -c "^public" Sources/MirageShell/*.swift Sources/MirageShell/*/*.swift | grep -v ":0" || echo "（除 MirageEntry 外無 public 宣告）"`

Expected: 只有 `MirageEntry.swift` 有 `public`。這證明三個 smoke test 全部是靠 `@testable` 觸及 internal——也就是這條路真的通。把輸出貼進報告。

- [ ] **Step 5: 全套測試**

Run: `cd app && swift test 2>&1 | tail -3`
Expected: `Test run with 173 tests passed`（既有 170 + 新增 3）。

- [ ] **Step 6: release 零警告**

Run: `cd app && swift build -c release 2>&1 | grep -i warning | grep -v deprecat`
Expected: 無輸出。

- [ ] **Step 7: Commit**

```bash
cd app && git add -A
git commit -m "test: MirageShellTests target 與 3 個 App 層 smoke test

證明 @testable import MirageShell 這條路真的通——三個測項分別觸及 AppKit view
佈局（MirrorContainerView 的 letterbox，先前只能靠讀碼相信）、碰 AVFoundation
的型別（AudioPlayer 靜音狀態）、純值型別（InstallState）。

刻意不測 MouseCapture：它的 capture() 會動全域游標狀態，在測試裡碰有機會把
開發機搞壞，要測得先設計注入點。"
```

---

## Task 5: `coverage.sh` 改成分兩段報告

**Files:**
- Modify: `app/scripts/coverage.sh`

**Interfaces:**
- Consumes: `MirageShell` target（Task 2）
- Produces: 分段的覆蓋率輸出

> **這是本計畫最容易被誤判的一環。** `MirageShell` 成為正式 target 後就會出現在 `llvm-cov` 報告裡，而 App 層 1668 行**幾乎零覆蓋**，合併 TOTAL 會從目前的 87.80% 再掉到 50 幾%。
>
> **那不是回歸**——那 1668 行的覆蓋率一直是 0，只是先前結構上被排除在報告外。但下一個人跑 `coverage.sh` 看到「87.80% → 50 幾%」必然誤判。這正是本專案踩過一次的坑（`RESULTS-p1a.md` 曾把不當數字當證據、後被撤回）。

- [ ] **Step 1: 先量重構前的基準**

Run: `cd app && ./scripts/coverage.sh 2>&1 | grep -E "^TOTAL|MirageCore/" | tail -5`

把 **`MirageCore` 相關檔案的數字**記下來——驗收線 4 要求「不低於重構前實測基準」，這就是那個基準。貼進報告。

（此時 `MirageShell` 已經是 target，所以這一步量到的 TOTAL 已含 App 層。要取的是 `MirageCore/` 那些行的數字。）

- [ ] **Step 2: 改寫報告段落**

修改 `app/scripts/coverage.sh` 末段——把原本單一的 `llvm-cov report` 呼叫換成分兩段：

```bash
echo ""
echo "=== 覆蓋率（分兩段報告）==="
echo ""
echo "--- 段 1：MirageCore（判定用這一段）---"
xcrun llvm-cov report "$TEST_BIN" -instr-profile "$MERGED_PROFDATA" \
  -ignore-filename-regex 'Generated|Tests|\.build|MirageShell'
echo ""
echo "--- 段 2：MirageShell（App 層，進度指標不是門檻）---"
xcrun llvm-cov report "$TEST_BIN" -instr-profile "$MERGED_PROFDATA" \
  -ignore-filename-regex 'Generated|Tests|\.build|MirageCore'
```

並把末尾的「判讀」段落換成：

```bash
echo ""
echo "=== 判讀 ==="
echo "**必須分兩段看，不要看合併後的 TOTAL。**"
echo ""
echo "段 1（MirageCore）：判定依據。要求是「不因改動而下降」，不是某個絕對數字——"
echo "  目前基準約 87.80%，其中 MmapStreamTransport.swift 為 0%（MMAP 是 opt-in 路徑，"
echo "  本腳本不設 MIRAGE_TRANSPORT=mmap，故一行都不會執行到）。那是已記錄的預期後果，"
echo "  見 app/RESULTS-mmap.md 驗收線 4，不是回歸。"
echo ""
echo "段 2（MirageShell）：App 層，從接近 0 起算，是**進度指標不是門檻**。"
echo "  這 1668 行的覆蓋率一直是 0，只是在抽成 library target 之前結構上被排除在報告外。"
echo "  看到它很低不代表退步——代表這筆債現在終於**看得見**了。"
echo ""
echo "若段 1 明顯低於基準，先確認上面兩次 swift test 是否皆全綠、以及 Run 2 前的"
echo "發聲觸發是否成功（Run 2 的 [audio-live] writes 應 >= 75）——單獨漏跑 Run 2"
echo "是最常見的誤判成因，不是真的覆蓋率回歸。"
```

- [ ] **Step 3: 跑改寫後的腳本**

Run: `cd app && ./scripts/coverage.sh 2>&1 | tail -40`
Expected: 兩段數字皆有輸出；段 1 的 `MirageCore` 數字**不低於 Step 1 量到的基準**。

**若段 1 低於基準**：停下來回報，附兩次的數字。**不要為了讓數字好看而調整 `-ignore-filename-regex` 或門檻**——這個專案已經明文裁決過「把量測缺口偽裝成沒有缺口」是不可接受的。

- [ ] **Step 4: Commit**

```bash
cd app && git add scripts/coverage.sh
git commit -m "chore: coverage.sh 改成 MirageCore / MirageShell 分兩段報告

App 層抽成 library target 後會進入 llvm-cov 報告，而那 1668 行覆蓋率一直是 0
（先前只是結構上被排除），合併 TOTAL 會從 87.80% 掉到 50 幾%——那不是回歸，
但下一個人看到必然誤判。分兩段並在判讀文字裡寫明理由：段 1 是判定依據、
段 2 是進度指標不是門檻。"
```

---

## Task 6: 文件與驗收紀錄

**Files:**
- Create: `app/RESULTS-shell-target.md`
- Modify: `app/README.md`

**Interfaces:**
- Consumes: Task 1–5 的全部產出與量測數字
- Produces: 無（文件）

- [ ] **Step 1: 蒐集驗收數字**

依序執行並保留**真實輸出**：

```bash
cd app
swift test 2>&1 | tail -3                                          # 驗收線 1、2
swift build -c release 2>&1 | grep -ci warning                     # 驗收線 3
./scripts/coverage.sh 2>&1 | tail -40                              # 驗收線 4
grep -c "^public" Sources/MirageShell/*.swift Sources/MirageShell/*/*.swift | grep -v ":0"  # 驗收線 5
wc -l Sources/MirageShell/MirageScene.swift Sources/MirageShell/AppModel.swift             # 驗收線 7
```

驗收線 6（App 行程可啟動並存活 ≥5 秒）用 Task 2 Step 9 的做法重跑一次。

- [ ] **Step 2: 寫 `RESULTS-shell-target.md`**

比照 `app/RESULTS-p1e.md` 與 `app/RESULTS-mmap.md` 的格式與誠實度標準（先讀它們）。必含：

1. **驗收線逐條裁決**（spec §8 的 7 條），每條標 PASS / FAIL / pending-human 與**實際輸出**
2. **R1 的結論**（Task 1）：`App.main()` 從非 `@main` 位置呼叫是否可行、用什麼方式驗的。若走了退路（2 個型別改 public），必須明講並說明公開介面實際長什麼樣
3. **公開介面的實際大小**：驗收線 5 要求「只有 `MirageEntry`」，貼 grep 佐證
4. **覆蓋率的兩段數字**與「段 2 很低不是退步、是這筆債終於看得見」的說明
5. **這筆債的來歷**：跨 P1-c／P1-d／P1-e 三個階段被記錄，每次都以「App 層無法 import」結案。現在通了，但**本階段刻意只開路不鋪路**——實際補測試是另一輪
6. **仍未被測試涵蓋的 App 層元件清單**（`KeymapController`、`AdbClient`、`GameDetector`、`MenuBarController`、`MouseCapture`、`AppModel` 本體……），以及為什麼 `MouseCapture` 被刻意排除（全域游標副作用，要測得先設計注入點）
7. **pending-human**：需真 GUI session 才能驗的項目（若螢幕鎖定導致 Task 2 Step 9 只驗到「行程存活」而沒有實際畫面，如實記錄）

**誠實標準**：本專案有 `RESULTS-p1a.md` 曾把不當數字當證據、後被撤回的前例。量不到就寫 pending-human，FAIL 就寫 FAIL。

- [ ] **Step 3: 更新 `README.md`**

新增一節說明 target 結構，涵蓋：

- 三層結構：`MirageCore`（純邏輯，禁 AppKit/SwiftUI/Metal/AVFoundation）→ `MirageShell`（App 層 library）→ `MirageApp`（executable，只有一個轉呼叫的 `@main`）
- 為什麼這樣拆：App 層要能被 `@testable import`，但 library target 不能帶 `@main`
- **公開介面只有 `MirageEntry.main()`**——新增 App 層程式碼時不需要、也不應該加 `public`
- 覆蓋率要跑 `scripts/coverage.sh`，**分兩段看**，段 2（`MirageShell`）低是預期的
- 指向 `RESULTS-shell-target.md` 與 `../docs/specs/2026-07-27-app-layer-library-target-design.md`

- [ ] **Step 4: Commit**

```bash
cd app && git add RESULTS-shell-target.md README.md
git commit -m "docs: App 層 library target 驗收結果與使用文件"
```

---

## 驗收線對照表（spec §8）

| # | 驗收線 | 由哪個 Task 產生證據 |
|---|---|---|
| 1 | `swift test` 全綠，既有 170 個 `@Test` 不回歸 | Task 2 Step 7、Task 3 Step 7、Task 4 Step 5、Task 6 Step 1 |
| 2 | 3 個 smoke test 通過，且證明 `@testable import` 可觸及 internal | Task 4 Step 3、Step 4 |
| 3 | `swift build -c release` 零非-deprecation 警告 | Task 2 Step 8、Task 3 Step 7、Task 4 Step 6 |
| 4 | `coverage.sh` 分兩段輸出；`MirageCore` 段不低於重構前實測基準 | Task 5 Step 1（基準）、Step 3（比對） |
| 5 | `MirageShell` 的 `public` 宣告只有 `MirageEntry` | Task 4 Step 4、Task 6 Step 1 |
| 6 | App 行程可啟動並存活 ≥5 秒 | Task 2 Step 9、Task 6 Step 1 |
| 7 | `MirageScene.swift`、`AppModel.swift` 各自 < 400 行 | Task 3 Step 5、Task 6 Step 1 |
