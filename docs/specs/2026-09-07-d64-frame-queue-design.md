# D64：抵達抖動的深度 2 幀佇列，環境變數切換以便同一顆 build 做 A/B

- 日期：2026-09-07
- 狀態：任務簡報（交 codex 實作，PM 把關）
- 分支：`d64-frame-queue`
- 相關：D64（P2）、`app/RESULTS-frame-counters.md`、`app/RESULTS-d64.md`、`app/RESULTS-backpressure.md`

## 1. 背景

驗收線 7（全螢幕 60fps）的損失來源已經全部切開。Mirage 側唯一還能動的是 D64：使用者同時操作機器時，guest 出 59.5 到 59.9、抵達 60，但 `Renderer.draw` 只 present 47 到 53，`dropped` 6 到 8、`noframe` 6，同時 `gap20=0`、`in_p95` 約 9ms、`nodrawable=0`。三次現場（`RESULTS-frame-counters.md` 跑次 2 第 5 輪、`RESULTS-backpressure.md` 抽函式對照第 2 輪與 `app` 條件三輪）形狀一致，純 CPU burner 重現不了。

解讀：display link 準時、上傳快、drawable 有，但 60 幀抵達的節奏不均勻。有的 vsync 間隔收到兩幀，`LatestFrameBox` 是單格 latest-wins，前一幀被覆蓋（`dropped`）；下一個 vsync 收到零幀，沒東西畫（`noframe`）。損失來自抵達抖動與單格信箱的組合，不是任何一段慢。

## 2. 目標（一句話）

新增一個深度 2 的 FIFO 幀佇列，由環境變數 `MIRAGE_FRAME_QUEUE=2` 啟用，預設不啟用；抵達抖動時 vsync 仍有上一幀可畫，代價最多多一個 vsync 的延遲。

## 3. 為什麼是「新增型別加開關」而不是直接改 `LatestFrameBox`

- 三次現場都是「使用者在操作機器」時才出現，安靜時 60→60→0 沒有損失。改動只該在抖動時有作用，安靜時行為要與現在一致。
- 驗收要做 A/B：同一顆 build、同一台 emulator、同一份畫面，開關關與開交錯量，比 `dropped`／`noframe`／`mirage` 三個數。沒有開關就做不到同顆 build 對照。
- `LatestFrameBox` 有 30 幾個呼叫端（多數是測試傳 `LatestFrameBox()` 給 `EmulatorClient.start`），改它的語意會讓既有測試的期望值變，那些測試在保護 latest-wins，不該動。

## 4. 範圍

### A. `MirageCore`：抽 protocol `FrameSink`，兩個實作

- `public protocol FrameSink: Sendable { func put(_ frame: Frame); func takeLatest() -> Frame?; func stats() -> FrameCounterSnapshot }`。方法名沿用現有的，讓 `FramePump`、`Renderer`、`EmulatorClient` 的呼叫端只改型別不改呼叫。
- `LatestFrameBox` 遵從 `FrameSink`，內容一個位元組不改。
- 新增 `FrameQueue`（`FrameQueue.swift`，`@unchecked Sendable` 加 `NSLock`，照 `LatestFrameBox` 的寫法）：
  - `init(depth: Int)`，depth 最小 1（等於 latest-wins）、本任務只用 2。
  - `put`：無效幀 `rejected += 1` 不入列；有效幀 `arrived += 1`，佇列滿時丟最舊的一幀（`dropped += 1`）再入列。
  - `takeLatest()`：取出**最舊**的一幀（FIFO），佇列空回 nil。方法名叫 `takeLatest` 是為了不改呼叫端，但要在 doc comment 明講這裡的語意是 FIFO 而非 latest。
  - `stats()` 回 `FrameCounterSnapshot`，語意與 `LatestFrameBox` 一致（`arrived`、`dropped`、`rejected`）。
  - 額外提供 `depth` 與目前 `count` 的唯讀屬性，供測試與 log。
- `FramePump.attach(_:into:onEnd:)` 的 `into` 參數型別改成 `any FrameSink`；`EmulatorClient.start(box:width:height:)` 的 `box` 同樣改成 `any FrameSink`（參數名不改，呼叫端傳 `LatestFrameBox()` 照樣編得過）。

### B. `MirageShell`：接線與開關

- `AppModel.swift` 第 14 行的 `let box = LatestFrameBox()` 改成依環境變數建：`MIRAGE_FRAME_QUEUE` 未設或不是正整數 → `LatestFrameBox()`；設為 `N`（≥ 2）→ `FrameQueue(depth: N)`。解析抽成純函式（例如 `FrameSinkFactory.make(from environment: [String: String]) -> any FrameSink`）放在 `MirageCore`，可單元測試。
- `Renderer` 的 `box` 型別改成 `any FrameSink`，`draw` 一行都不改。
- `MIRAGE_CONN_LOG=1` 時在啟動印一行 `[app] frame sink=latest` 或 `[app] frame sink=queue depth=2`，讓 log 看得出這次跑的是哪一種（驗收腳本要靠它確認 A/B 真的切換了）。
- `MirrorView.swift` 第 84 行的 `let box: LatestFrameBox` 同樣改型別。

### C. 延遲量測不能被佇列騙

`Frame.receivedAt` 是抵達時刻，`Renderer.recordLatency` 用它算「抵達到 present」的延遲（`MIRAGE_LATENCY_LOG=1`）。佇列會讓這個延遲多一個 vsync，這是預期的代價，必須量得到：驗收要同時開 `MIRAGE_LATENCY_LOG=1`，比 p50 與 p95 在開關關與開之間的差。不要動 `recordLatency`。

### D. `verify_fps_fullscreen.sh` 加 A/B 模式

- 加旗標 `-q <depth>`：設了就在啟動 app 時多傳 `MIRAGE_FRAME_QUEUE=<depth>` 與 `MIRAGE_LATENCY_LOG=1`，並在收斂後從 log 抓 `[app] frame sink=` 那行印出來確認。
- 加旗標 `-A`：A/B 交錯模式，每一輪跑兩次（一次不設、一次 `-q 2`），順序輪轉，逐輪印兩行 `[round N sink=latest]` 與 `[round N sink=queue2]`，欄位同既有 `[round N]` 加 `lat_p50=`、`lat_p95=`（從 `[app] lat` 行取中位數，`gui_session.sh` 加 `latency_median <log> <p50|p95> [skip]`，比照 `tagged_median`）。摘要多印 `SINK_LATEST_MEDIAN=`、`SINK_QUEUE_MEDIAN=`、`DROPPED_LATEST=`、`DROPPED_QUEUE=`、`LAT_P95_LATEST=`、`LAT_P95_QUEUE=`。
- 不帶 `-q` 也不帶 `-A` 時，行為與現在完全相同（既有的 `[round N]`、`[round N draw]`、判定、退出碼一律不動）。`-A` 模式的驗收判定沿用既有規則但只看 `sink=queue2` 那組的中位數（那是提案要驗收的東西），`sink=latest` 只印不判。

### E. 測試

- `FrameQueueTests`（swift-testing）：FIFO 順序（put 1,2,3 depth 2 → take 得 2 再 3，dropped=1）；depth 1 等於 latest-wins（與 `LatestFrameBoxTests` 同一組輸入得同樣結果）；無效幀 rejected 不入列；take 空佇列回 nil；`stats()` 三個計數的語意；並行 put／take 不崩（照既有 5000 次寫法）。
- `FrameSinkFactory` 的解析：未設、空字串、`0`、`1`、`abc` → `LatestFrameBox`；`2`、`3` → `FrameQueue` 對應深度。
- 既有 `LatestFrameBoxTests`、`FramePumpTests`、`EmulatorClientReconnectTests` 一個字都不改，必須照常通過。
- `gui_session_selftest.sh` 加 `latency_median` 的案例（`[app] lat p50=12.3ms p95=18.9ms n=57` 這種行）。
- `#expect` 不拿 Bool 跟 true／false 比。

### F. 結果文件 `app/RESULTS-d64-queue.md`

改了什麼、`FrameSink` 呼叫端清單（用 `git grep` 列，證明既有測試沒改）、測試清單、自我測試故障注入、沒驗的是什麼。活體 A/B 數字由 PM 補寫。

## 5. 禁區

- 不改 `LatestFrameBox` 的內容，不改既有 `LatestFrameBoxTests`、`FramePumpTests`、`EmulatorClientReconnectTests`。
- 不改 `Renderer.draw` 的控制流、不改 `recordLatency`、不改 `countPresentedFrame` 的三行輸出。
- 預設（環境變數未設）行為必須與現在一模一樣。
- 不改 `verify_fps_fullscreen.sh` 既有模式的輸出與判定。
- 不啟動 emulator、不跑 `swift build`／`swift test`（沙箱跑不了）。
- 不改債務表。

## 6. 驗收條件

1. `swift build --build-tests` 過；`swift test` 全綠，既有測試數只增不減（PM 跑）。
2. `bash app/scripts/ci.sh` 全綠（PM 跑）。
3. 環境變數未設時 app 啟動印 `[app] frame sink=latest`；設 `MIRAGE_FRAME_QUEUE=2` 印 `[app] frame sink=queue depth=2`（PM 在 emulator 上看）。
4. `verify_fps_fullscreen.sh` 不帶新旗標時輸出與改前一字不差（PM 在 emulator 上跑一輪比對）。
5. A/B 活體（PM 跑，在使用者操作機器的條件下）：`sink=queue2` 的 `dropped` 與 `noframe` 相對 `sink=latest` 明顯下降、`mirage` 追上 `guest`、`lat_p95` 增加不超過 20ms。這條是提案成不成立的判準，不是程式碼的驗收；由 PM 判。

## 7. 工作方式

- 沙箱跑不了 Swift；寫到能編的品質後 commit（寫不了 index.lock 就留在工作樹），PM 編譯回饋。strict concurrency 照既有寫法。
- 你能自己驗的：`swiftc -parse`、`bash -n`、`/bin/bash` 3.2 跑自我測試、閘門 4 的 grep。
- 測試先寫，再實作。每個部分一個 commit，訊息 `<type>: <描述>`，繁體中文。
- 註解與文件用繁體中文台灣用語，不用破折號接補充說明。
- 結束時把報告寫進 `app/RESULTS-d64-queue.md`，最後一則訊息列出改動檔案、每條驗收條件的證據、沒做到的事。
