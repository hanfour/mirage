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
