# D64 深度 2 幀佇列結果

- 日期：2026-09-07
- 分支：`d64-frame-queue`
- 狀態：程式碼與允許的沙箱驗證完成，Swift 編譯與完整測試由 PM 執行

## 改動

- 在 `MirageCore` 新增 `FrameSink` protocol、`FrameQueue` 與 `FrameSinkFactory`。
- `FrameQueue` 使用 `NSLock`，深度至少為 1；滿列時丟最舊幀，`takeLatest()` 依 FIFO 取出最舊幀。
- `LatestFrameBox` 透過 extension 遵從 `FrameSink`，原始檔內容未改。
- `FramePump.attach`、`EmulatorClient.start`、`Renderer` 與 `MirrorView` 改接 `any FrameSink`。
- `AppModel` 依 `MIRAGE_FRAME_QUEUE` 建立 sink。未設、空值、非整數、0、1 都使用既有 latest-wins；2 以上建立對應深度的佇列。
- `MIRAGE_CONN_LOG=1` 時新增 `[app] frame sink=latest` 或 `[app] frame sink=queue depth=N`。
- `verify_fps_fullscreen.sh` 新增 `-q <depth>` 與 `-A`。`-A` 交錯執行 latest 與 queue2，印出幀計數與 latency p50/p95，摘要只以 queue2 中位數判定。
- `gui_session.sh` 新增 `latency_median <log> <p50|p95> [skip]`。

## FrameSink 呼叫端

以下為 `git grep -n -E 'FrameSink|FrameQueue' HEAD -- app/Sources/MirageCore app/Sources/MirageShell app/Tests/MirageCoreTests` 的結果摘要：

- `app/Sources/MirageCore/FrameSink.swift:5` protocol 定義，`:11` 遵從 `LatestFrameBox`
- `app/Sources/MirageCore/FrameQueue.swift:7` queue 實作
- `app/Sources/MirageCore/FrameSinkFactory.swift:4,14` 工廠與 log 標籤
- `app/Sources/MirageCore/FramePump.swift:10` `attach` sink 參數
- `app/Sources/MirageCore/EmulatorClient.swift:42,127,352` 儲存、啟動與掛載
- `app/Sources/MirageShell/AppModel.swift:14,36` 建立與啟動 log
- `app/Sources/MirageShell/MirrorView.swift:84` view sink
- `app/Sources/MirageShell/Renderer.swift:20,36,45` renderer sink
- `app/Tests/MirageCoreTests/FrameQueueTests.swift` queue 測試
- `app/Tests/MirageCoreTests/FrameSinkFactoryTests.swift` 工廠解析測試

既有測試未改動的證據：

```text
git diff --quiet HEAD~4 HEAD -- \
  app/Tests/MirageCoreTests/LatestFrameBoxTests.swift \
  app/Tests/MirageCoreTests/FramePumpTests.swift \
  app/Tests/MirageCoreTests/EmulatorClientReconnectTests.swift
exit=0
```

`LatestFrameBox.swift` 也未改動。`Renderer.swift` 的差異只有 sink 型別與兩個初始化簽章；`draw`、`recordLatency`、`countPresentedFrame` 內容未改。

## 測試清單

- `FrameQueueTests`：深度 2 FIFO、滿列丟最舊、深度 1 latest-wins、無效幀 rejected、空佇列、stats/count、並行 put/take 5000 次。
- `FrameSinkFactoryTests`：未設、空字串、0、1、`abc` 使用 `LatestFrameBox`；2、3 建立對應深度的 `FrameQueue`。
- `gui_session_selftest.sh`：latency p50/p95 小數與 `ms` 後綴、中位數、skip、未知欄位故障案例。
- `verify_common_selftest.sh`：既有斷言與故障注入案例。

## 可重現驗證

以下均通過：

- `swiftc -parse`：本次修改的 MirageCore、MirageShell 與新增測試檔。
- `bash -n`：`verify_fps_fullscreen.sh`、`gui_session.sh`、`gui_session_selftest.sh`。
- `/bin/bash app/scripts/lib/gui_session_selftest.sh`。
- `/bin/bash app/scripts/lib/verify_common_selftest.sh`。
- `git diff --check`。
- 工作樹在寫入本報告前保持乾淨，index lock 可正常寫入，已完成分段提交。

## Commit

- `88c0ed5 test: 新增幀佇列與延遲解析測試`
- `d6ffec0 feat: 新增可切換幀接收端`
- `540e860 feat: 接入可切換幀接收端`
- `e933b10 feat: 加入幀佇列 A/B 驗收腳本`
- 本報告另以 `docs: 記錄 D64 幀佇列結果` 提交

## 驗收條件

1. `swift build --build-tests` 與 `swift test`：依第 7 節未在沙箱執行，待 PM 編譯並回報。
2. `bash app/scripts/ci.sh`：未執行，待 PM 執行完整 CI。
3. 啟動 log：程式碼已接上 `MIRAGE_CONN_LOG=1` 的 latest/queue 標籤，未啟動 emulator；由 PM 在兩種環境變數下確認實際 log。
4. 無 `-q`、無 `-A`：既有量測迴圈與判定分支保留，新增邏輯只在新旗標條件內執行；已做靜態 diff 檢查，未在 emulator 做逐字輸出比對。
5. 活體 A/B：未在沙箱執行。PM 請補填使用者操作條件下的數字。

```text
SINK_LATEST_MEDIAN=
SINK_QUEUE_MEDIAN=
DROPPED_LATEST=
DROPPED_QUEUE=
LAT_P95_LATEST=
LAT_P95_QUEUE=
```

## 尚未驗證

- Swift 型別檢查、`swift build --build-tests`、`swift test`。
- `bash app/scripts/ci.sh`。
- emulator 上的啟動 log、全螢幕量測、A/B dropped/noframe/mirage/latency 數字。
- PM 的活體判準：queue2 相對 latest 的 dropped 與 noframe 下降、mirage 追上 guest，以及 latency p95 增幅不超過 20ms。

## PM 把關與活體驗證（2026-09-07）

### 把關

- codex 盲寫的 Swift 一次編過，340 條測試綠（新增 8 條，`LatestFrameBox` 與既有三個測試檔一字未改）。ci.sh 十六個 ✅。
- 接線只換型別，`Renderer.draw` 沒動；預設環境下 `FrameSinkFactory` 建的是 `LatestFrameBox`。
- 獨立審查抓到一點：A/B 模式收斂失敗不會把 `SIZE_OK` 設回 0，故障模式會被其他輪次的樣本吃掉。一行修好（`verify_fps_fullscreen.sh` `run_ab_sink` 的失敗分支）。
- `/bin/bash` 3.2 下自我測試綠、`-A` 與 `-q` 互斥有擋、閘門 4 乾淨。
- 驗收 3 通過：未設時 log 第一行 `[app] frame sink=latest`，`MIRAGE_FRAME_QUEUE=2` 時 `[app] frame sink=queue depth=2`。
- 驗收 4 通過：既有模式的 `✅ 串流尺寸已收斂…`、`[round N]`、判定訊息與改前一字不差。
- D65 的鎖定檢查第一次實戰生效：一次跑次撞到螢幕自動鎖定，前置直接印「螢幕已鎖定」而不是無聲失敗。

### 活體 A/B（`verify_fps_fullscreen.sh -A -r 3 -l 30`，使用者透過螢幕分享操作機器，外來 CPU 244%）

| 輪 | sink | guest | arrived | presented | dropped | mirage | noframe | in_p95 | lat_p50 | lat_p95 |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | latest | 20.16 | 19 | 19 | 0 | 19 | 42 | 9.7 | 16.9 | 24.2 |
| 1 | queue2 | 15.09 | 14 | 14 | 0 | 15 | 46 | 2.9 | 10.7 | 18.4 |
| 2 | queue2 | 15.76 | 17 | 17 | 0 | 17 | 45 | 3.0 | 11.2 | 18.3 |
| 2 | latest | 20.73 | 17 | 17 | 0 | 20 | 43 | 2.8 | 11.3 | 18.4 |
| 3 | latest | 14.33 | 16 | 16 | 0 | 15 | 47 | 9.7 | 16.6 | 25.0 |
| 3 | queue2 | 15.71 | 15 | 15 | 0 | 16 | 46 | 9.8 | 17.4 | 24.9 |

六輪全部因 guest 未達 55 判無效，退出碼 1。

### 判定

1. **A/B 機制全部驗證通過**：開關真的切換（兩個 sink 的 log 各有自己的 `frame sink=` 行）、交錯順序正確、`lat_p50`／`lat_p95` 解析正確、無效輪次如實不計。工具可用。
2. **提案本身未驗證**：這次的負載形態（螢幕分享，外來 CPU 244%）把 guest 壓到 14 到 21 fps，是 D60 的形狀（guest 先死），不是 D64 的（guest 59 但 Mirage 掉）。guest 每秒只出 15 到 20 幀時抵達間隔遠大於 vsync，兩個 sink 都是 `dropped=0`、`presented=arrived`，抵達抖動根本沒機會出現，佇列自然沒東西可救。
3. **D64 的觸發條件比「使用者在用機器」更窄**：三次現場的外來 CPU 分別是 183%、91%、0 到 34%，guest 都還在 59 以上。要驗證佇列需要「中度負載」：guest 維持 55 以上、但 Mirage 出現 `dropped` 6 到 8、`noframe` 6 的那種。螢幕分享太重，純 CPU burner 又重現不了，目前沒有可靠的重現手段。
4. 一個順帶的觀察：queue2 的 `lat_p50` 沒有比 latest 多一個 vsync（10.7 對 16.9、11.2 對 11.3、17.4 對 16.6），因為抵達太稀疏佇列裡從沒有第二幀。佇列的延遲代價只在抖動真的發生時才付，這與設計預期一致。

### 處置

改動合併（預設關閉，零行為變化，A/B 工具已可用）。D64 維持 P2，狀態改為「解法已實作待驗證，缺可靠的重現條件」。下次自然出現時（`verify_fps_fullscreen.sh` 既有模式量到 guest ≥ 55 但 `dropped` ≥ 5 的輪次），立刻在同條件下跑 `-A`。
