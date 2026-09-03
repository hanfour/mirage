# App 內幀計數：抵達／丟棄／present 與 guest fps 同窗口並列

- 日期：2026-09-03
- 狀態：任務簡報（交 codex 實作，PM 把關）
- 分支：`app-frame-counters`
- 相關：D48（fps 未達驗收線 7）、`app/RESULTS-d58.md`、`app/RESULTS-swift-pull.md`

## 1. 背景

驗收線 7（全螢幕 60fps，門檻 55）的損失來源今天已經排除兩段：傳輸（Python raw 58.98／MMAP 59.57）與 grpc-swift client（直拉不渲染 56.61）。Mirage 自己量到 43 到 54。剩下的候選只有兩個：

- (a) Mirage 行程內的消費端：`FramePump` 把幀 `put` 進 `LatestFrameBox`，`Renderer.draw` 每個 vsync `takeLatest` 一次。被覆蓋的幀 `LatestFrameBox` 已經在數（`dropped`），只是沒人印。
- (b) app 自己的 CPU／GPU 負載回頭壓 guest 出幀。D48 在真 GUI 下量到 guest 只有 49 到 57。

還有一個結構性嫌疑：單格 latest-wins 信箱面對約 58 fps 的抵達與 60 Hz 的消費會有拍頻，有的 vsync 收到兩幀丟一張、有的收到零幀沒東西畫。這種損失不需要任何一段「慢」就會出現。

現在 app 只印 present 的 `fps=`。缺的是同一個窗口裡的抵達數與丟棄數。有了這三個數，加上 `verify_fps_fullscreen.sh` 已逐輪對齊的 guest fps，一次活體就能把 (a)、(b) 與拍頻分開。

## 2. 目標（一句話）

`MIRAGE_FPS_LOG=1` 時 app 每秒多印一行 `[app] frames arrived=N dropped=N presented=N`，`verify_fps_fullscreen.sh` 逐輪解析並與 guest fps、Mirage fps、對照組並列印出。只加計數與 log，不改任何行為。

## 3. 範圍

### A. `MirageCore/LatestFrameBox.swift`：加 `arrived` 計數

- `put` 收到有效幀時 `arrived += 1`（無效幀只算 `rejected`，不算 `arrived`）。
- 提供讀取三個計數的方法。既有的 `stats()` 有呼叫端（先 grep `stats()` 找出全部），改動後所有既有呼叫端不用改一個字就能編譯。做法自選：擴充成具名 tuple 加一個欄位，或新增一個回傳 struct 的方法。
- 語意不變：仍是單格 latest-wins。本任務不修任何東西，只量。

### B. `MirageShell/Renderer.swift`：每秒印一行計數

- 只在 `MIRAGE_FPS_LOG=1` 時印，格式固定：`[app] frames arrived=<N> dropped=<N> presented=<N>`，三個數都是這一秒窗口內的增量（不是累計）。
- `arrived`、`dropped` 來自 `LatestFrameBox` 兩次快照的差；`presented` 是 `countPresentedFrame` 同一窗口的計數。
- 既有的 `[app] fps=<N>` 那一行**一個位元組都不能變**：`app/scripts/lib/gui_session.sh` 的 `fps_median`／`fps_samples` 用 `grep 'fps='` 抓它，新行不可含 `fps=` 字樣。
- 增量計算抽成一個純值型別（例如 `FrameCounterWindow`），放在 `MirageShell` 或 `MirageCore` 都可以，要能在沒有 Metal 的單元測試裡驗。`Renderer` 只負責取快照與印字。

### C. `app/scripts/lib/gui_session.sh`：解析 `[app] frames` 行

- 新增 `frames_median <log> <欄位> [跳過前 N 行]`：取 log 裡 `[app] frames` 行的指定欄位（`arrived`／`dropped`／`presented`）算中位數，整數。`跳過前 N 行` 讓呼叫端把量測窗口之前的行排除，與既有 `fps_samples`／`BEFORE` 的用法對齊。
- 新增 `frames_samples <log>`：`[app] frames` 行數。
- 新增 `app/scripts/lib/gui_session_selftest.sh`：用寫死的假 log 驗 `frames_median` 三個欄位、跳過前 N 行、沒有樣本時印 0、以及 `fps_median` 對「同一份 log 裡混有 `[app] frames` 行」仍算對（這條是防護：確認新行沒污染舊解析）。`ci.sh` 閘門 7 加進去跑，比照既有四支自我測試的寫法。

### D. `app/scripts/verify_fps_fullscreen.sh`：逐輪並列

- 每一輪在既有 `M=$(fps_median "$LOG")` 旁邊，用同一個窗口（同樣的「跳過量測前的行」邏輯）算出 `A`（arrived）、`D`（dropped）、`P`（presented）三個中位數。
- 逐輪那行改成 `[round N] guest=<G> arrived=<A> presented=<P> dropped=<D> mirage=<M> baseline=<B> ratio=<R>%`。既有欄位的名字與順序不要動，新欄位插在 `guest` 與 `mirage` 之間。
- 結尾摘要多印 `ARRIVED_MEDIAN=`、`DROPPED_MEDIAN=`、`PRESENTED_MEDIAN=`（跨有效輪次的中位數，沒樣本印空字串，比照 `MIRAGE_MEDIAN`）。
- 驗收判定邏輯（`GUEST_MIN`、`assert_at_least`、跨越門檻的警告）一律不動。這支腳本是驗收線 7 的判準，本任務只加診斷欄位。

### E. 測試

- `LatestFrameBoxTests`：`arrived` 隨有效 `put` 遞增、無效幀不遞增、`takeLatest` 不影響 `arrived`、`dropped` 語意不變。
- `FrameCounterWindow`（或你取的名字）的單元測試：給兩次快照與 presented 計數，輸出的三個增量正確；快照倒退（理論上不會，但要防）不會印負數。
- `gui_session_selftest.sh` 見 C，並用故障注入證明它會紅（改壞 `frames_median` 的欄位比對，貼輸出）。
- `verify_fps_fullscreen.sh` 沒有 emulator 跑不了，只做 `bash -n` 與 `bash app/scripts/ci.sh` 閘門 4 的裸變數檢查。

### F. 結果文件 `app/RESULTS-frame-counters.md`

寫下：改了什麼、既有 `stats()` 呼叫端清單與確認方式、測試清單、故障注入輸出、沒驗的是什麼。活體數字由 PM 補寫。

## 4. 禁區

- 不改 `LatestFrameBox` 的 put／take 語意，不改 `FramePump`、任何 transport、`EmulatorClient`。
- 不改 `[app] fps=` 那一行，不改 `fps_median`／`fps_samples`／`fps_average`。
- 不改 `verify_fps_fullscreen.sh` 的判定邏輯與退出碼。
- 不啟動 emulator、不執行 adb、不跑 `package_app.sh`。
- 不改債務表。

## 5. 驗收條件

1. `swift build --build-tests` 過；`swift test` 全綠（由 PM 跑）。
2. `bash app/scripts/ci.sh` 九道閘門全綠，閘門 7 多跑 `gui_session_selftest.sh`（由 PM 跑）。
3. `git diff main..HEAD -- app/Sources/MirageShell/Renderer.swift` 裡 `"[app] fps="` 那個字串沒有被動到。
4. `gui_session_selftest.sh` 有一份故障注入輸出證明會紅。
5. 既有 `stats()` 呼叫端全部列在結果文件裡，且都沒有改。

## 6. 工作方式

- 你的沙箱跑不了 `swift build`／`swift test`，不要嘗試。寫到能編的品質後 commit，PM 編譯回饋。strict concurrency 照 `MirageCore` 既有寫法；`Renderer` 是 `@MainActor`，新型別若被它持有要能在 main actor 用。
- 你能自己驗的：`swiftc -parse`、`bash -n`、直接執行 `gui_session_selftest.sh`（它不需要 Swift 也不需要 emulator）、閘門 4 的 grep。
- 測試先寫，再實作。每個部分一個 commit，訊息 `<type>: <描述>`，繁體中文。
- 註解與文件用繁體中文台灣用語，不用破折號接補充說明。
- bash：`set -uo pipefail`，`${rc}，` 不是 `$rc，`。
- 結束時把報告寫進 `app/RESULTS-frame-counters.md`，最後一則訊息列出改動檔案、每條驗收條件的證據、沒做到的事。

## 7. 把關退回的修正清單（第二輪，2026-09-03）

第一輪交付：PM 編譯一次過、327 條 Swift 測試綠、ci.sh 九道閘門綠（含新的第五支自我測試）、故障注入（欄位比對改壞、亂序輸入）都如預期。獨立審查對 diff 沒有擋合併的問題。但活體跑 `verify_fps_fullscreen.sh` 時三輪九次啟動全部停在 888×1972 沒進全螢幕，PM 追到原因，連同審查的四點文件補強一起退回。

### 7.1 `verify_fps_fullscreen.sh` 的 `AXFullScreen` 送太早，且不重送

實測（PM 手動重現）：`gui_session_start` 在 +7.3 秒回來，視窗在 AX 出現是 +7.8 秒，腳本卻在回來的瞬間就送 `set value of attribute "AXFullScreen"`，System Events 回 `無法取得「window 1 of process "MirageApp"」（-1719）`，被 `> /dev/null 2>&1` 吃掉；之後的 10 秒輪詢只看 `attachStream` 尺寸、不重送，於是每次都停在視窗模式的 888×1972。視窗出現後再送，1.5 秒內就收斂到 898。

修法（第 297 行附近，每次啟動嘗試內）：
- 先輪詢「`count of windows of process "MirageApp"` ≥ 1」，每 0.5 秒一次，最多 `FULLSCREEN_WINDOW_TIMEOUT`（預設 15）秒；等不到就把這次啟動判為失敗，走既有的關掉重開路徑，並印出「視窗 N 秒內未在 AX 出現」。
- 視窗出現後送 `AXFullScreen`，**不要吃掉 stderr**：失敗訊息印到 stdout 加前綴，方便下次追。
- 既有的 10 秒 `attachStream` 輪詢保留，但每 2 秒讀一次 `AXFullScreen` 的值，若不是 `true` 就重送一次（最多 3 次）。
- 這些數字都用變數，放在既有的 `FULLSCREEN_POLL_TIMEOUT` 旁邊，註解說明 +7.3／+7.8／+9.3 這三個實測時間點。

### 7.2 審查要求的四點文件與防護（不改行為）

1. `Renderer.countPresentedFrame`：在兩個 `print` 上方加註解，明講 `[app] fps=` 與 `[app] frames` 必須在同一個分支背靠背印、一對一，因為 `verify_fps_fullscreen.sh` 拿 `fps_samples` 的數當 `frames_median` 的跳過數。
2. `gui_session_selftest.sh`：加一條斷言，對同一份混合 log 檢查 `fps_samples` 等於 `frames_samples`，鎖住上面那個一對一假設。
3. `verify_fps_fullscreen.sh` 在算 `A`／`D`／`P` 那幾行上方加註解：`mirage=M` 的取樣母體含全螢幕收斂期（`fps_median` 沒有跳過參數，這是既有行為，本任務不動判定），`arrived`／`dropped`／`presented` 只含量測窗口，兩者不是同一個窗口，逐輪不能直接相減。
4. `app/RESULTS-frame-counters.md` 加一節「讀數的三個限制」：`presented` 是窗口原始計數、`fps=` 是除以 elapsed 後四捨五入，抵達不規律時可差超過 1；`arrived - dropped >= presented`，等號不保證成立，因為 `takeLatest` 之後 `draw` 早退遺失的幀不進任何計數；`M` 與新三欄母體不同（同第 3 點）。

### 工作方式（第二輪）

同一分支接著做，7.1 與 7.2 各一個 commit。你能自己驗的：`bash -n`、直接跑 `gui_session_selftest.sh`、`swiftc -parse`。不要跑 `swift build`／`swift test`／emulator。PM 的活體數字由 PM 補寫。
