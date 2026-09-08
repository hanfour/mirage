# 驗收線 2：輸入延遲

日期：2026-09-08。狀態：Mirage 可控三段的活體量測完成，判定通過。
三次跑次共 9 輪、8 輪有效，合計 24.9 到 41.8ms，門檻 80ms。guest 反應段與 present 到上屏未量，見文末。

## 先前探測與舊數字

本次沒有重新探測 emulator。以下數字來自任務簡報
`docs/specs/2026-09-07-acceptance-2-input-latency-design.md` 第 1 節，並非本次實測：

- 舊紀錄約 110 到 119ms，將送出觸控到幀抵達 78.1ms 視為主要耗時。
- 簡報指出偵測門檻接近噪音、9/50 misses 被排除、觸控指示為漸入動畫，舊結論不成立。
- 簡報的新探測 n=40、misses=0：送出到 ack p50/p95 1.8/8.6ms，ack 到幀產生 95.4/154.7ms，傳輸 11.8/19.3ms，合計 110.3/170.1ms。
- 新判定只加總 Mirage 的輸入注入、傳輸、抵達到 present；上述 Python 數字不能代替 Mirage 三輪驗收。

## 活體量測（PM 執行，2026-09-08）

`/bin/bash app/scripts/verify_input_latency.sh -r 3`，三次跑次共 9 輪、8 輪有效。單位毫秒。

| 跑次 | 輪次 | inject p50 | transit p50 | render p50 | sum p50 | CPU floor 10 | CPU floor 0 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 1 | 2.7 | 10.7 | 12.1 | 25.5 | 29% | 129% |
| 1 | 2 | 4.1 | 11.0 | 26.7 | 41.8 | 17% | 81% |
| 1 | 3 | 2.9 | 10.7 | 25.1 | 38.7 | 44% | 90% |
| 2 | 1 | 0.9 | 10.4 | 20.5 | 31.8 | 24% | 83% |
| 2 | 2 | 無效 | 無效 | 無效 | 無效 | 55% | 116% |
| 2 | 3 | 0.6 | 10.1 | 18.5 | 29.2 | 44% | 96% |
| 3 | 1 | 1.8 | 10.7 | 12.4 | 24.9 | 37% | 87% |
| 3 | 2 | 3.4 | 10.8 | 10.9 | 25.1 | 12% | 73% |
| 3 | 3 | 1.7 | 10.8 | 24.4 | 36.9 | 20% | 90% |

每一輪 `invalid=0`、`unavailable=0`、`inject_n` 71 到 74、`transit_n` 1076 到 1176。

| 跑次 | 有效輪 | INJECT | TRANSIT | RENDER | SUM_MEDIAN | SUM_RANGE | 退出碼 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 3/3 | 2.9 | 10.7 | 25.1 | 38.7 | 25.5..41.8 | 0，印 PASS |
| 2 | 2/3 | 0.8 | 10.2 | 19.5 | 30.5 | 29.2..31.8 | 1，輪數不足 |
| 3 | 3/3 | 1.8 | 10.8 | 12.4 | 25.1 | 24.9..36.9 | 0，印 PASS |

### 判定

**驗收線 2 的 Mirage 可控三段通過。** 8 個有效輪的合計落在 24.9 到 41.8，門檻 80。
最大值離門檻還有將近一倍，量測變異不會跨越判準，這與驗收線 7 的情況不同
（那裡同一天量到 31 到 58 而門檻 55，尺判不動線）。

跑次 2 的退出碼是 1，原因是第 2 輪外來 CPU 55% 被閘門擋下、有效輪數 2 未達 3。
那不是量測值不合格，是主機負載閘門照設計運作。同跑次的兩個有效輪是 31.8 與 29.2。

三段的相對大小：渲染段（10.9 到 26.7）最大，傳輸段（10.1 到 11.0）非常穩定，
注入段（0.6 到 4.1）最小。渲染段的跨度來自主機負載，同一顆 build 在 CPU 12% 的輪次是 10.9，
在 44% 的輪次是 25.1。

### 量測條件

固定點擊為全螢幕視窗水平中央、由上往下 20% 處，換算到 guest 約 (540, 480)。
PM 實測對該座標送觸控後 1.5 秒，全畫面差異 3.1%，與另外兩個純背景座標（150,1500）與（900,1400）
相同；畫面仍在主選單、沒有進關卡。這個座標離關卡六邊形上緣約 12 個 guest 像素，遊戲進度改變時要重驗。

點擊以 `osascript -l JavaScript app/scripts/lib/cgclick.js` 送 CGEvent。
先前用 System Events 的 `click at` 完全無效：退出碼 0、有回傳座標，但 `[app] inject` 是 0 行，
因為 `click at` 走 AX 層，NSView 的 `mouseDown` 收不到。單獨對照實測 6 次點擊產生 0 個事件，
換成 CGEvent 後 8 次點擊產生 16 個事件（down 與 up 各一），與 `[app] inject` 的 n=5,5,4,2 完全對上。

量測期間以 `caffeinate -disu` 擋掉螢幕保護程式（本機 `com.apple.screensaver idleTime` 是 300 秒，
三輪約 4 到 6 分鐘會撞到）。這不改使用者設定，跑完即失效。

逐輪 p50 是每秒窗口 p50 的中位數，沿用共用解析函式；SUM_MEDIAN 是逐輪三段相加後的中位數，
不是同一次觸控完整路徑的 p50。
transit 統計在 Renderer present 時計入，因此樣本是實際 present 的幀；被替換而未 present 的幀不在這份統計內。

CPU 快照在 20 秒量測窗口起點與終點擷取。兩個值都排除 `qemu-system|MirageApp|WindowServer`，
WindowServer 合成 Mirage 畫面視為工作負載。判定採 floor 10、要求外來 CPU <50%，
與驗收線 7 的診斷尺度一致。驗收線 7 本身沒有比較 FOREIGN_TOTAL 的自動閘門，50% 是它的人工判讀紀律。
floor 0 只列額外資訊，包含每個低於 10% 的行程，實測比 floor 10 高 28 到 100 個百分點，
不能套用同一個 50% 判準。

每輪 CPU 輸出保存在 `result-N.log`，有效數字另存 `rounds.txt`，無效原因存 `rejected.txt`。

### 過程中遇到的環境問題

- 第一次三輪嘗試：`build_warm` 重編一個 target 後 load average 是 46.10（上限 18），
  三輪在一秒內接連被 `load_gate` 擋掉。已加重試（6 次、每次 5 秒）與建置後最多 60 秒的等待。
- 第二次三輪嘗試：`require_grpc` 報 `gRPC 8556 無回應`。emulator 行程整個消失，
  `adb devices` 為空，沒有留下 crash report，磁碟仍有 12Gi。同一時段本機出現過記憶體壓力
  （背景等待被系統以記憶體不足停掉兩次）。以
  `emulator -avd mirage-game -port 5556 -grpc 8556 -gpu host` 重開並重新啟動 Pixel Flow 後恢復。
  這次失敗是紅燈不是假數字，`require_grpc` 有擋住。

## 六條故障注入

使用合成日誌，直接執行活體腳本所呼叫的相同解析與斷言函式；沒有啟動 GUI、建置 Swift 或送觸控。
整套指令：`/bin/bash app/scripts/lib/input_latency_selftest.sh`，實際退出碼 0。
個別重現指令與實際紅燈輸出如下。每一支個別指令退出碼皆為 1。

```text
$ /bin/bash app/scripts/lib/input_latency_selftest.sh --fault inject
FAIL: inject_n=20 must be >=30

$ /bin/bash app/scripts/lib/input_latency_selftest.sh --fault transit
FAIL: transit_n=580 must be >=600

$ /bin/bash app/scripts/lib/input_latency_selftest.sh --fault invalid
FAIL: invalid=20; clock assumption failed

$ /bin/bash app/scripts/lib/input_latency_selftest.sh --fault unavailable
FAIL: unavailable=20; MMAP cannot measure transit

$ /bin/bash app/scripts/lib/input_latency_selftest.sh --fault cpu
FAIL: foreign CPU must be <50%, got 50

$ /bin/bash app/scripts/lib/input_latency_selftest.sh --fault sum
[round 1] inject_p50=2 transit_p50=80 render_p50=15.0 sum_p50=97.0 inject_n=80 transit_n=800 invalid=0 unavailable=0
INJECT_MEDIAN=2.0
TRANSIT_MEDIAN=80.0
RENDER_MEDIAN=15.0
SUM_MEDIAN=97.0
SUM_RANGE=97.0..97.0
FAIL: SUM_MEDIAN must be <80ms; largest segment=transit
```

自我測試另涵蓋空日誌、缺欄位、MMAP 全 nil、前置行略過、三輪摘要、恰好 80ms 拒絕、六個各 9% 的外來行程合計 54%。這些都是合成資料，不能當成活體結果。

### 本輪補強證據

重新執行自我測試退出碼 0，六條個別故障仍各退出 1。新增 A 與 B 的實際合成輸出節錄：

```text
[round 1] foreign_cpu_floor10=0% foreign_cpu_floor0=54%
[round 2] INVALID; continuing
FAIL: invalid=20; clock assumption failed
[round 3] inject_p50=2 transit_p50=12 render_p50=15.0 sum_p50=29.0 inject_n=80 transit_n=800 invalid=0 unavailable=0
VALID_ROUNDS=2 REQUIRED_ROUNDS=3
INJECT_MEDIAN=2.0
TRANSIT_MEDIAN=12.0
RENDER_MEDIAN=15.0
SUM_MEDIAN=29.0
SUM_RANGE=29.0..29.0
FAIL: insufficient valid rounds
[round 2] INVALID
FAIL: invalid=20; clock assumption failed
input_latency selftest failures=0
```

測試斷言兩個 floor 都印出且依 floor 10 放行；第二輪無效後仍有第三輪結果，保留兩筆有效數字，
要求三筆時 `input_latency_finish` 退出 1，未印驗收通過。整套測試的 0 表示預期紅燈已被驗證。
Python 全套測試為 44 passed，補入 ack 前產生幀排除、負值整筆排除、不同觸控集合造成假綠燈的反例。
門檻敏感度現在只比較三門檻皆命中的觸控，並印出共同樣本數；各門檻另外印 negative 計數。

## PM 把關紀錄

- Swift 建置：三輪修正各編一次，皆 `Build complete!`（252.29s、25.86s、no-op）。
- `app/scripts/ci.sh`：三輪各跑一次，九道閘門全綠、退出碼 0，343 條 Swift 測試各跑三次、
  provision 95 條、`phase0/harness` pytest 44 條。
- 獨立審查 agent 讀全分支 diff，列出 9 條。其中 7 條採納（見上方 A 到 G），
  1 條經查為誤判（它說 `defer { timer?.cancel() }` 是死碼、`cont` 從不 `finish()`，
  但 `InputQueue.swift:100` 有 `deinit { cont.finish() }` 且 detached task 不捕捉 self），
  1 條指出的是簡報措辭不精確，由 PM 改簡報。
- PM 自己的故障注入：合成日誌驗 `tagged_median` 對 transit 與 inject 的解析（`ms` 後綴會剝掉、
  未白名單欄位回 0）；實測 floor 0 與 floor 10 在同一時刻差 28 到 100 個百分點。
- `phase0/harness/e2e_latency.py` 活體實跑：`misses=0`、`negative=0`，門檻 20／100／400
  下 `ack_to_generated` p50 為 16.5／15.8／19.9ms，存活者偏誤在門檻 800 時正確標為「不可引用」。

## 未量項

- guest 反應段不列入驗收判定。它可以量（同日實測 16 到 20ms），但對偵測門檻的選擇敏感，
  門檻覆蓋率超過約 20% 就會量成「觸控指示淡入到哪個程度」。
- present 到 Mac 上屏未量，需高速攝影設備，不加入 80ms 合計。
- 三個環境變數關閉時 `verify_fps_fullscreen.sh` 的判定與數值是否完全相同，未逐項比對；
  已確認它讀的兩個錨點（`fps=` 與 `^[app] lat`）未被改動，且該腳本原始碼一個字沒改。
- 量測期間 guest 的 `show_touches` 與 `pointer_location` 都是關的，
  只有 `e2e_latency.py` 的工具驗證短暫開啟過，結束時已關回 0。

## 第三輪 H、I 修正與證據

PM 提供的修正前活體輸出為 `[app] transit p50=10.8ms p95=14.1ms n=55 invalid=0 unavailable=0`、`[app] lat p50=24.7ms p95=27.9ms n=55`，全螢幕 898x1995、fps 55 到 60。B 正確印出 `[round N] INVALID; continuing`、`VALID_ROUNDS=0 REQUIRED_ROUNDS=3` 與 `FAIL: insufficient valid rounds`，沒有 PASS；D65 螢幕鎖定檢查正確擋下並說明原因。

H：PM 對照測試中 AX `click at` 退出 0 卻沒有 inject。改以 `lib/cgclick.js` 接受 x、y、次數、間隔秒，透過 CGEvent 送事件；System Events 只讀視窗座標並置前。PM 已驗證此 CGEvent 做法 8 次點擊產生 16 個事件，inject 的 n=5,5,4,2 合計 16。這是替代做法的實測，尚非本輪整合腳本的三輪結果。

I：每輪沿用 fullscreen 腳本形狀，最多檢查 6 次，每次擋下等 5 秒，耗盡才判該輪無效，訊息格式一致。建置後先以 5 秒間隔等負載通過，上限 60 秒，印實際耗時；逾時仍交由每輪重試判定，沒有放寬有效輪數或負載門檻。

本輪 `/bin/bash app/scripts/lib/input_latency_selftest.sh` 退出 0。JXA 測試使用模擬 CGEvent，驗證座標、事件順序、8 次點擊共 16 個事件、0.03 秒按壓及參數化間隔。缺參數、非數值、非有限值、非法次數與負間隔皆拒絕；另外直接執行正式 JXA 的無效參數案例，確認退出非 0，驗證在載入 CoreGraphics 之前完成，未送任何 GUI 事件。

負載測試替換 load_gate 與 sleep，涵蓋立即通過、第三次與最後一次通過、6 次耗盡後有效輪數為 0 且不印 PASS，以及建置後立即通過、等 10 秒通過、12 秒上限截短最後一次等待並逾時。六條原故障注入仍各退出 1。

第三輪七支共用 shell 自我測試全部退出 0，輸出保存在 `/tmp/<檔名>.acceptance2-third.log`；改動 shell 語法檢查、正式腳本 `-h` 與 `git diff --check` 皆退出 0。未跑 GUI 活體，未 commit。
