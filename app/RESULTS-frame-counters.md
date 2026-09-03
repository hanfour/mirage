# App 內幀計數結果

- 日期：2026-09-03
- 分支：`app-frame-counters`
- 規格：`docs/specs/2026-09-03-app-frame-counters-design.md`
- 活體數字：由 PM 補寫

## 改了什麼

- `LatestFrameBox` 對有效 `put` 增加 `arrived`，無效幀仍只增加 `rejected`。`takeLatest` 與單格 latest-wins 語意沒有改動。
- `stats()` 改回傳 `FrameCounterSnapshot`，包含 `arrived`、`dropped`、`rejected`。既有呼叫端使用的 `.dropped` 與 `.rejected` 屬性保持不變。
- 新增 `FrameCounterWindow`，用兩次快照和 `presented` 計數計算非負窗口增量。快照倒退或負的 presented 計數會歸零。
- `Renderer` 在既有每秒窗口邊界取 box 快照，保留原 `[app] fps=` 輸出，另印 `[app] frames arrived=N dropped=N presented=N`。新行不含 `fps=`。
- `gui_session.sh` 新增 `frames_samples` 與 `frames_median`。`frames_median` 支援 `arrived`、`dropped`、`presented`，以及跳過前 N 條幀計數行。
- `gui_session_selftest.sh` 加入閘門 7。`verify_fps_fullscreen.sh` 逐輪印 guest、arrived、presented、dropped、mirage、baseline、ratio，並輸出三個跨有效輪次的中位數。
- 未修改 `FramePump`、transport、`EmulatorClient`、`takeLatest` 語意、既有 fps 解析函式、驗收判定邏輯或債務表。

## 既有 stats() 呼叫端

修改前用下列命令盤點：

```text
git grep -n 'stats()' main -- app/Sources app/Tests
```

既有呼叫端只有以下三處，內容均未修改：

- `app/Tests/MirageCoreTests/LatestFrameBoxTests.swift:16`，讀取 `.dropped`
- `app/Tests/MirageCoreTests/LatestFrameBoxTests.swift:30`，讀取 `.rejected`
- `app/Tests/MirageCoreTests/LatestFrameBoxTests.swift:31`，讀取 `.dropped`

修改後新增的 `stats()` 使用點是 `Renderer` 的窗口起點與終點快照，以及新增測試需要的快照讀取。產品碼原本沒有其他 `stats()` 呼叫端。

## 測試

- `LatestFrameBoxTests`：有效 `put` 使 `arrived` 遞增、無效幀不增加 `arrived`、`takeLatest` 不影響 `arrived`，並保留 `dropped` 原有語意。
- `FrameCounterWindowTests`：兩次快照的三個窗口差值，以及快照倒退和負 presented 計數的歸零行為。
- `gui_session_selftest.sh`：四筆固定假 log 的三欄中位數、跳過前一筆、跳過全部樣本、零樣本回 0、`frames_samples`，以及混入 `[app] frames` 後 `fps_median` 仍正確。

## 故障注入

在暫存副本把 `frames_median` 的欄位比對故意改成只接受 `arrived`，再執行同一份 selftest。預期以退出碼 1 失敗，實際輸出如下：

```text
fault-injection exit=1
=== frames_median ===
✅ frames_samples 計數
✅ arrived 中位數
❌ dropped 中位數：得到 14，期待 3
❌ presented 中位數：得到 14，期待 11
✅ 跳過前一筆後的 arrived 中位數
❌ 跳過前一筆後的 dropped 中位數：得到 16，期待 4
❌ 跳過前一筆後的 presented 中位數：得到 16，期待 12
✅ 跳過全部樣本回 0
✅ 沒有幀樣本回 0
✅ 沒有幀樣本時筆數為 0

=== fps_median 相容性 ===
✅ 混入 frames 行不污染 fps_median

4 項失敗
```

## 驗收證據

1. `swiftc -parse` 通過，涵蓋變更 Swift 原始碼與新增 Swift 測試。依第 6 節限制，沒有執行 `swift build --build-tests` 或 `swift test`，這兩項由 PM 執行。
2. 四支相關 shell 腳本的 `bash -n` 通過，`gui_session_selftest.sh` 直接執行通過。沒有執行完整 `app/scripts/ci.sh`，因它會觸發規格禁止的 Swift build/test；PM 執行九道閘門。
3. 直接比較 `main` 與 `HEAD` 的 `Renderer.swift`，原行完全相同：

   ```text
   fps line unchanged:             print("[app] fps=\(Int((Double(fpsCount) / elapsed).rounded()))")
   ```

   `fps_median`、`fps_samples`、`fps_average` 的函式內容也沒有修改。
4. 正常 `gui_session_selftest.sh` 全部通過；上方故障注入以退出碼 1 紅燈，證明欄位比對測試會失敗。
5. `stats()` 既有呼叫端已完整列於上方，並用 `git grep` 對照 `main` 確認沒有遺漏。
6. `git diff --check` 通過。

## 尚未驗證

- 尚未執行 Swift package build、Swift 測試套件與完整 `ci.sh`，等待 PM 編譯回饋。
- 尚未執行 emulator、adb、`package_app.sh` 或 `verify_fps_fullscreen.sh` 活體量測。
- `verify_fps_fullscreen.sh` 僅完成 `bash -n` 與靜態檢查；活體的 guest、Mirage、arrived、dropped、presented、baseline、ratio 數字由 PM 補寫。
- `swiftc -parse` 只驗證語法，不能取代 package build 的型別、連結與平台 SDK 驗證。

## Commits

- `0bf012e test: 補上幀計數與視窗增量測試`
- `c71802f feat: 加入 App 幀計數與秒窗口診斷`
- `b4f8fc4 test: 補上 GUI 幀計數解析自我測試`
- `8079f1b feat: 加入幀計數 shell 解析與逐輪摘要`
