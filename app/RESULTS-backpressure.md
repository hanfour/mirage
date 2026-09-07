# Mirage 對 guest 回壓量測

- 日期：2026-09-07
- 規格：`docs/specs/2026-09-07-mirage-cpu-backpressure-design.md`
- 狀態：shell 實作完成，活體數字由 PM 補寫

## 改動

- 新增 `scripts/lib/backpressure.sh`，提供條件輪轉、下位中位數差值、有效樣本分流與 CPU 報表加總。
- 新增 `scripts/lib/backpressure_selftest.sh`，覆蓋三條件與兩條件輪轉、空樣本差值、`FOREIGN_MAX` 邊界。
- 新增 `scripts/verify_guest_backpressure.sh`，依序量測 `none`、`pull`、`app`，在 client ready 後才重新清零 guest 與 CPU 窗口。
- `gui_session.sh` 新增 `gui_session_fullscreen <log> <bundle> <min_width>`。
- `verify_fps_fullscreen.sh` 改呼叫共用函式，保留原本的重試控制與判定。
- `ci.sh` 閘門 7 新增 `backpressure_selftest.sh`。

`pull` 固定請求 898x1996；`app` 使用同一個 AXFullScreen 與 `attachStream` 寬度收斂流程。有效性只把 guest 找不到 layer 或 `foreign > FOREIGN_MAX` 的樣本排除；`app` 行另印 `mirage_fps` 中位數。

## 全螢幕抽取證明

抽取前後以兩種靜態檢查對照：

```text
$ git diff --unified=0 HEAD -- app/scripts/verify_fps_fullscreen.sh \
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
❌ 三條件第 1 輪：得到 none,pull,none，期待 none,pull,app
❌ 三條件第 2 輪：得到 pull,none,pull，期待 pull,app,none
❌ 三條件第 3 輪：得到 none,pull,none，期待 app,none,pull
3 項失敗
FAULT_INJECTION_EXIT=1
```

既有的 `gui_session`、`load_sentinel`、`guest_fps`、`verify_common`、`audio_stats` 五支 self-test 也以 `/bin/bash` 全部通過。依規格，`gui_session_fullscreen` 本身需要 GUI，沒有被 `gui_session_selftest.sh` 覆蓋。

## Dead-port 驗證

```text
$ app/scripts/verify_guest_backpressure.sh -p 45999
EXIT=1
=== 前置：gRPC ===
❌ gRPC 45999 無回應——模擬器未啟動。
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

本環境也無法建立規格要求的分段 Git commit：嘗試提交時上層 worktree Git index 拒絕建立 `index.lock`（`Operation not permitted`）。
