# Mirage 對 guest 回壓量測

- 日期：2026-09-07
- 規格：`docs/specs/2026-09-07-mirage-cpu-backpressure-design.md`
- 狀態：第二輪 shell 修正完成，活體數字由 PM 補寫

## 改動

- 新增 `scripts/lib/backpressure.sh`，提供條件輪轉、下位中位數差值、有效樣本分流與 CPU 報表加總。
- 新增 `scripts/lib/backpressure_selftest.sh`，覆蓋三條件與兩條件輪轉、空樣本差值、`FOREIGN_MAX` 邊界。
- 新增 `scripts/verify_guest_backpressure.sh`，依序量測 `none`、`pull`、`app`，在 client ready 後才重新清零 guest 與 CPU 窗口。
- `gui_session.sh` 新增 `gui_session_fullscreen <log> <bundle> <min_width>`。
- `verify_fps_fullscreen.sh` 改呼叫共用函式，保留原本的重試控制與判定。
- `ci.sh` 閘門 7 新增 `backpressure_selftest.sh`。
- 8.1：`app` 啟動與全螢幕收斂失敗時，依 `ROUND_RETRY_MAX`（預設 3）關掉重開；三次都失敗只淘汰當下樣本，不中止跑次。無效逐輪行仍印出 `mirage_fps=0`。
- 8.2：前置完成後加入 `COOLDOWN_SECONDS`（預設 20）冷卻，再過一次 `load_gate`；條件之間加入 `CONDITION_GAP`（預設 5），包含輪次邊界。
- 8.4：`pull` 的 `--seconds` 改為 `DURATION+30`。`SNAP_B` 後立即檢查 `mirage-pull`／`MirageApp` 是否仍存活；提前結束的樣本印明確理由、`host_cpu_client=NA`，不計入中位數。

`pull` 固定請求 898x1996；`app` 使用同一個 AXFullScreen 與 `attachStream` 寬度收斂流程。有效性會排除 guest 找不到 layer、`foreign > FOREIGN_MAX` 或 client 提前結束的樣本；正常 `app` 逐輪行另印 `mirage_fps` 中位數。

本輪依工作方式將 8.1、8.2、8.4 分成三個獨立提交，結果文件隨 8.4 提交一併更新。

## 全螢幕抽取證明

抽取前後以兩種靜態檢查對照：

```text
$ git diff --unified=0 6bf17f7^..HEAD -- app/scripts/verify_fps_fullscreen.sh \
    | rg '\[round [^]]+\]|\[round [^]]+ draw\]' \
    || echo 'no [round N] or [round N draw] lines changed'
no [round N] or [round N draw] lines changed
```

原本的可觀察訊息字串仍全部存在，只從主腳本搬到共用函式或保留在呼叫端：

```text
視窗 ${...} 秒內未在 AX 出現，這次啟動失敗，關掉重開
⚠️ AXFullScreen 設定失敗：${...}
⚠️ AXFullScreen 第 ${...} 次重送失敗：${...}
本輪第 ${...} 次啟動未收斂到解析度上限（最後一次請求 ...），關掉重開
✅ 串流尺寸已收斂到解析度上限附近（...，寬度 ≥ 896）
```

變更只替換函式內部變數名稱，預設值仍為視窗等待 15 秒、尺寸輪詢 10 次且每次 1 秒、重送間隔 2 秒最多 3 次、寬度門檻 896。`[round N]` 與 `[round N draw]` 行沒有 diff。沒有 emulator，因此尚未做 PM 要求的活體逐輪輸出比對。

## 自我測試

執行環境：

```text
/bin/bash GNU bash 3.2.57(1)-release (arm64-apple-darwin25)
```

`/bin/bash -n` 通過以下變更腳本：`verify_guest_backpressure.sh`、`backpressure.sh`、`backpressure_selftest.sh`、`gui_session.sh`、`verify_fps_fullscreen.sh`、`ci.sh`。

回壓 self-test：

```text
=== rotate_conditions ===
✅ 三條件第 1 輪
✅ 三條件第 2 輪
✅ 三條件第 3 輪
✅ 兩條件第 1 輪
✅ 兩條件第 2 輪
✅ 兩條件第 3 輪

=== median_delta ===
✅ 中位數差值 A-B
✅ 左側無資料
✅ 右側無資料

=== FOREIGN_MAX 無效分流 ===
✅ guest 找不到優先判無效
✅ foreign 超過上限判無效
✅ foreign 等於上限仍有效

全部通過
```

故障注入把 `rotate_conditions` 的模數從條件數改成 2，self-test 紅燈：

```text
❌ 三條件第 3 輪：得到 none,pull,app，期待 app,none,pull
1 項失敗
FAULT_INJECTION_EXIT=1
```

`gui_session`、`load_sentinel`、`guest_fps`、`verify_common`、`audio_stats` 與 `backpressure` 六支 self-test 這次均以 `/bin/bash` 通過並輸出 `全部通過`。依規格，`gui_session_fullscreen` 本身需要 GUI，沒有被 `gui_session_selftest.sh` 覆蓋。

## Dead-port 驗證

```text
$ app/scripts/verify_guest_backpressure.sh -p 45999
EXIT=1
=== 前置：gRPC ===
❌ gRPC 45999 無回應，模擬器未啟動。
```

此結果證明腳本在 `require_grpc` 就停止，未進入 `require_device`、Swift 建置或量測流程。

## 驗收對照

1. `bash app/scripts/ci.sh`：未執行。該腳本會執行 `swift build` 與 `swift test`，本輪規格明確禁止；閘門 7 的六支 shell self-test 已直接驗證。
2. `verify_fps_fullscreen.sh` 活體逐輪輸出：未驗證，需 PM 在 emulator 上執行；靜態證據見上方，`[round N]` 與 `[round N draw]` 未變更。
3. `backpressure_selftest.sh`：通過；輪轉故障注入退出碼 1。
4. `verify_guest_backpressure.sh -p 45999`：退出碼 1，且在 `require_grpc` 紅燈。
5. `/bin/bash` 3.2 的 `bash -n` 與 self-test：通過。

## 尚未取得的數字

沒有啟動 emulator、沒有執行 adb、沒有執行 `swift build`／`swift test`，所以尚無 `none`／`pull`／`app` 的 guest fps、主機 CPU、中位數與 `DELTA_NONE_PULL`／`DELTA_PULL_APP`／`DELTA_NONE_APP`。PM 需補上活體數字，以及抽函式前後一次完整 `verify_fps_fullscreen.sh` 的逐輪輸出。

本輪三個修正均已建立獨立 Git commit；工作樹中原有的 `phase0/harness/.venv-d45` 未追蹤目錄未被納入。

## PM 把關與活體驗證（2026-09-07）

### 把關

- ci.sh 兩輪都十六個 ✅（六支自我測試），`/bin/bash` 3.2 下 `bash -n`、`backpressure_selftest.sh`、`gui_session_selftest.sh`、`-p 45999` 退出碼 1 全部通過。
- `verify_fps_fullscreen.sh` 抽出 `gui_session_fullscreen` 後在 emulator 上跑兩輪，`✅ 串流尺寸已收斂…`、`[round N]`、`[round N draw]` 三種行與抽前一字不差。
- 第一輪活體在 `app` 條件一次失敗就整個跑次作廢，加上第一個條件撞到 `build_warm` 的餘熱（`none` 量到 50.85，同機手動量兩次 59.68／59.61），退回三點：`app` 條件關掉重開最多 3 次、前置後冷卻 20 秒再過一次 `load_gate`、條件間留 5 秒。獨立審查另外抓到 `pull` 的 client 靠 `--seconds` 自己下車可能在 `SNAP_B` 前結束讓 `host_cpu_client` 安靜印 0.0，改成 `SNAP_B` 後才 kill 並用 `kill -0` 驗存活。
- 第二次活體 `app` 條件九次啟動全部「視窗 15 秒內未在 AX 出現」，根因是螢幕在跑次中途自動鎖定（D65 第二次）。PM 補了 `gui_session_start` 的前置檢查：鎖定就紅並明講，附純函式 `gui_screen_lock_state` 與四條自我測試。

### 活體 run2：`none` 與 `pull` 三輪全部有效（負載 5.88，冷卻後 load_gate 通過）

| 輪 | 條件 | guest | frames | host_cpu_qemu | host_cpu_client | host_cpu_foreign |
|---|---|---|---|---|---|---|
| 1 | none | 59.90 | 1206 | 126.0 | 0 | 44.3 |
| 1 | pull | 59.92 | 1208 | 186.7 | 36.2 | 15.4 |
| 2 | pull | 59.96 | 1210 | 239.1 | 40.5 | 20.3 |
| 2 | none | 59.78 | 1208 | 147.2 | 0 | 46.6 |
| 3 | none | 59.92 | 1206 | 131.8 | 0 | 13.0 |
| 3 | pull | 59.87 | 1212 | 263.7 | 45.0 | 13.3 |

中位數：`none` 59.9（qemu 131.8%）、`pull` 59.9（qemu 239.1%）。`DELTA_NONE_PULL=0.0`。

### 判定（部分）

1. **emulator 端編碼與送出對 guest 零回壓。** 有 client 拉 898×1996 raw RGBA 時 qemu 的 CPU 從約 132% 升到約 239%（多了約 107 個百分點做編碼與 gRPC 送出），guest 出幀率完全不動（59.9 對 59.9）。qemu 有足夠的核心，編碼工作沒有搶到 guest 的 vCPU。
2. `pull` 條件 `mirage-pull` 自己約 36 到 45% CPU（解碼 7.2 MB 幀約 60 次每秒）。
3. **`app` 條件（Mirage 全螢幕渲染對 guest 的回壓）尚未量到**，D65 擋掉了。由 `DELTA_PULL_APP` 補。

### 活體 run3：`app` 條件三輪全部有效（解鎖後補跑 `-c none,app`）

| 輪 | 條件 | guest | frames | host_cpu_qemu | host_cpu_client | host_cpu_foreign | mirage_fps | 判定 |
|---|---|---|---|---|---|---|---|---|
| 1 | none | 59.74 | 1205 | 168.7 | 0 | 84.8 | | 無效（foreign > 60） |
| 1 | app | 59.73 | 1209 | 224.5 | 43.6 | 0.0 | 47 | 有效 |
| 2 | app | 59.89 | 1214 | 238.0 | 41.6 | 13.1 | 48 | 有效 |
| 2 | none | 58.81 | 1190 | 187.0 | 0 | 112.0 | | 無效 |
| 3 | none | 59.22 | 1196 | 184.2 | 0 | 105.3 | | 無效 |
| 3 | app | 59.81 | 1211 | 205.6 | 44.2 | 34.0 | 50 | 有效 |

`app` 中位數 guest 59.8（qemu 224.5%、MirageApp 41.6 到 44.2%）。`none` 三輪都被 foreign 判無效（使用者剛解鎖在操作機器），但 run2 已有三輪乾淨的 `none` 59.9，用它比。

### 判定（完整）

| 差值 | 值 | 意義 |
|---|---|---|
| `none − pull` | 0.0 | emulator 端編碼與送出對 guest 零回壓 |
| `pull − app` | 約 0.1 | Mirage 渲染（Metal 上傳、視窗合成）對 guest 零回壓 |
| `none − app` | 約 0.1 | 總回壓為零 |

1. **Mirage 對 guest 的回壓為零。** 三種條件下 guest 都是 59.8 到 59.9。有 client 時 qemu 多花約 100 個百分點做編碼，MirageApp 自己約 42 到 44%，這些 CPU 都沒有搶到 guest 的 vCPU。「Mirage 少吃 CPU 以減少對 guest 回壓」這條路關掉，沒有東西可省。
2. **驗收線 7 在使用者同時用機器時的殘餘，完全在 emulator 側**（D60：guest 對外來 CPU 的敏感度，29% 時 59、90% 時 50、480% 時 34）。Mirage 能做的只有偵測並告知使用者，不能改變它。這變成產品決策。
3. **順帶第三次抓到 D64 的現場**：`app` 三輪 guest 59.7 到 59.9 但 `mirage_fps` 只有 47／48／50，foreign 0 到 34%。guest 沒掉、Mirage 掉了，與 `RESULTS-frame-counters.md` 跑次 2 第 5 輪、`RESULTS-backpressure.md` 抽函式對照第 2 輪同形。三次都是使用者在操作機器時，純 CPU burner 重現不了。回壓腳本沒印三計數與 draw 時序行（設計如此），下次要抓現場用 `verify_fps_fullscreen.sh`。
4. `none` 條件的 `host_cpu_foreign` 比 `app` 條件高（85 到 112 對 0 到 34），是因為 `none` 排在使用者剛回到機器的時段，不是條件本身的差異。
