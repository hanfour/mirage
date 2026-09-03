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
- `gui_session_selftest.sh`：四筆固定假 log 的三欄中位數、跳過前一筆、跳過全部樣本、零樣本回 0、`frames_samples`，以及混入 `[app] frames` 後 `fps_median` 仍正確，並確認 `fps_samples` 與 `frames_samples` 一對一。

## 讀數的三個限制

1. `presented` 是量測窗口內的原始計數；`fps=` 是它除以 elapsed 後四捨五入的整數。抵達不規律時，兩者可能差超過 1。
2. 計數關係可寫成 `arrived - dropped >= presented`，但等號不保證成立。`takeLatest` 之後若 `draw` 提前返回，該幀不會進入任何計數。
3. `M` 與新三欄的取樣母體不同。`M` 使用沒有跳過參數的既有 `fps_median`，包含全螢幕收斂期；`arrived`、`dropped`、`presented` 只取量測窗口，逐輪不能直接相減。

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

## 第二輪驗證

- 7.1 的 `verify_fps_fullscreen.sh` 通過 `bash -n`；`git diff --check` 也通過。
- 7.2 的 `gui_session_selftest.sh` 會額外確認同一份混合 log 的 `fps_samples` 等於 `frames_samples`；`Renderer.swift` 可用 `swiftc -parse` 驗證語法。
- 7.1 與 7.2 都未執行 Swift package build、Swift 測試套件、emulator、adb、`package_app.sh` 或活體 fullscreen 量測，這些由 PM 負責。

## Commits

- `0bf012e test: 補上幀計數與視窗增量測試`
- `c71802f feat: 加入 App 幀計數與秒窗口診斷`
- `b4f8fc4 test: 補上 GUI 幀計數解析自我測試`
- `8079f1b feat: 加入幀計數 shell 解析與逐輪摘要`
- `fix: 修正全螢幕啟動時序與重送`（第二輪 7.1）
- `test: 補上幀計數輸出一致性防護與限制文件`（第二輪 7.2）

## PM 把關與活體驗證（2026-09-03）

### 把關

- codex 盲寫的 Swift 一次編過，327 條測試綠；ci.sh 九道閘門兩輪都綠（閘門 7 含新的第五支自我測試）。
- PM 的故障注入：`frames_median` 欄位比對改壞後自我測試 4 條紅；亂序輸入的中位數正確。
- 獨立審查沒有擋合併的問題，四點文件與防護要求在第二輪補齊。
- 第一次活體三輪九次啟動全部停在 888×1972：`AXFullScreen` 在視窗於 AX 出現前 0.5 秒送出且不重送（實測 `gui_session_start` +7.3 秒回來、視窗 +7.8 秒出現、送成功後 +9.3 秒收斂）。第二輪修好後兩次跑次全部收斂到 898×1996。

### 活體跑次 1（外來 CPU 29%，負載 5.6）

| 輪 | guest | arrived | presented | dropped | mirage | baseline | 判定 |
|---|---|---|---|---|---|---|---|
| 1 | 53.85 | 60 | 48 | 7 | 47 | | 無效（guest < 55） |
| 2 | 45.49 | 52 | 48 | 1 | 50 | | 無效（guest < 55） |
| 3 | 59.26 | 60 | 60 | 0 | 59 | 59.02 | 有效 |
| 4 | 59.75 | 60 | 61 | 0 | 60 | 59.65 | 有效 |
| 5 | 59.74 | 61 | 60 | 0 | 59 | 59.73 | 有效 |

`MIRAGE_VALUES=59 59 60`、中位數 59、跨度 59 到 60，退出碼 0。**驗收線 7 首次通過**（門檻 55，逐輪 guest 門檻 55，D56 規則）。

### 活體跑次 2（外來 CPU 183%，負載 6.7）

| 輪 | guest | arrived | presented | dropped | mirage | baseline | 判定 |
|---|---|---|---|---|---|---|---|
| 1 | 42.50 | 53 | 50 | 0 | | | 無效 |
| 2 | 36.59 | 38 | 37 | 1 | | | 無效 |
| 3 | 59.15 | 61 | 60 | 0 | 59 | 59.77 | 有效 |
| 4 | 59.52 | 61 | 60 | 0 | 60 | 59.38 | 有效 |
| 5 | 58.89 | 60 | 50 | 8 | 49 | 58.07 | 有效 |

`MIRAGE_VALUES=49 59 60`、中位數 59、跨度 49 到 60，腳本判「跨越門檻，判定不了」（D56 的離散度規則）。

### 判定

1. **主機安靜時 Mirage 行程內零損失**：guest 59 到 60 的輪次裡 arrived 60 到 61、presented 60、dropped 0、mirage 59 到 60、與 Python 對照組相等。單格 latest-wins 信箱的拍頻損失沒有出現；D48 原本推估的「Mirage 自己那段掉 7.2%」在安靜窗口不存在。
2. **驗收線 7 在安靜窗口通過**：跑次 1 中位數 59、跨度 59 到 60。這是 repo 內第一次退出碼 0 且跨度不跨門檻的跑次。
3. **主機負載下的損失分兩種形狀**：(b) guest 先掉（跑次 1 的第 1、2 輪，跑次 2 的第 1、2 輪，guest 36 到 54），Mirage 只是跟著掉，抵達與 present 幾乎相等；(a) guest 沒掉但渲染端掉（跑次 2 第 5 輪：guest 58.89、arrived 60、presented 50、dropped 8），這是 `Renderer.draw` 在主機負載下錯過 vsync。跑次 1 第 1 輪（arrived 60、presented 48、dropped 7、guest 53.85）兩者同時出現。
4. 抵達與 present 之間「不進任何計數」的遺失也量到了：跑次 2 第 1 輪 arrived 53、dropped 0、presented 50，差 3，就是 `takeLatest` 之後 `draw` 早退的那條路徑（審查第 4 點）。
5. 所以驗收線 7 剩下的不是「哪一段慢」，是**對主機負載的耐受度**：guest 對外來 CPU 的敏感度（D60）與渲染端在主執行緒被搶時掉幀。兩者都不在傳輸或 client 路徑上。
