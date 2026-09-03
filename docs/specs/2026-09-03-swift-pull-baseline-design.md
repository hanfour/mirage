# Swift 直拉對照組：把 grpc-swift 與渲染兩段切開

- 日期：2026-09-03
- 狀態：任務簡報（交 codex 實作，PM 把關）
- 分支：`swift-pull-baseline`
- 相關：D48（fps 未達驗收線 7）、D16（grpc-swift 發請求時 MMAP 更新率遠低於 Python）、`app/RESULTS-d58.md`

## 1. 背景

D58 的三輪交錯對照（`app/RESULTS-d58.md`「PM 把關與活體驗證」）證明：在驗收環境（`mirage-game`、真實 Pixel Flow 畫面、900×2000）上，Python client 走 raw RGBA 就到 vsync 天花板（58.98 fps），傳輸不是驗收線 7 的瓶頸。但 Mirage 自己量到的是 43 到 54。

Python 直拉 59、Mirage 43 到 54，損失在 Mirage 行程內部，只剩兩段：

1. grpc-swift 這條 client 路徑（`GrpcChannelBox` + `GrpcStreamTransport`）。D16 的調查證明它在同一台 emulator 上行為與 Python 不同，插一個 TCP relay 就改善 6 倍；它用單一 NIO 執行緒與 16 KB 的 HTTP/2 frame，每秒要處理約 26,000 個 frame 才吞得下 405 MiB/s。
2. macOS 端的解碼、Metal 貼圖上傳、視窗合成（`MirageShell`）。

現在沒有任何工具能分開量這兩段。本任務做一支「用 grpc-swift 拉 raw RGBA 但不渲染」的工具，與 Python 對照組同窗口交錯。結果只有兩種：Swift 直拉也只有 45 上下，瓶頸在 grpc-swift；Swift 直拉也有 59，瓶頸在渲染端。

## 2. 目標（一句話）

一支 Swift 命令列工具，用產品實際的 transport 拉 raw RGBA 不渲染，輸出與 `fps_baseline.py` 相同的狀態契約，並排進 `verify_transport_compare.sh` 與 Python 同窗口交錯。

## 3. 範圍

### A. 新 library target `MiragePull` 與 executable target `mirage-pull`

在 `app/Package.swift` 新增：

- `.target(name: "MiragePull", dependencies: ["MirageCore"])`：可測試的純邏輯與量測迴圈。
- `.executableTarget(name: "mirage-pull", dependencies: ["MiragePull"])`：只有 `main.swift`，解析參數、呼叫 library、印輸出、回傳退出碼。
- `.testTarget(name: "MiragePullTests", dependencies: ["MiragePull", swift-testing])`。

三者都套用既有的 `strict` 設定。不要動 `MirageCore`、`MirageShell`、`MirageApp` 的宣告。

### B. `mirage-pull` 的命令列與輸出

旗標與 `fps_baseline.py` 對齊：`--endpoint localhost:8556`（預設）、`--seconds 20`、`--width 900`、`--height 2000`、`--json`。

JSON 輸出欄位與 `fps_baseline.py` 完全相同（`status`、`error`、`fps`、`frames`、`elapsed`、`width`、`height`、`transport`、`distinct`），外加 `client: "grpc-swift"`。純文字輸出格式照 `fps_baseline.py` 的那一行，在結尾加 `client=grpc-swift`。

狀態與退出碼同一套：`measured` 0、`error` 1、`static` 2、`stale` 3。

### C. 量測迴圈（`MiragePull`）

- 用 `GrpcChannelBox(host:port:)` 與 `GrpcStreamTransport(channel:)`，也就是產品實際走的那條路。不要自己另外建 gRPC 連線。
- `for try await frame in transport.frames(width:height:)` 計 frames；每一幀用「每 64 位元組取樣一次」算指紋（與 Python 對齊：`fps_baseline.py` 第 114 行起），用 64 位元 FNV-1a 就夠，只需要同一次執行內可比較。
- 時間到就 `transport.cancelStream()`，然後 `channel.shutdown()`。串流因取消而拋出的錯誤不算 `error`。`streamScreenshot` 是變化驅動的，畫面靜止時 `next()` 會無限期停住，所以取消一定要靠外部計時器，不能靠串流自己結束。
- `elapsed` 從送出請求起算到迴圈結束，與 Python 的 `t0` 對齊。
- `frames == 0` 是 `static`，`distinct < 2` 是 `stale`，連線或 RPC 失敗是 `error`（把 gRPC 的 status code 名稱放進 `error` 欄位）。
- 程式結束前 channel 要拆乾淨：這個 repo 在 NIO 拆除上吃過死鎖（D1），`GrpcChannelBox.shutdown()` 是為此設計的，用它，然後給拆除一點時間再 `exit`。

### D. `verify_transport_compare.sh` 加第三個系列

- 新增 `-s` 旗標指定系列，逗號分隔，預設 `rgba,swift`。可用值：`rgba`（Python raw）、`mmap`（Python MMAP）、`swift`（`mirage-pull`）。
- 交錯：第 i 輪從第 `(i-1) mod n` 個系列開始輪轉，每輪每個系列各量一次。
- `swift` 系列的前置：在所有輪次開始前用 release 組態建好 `mirage-pull`（`swift build -c release --product mirage-pull`），並用 `verify_common.sh` 的 `build_warm` 確認建置快取是暖的，不讓建置落進量測窗口（D57）。二進位路徑用 `swift build -c release --show-bin-path` 取得。
- 解析 JSON 的那段 Python 要能吃兩種工具的輸出（欄位相同，`client` 多出來也不影響）。
- 表格多一欄 `client`；中位數與有效輪數每個系列各一行；差值改成「每個系列相對第一個系列」。
- 既有斷言不變：每個系列至少 `MIN_VALID` 個有效樣本。

### E. 測試（`MiragePullTests`，swift-testing）

不需要 emulator。`MiragePull` 的量測迴圈要能注入一個假的 `DisplayTransport`（這是 `MirageCore` 的 public protocol，直接實作它）。至少涵蓋：

- 狀態對映四種與退出碼
- 指紋：兩幀只差一整列 distinct=2、只差第 1 個位元組 distinct=2、完全相同 distinct=1
- 假 transport 送 N 幀後停住（不結束串流），時間到工具會取消並回 `measured`，frames=N
- 假 transport 一幀都不送，時間到回 `static`
- 假 transport 拋 `TransportError.unavailable` 回 `error`，且 `error` 欄位有內容
- JSON 欄位集合等於 `fps_baseline.py` 的欄位集合加 `client`
- `cancelStream()` 在時間到之後被呼叫過（假 transport 記錄）

`#expect` 不要拿 Bool 跟 `true`／`false` 比（閘門 5 會擋，而且那種斷言永遠不會紅）。

### F. 結果文件 `app/RESULTS-swift-pull.md`

寫下：改了什麼、測試清單與輸出、`verify_transport_compare.sh` 的新旗標在沒有 emulator 時的行為（`require_grpc` 會紅）、沒驗的是什麼。真實 emulator 上的數字由 PM 補寫。

## 4. 禁區

- 不改 `MirageCore`、`MirageShell`、`MirageApp` 的任何原始檔。若 `MirageCore` 有東西不夠 public 讓你做不下去，停下來在結果文件寫清楚需要什麼，不要自己改。
- 不改 `fps_baseline.py`、`bench_mmap_vs_rgba.py`、`verify_fps_fullscreen.sh`、`verify_mmap.sh`。
- 不啟動 emulator、不執行 adb。
- 不改債務表 `docs/specs/2026-07-29-project-review.md`。

## 5. 驗收條件

1. `swift build -c release --product mirage-pull` 成功；`swift test --filter MiragePullTests` 全綠。
2. `bash app/scripts/ci.sh` 九道閘門全綠（由 PM 在沙箱外跑，你只要確認你的測試在 `swift test` 裡會被跑到）。
3. 沒有 emulator 時：`mirage-pull --endpoint localhost:45999 --seconds 2 --json` 以退出碼 1 結束，JSON 的 `status` 是 `error`，`fps` 是 0。
4. `verify_transport_compare.sh -s rgba,swift -p 45999` 在 `require_grpc` 就紅（退出碼 1）。
5. `verify_transport_compare.sh -s rgba,mmap` 的行為與改前完全一樣（用改前版本對照輸出）。

## 6. 工作方式

- 你的沙箱裡 SwiftPM 自己的 sandbox-exec 會被擋（巢狀）。建置與測試一律加 `--disable-sandbox --cache-path .build/cache`，例如 `swift build --disable-sandbox --cache-path .build/cache -c release --product mirage-pull`、`swift test --disable-sandbox --cache-path .build/cache --filter MiragePullTests`。第一次建置要三到四分鐘，等它。
- 測試先寫（紅），再實作（綠）。
- 每完成一個部分就 commit，訊息格式 `<type>: <描述>`，描述用繁體中文。
- 註解與文件用繁體中文台灣用語，不用破折號接補充說明。
- bash：`set -uo pipefail`，裸變數後面不接全形標點（`${rc}，` 不是 `$rc，`）。
- 結束前把報告寫進 `app/RESULTS-swift-pull.md`，最後一則訊息列出：改動的檔案、每條驗收條件的證據、沒做到的事。
