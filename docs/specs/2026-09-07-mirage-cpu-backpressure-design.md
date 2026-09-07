# Mirage 對 guest 的回壓：同窗口交錯「Mirage 渲染」與「直拉不渲染」的 guest fps 差

- 日期：2026-09-07
- 狀態：任務簡報（交 codex 實作，PM 把關）
- 分支：`mirage-cpu-backpressure`
- 相關：D60（主機負載壓垮 guest 出幀）、D64（降 P3）、`app/RESULTS-d64.md`

## 1. 背景

驗收線 7（全螢幕 60fps，門檻 55）的損失來源已經全部切開：傳輸、grpc-swift client、渲染端在純 CPU 負載下都零損失。掉的全是 guest，而 guest 對主機外來 CPU 的敏感度是：外來 CPU 29% 時 59、90% 時 50、480% 時 34。

Mirage 自己在全螢幕 60fps 下約吃 50% 到 60% CPU。這些 CPU 有多少會回頭壓到 guest，沒人量過。這是 Mirage 對「使用者同時用機器也 ≥ 55」剩下的唯一槓桿。若回壓小於 2 fps，這條路關掉，殘餘全在 emulator 側（D60），變成產品決策；若明顯，下一步才是看 Mirage 的 CPU 花在哪。

## 2. 目標（一句話）

一支腳本在同一台 emulator、同一份畫面上交錯量三種條件下的 guest fps 與主機 CPU，印出每種條件的中位數與相對「無 client」的差值。

## 3. 三種條件

| 條件 | 做什麼 | guest 收到的請求 | 主機上跑的東西 |
|---|---|---|---|
| `none` | 什麼都不接，只量 guest | 無 | 只有 qemu |
| `pull` | `mirage-pull` 拉 898×1996 raw RGBA 不渲染 | 同 Mirage | qemu＋grpc-swift 解碼 |
| `app` | Mirage 全螢幕渲染（照 `verify_fps_fullscreen.sh` 的啟動與收斂流程） | 同上 | qemu＋Mirage 完整鏈路 |

`pull` 與 `app` 對 guest 送的是同一種請求（`streamScreenshot` 898×1996），差別只有主機上多了 Metal 上傳與視窗合成。三者兩兩相減：`none − pull` 是「emulator 端編碼與送出」的成本，`pull − app` 是「Mirage 渲染」的成本，`none − app` 是總回壓。

## 4. 範圍

### A. 新增 `app/scripts/verify_guest_backpressure.sh`

- 用法：`verify_guest_backpressure.sh [-p 8556] [-s emulator-5556] [-r 3] [-d 20] [-c none,pull,app]`。預設三種條件都量、3 輪、每輪 20 秒。
- 前置：`require_grpc`、`require_device`、`PREFLIGHT_GUEST_MIN` 那段照 `verify_fps_fullscreen.sh`（guest 至少在動）、`build_warm release`（`mirage-pull` 與 `MirageApp` 兩個 product 都要暖，`build_warm` 已支援 product 參數）、venv 不需要（這支不用 Python）。
- 每一輪先過 `load_gate`（`LOAD_LIMIT` 預設 18，同驗收腳本），輪次內依序跑三種條件，順序每輪輪轉（第 i 輪從第 `(i-1) mod 3` 個條件開始），抵消順序效應與 guest 的熱身狀態。
- 每個條件的量測窗口：`guest_window_start` → 啟動 client（`none` 不啟動）→ 等 client 就緒（`pull` 等 3 秒；`app` 等視窗出現、送 `AXFullScreen`、等 `attachStream` 寬度 ≥ `FULLSCREEN_MIN_WIDTH`，這整段照抄 `verify_fps_fullscreen.sh` 第 300 到 380 行的邏輯，抽成函式放進 `app/scripts/lib/gui_session.sh` 讓兩支腳本共用，抽的時候 `verify_fps_fullscreen.sh` 行為不能變）→ **就緒後才** `guest_window_start`（重新清零，讓窗口不含啟動期）→ `cpu_snapshot` → `sleep $DURATION` → `cpu_snapshot` → `guest_window_end` → 關 client。
- 每個條件印一行：`[round N cond=<c>] guest=<fps> frames=<n> host_cpu_qemu=<pct> host_cpu_client=<pct> host_cpu_foreign=<pct>`。`host_cpu_*` 用 `cpu_delta_report` 從兩次快照算：qemu 是 `qemu-system`、client 是 `mirage-pull` 或 `MirageApp`（`none` 印 0）、foreign 是排除這三者與 `WindowServer` 之後的總和。
- `app` 條件的 Mirage 側 `fps=` 中位數也印出來（用 `fps_median`），確認 Mirage 真的在 present，不然量到的不是渲染的回壓。
- 有效性：`guest` 量不到（找不到 layer）或 `foreign > FOREIGN_MAX`（預設 60%）的樣本判無效並印理由，不計入中位數。這是 D60 的教訓：外來 CPU 會把三種條件一起拉低，讓差值失真。
- 結尾摘要：每種條件的中位數與有效輪數、`DELTA_NONE_PULL=`、`DELTA_PULL_APP=`、`DELTA_NONE_APP=`（fps，一位小數），以及每種條件的 `host_cpu_qemu` 中位數。
- 斷言：每種被要求的條件至少 `MIN_VALID`（預設 2）個有效樣本，否則退出碼 1。不對差值下判定，判定是人的事。
- `source` 路徑在 `cd` 之前解析成絕對路徑（D55）；`set -uo pipefail`；空陣列展開前判 `${#ARR[@]}`（D66）；不用 `seq 1 0`。

### B. `app/scripts/lib/gui_session.sh`

- 抽出 `gui_session_fullscreen <log> <bundle> <min_width>`：從「視窗出現輪詢」到「`attachStream` 寬度收斂」的整段，回傳 0 表示收斂、1 表示沒收斂（呼叫端自己決定要不要重開）。既有的 `FULLSCREEN_*` 變數改成函式內 `${VAR:-預設}` 讀取，預設值不變。
- `verify_fps_fullscreen.sh` 改成呼叫這個函式，逐行對照改前改後的輸出訊息要一致（同樣的「視窗 N 秒內未在 AX 出現」等字串）。
- `gui_session_selftest.sh` 不用動（這個函式需要 GUI，自我測試驗不了），但要在結果文件寫明它沒被自我測試涵蓋。

### C. 測試

- `app/scripts/lib/backpressure_selftest.sh`：把「三條件輪轉順序」與「摘要差值計算」抽成純函式（例如 `rotate_conditions <round> <list>` 印該輪順序、`median_delta <valsA> <valsB>` 印差值），用寫死的輸入驗：3 輪的順序分別是 `none,pull,app`／`pull,app,none`／`app,none,pull`；`-c none,app` 兩條件時順序輪轉正確；差值對空樣本印「無資料」；`FOREIGN_MAX` 判無效的分流。進 `ci.sh` 閘門 7。
- 故障注入：把 `rotate_conditions` 的 mod 改壞，自我測試要紅，貼輸出。
- 沒有 emulator 時 `verify_guest_backpressure.sh -p 45999` 在 `require_grpc` 紅（退出碼 1），貼輸出。

### D. 結果文件 `app/RESULTS-backpressure.md`

改了什麼、`verify_fps_fullscreen.sh` 抽函式前後輸出一致的證明方式、自我測試與故障注入輸出、沒驗的是什麼。活體數字由 PM 補寫。

## 5. 禁區

- 不改 `app/Sources/` 任何檔案。
- 不改 `verify_fps_fullscreen.sh` 的判定、退出碼、`[round N]` 行、`[round N draw]` 行。抽函式只能搬邏輯，不能改行為。
- 不改 `mirage-pull`、`fps_baseline.py`。
- 不啟動 emulator、不執行 adb、不跑 `package_app.sh`、不跑 `swift build`／`swift test`。
- 不改債務表。

## 6. 驗收條件

1. `bash app/scripts/ci.sh` 九道閘門全綠，閘門 7 多一支自我測試（PM 跑）。
2. `verify_fps_fullscreen.sh` 抽函式後，PM 在 emulator 上跑一次，逐輪輸出格式與抽前相同。
3. `backpressure_selftest.sh` 有故障注入紅燈輸出。
4. `verify_guest_backpressure.sh -p 45999` 退出碼 1。
5. 用 `/bin/bash`（3.2）跑 `bash -n` 與自我測試都過。

## 7. 工作方式

- 沙箱跑不了 Swift 與 emulator；這一輪沒有 Swift 改動，所以你能自己驗的比前幾輪多：`bash -n`、自我測試、`/bin/bash` 3.2 實跑、閘門 4 的 grep。
- 測試先寫，再實作。每個部分一個 commit，訊息 `<type>: <描述>`，繁體中文。
- 註解與文件用繁體中文台灣用語，不用破折號接補充說明。
- 結束時把報告寫進 `app/RESULTS-backpressure.md`，最後一則訊息列出改動檔案、每條驗收條件的證據、沒做到的事。
