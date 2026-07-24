# P1-b 生命週期與系統整合（核心 + 剪貼簿）— 設計文件

- **日期**：2026-07-24
- **狀態**：已核准（brainstorming 流程）
- **上游文件**：`2026-07-22-mirage-project-plan.md` §5；建於已合併的 P1-a
- **並行對象**：P1-c（鍵位映射，`2026-07-24-p1c-keymap-engine-design.md`）——合併順序 **P1-b 先**。
- **P1-a 終審遺留（本件負責關閉）**：§4.3 健康探測未實作、斷線期間 banner 顯示「已連線」、
  attempt 恆 0、重連遞迴堆積 async frame（終審 Minor #7）。

## 1. 目標

把 P1-a 的「能連能重連」升級為**可信的生命週期**與**基本系統整合**：真實健康探測、
快照休眠/喚醒、選單列常駐、雙向剪貼簿。體驗對標 iPhone Mirroring 的「關掉即凍結、
點開即回」。

**本件 MVP 範圍（使用者裁決：核心 + 剪貼簿）**：
1. 健康探測（修 P1-a 終審缺口）
2. 快照休眠/喚醒（**gRPC 層**：對執行中模擬器 saveSnapshot/loadSnapshot + app 端凍結/喚醒）
3. 選單列常駐
4. 雙向剪貼簿

**非目標（YAGNI，明確延後）**：
- **行程級休眠**（停 qemu、冷喚醒）→ P1-b2（使用者已確認 MVP 先做 gRPC 層）。
- APK 拖放安裝、音訊 → 後續子專案。
- 通知橋接 → P2。

## 2. 背景約束

- 建於 P1-a：`EmulatorClient`（actor）以 reducer 驅動連線，目前 `doConnect` 在
  `transport == nil` 時跳過重建、且 `.connectSucceeded` 只要 channel 建得起來就觸發
  （無真實探測）——**這正是本件要修的**。實際重連目前靠 grpc-swift `GRPCChannelPool`
  內部完成（P1-a 終審核實）。
- emulator gRPC：`getStatus`（探測）、`SnapshotService.saveSnapshot/loadSnapshot`
  （snapshot_service.proto）、`setClipboard/getClipboard/streamClipboard`（EmulatorController）。
- 併發 `-strict-concurrency=complete`；MirageCore 不 import AppKit/SwiftUI/Metal；不 fatalError。
- 開發環境無 Xcode：swift-testing。
- **NIO teardown**（P1-a Task 4 遺留）：`stop()` 後放掉 channel 前需 await 串流取消——
  本件重構重連時一併處理，且 Cmd+Q 路徑補實測。

## 3. 專案結構

```
app/Sources/MirageCore/Lifecycle/
├── HealthProbe.swift          # getStatus 探測封裝 + 逾時；純介面便於注入
├── SnapshotService.swift      # saveSnapshot/loadSnapshot gRPC 封裝
├── ClipboardBridge.swift      # 雙向同步 + 防回音邏輯（純，重測）
└── PowerState.swift           # active/suspended 純狀態機（凍結/喚醒轉移）
app/Sources/MirageCore/
├── EmulatorClient.swift       # 修改：健康探測 gate、重連改迴圈、drop channel、擴充 snapshot/clipboard
└── ConnectionStateMachine.swift # 可能微調（attempt 語意，見 §4.1）
app/Sources/MirageApp/Lifecycle/
├── MenuBarController.swift     # NSStatusItem：狀態、喚醒、退出
├── ClipboardWatcher.swift      # NSPasteboard 輪詢（AppKit 膠水）
└── AppLifecycle.swift          # 視窗關閉→凍結、喚醒→loadSnapshot、Cmd+Q teardown
app/Sources/MirageApp/
└── MirageApp.swift            # 修改：注入生命週期、選單列、剪貼簿
app/Tests/MirageCoreTests/
├── HealthProbeTests.swift      # 探測成功/逾時/失敗 → 連線事件
├── EmulatorClientReconnectTests.swift # 擴充：健康探測 gate 後的重連/attempt 遞增/banner 誠實
├── ClipboardBridgeTests.swift  # 防回音、雙向、去重
└── PowerStateTests.swift       # 凍結/喚醒轉移
```

## 4. 核心設計

### 4.1 健康探測與重連迴圈（修 P1-a 終審缺口）

**問題**：現況 `doConnect` 建了 channel 就 `.connectSucceeded`，斷線期間 banner 恆「已連線」、
attempt 恆 0、我方 backoff 半死碼。

**修法**：
- `doConnect` 改為：確保 channel 存在（斷線時**先 drop 舊 channelBox/transport 再重建**）→
  以 `HealthProbe.probe(timeout:)`（呼叫 `getStatus`）驗證 → 成功才 `.connectSucceeded`、
  失敗 `.connectFailed`（復活 attempt 遞增與 backoff）。
- 重連由**遞迴改迴圈**：`while running` 迴圈執行「探測→（成功掛串流／失敗睡 backoff 再試）」，
  消除終審 Minor #7 的 async frame 堆積。
- `states` 現在會真實經過 `.reconnecting(attempt: n)`，banner 顯示真實重試次數。
- 注入點：`HealthProbe` 以 protocol 注入，單元測試用假探測（成功/逾時/失敗）驅動迴圈，
  沿用 P1-a 的假 sleeper/randomSource——全程不碰網路。
- **保留 P1-a 的既有行為驗收**：斷線後仍在 10s 內恢復（健康探測只是讓恢復「被正確標記」，
  不拖慢；GRPCChannelPool 的內部重連仍在，探測確認其就緒）。

### 4.2 SnapshotService 與 PowerState（gRPC 層休眠）

```swift
enum PowerState: Sendable { case active, suspending, suspended, waking }
```

- **休眠（視窗關閉／選單列休眠）**：`SnapshotService.save("mirage_suspend")` → 停止 FramePump
  拉幀（省 CPU）→ PowerState `.suspended` → banner/選單列顯示「已休眠」。
  註：MVP 不停 qemu 行程，模擬器仍在背景執行；「休眠」= app 停止串流與渲染。
- **喚醒（選單列點擊／重開視窗）**：PowerState `.waking` → 確認連線（健康探測）→
  `SnapshotService.load("mirage_suspend")`（回到休眠時畫面）→ 恢復 FramePump → `.active`。
- PowerState 為純狀態機（可測轉移）；實際 gRPC 呼叫由 EmulatorClient 執行。
- 快照 save/load 失敗 → 記錄並降級（喚醒時 load 失敗就直接恢復串流當前畫面，不崩）。

### 4.3 ClipboardBridge（雙向 + 防回音）

- **guest→host**：`streamClipboard` 串流 → 更新 NSPasteboard。
- **host→guest**：`ClipboardWatcher` 輪詢 NSPasteboard changeCount → `setClipboard`。
- **防回音**（核心可測邏輯）：記錄最後一次「自己寫入的值+方向」，收到相同值時不回彈，
  避免無限迴圈。`ClipboardBridge.shouldPropagate(value:direction:) -> Bool` 純函式。
- 僅同步純文字（MVP）；圖片/檔案延後。

### 4.4 MenuBarController 與 AppLifecycle（膠水）

- `MenuBarController`：NSStatusItem，選單顯示連線/電源狀態、喚醒、顯示視窗、退出。
- `AppLifecycle`：
  - 視窗關閉 → 觸發休眠（save snapshot + 凍結），不退出 app（選單列常駐）。
  - 選單列喚醒 → load snapshot + 恢復。
  - **Cmd+Q teardown**（修 P1-a NIO race）：`applicationWillTerminate` → await `client.stop()`
    （含 await 串流取消）→ 放 channel → 退出。P1-a 已加 semaphore 版；本件確認其正確並補實測。

## 5. 錯誤處理

- 健康探測逾時/失敗 → `.connectFailed` → backoff 重試（非崩潰、非靜默）。
- snapshot save/load 失敗 → 降級（休眠仍凍結、喚醒回當前串流），記錄。
- 剪貼簿 gRPC 失敗 → 記錄並跳過該次同步，不影響顯示。
- MirageCore 全程不 fatalError；App 層決定呈現。

## 6. 測試策略

- **單元（MirageCoreTests，TDD，≥80%）**：
  - `HealthProbe`：成功→connectSucceeded、逾時→connectFailed、失敗→connectFailed。
  - `EmulatorClientReconnectTests`（擴充）：健康探測 gate 後——探測失敗使 attempt 遞增、
    states 真實經過 reconnecting(n)、探測成功才 connected；重連是迴圈非遞迴（無堆積）。
  - `ClipboardBridge`：host→guest→防回音不回彈、雙向、去重、非文字略過。
  - `PowerState`：active→suspending→suspended→waking→active 合法轉移，非法轉移 no-op。
- **整合/活體**：真模擬器 save/load snapshot round-trip（休眠前後畫面一致）；殺模擬器→
  重連期間 banner 真實顯示 reconnecting（修復驗證）；剪貼簿雙向實測。
- **pending-human（解鎖後）**：選單列互動、視窗關閉→休眠→喚醒體感、Cmd+Q 乾淨退出、
  剪貼簿跨 app 實測。

## 7. 驗收標準（P1-b 出貨線）

1. MirageCore Lifecycle 單元測試全綠、覆蓋 ≥80%；`swift build -c release` 零警告；
   既有 28 tests 不回歸。
2. **健康探測修復驗證**：殺模擬器後，App 的 `states` 序列**真實出現 `.reconnecting(attempt: n)`**
   （n 隨失敗遞增），恢復後回 `.connected`——單元測試 + 活體 log 雙證（關閉 P1-a 終審缺口）。
3. 重連仍在 10s 內恢復（不因健康探測而變慢）——沿用 `verify_reconnect.sh`（含 P1-a 加的 1MB 門檻）。
4. 快照 round-trip：對執行中模擬器 save→改變畫面→load，畫面回到 save 當時（活體，腳本擷圖佐證）。
5. 剪貼簿防回音：單元測試證明「host 設值→guest 收到→不回彈給 host」不成無限迴圈。
6. **pending-human（解鎖後）**：休眠/喚醒體感、選單列、Cmd+Q teardown 實測、剪貼簿跨 app。

## 8. 風險與備註

- **健康探測不可拖慢恢復**：探測 timeout 要短（~1s），且與 GRPCChannelPool 內部重連協調——
  探測是「確認就緒並正確標記」，不是取代 pool 的重連。計畫需實測恢復時間不回歸 P1-a 的 1s。
- **快照語意**：MVP 對執行中模擬器操作，非行程級休眠——「省 CPU」僅省 app 端串流/渲染，
  qemu 仍在跑。真零耗休眠是 P1-b2。spec §7 驗收 4 只驗 gRPC round-trip，不驗 qemu 耗用。
- **與 P1-c 共用面**：本件改 `EmulatorClient`（健康探測/重連迴圈/snapshot/clipboard 方法）與
  `MirageApp`（選單列/生命週期）；P1-c 加 sendTouches/sendKey 與輸入路由。**P1-b 先合**，
  P1-c 整合時建於本件清乾淨的重連迴圈上。`ConnectionStateMachine` 若本件微調 attempt 語意，
  P1-c 不依賴該處，衝突面小。
- NIO teardown 的 Cmd+Q 實測需 GUI + 解鎖，可能落 pending-human——但邏輯正確性本件以
  程式碼分析 + 單元覆蓋確保。
