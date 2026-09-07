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
