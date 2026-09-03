# D64 量測：人為主機負載下的渲染端掉幀，分辨回呼延後、上傳變慢、拿不到 drawable

- 日期：2026-09-03
- 狀態：任務簡報（交 codex 實作，PM 把關）
- 分支：`d64-draw-timing`
- 相關：D64（渲染端在主機負載下錯過 vsync）、D60（主機負載壓垮 guest 出幀）、`app/RESULTS-frame-counters.md`

## 1. 背景

`app/RESULTS-frame-counters.md` 跑次 2 第 5 輪：guest 58.89、arrived 60、但 presented 50、dropped 8，外來 CPU 183%。安靜窗口下同一條路徑是 60／60／0。所以渲染端在主機負載下會掉幀，但現在分不出是哪一種：

1. `MTKView` 的 display-link 回呼（`Renderer.draw`）被主執行緒上的其他工作或系統排程延後，兩次回呼之間出現遠大於 16.7ms 的空隙。
2. `draw` 本身變慢：7.2 MB 的 `texture.replace` 上傳或 encode／commit 在負載下超過一個 vsync 週期。
3. `view.currentDrawable` 拿不到（drawable 池被 GPU 或視窗合成器扣住），`draw` 走早退路徑，幀被 take 走卻沒 present。

三種的修法完全不同（1 是把渲染移出主執行緒、2 是換上傳方式、3 是 GPU／合成器端）。先量再動。

## 2. 目標（一句話）

`Renderer` 每秒多印一行 draw 時序統計，`verify_fps_fullscreen.sh` 逐輪解析，另有一支包裝腳本在人為 CPU 負載下跑它，一次實驗把三種形狀分開。

## 3. 範圍

### A. `MirageCore`：`DrawTimingWindow` 純值型別

累積一個窗口內的：
- `calls`：`draw` 被呼叫次數。
- `gapOver20ms`：兩次 `draw` 之間間隔超過 20ms 的次數（正常 vsync 是 16.7ms，20 給一點餘裕）。
- `maxGapMs`：窗口內最大間隔，整數毫秒。
- `inP95Ms`：`draw` 內部耗時（從進入到 `commit` 之後）的 p95，一位小數毫秒。
- `noDrawable`：`currentDrawable` 或 command buffer 拿不到而早退的次數。
- `noFrame`：`takeLatest` 回 nil（這個 vsync 沒有新幀）的次數。

提供 `record(interval:duration:outcome:)` 之類的累加介面與 `reset()`。p95 用排序取位就好，窗口內最多幾百筆。全部只用整數與 `Double`，不配置大物件。

### B. `MirageShell/Renderer.swift`

- `draw(in:)` 進入時記時間戳，算與上次的間隔；早退路徑要記 `noDrawable`（`texture` 為 nil 的早退不算，那是還沒有第一幀）；正常路徑在 `commit` 後記耗時。
- 只在 `MIRAGE_FPS_LOG=1` 時累加與印出，其他時候零成本（不記時間戳）。
- 每秒印一行，格式固定：`[app] draw calls=<N> gap20=<N> maxgap=<N>ms in_p95=<N.N>ms nodrawable=<N> noframe=<N>`。
- **印在既有 `[app] fps=` 與 `[app] frames` 同一個分支、緊接在後面**，維持三行一對一（`verify_fps_fullscreen.sh` 用 `fps_samples` 當跳過數，見 `countPresentedFrame` 的註解）。窗口與那兩行共用同一個 1 秒邊界。
- 注意：`countPresentedFrame` 只在有幀 present 時才被呼叫，但 draw 統計必須連「沒有新幀的 vsync」也計，所以累加要在 `draw` 一開始做，印出仍由既有的窗口邊界觸發。窗口邊界只在 present 時檢查這件事不用改，寫進註解即可。

### C. `app/scripts/lib/gui_session.sh`

- `frames_median` 已能解析 `[app] frames`。把它一般化成 `tagged_median <log> <tag> <欄位> [skip]`（tag 是 `frames` 或 `draw`），`frames_median` 改成薄包裝，既有呼叫端與自我測試不用改。欄位值容許小數與 `ms` 後綴（`in_p95=3.4ms`、`maxgap=41ms`），中位數印一位小數或整數都可以，但要一致。
- `gui_session_selftest.sh` 加 `draw` 行的案例：六個欄位、含 `ms` 後綴、跳過前 N 行、混入 draw 行後 `fps_median` 與 `frames_median` 仍正確、`fps_samples` 等於 draw 行數。

### D. `app/scripts/verify_fps_fullscreen.sh`

- 每一輪算 `gap20`、`maxgap`、`in_p95`、`nodrawable`、`noframe` 的中位數（同 `A`／`D`／`P` 的跳過邏輯），印一行 `   draw 時序：gap20=<N> maxgap=<N>ms in_p95=<N>ms nodrawable=<N> noframe=<N>`。
- 逐輪 `[round N]` 那一行**不動**（它已經夠長，而且有工具在解析），另印一行 `[round N draw] gap20=... maxgap=... in_p95=... nodrawable=... noframe=...`。
- 結尾摘要多印 `GAP20_MEDIAN=`、`MAXGAP_MEDIAN=`、`IN_P95_MEDIAN=`、`NODRAWABLE_MEDIAN=`。
- 判定邏輯與退出碼一律不動。

### E. 新增 `app/scripts/verify_fps_under_load.sh`：人為負載包裝

- 用法：`verify_fps_under_load.sh -n <burner 數> [其餘參數原樣傳給 verify_fps_fullscreen.sh]`。
- 啟動 N 個 CPU burner（`yes > /dev/null` 或等價，記錄 pid），`trap` 在 EXIT 與 INT 時全部殺掉並確認殺乾淨（`kill -0` 回檢），然後呼叫 `verify_fps_fullscreen.sh -l 99 "$@"`（抬高負載門檻，因為這次是故意加負載）。
- 開頭印一段醒目說明：這是診斷實驗，數字不作驗收線 7 的判定用；印出 burner 數與啟動前後的 `load_avg_1min`。
- 退出碼照傳 `verify_fps_fullscreen.sh` 的退出碼。
- `-n 0` 時不啟動 burner、也不抬門檻，行為與直接跑 `verify_fps_fullscreen.sh` 相同（對照組）。
- 用 `set -uo pipefail`，`source` 用絕對路徑（D55）。

### F. 測試

- `DrawTimingWindow` 的單元測試：間隔計數與最大值、p95 對 20 筆與 1 筆都對、`noDrawable`／`noFrame` 分開計、`reset` 清零。
- `gui_session_selftest.sh` 見 C，並用故障注入證明會紅（把 `tagged_median` 的 tag 比對改壞）。
- `verify_fps_under_load.sh`：沒有 emulator 時 `-n 2 -p 45999` 要在 `require_grpc` 紅之後把 burner 殺乾淨（用 `pgrep -f` 證明沒有殘留）；這條由你自己跑並貼輸出，它不需要 Swift。

### G. 結果文件 `app/RESULTS-d64.md`

改了什麼、測試清單、自我測試故障注入輸出、burner 清理的證明、沒驗的是什麼。活體數字由 PM 補寫。

## 4. 禁區

- 不改 `draw` 的控制流與任何渲染行為，只加計時與計數。
- 不改 `[app] fps=`、`[app] frames` 兩行與 `fps_median`／`frames_median` 的既有行為。
- 不改 `verify_fps_fullscreen.sh` 的判定、退出碼、`[round N]` 行。
- 不啟動 emulator、不執行 adb、不跑 `package_app.sh`、不跑 `swift build`／`swift test`。
- 不改債務表。

## 5. 驗收條件

1. `swift build --build-tests` 過；`swift test` 全綠（PM 跑）。
2. `bash app/scripts/ci.sh` 九道閘門全綠（PM 跑）。
3. 三行 `[app] fps=`／`[app] frames`／`[app] draw` 在 `Renderer.swift` 裡是同一個分支背靠背印出，`gui_session_selftest.sh` 有斷言鎖住三者行數相等。
4. `verify_fps_under_load.sh -n 2 -p 45999` 退出碼 1，且結束後 `pgrep -f` 找不到 burner。
5. `gui_session_selftest.sh` 有故障注入紅燈的輸出。

## 6. 工作方式

- 沙箱跑不了 `swift build`／`swift test`，不要嘗試；寫到能編的品質後 commit，PM 編譯回饋。`Renderer` 是 `@MainActor`，計時用 `CFAbsoluteTimeGetCurrent()` 或 `ContinuousClock`，照既有 `fpsWindowStart` 的寫法。
- 你能自己驗的：`swiftc -parse`、`bash -n`、直接跑 `gui_session_selftest.sh` 與 `verify_fps_under_load.sh -n 2 -p 45999`、閘門 4 的 grep。
- 測試先寫，再實作。每個部分一個 commit，訊息 `<type>: <描述>`，繁體中文。
- 註解與文件用繁體中文台灣用語，不用破折號接補充說明。
- bash：`set -uo pipefail`，`${rc}，` 不是 `$rc，`。
- 結束時把報告寫進 `app/RESULTS-d64.md`，最後一則訊息列出改動檔案、每條驗收條件的證據、沒做到的事。
