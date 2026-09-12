# 模擬器多開：設計

- 日期：2026-09-12
- 狀態：已核可，範圍為選項 B（多台可切換）
- 量測依據：`app/RESULTS-multi-instance.md`

## 1. 量測結論

這台開發機（Apple M1，4 效能核＋4 節能核，16 GB）上：

| 條件 | guest fps |
|---|---|
| 兩台模擬器都在遊戲關卡內，沒有 Mirage | 59.35 到 59.72（單台 59.9） |
| 兩台＋畫面持續變化＋一個 Mirage | 8.4 到 10.2，兩台一起掉 |
| 每台降到 2 vCPU | 兩台 ANR；單台＋Mirage 也只剩 20 到 22（4 vCPU 時 54 到 57） |
| `-no-window` | 單台無負載 29 到 32；兩台時 1 fps 以下 |

兩個可調的變數都讓結果更差。「兩台同時可玩」在這台機器上不成立，不是參數能解的。

## 2. 範圍：需要裁決

| 選項 | 內容 | 這台機器上可行 |
|---|---|---|
| A. 同時可玩 | 兩台各接一個 Mirage 視窗，同時操作 | 否 |
| B. 可切換 | 多台各自存在、各自開機，同一時間只有一台接 Mirage 串流；切換時舊的那台維持開機但不串流 | 是（兩台開機不串流時各 59.4 以上） |
| C. 不做 | 維持單台 | 是 |

建議 B。切換的成本是重新連線（`EmulatorClient.stop()` → 換端點 → `start()`），現有的重連機制已經涵蓋。

## 3. 選項 B 的設計

### 3.1 資料

一台實例由三個值決定：AVD 名稱、console 埠（5554、5556、……）、gRPC 埠（8554、8556、……）。gRPC token 每台各自在探索檔 `pid_<pid>.ini`，`EmulatorDiscovery` 已能依 gRPC 埠找到對應的 token，不用改。

每台要有自己的 AVD。同一個 AVD 開兩份要 `-read-only`，guest 內的寫入不保存，不能當正式用法。AVD 複製用 `tools/provision`（D33）的規格加一台，userdata 約 6.9 GB 一份。

### 3.2 `app/scripts/emu.sh`

- 加 `-n <名稱>`：名稱對應到一組（AVD、console 埠、gRPC 埠），預設名稱維持現在的 5554／8554。
- `running()` 改成比對該實例的 console 埠而不是任何 qemu 行程。現在的寫法會讓第二台被當成「已在執行」。
- `status` 列出所有執行中的實例與各自的 gRPC 綁定位址。
- `stop` 只停指定實例。

### 3.3 Mirage

- `AppModel` 新增「目前實例」：由 `EmulatorEndpoint` 表示，預設值與環境變數覆寫維持現況。
- 選單列加「切換模擬器」子選單：列出探索檔裡活著的實例（`EmulatorDiscovery` 掃 `pid_*.ini`，這是既有的讀檔邏輯，加一個「列出全部」的純函式即可）。選一個就 `client.stop()` → 換端點 → `client.start()`。
- 切換期間顯示既有的連線橫幅（`ConnectionBanner`），不另做畫面。
- 鍵位 profile 依遊戲偵測自動套用，與實例無關，不改。

### 3.4 不做

- 兩個 Mirage 視窗同時開。
- 同時串流兩台。
- 實例的建立、刪除放在 Mirage 的 UI 裡：用 `tools/provision` 與 `emu.sh`。

### 3.5 驗證

- `emu.sh`：兩台 `-n` 各自 start／status／stop，`running()` 不互相誤判；自我測試放進 ci.sh 閘門 7。
- `EmulatorDiscovery` 列出全部實例的純函式：單元測試，用真實探索檔格式。
- 切換：`verify_keyboard.sh` 先對 5554 通過，切到 5556 再通過一次，切回 5554 再通過一次；guest 端用 `getevent` 判定，不看 Swift 測試的綠燈。
- 切換後另一台仍在開機狀態，`adb shell getprop sys.boot_completed` 為 1。

## 4. 未查的問題

- `-no-window` 為什麼比有視窗慢一倍：兩者 log 都是 Metal translator，原因未查。選項 B 不依賴它。
- 昨天記錄的「兩台＋一個 Mirage 約 19.8」與今天的約 10 差一倍，今天用像素簽名確認兩台都在關卡內，昨天沒有。以今天為準。
