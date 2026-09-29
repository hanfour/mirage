# 模擬器由 app 啟動與管理（InstanceManager）

- 日期：2026-09-29
- 狀態：設計已確認，待拆實作任務
- 對應計畫：`2026-07-22-mirage-project-plan.md` §4.1 的 `InstanceManager`

## 1. 目標

使用者點開 Mirage.app 就能用，不必先開終端機跑 `emu.sh start`。按 ⌘Q 時，app 自己開的模擬器跟著關掉。

完成後的判準：在一台已經跑過 `tools/provision/provision.py` 的 Mac 上，模擬器沒在跑的狀態下從 Finder 開 Mirage，約 30 秒內看到 Android 桌面；⌘Q 後 `pgrep -fl qemu-system` 沒有結果。

## 2. 範圍

要做：

1. 實例表改成單一檔案，`emu.sh` 與 app 都讀它。
2. app 啟動時，目標實例沒在跑就自己啟動。已經在跑就直接接上。
3. app 記錄自己啟動了哪些模擬器，⌘Q 只停這些。
4. 自己啟動的模擬器非預期結束時自動重開一次，再失敗就停下並顯示原因。
5. 連線提示改成依啟動狀態顯示文字，失敗時提供「重新啟動」按鈕；選單列加「重新啟動模擬器」。
6. 多開選單列出實例表中所有實例，選到沒在跑的就啟動它。

不做：

- 快速開機（快照）。`loadSnapshot` 曾讓執行中的模擬器崩潰（`RESULTS-p1b.md` 發現 1），冷開機約 30 秒先接受，另開一筆處理。
- 首次啟動精靈（下載 SDK、建立 AVD）。缺 SDK 或 AVD 時只顯示缺什麼、提示執行 `provision.py`，精靈是下一份設計。
- 效能設定畫面（CPU、RAM、解析度）。
- 修改 `emu.sh` 的行為。`emu.sh` 保留給驗證腳本用，只改它讀實例表的方式。

## 3. 現況

| 項目 | 現況 |
|---|---|
| 啟動模擬器 | 只有 `app/scripts/emu.sh start` 會做。app 內唯一呼叫 `Process()` 的是 `AdbClient` |
| 啟動旗標 | `-avd <AVD> -no-snapshot -port <console> -grpc <grpc> -grpc-use-token -no-window`（`emu.sh:126-127`） |
| 開機完成判斷 | `emu.sh` 用 adb 輪詢 `sys.boot_completed`，每 3 秒一次、最多 60 次 |
| 開機後設定 | `settings put secure show_ime_with_hard_keyboard 0`（`emu.sh:configure_guest_keyboard`） |
| 停止 | `adb -s emulator-<console> emu kill`，等 30 秒。不用 `kill -9`，會留下孤兒行程 |
| 實例表 | 寫死在 `app/scripts/lib/emu_instances.sh:17`：`mirage-game:5554:8554 mirage-poc:5556:8556`，可用 `MIRAGE_INSTANCES` 整份覆寫 |
| app 找實例 | `EmulatorDiscovery.instances()` 讀 `~/Library/Caches/TemporaryItems/avd/running/pid_*.ini`，只看得到正在跑的 |
| app 端點 | `EmulatorEndpoint.default` 是 `localhost:8554`，可用 `MIRAGE_HOST`／`MIRAGE_PORT` 覆寫 |
| 沒有模擬器時 | `ConnectionBanner` 顯示紅色「未連線」，沒有任何操作可做 |

## 4. 設計

### 4.1 實例表只保留一份

新增 `app/Sources/MirageCore/Resources/instances.conf`，一行一台，格式與現在的三元組相同：

```
# AVD 名稱:console 埠:gRPC 埠。第一行是 app 預設連的實例。
mirage-game:5554:8554
mirage-poc:5556:8556
```

- `Package.swift` 的 MirageCore `resources` 加上 `.copy("Resources/instances.conf")`。
- `emu_instances.sh` 的 `EMU_DEFAULT_INSTANCES` 改成讀這個檔（以 `BASH_SOURCE` 算出相對路徑，忽略 `#` 開頭與空行，串成空白分隔字串）。`MIRAGE_INSTANCES` 覆寫維持不變。讀不到檔案時直接報錯退出，不退回寫死的值。
- Swift 端新增 `InstanceTable`（純函式）解析這個檔，驗證規則與 `emu_validate_triplet` 一致：console 埠為 5554 到 5682 的偶數、gRPC 埠為 1 到 65535、AVD 名稱不重複、埠不重複。解析失敗時 app 顯示錯誤，不猜。

### 4.2 元件

| 檔案 | 類型 | 職責 |
|---|---|---|
| `MirageCore/Lifecycle/InstanceTable.swift` | 純函式 | 解析與驗證 `instances.conf` |
| `MirageCore/Lifecycle/SdkLocator.swift` | 純函式（環境可注入） | 決定 SDK 根目錄：`ANDROID_SDK_ROOT` → `ANDROID_HOME` → `~/Library/Android/sdk`。從 Finder 開啟的 app 拿不到 shell 的環境變數，所以最後一項是實際會走到的路徑。`AdbClient.standard` 改用它 |
| `MirageCore/Lifecycle/LaunchPlan.swift` | 純函式 | 輸入實例與 SDK 路徑，輸出 emulator binary 路徑、參數陣列、log 路徑。參數與 `emu.sh` 相同，並以單元測試鎖住 |
| `MirageCore/Lifecycle/LaunchCheck.swift` | 純函式（檔案存在與否可注入） | 啟動前檢查：emulator binary 存在、`~/.android/avd/<AVD>.ini` 存在（`ANDROID_AVD_HOME` 可覆寫）、同一個 AVD 沒有在別的 console 埠上跑。回傳第一個不通過的原因 |
| `MirageCore/Lifecycle/InstanceState.swift` | 純狀態機 | 狀態與轉移，見 §4.4 |
| `MirageCore/Lifecycle/OwnedInstances.swift` | 純函式＋檔案讀寫 | app 啟動過的實例清單，見 §4.5 |
| `MirageShell/Lifecycle/EmulatorLauncher.swift` | I/O | 唯一碰 `Process` 啟動模擬器的地方：啟動、停止、每 2 秒檢查 pid 是否還活著 |
| `MirageShell/AppModel+Launcher.swift` | 接線 | 把狀態接到 `ConnectionBanner`、選單列、多開切換 |

`EmulatorLauncher` 用 `Process` 直接執行 emulator binary，stdin 接 `/dev/null`，stdout 與 stderr 寫到 `~/Library/Logs/Mirage/emulator-<AVD>.log`（每次啟動覆寫）。

### 4.3 啟動流程

app 啟動時（`AppModel.start()` 呼叫 `client.start` 之前）：

1. 有 `MIRAGE_HOST` 或 `MIRAGE_PORT` 覆寫時，不管理模擬器，行為與現在相同。驗證腳本都會設這兩個變數或自己先跑 `emu.sh`，因此不受影響。
2. 目標實例是實例表的第一行（與目前預設的 `localhost:8554` 相同）。
3. 讀探索檔。目標實例已經在跑，狀態直接進 `booting` 或 `running`，不重開。
4. 沒在跑時執行 `LaunchCheck`。不通過就進 `failed(原因)`。
5. 通過就啟動，進 `launching`。
6. 探索檔出現該實例（代表 gRPC 已開）後進 `booting`。`client.start` 照常呼叫，靠既有的重連機制連上，所以開機動畫會直接顯示在視窗裡。
7. `getStatus` 回傳 `booted == true` 後進 `running`，接著用 `AdbClient` 設定 `show_ime_with_hard_keyboard 0`。這一步失敗只記 log，不影響狀態。

開機完成改用 gRPC `getStatus().booted` 判斷，不再用 adb 輪詢。健康探測本來就在呼叫 `getStatus`（`HealthProbe.swift`），只要把 `booted` 帶進 `EmulatorInfo`。

逾時：`launching` 超過 30 秒、或 `launching` 加 `booting` 合計超過 120 秒，進 `failed(逾時)`，行程不殺，讓使用者可以看 log。

### 4.4 狀態

```
stopped ──啟動──▶ launching ──探索檔出現──▶ booting ──booted──▶ running
   ▲                  │                        │                   │
   │                  └──────────┬─────────────┴───────────────────┘
   │                        行程非預期結束
   │                             ▼
   │               restarting（已重開過一次就改進 failed）
   │
stopping ◀──⌘Q／選單停止──（任何狀態）
failed(原因) ──使用者按「重新啟動」──▶ launching
```

- 狀態只描述 app 啟動的實例。接上的外部實例（`emu.sh` 開的）狀態固定為 `external`，不重開、不停止，斷線時沿用既有的「重新連線中」提示。
- 自動重開規則：非預期結束後重開一次。重開後 60 秒內又結束，進 `failed(模擬器異常結束)`。超過 60 秒才結束，視為新的一次，可再重開一次。
- `stopping` 期間的結束屬於預期結束，不觸發重開。

轉移寫成純函式 `InstanceState.next(event:now:)`，時間由參數傳入，測試不必等待。

### 4.5 所有權

app 啟動模擬器後，把以下資料寫入 `~/Library/Application Support/Mirage/owned-instances.json`：

```json
[{ "avd": "mirage-game", "consolePort": 5554, "pid": 51234, "startedAt": "2026-09-29T10:00:00Z" }]
```

- 寫入採用暫存檔加 rename，與 `ProfileStore` 相同。
- app 啟動時讀這份清單，逐筆比對探索檔：同一個 pid 且 AVD 名稱相同才算數，其他的刪掉。這樣 Mirage 自己崩潰後重開，還認得出上次開的模擬器；pid 被系統重複使用時也不會誤認。
- 認回來的實例狀態是 `booting` 或 `running`（依 `booted`），⌘Q 時會停掉，也適用自動重開。
- 監看一律用 pid 檢查（`kill(pid, 0)`，已有 `EmulatorDiscovery.pidIsAlive`），不用 `Process.terminationHandler`。認回來的實例不是 app 的子行程，拿不到 `terminationHandler`，兩種來源用同一種方式監看。

### 4.6 停止

⌘Q 時在 `applicationWillTerminate` 裡，對清單中每台執行 `adb -s emulator-<console> emu kill`，最多等 5 秒。5 秒內沒結束也放手讓 app 退出，模擬器收到 kill 後會自己結束。不使用 `kill -9`。停止後從清單移除。

這一步必須在既有的 `model.shutdown()` 之前送出 kill、之後才等待，避免 app 退出卡住。實作時要實測 ⌘Q 到 app 消失的時間，超過 6 秒視為不通過。

關閉視窗仍然是休眠，模擬器繼續跑（驗收線 4 的既有決定）。

### 4.7 畫面

`ConnectionBanner` 目前只看 `ConnState`，改成同時看實例狀態：

| 實例狀態 | 顯示 | 操作 |
|---|---|---|
| `launching` | 啟動模擬器中… | 無 |
| `booting` | Android 開機中…（視窗同時顯示開機動畫） | 無 |
| `restarting` | 模擬器意外結束，重新啟動中… | 無 |
| `failed(找不到 SDK)` | 找不到 Android SDK。請先執行 tools/provision/provision.py | 無 |
| `failed(找不到 AVD)` | 找不到模擬器 <AVD>。請先執行 tools/provision/provision.py | 無 |
| `failed(AVD 已在使用)` | <AVD> 已在其他埠上執行 | 無 |
| `failed(逾時)`、`failed(異常結束)` | 原因＋「重新啟動」按鈕＋「顯示記錄檔」按鈕 | 重新啟動、在 Finder 顯示 log |
| `running`、`external` | 依原本的 `ConnState` 顯示 | 維持原樣 |

選單列加「重新啟動模擬器」，只在目前實例是 app 啟動的時候可用：停止後重新走 §4.3。

### 4.8 多開

選單列的「切換模擬器」改成列出實例表的全部實例，沒在跑的標示「未啟動」。選到沒在跑的實例時先啟動它，再走既有的 `switchInstance`。切換時不停止原本那台，與現行多開設計（`2026-09-12-multi-instance-design.md` 選項 B）一致；⌘Q 時所有 app 啟動的實例一起停。

## 5. 相容性

- `emu.sh` 的參數與行為不變。`emu_selftest.sh` 需要改成從 `instances.conf` 取預設值，並加一條測試：`instances.conf` 讀不到時 `emu.sh` 退出碼非 0。
- 設了 `MIRAGE_HOST`／`MIRAGE_PORT` 的驗證腳本，app 不管理模擬器。
- 沒設覆寫、但先用 `emu.sh` 開好模擬器的腳本，app 會接上外部實例，不重開也不停止。`verify_reconnect.sh` 這類會自己殺模擬器的腳本，看到的仍是「重新連線中」，不會被 app 的自動重開干擾。實作時要逐一檢查 `app/scripts/verify_*.sh` 中會停止模擬器的腳本，確認都屬於上述兩種情況。
- `EmulatorEndpoint.default` 維持寫死 `localhost:8554`，另加單元測試檢查它等於實例表第一行的 gRPC 埠。執行期不多一條讀檔失敗的路徑，兩邊不一致時測試會失敗。

## 6. 測試

單元測試（`swift test`，不需要模擬器）：

- `InstanceTable`：正常兩行、空行與註解、console 埠奇數、埠超出範圍、AVD 重複、埠重複、空檔。
- `SdkLocator`：三個來源的優先順序。
- `LaunchPlan`：參數陣列與 `emu.sh` 完全相同（逐項比對）、log 路徑。
- `LaunchCheck`：每種不通過原因各一條。
- `InstanceState`：每條轉移；重開後 59 秒與 61 秒結束的兩種結果；`stopping` 中結束不重開；`external` 不受任何事件改變。
- `OwnedInstances`：pid 相同但 AVD 不同時刪除、pid 已結束時刪除、檔案不存在時回空清單、檔案內容壞掉時回空清單並記 log。
- `emu_selftest.sh`（閘門 7）：從 `instances.conf` 取得的預設表與舊的寫死值相同。

實機驗證，新增 `app/scripts/verify_instance_lifecycle.sh`，用 `package_app.sh` 打包、`open -n --env MIRAGE_BACKGROUND_MODE=0` 啟動，不設 `MIRAGE_HOST`／`MIRAGE_PORT`：

| 情境 | 前置 | 判準 |
|---|---|---|
| L1 冷啟動 | `emu.sh stop` 停掉所有實例 | 120 秒內 app log 出現 `running`，`owned-instances.json` 有一筆，pid 存活 |
| L2 接上外部實例 | `emu.sh start` 先開好 | app 不啟動新行程（qemu 行程數不變），狀態為 `external` |
| L3 ⌘Q 停止 | 接在 L1 之後，用 `lib/cgkey.js` 送 ⌘Q | app 6 秒內結束；30 秒內該 pid 結束；清單為空 |
| L4 自動重開 | 接在 L1 之後，對模擬器 pid 送 SIGTERM | 狀態經過 `restarting` 回到 `running`，新 pid 與舊 pid 不同 |
| L5 L2 之後 ⌘Q | 接在 L2 之後 | 外部模擬器 pid 仍存活 |

判斷一律看 app log 與 `pgrep`，不看畫面。每個情境至少跑兩次。

## 7. 實作任務

依序做，每項完成都要過 `ci.sh`：

1. `instances.conf`、`InstanceTable`、`emu_instances.sh` 改讀檔、`emu_selftest.sh` 補測試、`EmulatorEndpoint.default` 與表一致的測試。
2. `SdkLocator`、`LaunchPlan`、`LaunchCheck` 與單元測試。`AdbClient.standard` 改用 `SdkLocator`。
3. `InstanceState` 狀態機與單元測試。`EmulatorInfo` 加上 `booted`。
4. `OwnedInstances` 與單元測試。
5. `EmulatorLauncher`、`AppModel+Launcher` 接線、`applicationWillTerminate` 停止流程。
6. `ConnectionBanner` 與選單列（重新啟動、多開列出全部實例）。
7. `verify_instance_lifecycle.sh`，L1 到 L5 各跑兩次，結果寫進 `app/RESULTS-instance-manager.md`。
