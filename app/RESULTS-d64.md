# D64 結果

- 日期：2026-09-03
- 分支：`d64-draw-timing`
- 狀態：完成程式與局部驗證，Swift 編譯與活體量測由 PM 執行

## 改了什麼

- `MirageCore` 新增 `DrawTimingWindow`，累積 draw 次數、超過 20ms 的間隔、最大間隔、commit 耗時 p95、`noDrawable` 與 `noFrame`。p95 使用窗口內小型 `Double` 樣本排序取 nearest-rank。
- `Renderer.draw(in:)` 只在 `MIRAGE_FPS_LOG=1` 取時間戳，保留原本的 guard、encode、present、commit 控制流與渲染行為。`fps`、`frames`、`draw` 三行在同一個一秒窗口背靠背輸出。
- `gui_session.sh` 新增 `tagged_median`，`frames_median` 改為薄包裝，支援小數與 `ms` 後綴。
- `gui_session_selftest.sh` 新增 draw 六欄解析、跳過前置行，以及 `fps`／`frames`／`draw` 行數相等斷言。
- `verify_fps_fullscreen.sh` 新增每輪 draw 時序診斷、`[round N draw]` 行與四個 draw 摘要中位數，沒有改判定邏輯、退出碼或既有 `[round N]` 行。
- 新增 `verify_fps_under_load.sh`，支援 `-n 0` 對照組與 `-n >0` 的 burner、`-l 99`、退出清理及 `kill -0` 回檢。
- 沒有修改債務表。

## 測試清單

- `swiftc -parse app/Sources/MirageCore/DrawTimingWindow.swift app/Sources/MirageShell/Renderer.swift app/Tests/MirageCoreTests/DrawTimingWindowTests.swift`：通過。
- 四支相關 shell 腳本 `bash -n`：通過。
- `git diff --check`：通過。
- `./app/scripts/lib/gui_session_selftest.sh`：全部通過，包含 draw 六欄、`ms` 後綴、跳過前一行、fps 中位數相容性與三行 `4/4/4`。
- DrawTimingWindow 單元測試已先提交，再提交型別實作；沒有執行 `swift build` 或 `swift test`。

## 故障注入

在暫存副本把 `tagged_median` 的 tag 比對固定成 `frames`，同一份 selftest 的結果：

```text
=== tagged_median draw ===
❌ draw calls 中位數：得到 0，期待 58
❌ draw gap20 中位數：得到 0，期待 2
❌ draw maxgap 解析 ms 後綴：得到 0，期待 41
❌ draw in_p95 解析小數與 ms 後綴：得到 0，期待 4.5
❌ draw nodrawable 中位數：得到 0，期待 1
❌ draw noframe 中位數：得到 0，期待 3
❌ draw 跳過前一行的 maxgap 中位數：得到 0，期待 61
❌ draw 跳過前一行的 in_p95 中位數：得到 0，期待 5.6
8 項失敗
FAULT_INJECTION_RC=1
```

## Burner 清理

實跑命令：`app/scripts/verify_fps_under_load.sh -n 2 -p 45999`。

本機缺少既有 `phase0/harness/.venv-d45/bin/python`，因此底層驗證腳本在 `require_grpc` 前退出碼 2；包裝腳本仍完成兩個 burner 的清理：

```text
✅ burner pid=75126 已清理：kill -0 回檢不存在。
✅ burner pid=75127 已清理：kill -0 回檢不存在。
WRAPPER_RC=2
PID_75126=不存在
PID_75127=不存在
```

另外執行 `pgrep -f '^yes$'` 時，沙箱拒絕 process-list 查詢並回報 `pgrep: Cannot get process list`，所以沒有把它誤報成成功證據；上方是 wrapper 自己的 `kill -0` 回檢與後續逐 PID 回檢。

## 驗收條件

1. 未執行 `swift build --build-tests` 或 `swift test`，依第 6 節交由 PM 編譯回饋。
2. 未執行 `app/scripts/ci.sh`，因其會觸發規格禁止的 Swift build/test，交由 PM 執行九道閘門。
3. 已以靜態行號檢查確認 `Renderer.swift` 的三個 `[app]` print 連續且在同一分支；selftest 斷言 `fps`／`frames`／`draw` 為 `4/4/4`。
4. 已執行指定負載命令並確認 burner 清理；但因本機缺少 venv，尚未到 `require_grpc`，退出碼 1 與 `pgrep -f` 證據待具備環境後由 PM 重跑。
5. 故障注入退出碼為 1，8 個 draw 解析斷言失敗，證明測試會紅。

## 尚未驗證

- Swift 型別檢查、`swift build --build-tests`、`swift test`。
- `app/scripts/ci.sh` 九道閘門。
- emulator、adb、`package_app.sh` 與全螢幕活體量測。
- D64 的實際 draw 時序、guest fps 與驗收線 7 活體數字，待 PM 補寫。

## 第二輪修正（2026-09-04）

- 7.1：`verify_fps_under_load.sh` 只有在 `BURNERS > 0` 時才執行 `seq 1 "$BURNERS"`，避免 macOS BSD `seq 1 0` 啟動兩個 burner。
- 7.2：清理 `BURNER_PIDS` 與呼叫驗證腳本時，先檢查陣列長度，避開 bash 3.2 `set -u` 對空陣列的 `unbound variable`。
- 7.3：負載模式預設把 `FULLSCREEN_WINDOW_TIMEOUT` 提高到 60 秒並印出；`verify_fps_fullscreen.sh` 的 `ROUND_RETRY_MAX` 改為可由環境變數覆寫，直接執行仍預設 3。

### 第二輪自我驗證

BSD `seq` 的問題仍可直接重現：

```text
$ seq 1 0
1
0
```

負載模式先以一個 burner、假 gRPC 埠確認抬高的逾時設定與清理路徑：

```text
burner 數：1
負載模式：FULLSCREEN_WINDOW_TIMEOUT=60 秒、ROUND_RETRY_MAX=3
❌ gRPC 45999 無回應——模擬器未啟動。
✅ burner pid=68815 已清理：kill -0 回檢不存在。
退出碼：1
```

規格指定的對照組命令：`/bin/bash app/scripts/verify_fps_under_load.sh -n 0 -p 45999`。
它未啟動 burner，因假 gRPC 埠退出 1：

```text
burner 數：0
load_avg_1min（啟動前）：15.75
load_avg_1min（啟動後）：15.75
❌ gRPC 45999 無回應——模擬器未啟動。
退出碼：1
```

命令前後執行 `pgrep -x yes` 都被本機沙箱拒絕 process-list 查詢，回報
`sysmon request failed with error: sysmond service not found` 與
`pgrep: Cannot get process list`（退出碼 3），所以沒有把查不到清單誤當成 0。
wrapper 自己的 burner PID `kill -0` 回檢在負載模式中已確認清理成功。

```text
pgrep -x yes（執行前）：退出碼 3，Cannot get process list
pgrep -x yes（執行後）：退出碼 3，Cannot get process list
```

本輪沒有另行執行 Swift 測試、啟動 emulator 或 `ci.sh`。在驗證空
`VERIFY_ARGS` 的探索命令 `-n 0` 中，由於本機 8556 端口已有服務，曾進入 wrapper
既有的 `build_warm`；SwiftPM manifest 階段被沙箱拒絕，退出碼 1。這段不作本輪通過證據。

## PM 把關與活體驗證（2026-09-04 到 09-07）

### 把關

- codex 盲寫的 Swift 一次編過，332 條測試綠；ci.sh 九道閘門兩輪都綠。
- 獨立審查抓到 `verify_fps_under_load.sh` 在 bash 3.2 對空陣列 `"${ARR[@]}"` 會炸；PM 活體追出另外兩個：macOS 的 `seq 1 0` 印 `1 0` 讓 `-n 0` 啟動兩個 burner、負載下 app 視窗 15 秒內不在 AX 出現。第二輪三點都修，PM 用 `/bin/bash` 3.2 實跑 `-n 0 -p 45999` 與 `-n 2`（不帶參數）兩條空陣列路徑，都不再炸、burner 零殘留。
- 9 月 4 日深夜的活體三組全部零輪，追到根因是螢幕鎖定（`CGSSessionScreenIsLocked=True`）：app 照收幀但 SwiftUI 不建視窗、`Renderer.draw` 一次沒跑。與分支無關（8 月 7 日 main 的舊二進位 A/B 一樣失敗）。解鎖後 9 月 7 日重跑。

### 活體：三組各五輪（`verify_fps_under_load.sh -n 0／4／8`）

環境同前：`mirage-game`、Pixel Flow 在前景、全螢幕 898×1996、每輪 20 秒。負載模式抬高 `LOAD_LIMIT` 到 99、`FULLSCREEN_WINDOW_TIMEOUT` 到 60。

| burner | 外來 CPU | guest（五輪） | arrived→presented（五輪） | dropped | gap20 | maxgap | in_p95 | nodrawable | noframe |
|---|---|---|---|---|---|---|---|---|---|
| 0 | 90% | 50.88／48.56／51.64／50.89／51.88 | 50→50／45→46／49→49／48→48／49→49 | 0 | 0 | 18ms | 9.3／9.3／9.3／2.3／9.3 | 0 | 11 到 15 |
| 4 | 481% | 32.72／33.59／34.76／36.99／33.66 | 34→33／35→35／36→36／37→37／34→34 | 0 | 0 | 18ms | 9.3／2.3／9.3／2.2／1.9 | 0 | 24 到 28 |
| 8 | 521% | 34.41／27.36／33.05／36.01／34.90 | 35→35／31→31／35→35／37→36／36→35 | 0 | 0 | 18ms | 1.8／1.7／9.2／9.2／9.2 | 0 | 24 到 30 |

十五輪全部因 guest 未達 55 判為無效（這是預期，實驗的目的是加負載），draw 時序行每輪都有。

### 判定

1. **純 CPU 負載下渲染端零損失。** 十五輪 `dropped=0`、`nodrawable=0`、`gap20=0`、`maxgap` 恆 18ms（display link 從沒被延後超過一個 vsync 加 1ms）、`in_p95` 最高 9.3ms（遠低於 16.7ms 的 vsync 週期）。guest 出多少幀 Mirage 就 present 多少，誤差 1。D64 假設的三種形狀（回呼延後、上傳變慢、拿不到 drawable）在純 CPU 負載下全部不成立。
2. **掉的全是 guest，而且與 CPU 負載單調相關**：0 burner 約 50、4 burner 約 34、8 burner 約 33（8 與 4 差不多，代表 4 個 burner 已經把 qemu 能拿到的 CPU 壓到底）。這是 D60 的形狀。
3. **`RESULTS-frame-counters.md` 跑次 2 第 5 輪（guest 58.89、arrived 60、presented 50、dropped 8）用純 CPU burner 重現不了。** 那次是使用者在操作機器（外來 CPU 183%），負載形態不同，嫌疑轉向 GPU 或視窗合成競爭（例如另一個全螢幕 Metal／瀏覽器視窗、Space 切換），不是 CPU 排程。D64 的描述要改：不是「主機負載下錯過 vsync」，是「特定但尚未辨識的負載形態下錯過 vsync，純 CPU 不會」。
4. `in_p95` 在 2 與 9ms 之間跳，與負載無關（對照組也跳）。9ms 那些窗口可能撞到 7.2 MB `texture.replace` 的頁面錯誤或 Metal 的 command buffer 排隊，但它沒有造成掉幀，記錄即可。
5. 對照組的 guest 只有 50，不是 59：這次外來 CPU 90%（不是 9 月 3 日的 29%），機器上有別的東西在跑。與 9 月 3 日「安靜時 guest 59、Mirage 59」合起來看，guest 對外來 CPU 的敏感度大約是：90% 掉 15%、480% 掉 43%。

### 對驗收線 7 的意義

Mirage 這一側在 CPU 負載下沒有東西可修。「使用者同時用機器也 ≥ 55」這個目標，剩下的變數是 guest 本身對主機 CPU 的敏感度（D60），而那在 emulator 行程內，Mirage 能做的只有降低自己的 CPU 用量（目前 MirageApp 在 60fps 全螢幕下約 50% 到 60% CPU，見 9 月 4 日 `ps` 的 58.7%）。這是下一個要量的數字：Mirage 自己佔的 CPU 有多少會回頭壓到 guest。
