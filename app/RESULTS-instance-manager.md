# InstanceManager 驗收結果

規格：`docs/specs/2026-09-29-instance-manager-design.md`
驗證腳本：`app/scripts/verify_instance_lifecycle.sh --rounds N`（判準見規格 §6）

## 結論

app 啟動時自己開模擬器、⌘Q 一起關、模擬器非預期結束會自動重開一次、`emu.sh` 開的外部實例不接管也不停止。L1 到 L5 共 15 輪全數通過（2026-09-29，3 輪）。

## 實測數字（第二次，3 輪）

| 項目 | 實測 | 上限 |
|---|---|---|
| L1 冷啟動到 `running` | 20.6、21.0、70.4 秒 | 120 秒 |
| L4 SIGTERM 後自動重開到 `running` | 20.9、22.5、44.9 秒 | 150 秒 |
| ⌘Q 到 app 行程消失 | 1.0 到 3.7 秒（9 次） | 6 秒 |
| 開機探測單次耗時 | 119 次，最長 16 ms | 1 秒 |

70.4 秒那一輪的延遲在探索檔出現之前（emulator 行程啟動到 gRPC 開始監聽），探索檔出現後 17 秒進入 `running`，與開機探測無關。

`emulator` 啟動程式與 qemu 是同一個 pid（兩次驗證共 15 次由 app 啟動，含冷啟動與自動重開，`spawnPid` 都等於探索檔 pid），不會 fork 後自行結束。所有權紀錄仍一律取探索檔的 pid。

## 驗證中找到並修正的缺陷

第一次實機驗證（2 輪）L1 第 1 輪停在 `booting` 172 秒，連啟動器自己的 120 秒 `bootTimedOut` 都沒觸發，其餘 9 輪通過。

- 原因：`GrpcHealthProbe.status(timeout:)` 用 `withTaskGroup` 讓 getStatus 與 sleep 賽跑。task group 離開時一定等所有子任務，getStatus 不回應取消時，1 秒逾時變成無限期。`EmulatorLauncher.tick()` 有防重入，一次卡住之後所有 tick 都直接返回，狀態機不再前進。
- 這個原因由程式碼推得，卡住當下的行程已被 ⌘Q 結束，沒有直接觀察到 getStatus 卡在哪一步。
- 修正（`438e2cd`）：`BootProbe` 自己呼叫 getStatus 並加 gRPC deadline；逾時改用 `firstOf`（先完成者勝出、不等另一方）。
- 修正依據是結構而不是次數：修正前 6 次開機卡 1 次，修正後 9 次未再發生，這個次數本身不足以證明。`FirstOfTests` 把 `firstOf` 換回 task group 時會在 2 秒內失敗（突變驗證過）。
- `GrpcHealthProbe.probe` 仍是同樣的 task group 寫法，由 `EmulatorClient` 的連線迴圈使用，未修改，見下方未完成項。

## 未完成

- `GrpcHealthProbe.probe`（連線迴圈的健康探測）有同樣的逾時失效風險，未修。至今沒有觀察到它卡住。
- 冷啟動沒有快照，約 20 秒。規格已把快速開機排除在這一版之外。
- 首次啟動精靈（缺 SDK 或 AVD 時只顯示提示）。
