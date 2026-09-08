# 驗收線 4：關視窗要休眠而不是退出，並量喚醒到第一幀

- 日期：2026-09-08
- 狀態：任務簡報（交 codex 實作，PM 把關）
- 分支：`acceptance-4-wake`
- 相關：母計畫 §5「點開即用」、`docs/specs/2026-07-28-mirror-never-rendered-investigation.md` §13、D60

## 1. 產品決策（使用者 2026-09-08 定）

「點開即用」允許背景常駐 emulator。冷啟動的 32.8 秒視為首次安裝的一次性成本，
不列入日常驗收；日常驗收判的是喚醒。驗收線 3 因此改寫，驗收線 4 成為這條路徑的判準。

## 2. 這條路徑現在是壞的

`AppLifecycle` 的設計是「關視窗回傳 false、隱藏視窗、呼叫 `client.suspend()`，
app 續存在選單列」，`MenuBarController` 也有「喚醒」與「顯示視窗」兩個項目。
2026-09-08 實測，這條路徑一步都沒有走到：

```
啟動後 app pid=44514，視窗數=1
--- 送 ⌘W ---
app 已退出（pid 44514 不在）
log 最後兩行：
[conn] connected --stopRequested--> disconnected
[conn] 串流錯誤：CancellationError()
```

`stopRequested` 只有 `AppModel.shutdown()` 會送，而它唯一的呼叫端是
`AppDelegate.applicationWillTerminate`。也就是關視窗直接走到退出，
`windowShouldClose` 的休眠分支沒有生效。

兩個候選根因，都要用實測分辨，不要讀碼推論：

1. `AppDelegate` 沒有實作 `applicationShouldTerminateAfterLastWindowClosed`，預設為 true，
   最後一個視窗關閉就終止行程。
2. `AppModel` 第 465 行用 `(NSApp as NSApplication?)?.windows.first?.delegate = self?.lifecycle`
   指派 delegate，包在一個只讓出一輪 run loop 的 `Task` 裡。那一輪不保證 `WindowGroup`
   的視窗已經建立，也不保證 `windows.first` 就是鏡像視窗。

`AppLifecycle` 目前在 `app/Tests` 底下沒有任何測試。

## 3. 目標（一句話）

關視窗改成休眠且 app 續存，並量到「從選單列喚醒到第一幀抵達」與
「app 未執行時啟動到第一幀抵達」兩個數字，判定前者低於 5 秒。

## 4. 已實測的關鍵事實（不要重新推導）

emulator 已在跑、Pixel Flow 在主選單、打包不計入計時的條件下，`open -a` 到各階段：

| 跑次 | app 第一行輸出 | 連上 emulator | 第一幀抵達 | 第一個 `fps=` 窗口 |
| --- | --- | --- | --- | --- |
| 1（冷） | 3.52s | 4.45s | 5.75s | 6.82s |
| 2 | 1.89s | 2.79s | 3.70s | 4.89s |
| 3 | 2.13s | 3.17s | 4.18s | 5.47s |

- 最大的一段是「行程啟動到第一行輸出」1.89 到 3.52 秒。
- 「第一幀抵達」3.70 到 5.75 秒，**變異跨越 5 秒門檻**，n=3 判不了，需要更多樣本。
- `gui_session_start` 內含寫死的 `sleep 6`，量啟動時間不能用它，要自己 `open -a` 再輪詢 log。
- suspend 本身是有效的：關視窗後 `[app] fps=` 行停止增加（實測 4→5→5、5→5→5）。
  壞掉的是 app 沒有續存。

## 5. 範圍

### A. 修「關視窗會退出」

- 先重現並用實測分辨第 2 節的兩個候選根因（例如在 `windowShouldClose` 與
  `applicationShouldTerminateAfterLastWindowClosed` 各加一行 `MIRAGE_CONN_LOG` 的診斷輸出，
  看哪一個被呼叫、delegate 是不是 nil）。把分辨過程與結論寫進報告。
- 依實測結果修。可能兩個都要改：實作
  `applicationShouldTerminateAfterLastWindowClosed` 回傳 false，並讓 delegate 指派
  可靠地掛到鏡像視窗（例如改用 `NSApplication.didFinishLaunchingNotification` 之後
  以視窗識別條件挑，或由 `MirrorView.viewDidMoveToWindow` 反向掛上）。
- ⌘Q 的退出路徑必須維持現狀：`applicationWillTerminate` 仍要跑
  `shutdown()` 與 `audioPlayer?.stop()`。修完之後 ⌘Q 仍然要能乾淨退出。

### B. 喚醒路徑的可觀測性

- `EmulatorClient` 的 power 狀態目前沒有任何 log。在 `setPower` 加一行
  `MIRAGE_CONN_LOG=1` 時輸出 `[conn] power <舊>--><新>`，格式比照既有的
  `[conn] <state> --<event>--> <next>`。
- 這是唯一新增的輸出。不要動 `[app] fps=`、`[app] frames`、`[app] lat`、`[app] transit`、
  `[app] inject` 任何一行的格式或配對關係。

### C. `app/scripts/verify_wake.sh`

沿用 `verify_common.sh` 與 `gui_session.sh` 的既有共用函式。量兩條路徑，各自多輪：

1. **喚醒**：app 已在跑且已休眠 → 從選單列點「顯示視窗」→ 第一幀抵達。
2. **啟動**：app 未執行 → `open -a` → 第一幀抵達。打包在計時之外。

- 計時用外部輪詢 log（間隔 20ms），不要靠 `sleep` 估。
- 選單列的點擊用 System Events：
  `click menu bar item 1 of menu bar 2` 之後 `click menu item "顯示視窗" of menu 1 of ...`。
  ⌘W 用 `keystroke "w" using command down`，送之前要先確認 MirageApp 在前景。
- 逐輪印一行，含兩條路徑的秒數與該輪的外來 CPU（floor 10 與 floor 0，沿用
  `input_latency_cpu_window` 的形狀）。
- 硬斷言（任一條不成立就該輪判無效並繼續，全跑結束要求有效輪數達標）：
  1. 送 ⌘W 後 app 行程必須仍存活，否則直接紅並明講「關視窗退出了，A 沒修好」。
  2. 休眠後 `[app] fps=` 的行數必須停止增加（至少 3 秒內不變），否則 suspend 沒生效。
  3. 喚醒後必須出現新的 `[conn] 幀 #1`，逾時 10 秒判無效。
  4. 喚醒到第一幀的中位數低於 5 秒才算通過。
  5. 外來 CPU floor 10 低於 50%。
- 每條斷言都要故障注入證明會紅。

### D. 測試

- `AppLifecycle` 的可測部分抽成純函式（例如「該不該休眠」的判斷），加單元測試。
  NSWindow 相關的部分測不了就不要假裝測得了，在報告裡寫明哪些只有活體涵蓋。
- 既有測試一個字不改，必須照常通過。
- `ci.sh` 閘門 7 加入新的自我測試。

### E. 文件

- `app/RESULTS-wake.md`：兩條路徑的逐輪數字、中位數與跨度、故障注入證據、判定。
- 回寫 `docs/specs/2026-07-29-project-review.md`：驗收線 3 改成「首次安裝的一次性成本，
  不列入日常驗收」並註明產品決策；驗收線 4 依實測結果更新；
  「關視窗會退出 app」這個缺陷不論修不修得完都要記成一筆債。

## 6. 禁區

- 不要改 `EmulatorClient.suspend()` 與 `wake()` 的語意。`wake()` 刻意不 load 快照，
  理由寫在原始碼註解裡（在運行中的模擬器上 `loadSnapshot` 會使它崩潰）。
- 不要改 `verify_fps_fullscreen.sh` 與 `verify_input_latency.sh` 的行為。
- 不要動 `gui_session_start` 既有的 `sleep 6`，那是別的腳本在依賴的時序。
  量啟動時間自己 `open -a`。
- 新增的 log 只有 B 那一行，且要在 `MIRAGE_CONN_LOG=1` 之下。

## 7. 已知會踩的坑

- 裸變數緊接全形標點（`$PID，`）在 `set -u` 下會炸成未綁定變數。PM 寫探測腳本時當場又踩一次。
- zsh 沒有 `PIPESTATUS[0]`，腳本內用 bash 3.2 驗證。
- `#expect` 拿 Bool 跟 `true`／`false` 比永遠不紅。
- macOS 螢幕鎖定會讓 GUI 活體無聲失敗，`gui_session_start` 已有前置檢查；
  自己 `open -a` 的路徑要記得也檢查（`gui_screen_lock_state`）。
- 螢幕保護程式閒置 300 秒，長活體用 `caffeinate -disu` 包起來。
- 主機外來 CPU 的判定用 floor 10、門檻 50，與驗收線 2 和 7 同尺。

## 8. 驗收條件

1. `app/scripts/ci.sh` 九道閘門全綠。
2. `verify_wake.sh` 五條斷言各自故障注入證明會紅。
3. 關視窗後 app 續存、選單列可喚醒，且 ⌘Q 仍能乾淨退出，三者皆有活體證據。
4. 兩條路徑各至少三個有效輪，數字寫進 `app/RESULTS-wake.md`。
5. 報告只寫量到的與看到的。自稱做了什麼不算證據。
