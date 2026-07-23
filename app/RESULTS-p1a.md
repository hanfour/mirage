# P1-a 驗收結果（日期：2026-07-23；host load：1.5–2.9（多數量測窗口，見各節）；emulator：canary 37.2.1.0 (37.2.1-15875889)）

## 環境條件（誠實聲明）

**本機螢幕在整個量測過程中處於鎖定狀態**（遠端使用者、螢幕已閒置超過 60 分鐘）。
macOS 鎖屏時 WindowServer 不會把使用者 session 的視窗合成到實體顯示器，
`MTKView` 內建的 `CVDisplayLink` 因此完全不觸發、`draw(in:)` 從未被呼叫、
`Renderer.upload()`（`[app] fps=` 唯一印出點）自然也從未執行——與
reconnect/backoff/channel/transport 邏輯完全無關（Task 7 已詳細建立這條證據鏈，
本次以 `screencapture -x` 重新確認畫面仍是全黑／無訊號，`fps=` 計數仍恆為 0）。

**因此本報告把五條驗收線分成兩層誠實處理**：
- 能在 headless／transport 層量到的（驗收 2、3、4，以及驗收 1 的 transport 天花板）：**實測填實數**。
- 必須依賴 App 實際合成畫面才有意義的（驗收 1 的 App 合成 fps、驗收 5 的「渲染中」CPU）：
  **標記 `pending-unlock`，不補假數字**。腳本用了現成的 `MIRAGE_FPS_LOG=1` 執行了完整流程並
  確認 `fps=` 行數恆為 0（見下方各節逐字記錄），但這只能證明「阻塞仍在」，不能倒推出一個
  「App 合成 fps」或「渲染中 CPU」的數字——沒有渲染發生，這兩個指標在定義上不存在，硬填數字
  就是造假。

---

| # | 驗收線（spec §7） | 實測 | 判定 |
|---|---|---|---|
| 1a | 540p 30s fps ≥55（**transport 層天花板**，headless 可測） | 3×30s 樣本：60.0 / 60.0 / 56.3 fps（取最低值視為 p5-ish）→ **56.3fps** | ✅ |
| 1b | 540p 30s fps ≥55（**App 合成層**，MIRAGE_FPS_LOG） | **pending-unlock**：screen-lock 阻塞，`fps=` 行數恆為 0（詳見下方逐字記錄） | ⏸️ pending-unlock |
| 2 | 殺模擬器→重啟→10s 內恢復 | Task 7 `verify_reconnect.sh`：連續 2 次 PASS，皆 **1 秒**恢復（`bytes_in` 判定） | ✅ |
| 3 | e2e p50 ≤ 基線(40.7ms)+10% = 44.8ms | **量測工具不經 P1-a 程式碼**（見下方校正）：harness e2e 52.9/54.9ms vs 基線 40.7ms；App 層 sendTap e2e = **pending-unlock** | ⚠️ 見校正／pending-unlock |
| 4 | 測試全綠、覆蓋 ≥80%、release 零警告 | **28/28 tests 全綠**；own-source 覆蓋率（完整呼叫含 live 測試）：**line 94.89% / region 84.80% / function 92.31%**；release build **0 warnings** | ✅ |
| 5 | CPU 佔用記錄（目標 <50% 單核當量） | **pending-unlock**（渲染中 CPU 無法量，理由同上）。**附註**（非本驗收線正式數字）：純網路/收幀（無渲染）穩態 CPU ≈ 31–32%，見下方逐字記錄 | ⏸️ pending-unlock |

---

## 判定

- [ ] P1-a 出貨 → 開 P1-b/P1-c
- [x] **PARTIAL PASS，未達標項與處置**：
  1. **驗收 3（e2e）——量測歸因校正（orchestrator 事後校正）**：本任務用 `phase0/harness/e2e_latency.py`
     量 e2e，該工具是**純 Python harness**（只 import grpc/protobuf/lib，直接 gRPC sendTouch +
     streamScreenshot 偵測），**完全不經過 P1-a 的 `MirageCore`/`MirageApp` 程式碼**——因此
     52.9/54.9ms vs 基線 40.7ms 的差異在定義上**不可能是 P1-a 的迴歸**（P1-a 沒碰這條路徑）。
     更關鍵的反證：本次 host load 1.8–2.6，遠比基線量測當時（load ~15）乾淨，延遲卻更差——
     這指向「基線 40.7ms 是 n=36 單次量測的樂觀取樣」或「長時間運行的 canary emulator 狀態漂移」，
     而非程式碼變差。**驗收 3 真正想驗的是 P1-a 的 App 輸入路徑（`sendTap`）延遲**，那需要 App
     實際執行合成——與驗收 1b/5 同樣被 screen-lock 阻塞，改列 **pending-unlock**。harness 數字
     保留為 transport 層參考，但**不作為 P1-a 的 pass/fail 訊號**。
  2. **驗收 1b（App 合成 fps）與驗收 5（渲染中 CPU）pending-unlock**——screen-lock 環境阻塞，
     與程式邏輯無關（見上方〈環境條件〉）。**處置**：使用者於本機解鎖螢幕後，重跑本檔 Step 1
     的 `MIRAGE_FPS_LOG=1` 與 CPU 取樣兩段指令即可補上，不需要改動任何測試腳本或產品碼。
- 在驗收 3 根因查明、且驗收 1b/5 在解鎖後補測之前，**不宣告 P1-a 完整出貨**。

---

## 逐條詳細記錄

### 驗收 1a：540p transport-level fps（headless，可測）

前置：`uptime` 確認 load 1.49–2.91（全程 <8）；emulator 已 boot（`sys.boot_completed=1`）。

```
$ cd phase0/harness && source .venv/bin/activate
$ (python animate.py --seconds 110 &)   # 動畫源，涵蓋 3 次 30s 量測
$ python stream_bench.py --format rgba --seconds 30 --width 540 --height 1200
format=rgba frames=1800 fps=60.0 p50=16.7ms p95=18.0ms avg_frame=2.47MiB throughput=148MiB/s size=540x1200
$ python stream_bench.py --format rgba --seconds 30 --width 540 --height 1200
format=rgba frames=1801 fps=60.0 p50=16.7ms p95=18.0ms avg_frame=2.47MiB throughput=148MiB/s size=540x1200
$ python stream_bench.py --format rgba --seconds 30 --width 540 --height 1200
format=rgba frames=1689 fps=56.3 p50=16.7ms p95=18.2ms avg_frame=2.47MiB throughput=139MiB/s size=540x1200
```

3 個樣本排序：56.3 / 60.0 / 60.0 → 取最低值（brief 建議的 p5-ish 代理，3 樣本時即為最小值）
= **56.3fps**，≥55 門檻 **通過**。這是 gRPC transport 本身（Python 收幀）的天花板，
**不含** App 內 NIO 收幀 + LatestFrameBox 拷貝 + Metal 貼圖上傳 + WindowServer 合成的完整鏈路
成本——那段成本正是驗收 1b 要驗的，目前 blocked。

### 驗收 1b：540p App-composited fps（MIRAGE_FPS_LOG，screen-lock 阻塞）

```
$ screencapture -x /tmp/mac_screen_check.png   # 確認鎖屏狀態
# → 全黑（無訊號），與 Task 7 記錄一致
$ (cd phase0/harness && python animate.py --seconds 15 &)
$ MIRAGE_FPS_LOG=1 ./app/.build/release/MirageApp > /tmp/mirage_acceptance_fps.log 2>&1 &
$ sleep 12 && kill %1
$ wc -l < /tmp/mirage_acceptance_fps.log
0
```

`fps=` 行數 = 0（重跑第二次、animate 22 秒，同樣 0 行，見驗收 5 節逐字記錄）。**pending-unlock**。

### 驗收 2：殺模擬器→重啟→10s 內恢復

Task 7 完成、無需重跑（Task 7 report §「正式驗證」）：

```
正式驗證 · 第 1 次：before-recovery bytes_in=11455547 → +1s bytes_in=68732387 → PASS（1s 恢復）
正式驗證 · 第 2 次：before-recovery bytes_in=11455547 → +1s bytes_in=132536199 → PASS（1s 恢復）
```

兩次 `BEFORE_BYTES` 基準值完全相同，兩次都在 boot 完成後 **1 秒**恢復出幀，遠低於 10 秒門檻。

### 驗收 3：e2e p50 迴歸（含汙染排查）

前置：`adb shell settings put system show_touches 1`；量測後 `... show_touches 0`。

**第一輪（汙染，作廢）**——guest 前景卡在先前手動測試留下的 Clock/Alarm App
（`adb shell screencap` 證實，畫面中央是深藍色 App 內容而非中性背景）：

```
run1: n=4  misses=46 p50=47.0ms p95=49.5ms
run2: n=2  misses=48 p50=43.0ms p95=50.7ms
```

n=2、n=4 統計上不可信（大量 miss），與 rebaseline 的 misses=14/50 特徵不符，判斷為 guest 前景
App 干擾偵測邏輯（`region_mean` 在特定畫面內容下對比不足）——**非重連/transport 邏輯問題**。
`adb shell input keyevent KEYCODE_HOME` 回到首頁（純黑桌布）後重跑：

**第二輪（乾淨，正式採用）**：

```
$ uptime
load averages: 1.79 1.94 2.10
$ python e2e_latency.py
n=36 misses=14 p50=52.9ms p95=64.1ms
$ uptime
load averages: 2.27 2.09 2.14
$ python e2e_latency.py
n=37 misses=13 p50=54.9ms p95=61.7ms
```

miss 率（13–14/50）與 Phase 0 rebaseline 的 14/50 吻合。**但（orchestrator 校正）**：
`e2e_latency.py` 是純 harness、不經 P1-a 程式碼（`grep import` 證實只有 grpc/protobuf/lib），
所以這組數字量的是「emulator + harness」的 e2e，**P1-a 的產品碼不在路徑上**，不能當作 P1-a
迴歸的證據。且本次 load（~2）遠比基線當時（~15）乾淨卻延遲更差，反而說明基線 40.7ms（n=36
單次）本身偏樂觀或 emulator 已狀態漂移。**驗收 3 應驗的 App `sendTap` e2e 需 App 合成，
與 1b/5 一同 pending-unlock**；此 harness 數字僅列為 transport 參考。

### 驗收 4：測試 / 覆蓋率 / 警告

```
$ swift test --enable-code-coverage 2>&1 | tail -2
✔ Suite EmulatorClientReconnectTests passed after 0.524 seconds.
✔ Test run with 28 tests passed after 0.524 seconds.
```

**覆蓋率方法論說明**：brief 原提供的
`xcrun llvm-cov report ... -ignore-filename-regex "Generated|Tests" | tail -5`
單獨執行時 TOTAL 只有 **3.22%**（region）——但這是**假訊號**：SwiftPM 的覆蓋率報告會把
靜態連結的第三方依賴（grpc-swift、SwiftNIO、SwiftProtobuf 的 45000+ regions）全部算進 TOTAL，
而 `Generated|Tests` 這個 regex 只濾掉 protobuf 產生碼與測試檔本身，**濾不掉** `.build/checkouts/`
和 DerivedSources 裡的第三方原始碼。真正有意義的分母是專案自己的 `Sources/MirageCore/*.swift`
（`MirageApp` 因為 test target 只依賴 `MirageCore`，結構上不會出現在報告裡——見下方備註）。
過濾到 `^Sources/` 後兩種呼叫方式的對照：

| 呼叫方式 | region | function | line |
|---|---|---|---|
| `swift test --enable-code-coverage`（預設，無 live） | 62.40% | 69.23% | 52.69%（**未達 80%**） |
| `MIRAGE_LIVE=1 MIRAGE_LIVE_MMAP=1 swift test --enable-code-coverage`（含 live smoke，emulator 在跑） | **84.80%** | **92.31%** | **94.89%**（**達標**） |

專案 `app/README.md`／既有測試檔（`LiveSmokeTests`）本來就把「跑 live smoke」列為既定測試流程的
一部分（`guard ProcessInfo...["MIRAGE_LIVE"] == "1" else { return }`——不設旗標時測試會提早
return，因此「通過」但沒有真的執行、也沒有覆蓋率），只是預設不開（需要活體 emulator）。
本次 emulator 剛好在跑，依專案文件記載的方式執行以取得完整覆蓋率，是誠實量測，不是放寬標準。
**採用含 live 的數字（94.89% line / 84.80% region）作為驗收 4 的覆蓋率判定**，因為它反映了
專案自己定義的完整測試流程實際能達到的覆蓋，而非「忘記開一個旗標」的假陰性。

**備註（範圍決定，非本任務發現）**：`Sources/MirageApp/`（`ConnectionBanner`/`MirageApp`/
`MirrorView`/`Renderer`，AppKit/MetalKit UI 層）不在任何覆蓋率報告裡——`Package.swift` 的
`testTarget` 只宣告依賴 `MirageCore`，結構上排除了 App 層。這與 Task 8 brief 自身
self-review 記載的「§6 測試=Task 2-5 單元+Task 4/7 整合」一致：App 層預期用整合/live smoke
驗證，不是 XCTest 單元覆蓋率——是既有、有意識的範圍決定。

```
$ swift build -c release   # 乾淨重建：先刪 .build/release + .build/arm64-apple-macosx/release
...
[473/474] Compiling MirageCore Backoff.swift
[473/474] Linking MirageApp
Build complete! (132.91s)
$ grep -c "warning:" <build log>
0
```

**測試 28/28 全綠、覆蓋率 94.89%（line）/84.80%（region）、release 零警告 → 全數達標。**

### 驗收 5：CPU 佔用（screen-lock 部分阻塞）

```
$ (cd phase0/harness && python animate.py --seconds 22 &)
$ MIRAGE_FPS_LOG=1 ./app/.build/release/MirageApp > /tmp/mirage_acceptance_fps2.log 2>&1 &
$ sleep 2; PID=$(pgrep -f "release/MirageApp")
$ for i in 1..8: ps -o %cpu= -p "$PID"; sleep 2
 0.0
 22.6
 32.2
 31.2
 31.6
 31.4
 31.6
 32.5
$ wc -l < /tmp/mirage_acceptance_fps2.log
0
```

`fps=` 恆為 0（渲染從未發生），但 App 行程 CPU 在 animate.py 持續注入下穩定在 **~31–32%**——
這是**純網路收幀成本**（NIO event loop 讀 socket、HTTP2 frame 解析、`FramePump`→
`LatestFrameBox` 寫入），**完全不含**渲染/Metal/貼圖上傳/WindowServer 合成的成本（因為那段
從未執行）。這不是驗收 5 要求的「渲染中 CPU」，只是一個誠實的下界／部分訊號，附註供參考，
**不作為驗收 5 的正式判定數字**。驗收 5 本身維持 **pending-unlock**。

---

## 觀察與備註

- **resize 行為**：Task 7 已記錄——本機無 Accessibility 權限，無法用 `osascript` 自動化拖拉視窗，
  且螢幕鎖定下連人工拖拉都無法由本次工作階段完成，記為 pending-human（Task 7 已有此結論，
  本任務未重複嘗試）。
- **drop/rejected 計數**：本任務未新增計數量測；既有單元測試（`FramePumpTests`、
  `LatestFrameBoxTests`）已涵蓋佇列滿/取代邏輯的正確性，本任務範圍是驗收量測與文件，
  非新測試開發。
- **e2e 汙染排查是本任務中最重要的方法論教訓**：guest 前景 App 狀態會直接影響
  `e2e_latency.py` 的偵測可靠度（同一份程式碼，Clock App 前景時 misses 92–96%，回首頁後
  misses 26–28%）。往後任何以 `region_mean` 為基礎的量測，執行前都應該先
  `adb shell input keyevent KEYCODE_HOME` 確保 guest 處在已知、乾淨的狀態——這條紀律建議
  補進 `e2e_latency.py` 的docstring或呼叫慣例，但本任務未修改任何 harness 程式碼
  （純量測任務，不擴大範圍）。
- **emulator 全程保留執行中**，未在本任務結束時關閉（依交付指示）。
