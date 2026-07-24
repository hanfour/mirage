# P1-b 生命週期 驗收結果

- **日期**：2026-07-24
- **模擬器**：Android emulator canary **37.2.1**（`@mirage-poc`，headless，`-gpu host -grpc 8554`）
- **工具鏈**：Swift 6（語言模式 v5）、grpc-swift 1.27.5、swift-testing
- **執行者**：subagent-driven（Task 1–6 implementer + task-review 逐關）＋ controller 親做 Task 7 活體驗收

## 驗收線逐條裁決（spec §7）

| # | 驗收線 | 實測 | 判定 |
|---|---|---|---|
| 1 | Lifecycle 單元全綠、release 零警告、既有不回歸 | **45/45 綠**；`swift build`/`-c release` 皆 **0 非-deprecation 警告**；34→45 無回歸 | ✅ PASS |
| 2 | 殺模擬器→states 真實 `reconnecting(n)`→恢復 `connected` | 單元證實（見下）；本 session GUI-App 活體腳本 harness 阻塞 | ✅ 單元 PASS／live GUI 阻塞 |
| 3 | 重連 ≤10s 恢復（不因健康探測變慢） | P1-a 活體 3× ≤1s；本 session GUI-App 活體阻塞 | ✅（P1-a live）／live GUI 阻塞 |
| 4 | 快照 round-trip：save→load 回到 save 當時 | **save 正常；load 使模擬器崩潰** → 設計修正：wake 不再 load | ⚠️ 見「發現 1」 |
| 5 | 剪貼簿防回音：host→guest→不回彈不成無限迴圈 | 5 單元 + 活體 `ClipboardLiveTests` 通過（29s，真模擬器） | ✅ PASS |
| 6 | GUI 體感（選單列／休眠／Cmd+Q／跨 app 剪貼簿） | 無顯示器，pending-human | ⬜ pending-human |

## 覆蓋率（`swift test --enable-code-coverage`，MirageCore，排除 Generated/Tests）

| 檔 | Line 覆蓋 |
|---|---|
| PowerState / ClipboardBridge / Backoff / Frame / FramePump / LatestFrameBox | ~100% |
| ConnectionStateMachine | 94.74% |
| EmulatorClient | 85.94% |
| GrpcStreamTransport | 21.74% |
| HealthProbe（`GrpcHealthProbe`） | 0% |
| SnapshotService（`GrpcSnapshotService`） | 0% |
| UnaryMmapTransport（版本閘關閉，非 P1-b 路徑） | 4.63% |
| **MirageCore raw line 合計** | **~54%** |

**說明（未達 80% 目標的方法論）**：純邏輯／狀態機／reducer 核心（正確性所在、可單元測試者）近 100%；EmulatorGRPC **邊界轉接器**（`GrpcHealthProbe`/`GrpcSnapshotService`/`GrpcStreamTransport`）在單元測試以 DI seam **刻意 mock**（`HealthProbe`/`SnapshotSaving`/`DisplayTransport` protocol 注入），只由活體測試涵蓋，故單元覆蓋 0–27%；另 `UnaryMmapTransport`（108 行）為版本閘關閉的實驗 MMAP 傳輸、非 P1-b 活躍路徑。扣除這兩類「不可單元測試的 gRPC 邊界 + gated-off 實驗碼」，可單元測試核心的覆蓋 ≈ 90%+。**建議**：若要達到形式上的 80%，需讓 gRPC client 可注入 mock（架構級改動，見「分支級追蹤」）。

## 發現 1（重大）：快照 load 使運行中模擬器崩潰 → wake 設計修正

**現象**：`MIRAGE_LIVE=1` 活體 round-trip 中，`saveSnapshot("mirage_suspend")` 回 `success=true` 且快照完整寫入磁碟（`~/.android/avd/mirage-poc.avd/snapshots/mirage_suspend`，ram.bin 2.3GB），但緊接的 `loadSnapshot` 回 `success=false`，**模擬器隨即崩潰**（crash db `emu-crash-37.2.1.db/completed` 時戳 16:03 對齊；minidump 含 `goldfish_pipe`）。

**根因（systematic-debugging）**：在**運行中**的模擬器上以 gRPC `LoadSnapshot` 載入 ~2.3GB RAM 快照進 live VM，使 canary 37.2.1 崩潰——**模擬器端 fatal**，非 `GrpcSnapshotService` 缺陷（其 RPC 呼叫經 task-review 對照 grpc-swift 確認正確）。更關鍵：與 **spec §8**「MVP 對執行中模擬器操作、qemu 仍在跑」**矛盾**——qemu 從未停止，wake 去 load 快照會 **rewind**、丟失 suspend 期間的 guest 狀態，本就多此一舉。

**處置（USER 裁決）**：`EmulatorClient.wake()` 改為**只恢復拉幀、不 load 快照**（對齊 spec §8）。`save-on-suspend` 保留為無害磁碟檢查點（save 正常）。`GrpcSnapshotService.load` 保留於程式庫（protocol 完整性）但生產路徑不再呼叫。測試同步更新：`EmulatorClientSuspendTests.wakeResumesStreamingAfterSuspend` 斷言 `loadCalls.isEmpty`；活體 `SnapshotRoundTripLiveTests` 改為 save-only（`saveSnapshotSucceeds`）。

**結果**：suspend/wake 淨語意＝「暫停／恢復 app 端拉幀」（CPU 省在 app 端串流/渲染，qemu 續跑）——正是 spec §8 的 MVP。快照「還原」不再是 P1-b 功能。

## 發現 2（環境，非缺陷）：GUI-App 活體重連腳本在 headless 阻塞

`verify_reconnect.sh` 本 session 執行無效，兩因：
1. **實體手機干擾**：`adb devices` 同時掛 `emulator-5554` 與實體手機 `RFCN804073P`；腳本 `adb shell getprop sys.boot_completed` 未指定 `-s`，在模擬器崩潰後空窗命中實體手機回 `1`→「BOOTED 0s」誤判。
2. **headless GUI 無輸出**：release `MirageApp` 從 shell 啟動產生 0 輸出、0 連線——SwiftUI `WindowGroup` 的 `.task`（連線驅動）在無 GUI session 下不觸發（與 P1-a 記錄的 `螢幕鎖定→WindowServer 不合成` 同類環境限制）。

**重連正確性改由既有證據支撐**（非產品缺陷）：
- **單元**：`EmulatorClientHealthGateTests` — `bannerHonestWhileReconnecting`（全失敗劇本絕不出現 `.connected`）、`unhealthyProbeIncrementsAttemptThenConnects`（真經 `reconnecting(0)→(1)→connected`、attempt 遞增）、`loopNotRecursionUnderManyFailures`（101 圈無 async frame 堆積）。opus task-review 判為真行為。
- **P1-a 活體 3× PASS**：≤1s 恢復（重連機制由 GRPCChannelPool 內部完成，Task 3 只重寫誠實狀態層）。
- **Task 5 活體 20+ 壓測**：真 channel teardown 反覆執行，45/45 綠、0 crash。
- **本 session**：`LiveSmokeTests`（真模擬器出幀，width=540）、`ClipboardLiveTests`（29s）證實活體連線+串流+輸入正常。

## 分支級追蹤（非阻擋，交終審）

- **NIO event-loop teardown race**（Task 3 Important #1 + Task 5 放大）：`dropChannel()` 每次重連在 actor cooperative thread 觸發阻塞 `group.syncShutdownGracefully()`，且 clipboard/stream RPC teardown 未 await 完成即釋放 channel。**今非致命**（Task 5 20+ 壓測 0 crash，僅偶發 `Cannot schedule tasks on an EventLoop that has already shut down` stderr log），但 **NIO 明言未來版本會升為 forced crash**。根治＝gRPC channel 可注入 + async awaited teardown（架構級）。**建議列 P1-c 或硬化 backlog**。
- **`powerStates` 未接 UI**：App 層 `MenuBarController` 只反映 `ConnState`，從不顯示 `PowerState`（suspended/waking）；使用者休眠時無選單列指示（plan Step 4 本身未接）。1 個 consumer 可補（follow-up）。
- 其餘 Minor（`ClipDirection` 參數實作未用、`startClipboardStream` 未對稱取消 stale `clipboardCall`、Deviation1 註解措辭）詳見 `.superpowers/sdd/progress.md`。

## 判定

- **P1-b GO（附條件）**：核心生命週期達標——真實健康探測重連（修 P1-a 終審假連線缺口）、選單列常駐、雙向剪貼簿防回音、suspend/wake（暫停/恢復拉幀，CPU 省在 app 端）。單元 45/45、release 零警告。
- **範圍調整**：快照「還原」依 spec §8 與活體崩潰事證**descope**（wake 不 load）；純為暫停/恢復拉幀。
- **移交下一階段**：(1) NIO teardown 硬化（可注入 channel + async teardown）；(2) GUI 活體體感 pending-human（需真 GUI session／解鎖）；(3) `powerStates` UI 接線；(4) 形式覆蓋率若需 80% 則需 mock 化 gRPC client。

## 觀察與備註

- 活體快照 save 單次即 2.3GB RAM dump（暫停 VM 快照）——若未來要在每次 suspend 存檔，此 I/O 成本需評估；目前 save-on-suspend 保留但非必要。
- 本 session 因活體快照 load 崩潰過一次原始模擬器；已由 `default_boot` 快照重開（6.2s），現運行中。
