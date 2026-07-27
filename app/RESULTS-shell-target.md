# App 層 library target 抽取 驗收結果

- **日期**：2026-07-28
- **HEAD**：`3484037`（`chore: coverage.sh 改成 MirageCore / MirageShell 分兩段報告`，Task 5 產出；本文件是 Task 6，只寫文件不改程式碼）
- **模擬器**（僅 `coverage.sh` 活體段落需要）：`localhost:8554`，共享資源，全程未殺／重啟／`loadSnapshot`
- **工具鏈**：`swift-driver version: 1.127.14.1 Apple Swift version 6.2.3`、swift-testing 0.99.0
- **執行**：subagent-driven（Task 1–5 implementer 逐關 + task-review）＋本 Task 6 在目前 HEAD 上重新量測全部 7 條驗收線並寫驗收文件與 README

## 一句話結論

計畫目標「把 App 層 21 檔、1668 行從無法測試 import 的 executable 抽成 library target」**已達成，7 條驗收線全數 PASS**。本階段刻意「只開路不鋪路」——`MirageShell` 段覆蓋率只有 2.62%，這不是退步，是這筆跨三個階段的架構債終於變得可見、可量測。

---

## 驗收線逐條裁決（spec §8）

| # | 驗收線 | 判定 | 實測（本次自行重新量測） |
|---|---|---|---|
| 1 | `swift test` 全綠，既有 170 個 `@Test` 不回歸 | ✅ PASS | `swift test 2>&1 \| tail -3` → `Test run with 173 tests passed after 0.687 seconds.`（單次跑完，無需 `pkill` 重試，未觸發 NIO teardown 卡死）。173 = 170（MMAP 階段基準）+ 3（Task 4 `ShellSmokeTests`），無回歸 |
| 2 | 新增 3 個 smoke test 通過，且證明 `@testable import MirageShell` 可觸及 internal | ✅ PASS | 本次重跑 `swift test --filter ShellSmokeTests` → `containerLetterboxesMirrorIntoFitRect`／`audioPlayerMuteTogglesState`／`installStateFinishedCarriesItems` 3/3 通過。三個型別（`MirrorContainerView`／`AudioPlayer`／`InstallState`）皆為 `internal`（grep 佐證見下「公開介面」節），測試檔用 `@testable import MirageShell`，若非 internal 可觸及則不可能編譯通過。**紅/綠對照證據引用 Task 4 report**（本次未重跑破壞測試，因會暫時偏離 baseline 程式碼；Task 4 report 記載：把 `MirrorContainerView.layout()` 暫改成 `mirror.frame = bounds` 後兩條斷言立即失敗，`git diff` 還原後全綠——**此節屬引用，非本次重跑**） |
| 3 | `swift build -c release` 零非-deprecation 警告 | ✅ PASS | 完整乾淨重建（先 `rm -rf .build/release .build/arm64-apple-macosx/release`）：`Build complete! (127.75s)`；對完整 log `grep -ci warning` 與 `grep -ci deprecat` **皆為 0**——零警告，連 deprecation 警告都沒有 |
| 4 | `coverage.sh` 分兩段輸出；`MirageCore` 段不低於重構前實測基準 | ✅ PASS | 本次實跑 `./scripts/coverage.sh`：段 1（`MirageCore`）TOTAL line **87.80%**，與 `RESULTS-mmap.md` 驗收線 4 記載的重構前基準 **87.80% 差異為 0**；段 2（`MirageShell`）TOTAL line **2.62%**（進度指標，非門檻）。兩次 `swift test` 皆全綠（173/173、1/1），`[audio-live] writes=458`（遠高於 75 門檻） |
| 5 | `MirageShell` 的 `public` 宣告只有 `MirageEntry` | ✅ PASS | `grep -c "^public" Sources/MirageShell/*.swift Sources/MirageShell/*/*.swift \| grep -v ":0"` → 只有一行 `Sources/MirageShell/MirageEntry.swift:1`。額外用 `grep -rn "\bpublic\b" Sources/MirageShell/` 對整棵樹複查，命中 4 行：2 行是 `MirageEntry.swift` 的實際宣告（`public enum MirageEntry` + `public static func main()`），另 2 行是 `MirageScene.swift`／`MirageEntry.swift` 裡**提到「public」這個詞的中文註解**（描述 `App` 協定的行為，非本檔案的宣告）。**R1 未走退路**，`MirageScene`／`AppDelegate` 維持 internal，公開介面確實只有一個型別、一個函式 |
| 6 | App 行程可啟動並存活 ≥5 秒 | ✅ PASS | `(./.build/release/MirageApp > /tmp/mirage_launch_task6.log 2>&1 &)` 後 `sleep 6`：`pgrep -f "release/MirageApp"` 命中，`ps` 顯示行程 `STAT=SN`、CPU/MEM 正常；`kill` 後乾淨終止、無殘留。**本機螢幕全程鎖定**（`ioreg -n Root -d1 -a \| grep CGSSessionScreenIsLocked` → `<true/>`），log 只印出 `[transport] raw rgba (default; ...)` 一行，`.task` 未觸發——**這是預期行為，不是失敗**：本條只驗「行程起得來且存活」，不驗畫面 |
| 7 | `MirageScene.swift`、`AppModel.swift` 各自 < 400 行 | ✅ PASS | `wc -l Sources/MirageShell/MirageScene.swift Sources/MirageShell/AppModel.swift` → `81` / `260`，總計 341，皆遠低於 400 行上限 |

**7 PASS／0 FAIL**。驗收線 2 的紅/綠對照證據是引用 Task 4 report（理由見上），其餘 6 條皆為本次在目前 HEAD 上重新執行取得的第一手輸出。

---

## R1 的結論（Task 1）：`App.main()` 從非 `@main` 位置呼叫可行，未走退路

spec §9 R1 是本計畫最大的風險：`App` 協定的 `static func main()` 通常只能掛在 `@main` 標注的型別上；若無法從轉呼叫鏈啟動，退路是把 `MirageScene`／`AppDelegate` 改 `public`（公開介面變成 2 個型別）。

**驗證方式**：Task 1 在**專案外**（`/private/tmp/.../r1spike/`）建了一個最小 SwiftPM package，結構刻意對應正式方案——

- `internal struct SpikeScene: App`（library target `SpikeLib`）
- `public enum SpikeEntry { public static func main() { SpikeScene.main() } }`
- executable target `SpikeApp`：`@main struct Main { static func main() { SpikeEntry.main() } }`

`swift build` 成功後背景啟動 `SpikeApp`，`sleep 5` 後 `pgrep -f SpikeApp` 仍命中 → **R1 PASS：行程存活**。驗證完畢後 spike 目錄整個刪除，Mirage 專案 git 狀態全程 CLEAN（`git status` 確認無新檔案/修改）。

**結論：R1 成立，沒有走 spec §3.1 的退路**。正式實作（Task 2）採用與 spike 完全同構的方案：`MirageScene: App`、`AppDelegate` 維持 `internal`；library 新增 `public enum MirageEntry { public static func main() { MirageScene.main() } }`；executable 端 `Sources/MirageApp/Main.swift` 為 `@main struct Main { static func main() { MirageEntry.main() } }`。**公開介面維持只有一個函式**（`MirageEntry.main()`），驗收線 5 的 grep 佐證與此結論一致。

唯一需要處理的技術細節：`App` 協定的 `static func main()` 是 `@MainActor` 隔離的，轉呼叫鏈（`Main.main()` → `MirageEntry.main()` → `MirageScene.main()`）若不標 `@MainActor` 會在 `-strict-concurrency=complete` 下出現 isolation 檢查問題。解法是把 `MirageEntry.main()` 與 `Main.main()` 都標 `@MainActor`——這是 `App` 協定 extension 自己採用的合法標注方式，**不是抑制警告**，而是讓呼叫端與被呼叫端的 isolation 一致。驗收線 3 的零警告結果確認此解法乾淨、未使用任何抑制手段。

---

## 公開介面的實際大小

驗收線 5 要求 `MirageShell` 的 `public` 宣告**只有 `MirageEntry`**。本次重新驗證：

```
$ grep -c "^public" Sources/MirageShell/*.swift Sources/MirageShell/*/*.swift | grep -v ":0"
Sources/MirageShell/MirageEntry.swift:1
```

`grep -c "^public"` 用 `MirageEntry.swift` 這個檔案本身**命中兩行 `^public`**（`public enum MirageEntry {` 與 `    public static func main() { ... }`，第二行縮排在方法上但因 grep 是逐行比對整個檔案的行首字元，實際命中數見下方複查），但輸出只顯示一行 `:1`——因為 `grep -c` 是**每個檔案**回報一個計數，`MirageEntry.swift` 這一整個檔案的 `^public`（行首無縮排）命中數是 1（只有 `public enum MirageEntry {` 這一行行首是 `public`；`public static func main()` 那行前面有 4 個空格縮排，不算 `^public`）。用不受縮排限制的複查確認完整清單：

```
$ grep -rn "\bpublic\b" Sources/MirageShell/
Sources/MirageShell/MirageEntry.swift:5:/// executable 看得見」而逐步把內部型別改成 `public`。
Sources/MirageShell/MirageEntry.swift:6:public enum MirageEntry {
Sources/MirageShell/MirageEntry.swift:8:    public static func main() { MirageScene.main() }
Sources/MirageShell/MirageScene.swift:7:/// extension 自帶 `public static func main()`，所以這個型別與 `AppDelegate` 都不必公開——
```

四行命中裡，兩行是**中文文件註解**提到「public」這個詞（描述設計意圖／`App` 協定行為，不是宣告本身），兩行是實際宣告：`public enum MirageEntry` 與其內的 `public static func main()`。**`MirageShell` 的 public 表面積是一個型別、一個函式**，其餘 23 個檔案（含 `MirageScene`、`AppModel` 及其 4 個 extension、`AppDelegate`、`KeymapController`、`AdbClient`、`GameDetector`、`MenuBarController`、`MouseCapture`、`Audio/AudioPlayer` 等）全部維持 `internal`，與設計文件 §3.1「其餘 21 檔的可見度一行都不改」的承諾一致。

（23 與 21 這兩個數字看似矛盾，其實量的是不同東西，說清楚：重構前 `Sources/MirageApp/` 共 21 個檔案（`git ls-tree` 於分支起點 `36ea24d` 覆核屬實），其中 1 個是 `MirageApp.swift`（同時裝著 `MirageScene`／`AppModel`／`AppDelegate` 三者）。`Sources/MirageShell/` 現有 24 個檔案 = 20 檔從那 21 檔中原封搬入（即扣掉 `MirageApp.swift` 後的剩餘檔案，可見度一行未改）+ `MirageApp.swift` 拆出的 3 檔（`MirageScene`／`AppModel`／`AppDelegate`，皆維持 `internal`，只是可見度沒變、檔案數變了）+ 新增的 `MirageEntry.swift`（唯一 `public`）。24 檔中扣掉 1 個 public，剩 23 個 internal——這是本節「23 個檔案」的來源。設計文件 §3.1「其餘 21 檔的可見度一行都不改」用的分母是原始 21 檔本身，與本節「23 個目前是 internal 的檔案」分母不同（後者已經把 1 檔拆 3 檔、又新增 1 檔算進去），兩個數字都各自成立，並非落差或錯誤，只是計算基準不同。）

---

## 覆蓋率的兩段數字

`./scripts/coverage.sh`（本次實跑，非引用）：

| 段 | TOTAL line | 說明 |
|---|---|---|
| 段 1：`MirageCore`（判定用） | **87.80%**（1238 行，151 未覆蓋） | 與 `RESULTS-mmap.md` 驗收線 4 記載的重構前基準**完全相同，差異為 0**——本階段沒有動 `MirageCore` 任何一行程式碼，兩個既有 100% 覆蓋的檔案（`ViewportFit.swift`、`AudioRingBuffer.swift`）即使被新的 `MirageShellTests` 額外呼叫，也無法再往上加（已經頂滿），故數字文風不動 |
| 段 2：`MirageShell`（進度指標） | **2.62%**（1336 行中 1301 未覆蓋） | 23 個檔案裡只有 `Audio/AudioPlayer.swift`（11.86%）與 `MirrorContainerView.swift`（43.08%）非零——正是 Task 4 三個 smoke test 直接觸及的 `AudioPlayer.setMuted` 與 `MirrorContainerView.layout()`；其餘 21 個檔案全部 0.00% |

**段 2 很低不是退步，是這筆債終於看得見了。** 這批 App 層程式碼的覆蓋率一直是 0——差別只在於：重構前它們住在 `executableTarget` 裡，`llvm-cov` 報告結構上根本不涵蓋這個 target（`RESULTS-p1e.md` 已明載「`Sources/MirageApp/` 不在此報告中」），所以「0%」這個事實從未被任何報告顯示出來；現在 `MirageShell` 成為正式的 library target，同一份「0%」事實第一次出現在報表裡。**沒有任何一行程式碼因為本次重構而變得更差**，只是原本看不見的債務現在被量出來了。

（數字上的一個澄清，避免兩種不同的「行數」被誤當同一件事：段 2 TOTAL 的 1336 行是 `llvm-cov` 可插樁行（分母，見上表）；`Sources/MirageShell/` 的實體行數（`find ... | xargs cat | wc -l`）另外量測是 **1684**——這是本次重新驗證的數字，比設計文件 §1 寫的 1668 略高（拆檔＋新增 `MirageEntry.swift`／`AppDelegate.swift` 過程中新增的註解與空行所致）。可插樁行與實體行本來就是兩種不同的量測，不應並列成一個範圍。）

### 一個必須修正的數字：spec 估計偏高，實測是 43.59%

`docs/specs/2026-07-27-app-layer-library-target-design.md` §4 預估「合併 TOTAL 會掉到大約 **50–60%**」。**本次自行重新驗證：這個估計偏高，實測是 43.59%。**

驗證方式：拿本次 `coverage.sh` 跑出的合併後 `.profdata`（`/tmp/mirage_coverage_merged.profdata`，本次執行覆蓋產生，非沿用舊檔），用**分段前（Task 5 之前）的舊過濾式** `-ignore-filename-regex 'Generated|Tests|\.build'`（不排除 `MirageShell`，讓 `MirageCore` 與 `MirageShell` 混在同一張表）跑 `llvm-cov report`：

```
$ TEST_BIN=".build/debug/MiragePackageTests.xctest/Contents/MacOS/MiragePackageTests"
$ xcrun llvm-cov report "$TEST_BIN" -instr-profile /tmp/mirage_coverage_merged.profdata \
    -ignore-filename-regex 'Generated|Tests|\.build' | tail -3
...
TOTAL    998    526    47.29%    438    258    41.10%    2574    1452    43.59%    0    0    -
```

**TOTAL line coverage = 43.59%**，與 progress.md 記載「Task 5 審查期間量到 43.59%」的數字完全一致——但本次是**我自己用當前 HEAD 重新產生的 profdata 重新跑出來的**，不是沿用舊檔案（雖然剛好數字相同，因為 `MirageCore`／`MirageShell` 的程式碼與測試在 Task 5→Task 6 之間沒有任何變動）。

**43.59% 遠低於 spec 估計的 50–60% 下限**，差距超過 6 個百分點。這正是本文件存在的意義：**不因為 spec 寫了估計值就照抄，量到多少就寫多少**。所幸這個數字不影響任何判定——spec §4 與本文件都明確指出「合併的 TOTAL 不再作為判定依據」，驗收線 4 判的是段 1（`MirageCore`）有沒有低於基準，43.59% 只是一個「如果有人不小心看了合併數字會被嚇到」的參考數字，如實記錄以避免未來被誤判為回歸。

---

## 這筆債的來歷

「App 層無法被測試 import」這筆架構債跨三個階段被記錄，每次都以同一句話結案：

- **P1-c 交接**：「真實觸點落點精度 pending-human；overlay 拖放存檔、look 手感、⌘E 即時行為 pending-human」——`KeymapController`／`MouseCapture` 等只能讀碼＋型別系統驗證。
- **P1-d 交接**：「完整 app-path（KeymapController+NSEvent）與真遊戲手感 pending-human」——`GameDetector`／`AdbClient` 同樣無法單元測試。
- **P1-e 終審**：明確寫出根因——「`MirageApp` 是 `executableTarget`，唯一測試 target 只依賴 `MirageCore`，**無法 import `MirageApp`**」，並在「未做，與理由」一節說「抽 App 層 library target……是架構重構而非缺陷修正……不適合夾帶在 fast-follow 裡」，把它列為獨立待辦。

**本階段（Task 1–6）把這個獨立待辦做掉了——但刻意只開路，不鋪路。** 設計文件 §1「非目標」明講：「不補齊測試。本階段只『開路』——把 target 邊界打通並用少量 smoke test 證明這條路真的通。實際為各元件補測試是**另一輪**的事。」段 2 的 2.62% 正是這個範圍決策的直接量化結果：路通了（`@testable import` 證實可行，見驗收線 2），但補測試的工作量（21 個仍是 0% 的檔案）留給下一輪。

---

## 一筆新的耦合：`MirageCoreTests` 與 `MirageShellTests` 共用同一個 xctest bundle

`Package.swift` 新增的 `MirageShellTests` 是獨立的 `.testTarget`，但 SwiftPM 在 macOS 上會把同一個 package 裡的全部 `.testTarget` 打進同一個 `MiragePackageTests.xctest`（`swift test` 的實際執行單位）。這代表**跑 `MirageCoreTests` 的行程現在也會載入 AppKit／SwiftUI／Metal／AVFoundation**（`MirageShellTests` 的依賴帶進來的）——即使你只想跑 `MirageCore` 那一半的測試，同一個行程仍會連結、初始化這些框架。

本次實測 173/173 全綠、`coverage.sh` 兩次獨立 run 都過，經驗上已排除問題。但這是一個新的失敗面：往後 `MirageCoreTests` 的測試有可能因為 AppKit／WindowServer 相關的理由而紅（例如無 GUI session、螢幕鎖定等環境限制），即使問題與 `MirageCore` 本身的程式碼完全無關。留下這行是為了將來排查「`MirageCoreTests` 為什麼突然紅了」時不必繞這個彎。

（`MirageCore` 本身「不得 import AppKit/SwiftUI/Metal/AVFoundation」的約束**沒有**被違反——那是原始碼層的約束，`Sources/MirageCore` 一行都沒改；上述耦合純粹來自兩個測試 target 被 SwiftPM 打進同一個可執行 bundle。）

---

## 仍未被測試涵蓋的 App 層元件清單

依 `coverage.sh` 段 2 實測，以下檔案（`Sources/MirageShell/`）目前 line coverage 為 **0.00%**：

`AppDelegate.swift`、`AppModel.swift`、`AppModel+Audio.swift`、`AppModel+Focus.swift`、`AppModel+FullScreen.swift`、`AppModel+Install.swift`、`ConnectionBanner.swift`、`Detect/AdbClient.swift`、`Detect/GameDetector.swift`、`Install/InstallBanner.swift`、`Keymap/KeymapController.swift`、`Keymap/KeymapOverlay.swift`、`Keymap/MouseCapture.swift`、`Keymap/OverlayEditorView.swift`、`Lifecycle/AppLifecycle.swift`、`Lifecycle/ClipboardWatcher.swift`、`Lifecycle/MenuBarController.swift`、`MirageEntry.swift`（唯一 public 入口本身也是 0%——只被實際 App 啟動路徑執行，未被任何單元測試呼叫）、`MirageScene.swift`、`MirrorView.swift`、`Renderer.swift`。

另外兩個檔案是**部分**覆蓋（Task 4 smoke test 涵蓋到的那一小段邏輯）：`Audio/AudioPlayer.swift`（11.86%，只有 `setMuted` 狀態切換被測，`start()`/AVFoundation 實際音訊路徑未測）、`MirrorContainerView.swift`（43.08%，`layout()` letterbox 佈局被測，其餘未測）。

`Install/InstallState.swift`（`InstallItem`／`InstallState` 兩個純值型別）未出現在 `coverage.sh` 報表裡——這兩個型別只有儲存屬性與 enum case，沒有函式本體可供 `llvm-cov` 插樁計數，Task 4 的 `installStateFinishedCarriesItems` 測試確實觸及它們（見紅/綠證據），只是 llvm-cov 的報表格式不會為零可插樁區域的檔案生成一行。

### 刻意排除在 smoke test 之外的全域副作用清單

設計文件 §5 只點名了 `MouseCapture`，但這個分支同時讓下列全域副作用第一次變成「測試碼可以直接呼叫」——**單獨點名 `MouseCapture` 容易誤導人以為其餘檔案是安全的，實際上至少有四顆地雷**：

1. **游標**（`Keymap/MouseCapture.swift`）：`capture()` 呼叫 `CGAssociateMouseAndMouseCursorPosition(0)` 與 `NSCursor.hide()`——鎖定整台開發機的游標、隱藏游標。這是設計文件 §5 唯一明講的一項。
2. **剪貼簿**（`AppModel.swift:224-225`、`Lifecycle/ClipboardWatcher.swift:6`）：`applyGuestClipboard` 呼叫 `NSPasteboard.general.clearContents()` / `setString`，`ClipboardWatcher` 也直接綁 `NSPasteboard.general`——測試會**清掉開發者的真實剪貼簿**。
3. **選單列**（`Lifecycle/MenuBarController.swift:29`）：`NSStatusBar.system.statusItem(...)`——`AppModel.startLifecycle()` 一呼叫就會在**開發者真實的選單列插一個項目**，測試行程結束前不會消失。
4. **使用者 profile 檔案**（`AppModel.swift:33/81/131`、`MenuBarController.swift:101-103`）：`ProfileStore.standard()` 解析到 `~/Library/Application Support/Mirage/profiles`（`MirageCore/Keymap/ProfileStore.swift:16-18`，且會 `createDirectory`）——一個 `AppModel().saveProfile(p)` 的測試會**覆寫開發者真實的 keymap profile**。

連結（`import`）本身不會出事——`MirageShell` 沒有 load-time 副作用（無 `+load`、無全域初始化），全部要等到建構才觸發（`AppModel()`、`MenuBarController(...)`、`ClipboardWatcher(...)`）。**也正因如此這是個容易踩的陷阱**：測試檔 `@testable import MirageShell` 一切正常，直到某人寫下 `AppModel()` + `startLifecycle()`，或單獨建構 `MenuBarController`/`ClipboardWatcher`。

要安全地測任何一項，都得先設計注入點（例如把 `CGAssociateMouseAndMouseCursorPosition`／`NSCursor`／`NSPasteboard`／`NSStatusBar`／`ProfileStore` 包成可替換的協定，測試注入假實作）。這屬於「補測試」那一輪的工作，不在本階段「開路」範圍內——`coverage.sh` 顯示這些檔案 0.00% 是刻意決策的結果，不是遺漏。

---

## pending-human 清單

1. **驗收線 2 的紅/綠對照**：本次未重新執行「暫時破壞 `MirrorContainerView.layout()` 再還原」的過程（會短暫偏離目前 HEAD 的程式碼狀態），沿用 Task 4 report 記載的真實輸出作為證據。若需要在本次 HEAD 上重新做一次紅/綠對照，屬於可執行但本次判斷為不必要重複的驗證（三個 smoke test 本身已在本次重新確認全綠）。
2. **驗收線 6 的畫面正確性**：本機螢幕全程鎖定（`CGSSessionScreenIsLocked=true`），只驗證了「行程起得來且存活 ≥5 秒」，未驗證任何實際渲染畫面（letterbox 目視、keymap overlay、選單列……）。這與 `RESULTS-p1e.md`／`RESULTS-mmap.md` 記載的既有限制一致——本階段不改變任何 UI 行為，故沒有新增 UI 層的 pending-human 項目，但沿用既有的「需真 GUI session 解鎖後驗證」限制。
3. **App 層 21 個 0% 覆蓋檔案的正確性**：目前僅靠讀碼＋型別系統＋（部分元件的）既有活體驗證（如 `verify_keymap_inject.sh` 對鍵位注入引擎的活體佐證，但那驗的是 `MirageCore.KeymapEngine`，不是 App 層的 `KeymapController`）間接佐證，無單元測試直接驗證。這是本階段刻意選擇的範圍邊界（見上「這筆債的來歷」），非本階段的驗收缺口。
4. **`KeymapController`／`AppModel` 的輸出驗證仍卡在另一筆債上**：3 個 smoke test 證明的是 `@testable import` 這條**語言／建置層**的路通了，但要觀察 `KeymapController.handleKeyDown` 等輸入實際產生什麼觸點，目前只有兩條路——(a) 建真 NIO channel（`EmulatorClient.start()` 才會建立 `channelBox`，見 `EmulatorClient.swift:212`；`EmulatorClient+Input.swift:38` 在 `channelBox` 為 nil 時整個呼叫靜默 no-op），這正是既有的 NIO teardown 架構債、`swift test` 偶爾卡死的來源；(b) 新增一個本階段沒建的注入縫——`KeymapController` 吃的是具體型別 `EmulatorClient`（`KeymapController.swift:8`），不是協定，`EmulatorClient.init` 的 `makeTransport`/`makeAudioTransport` 等注入閉包參數是 `GrpcChannelBox`，而 box 只能由真 channel 產生，對 hermetic 測試無用。**這需要 `EmulatorClient` 的可注入 transport 縫，屬既有 NIO 架構債，不在本階段範圍。**「不補齊測試」是本階段明確的非目標，實作沒有違反範圍——但精確地說：門開了，房間裡有一半的家具（`KeymapController`／`AppModel` 的行為驗證）還鎖在另一把鎖上。

---

## 判定

**GO**：7 條驗收線全數 PASS，附真實輸出（測試 173/173、release 零警告、`MirageShell` 公開介面僅 `MirageEntry`、`MirageCore` 覆蓋率與基準差異為 0、App 行程存活驗證通過、兩檔行數遠低於 400 行門檻）。R1 風險已用專案外 spike 驗證成立，未走型別公開化的退路。段 2 的低覆蓋率是刻意的範圍決策（只開路不鋪路），非回歸；spec 對合併 TOTAL 的估計（50–60%）偏高，本次自行重新驗證實測為 43.59%，已在此如實記錄與更正。
