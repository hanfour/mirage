# 驗收線 2 交付報告

日期：2026-09-08。分支：`acceptance-2-input-latency`。
第三輪完成 H、I 修正及離線驗證，沒有執行 GUI、git add 或 commit。以下前兩輪紀錄保留作為歷程。
PM 已在沙箱外確認 A 到 G 通過，Swift 重編綠、ci.sh 九道閘門第二輪全綠（343 條測試各跑三次、Python 44 條）。H、I 修正後尚待三輪活體複驗，不能判定驗收通過。

## 第三輪交付

- H：新增 `app/scripts/lib/cgclick.js`，正式腳本以 `osascript -l JavaScript` 傳入視窗水平中央、由上往下 20% 的座標、40 次、0.5 秒間隔。AX 只讀座標與置前，點擊改用 CGEvent。參數缺漏、非數值、非有限值、非正整數次數、負間隔皆在載入 CoreGraphics 前丟出錯誤，退出非 0。
- I：`input_latency_load_retry` 沿用既有 6 次檢查、每次擋下等 5 秒及指定訊息，耗盡才淘汰本輪。建置後另等負載下降，最多 60 秒，每 5 秒檢查，印實際耗時；逾時仍須通過逐輪重試，有效輪數不足維持紅燈。
- 測試：新增 `cgclick_selftest.js`，由既有 input_latency 自我測試呼叫，使用 JXA 及模擬 CGEvent，不需外部套件。涵蓋參數拒絕、事件種類與順序、座標、次數、按壓及間隔。正式 JXA 的無效參數案例也確認退出非 0。負載測試模擬 load_gate、sleep 與時間，涵蓋立即通過、重試恢復、最後一次通過、耗盡後不印 PASS，以及有上限的建置後等待。
- `/bin/bash app/scripts/lib/input_latency_selftest.sh` 退出 0，六條原故障各退出 1；未執行 GUI 活體、Swift 重編或完整 CI。
- `app/RESULTS-input-latency.md` 已補 PM 活體數字、B 與 D65 證據，以及背景座標實測：guest (540,480) 觸控後 1.5 秒畫面差異 3.1%，與另外兩個純背景座標相同，仍在主選單、沒有進關卡。

PM 提供的 transit p50/p95 為 10.8/14.1ms、render 為 24.7/27.9ms，均 n=55，transit invalid=0、unavailable=0；全螢幕 898x1995、fps 55 到 60。CGEvent 替代做法已由 PM 測得 8 次點擊、16 個 inject 事件；本輪整合腳本仍待複驗。

第三輪最後檢查：七支共用 shell 自我測試全部退出 0，完整輸出位於 `/tmp/<檔名>.acceptance2-third.log`。三支改動 shell 的 `/bin/bash -n`、正式腳本 `-h` 與 `git diff --check` 皆退出 0。

## 修改內容與檔案

- `app/Sources/MirageCore/Frame.swift`：新增預設 nil 的 transitMs，不參與 equality，註明兩種時鐘不可互減。
- `app/Sources/MirageCore/GrpcStreamTransport.swift`：建立 Frame 時計算一次傳輸時間。
- `app/Sources/MirageCore/MmapStreamTransport.swift`：明確傳 nil。
- `app/Sources/MirageCore/TransitWindow.swift`：沿用 LatencyWindow，另計 invalid/unavailable。
- `app/Sources/MirageShell/Renderer.swift`：保留 lat 行格式與原取樣時機，同窗口增加 transit 行。
- `app/Sources/MirageCore/Input/InputQueue.swift`：可選 enqueue 時刻、RPC 完成後記錄；開啟量測才建立每秒輸出工作，空窗口不印。輸出在 MainActor 執行以避免打斷 Renderer 的配對行，單一消費者仍依序 await。
- `app/Tests/MirageCoreTests/TransitWindowTests.swift`：Frame equality、負值與 nil 排除、reset 測試。
- `app/Tests/MirageCoreTests/InputQueueTests.swift`：新增開啟量測後的跨事件種類順序測試；原測試內容保留。
- `app/scripts/verify_input_latency.sh`：預先建置、每輪負載檢查、全螢幕、20 秒窗口、約 40 次點擊與摘要。
- `app/scripts/lib/input_latency.sh`：日誌欄位驗證、六條斷言、摘要。
- `app/scripts/lib/input_latency_selftest.sh`：合成日誌與六條故障注入。
- `app/scripts/lib/gui_session.sh`：tagged_median 接受 transit/inject 的 p50/p95。
- `app/scripts/lib/load_sentinel.sh`：可選單一行程最低 CPU 百分比，舊預設 10 保留；新腳本同時取 floor 10 與 floor 0，只用前者判定 <50%。
- `app/scripts/ci.sh`：閘門 7 加入 input_latency 自我測試。
- `phase0/harness/e2e_latency.py`：參數、差異像素數、序號游標、同批三個門檻、四段與 misses 輸出。
- `phase0/harness/tests/test_e2e_latency.py`：偵測、deque 滿後游標、門檻敏感度、misses 與參數測試。
- `app/RESULTS-input-latency.md`：簡報提供的先前數字、故障注入證據、待 PM 補量欄位與未量項。
- `CODEX-REPORT.md`：本報告。

## 實際執行

```text
$ /bin/bash --version
GNU bash, version 3.2.57(1)-release (arm64-apple-darwin25)

$ phase0/harness/.venv-d45/bin/python -m pytest -q phase0/harness/tests
..........................................                               [100%]
42 passed in 0.31s
```

使用下列迴圈驗證所有共用 shell 自我測試，輸出如下；每支完整 log 在 `/tmp/<檔名>.acceptance2.log`。

```bash
for f in app/scripts/lib/*_selftest.sh; do
    /bin/bash "$f" > /tmp/"$(basename "$f")".acceptance2.log 2>&1
    rc=$?
    echo "$(basename "$f") rc=$rc"
    if [ "$rc" -ne 0 ]; then
        tail -20 /tmp/"$(basename "$f")".acceptance2.log
        exit "$rc"
    fi
done
```

```text
audio_stats_selftest.sh rc=0
backpressure_selftest.sh rc=0
guest_fps_selftest.sh rc=0
gui_session_selftest.sh rc=0
input_latency_selftest.sh rc=0
load_sentinel_selftest.sh rc=0
verify_common_selftest.sh rc=0
```

`/bin/bash app/scripts/lib/input_latency_selftest.sh` 實際輸出節錄如下，完整六條紅燈指令與輸出見 RESULTS 檔：

```text
FAULT inject rc=1
FAIL: inject_n=20 must be >=30
FAULT transit rc=1
FAIL: transit_n=580 must be >=600
FAULT invalid rc=1
FAIL: invalid=20; clock assumption failed
FAULT unavailable rc=1
FAIL: unavailable=20; MMAP cannot measure transit
FAULT cpu rc=1
FAIL: foreign CPU must be <50%, got 50
FAULT sum rc=1
FAIL: SUM_MEDIAN must be <80ms; largest segment=transit
input_latency selftest failures=0
```

另外實際執行：

- `/bin/bash -n` 檢查新腳本、兩支新函式庫與改動的 gui_session.sh、load_sentinel.sh、ci.sh，退出碼皆 0，無輸出。
- `/bin/bash app/scripts/verify_input_latency.sh -h`，退出碼 0，印出兩行用法；沒有啟動活體流程。
- `phase0/harness/.venv-d45/bin/python phase0/harness/e2e_latency.py --help`，退出碼 0，列出 target、串流與 guest 尺寸、座標、samples、radius、threshold、timeout。
- 使用同一 venv 讀取已產生的 protobuf descriptor，輸出 `Image fields: format, width, height, image, seq, timestampUs`。
- `git diff --check`，退出碼 0，無輸出。
- `git diff --exit-code --` 指定 verify_fps_fullscreen.sh、LatestFrameBox/FramePump/FrameQueue 原始碼與四支指定不可改測試，退出碼 0，無輸出。此項只證明檔案未修改，不證明執行行為相同。

## 未執行

沒有執行 swift build、swift test、完整 ci.sh、GUI 活體量測、harness 實際觸控探測、三個環境變數關閉時的活體 fps 比較。未重啟 emulator、變更 AVD、安裝或移除 APK，未更改 guest 的 show_touches/pointer_location。

此節記錄前兩輪未執行項；PM 後續驗證及第三輪尚待複驗範圍，以本報告開頭及 RESULTS 的第三輪證據為準。

## A 到 G 修正與新增證據

- A、C：同一個 20 秒窗口兩端取 CPU 快照，同時印 floor 10 與 floor 0，只有 floor 10 比較 <50%。排除清單維持 `qemu-system|MirageApp|WindowServer`。驗收線 7 的 50% 是人工判讀紀律，本身沒有 FOREIGN_TOTAL 自動閘門。
- B：每輪失敗保留原因並繼續，保留有效數字；跑完要求有效輪數達到 `-r`，不足退出 1，並印所有無效輪次原因。沒有減少要求輪數。
- D、E：過濾及 ack 到產生延遲共用 ack 基準；負值整筆排除並印各門檻 negative 計數。敏感度以觸控編號交集配對，印三門檻皆命中的樣本數。
- F、G：零時間戳傳 nil，附中文 doc comment；四個指定 Swift 檔的新註解改中文，補回分段量測的優化決策理由，註明 78.1ms 已作廢。

本輪 `/bin/bash app/scripts/lib/input_latency_selftest.sh` 退出 0，六條故障各退出 1。
新增測試印出 `foreign_cpu_floor10=0% foreign_cpu_floor0=54%` 並通過 floor 10 判定。
輪次注入輸出 `[round 2] INVALID; continuing` 後仍印第三輪有效數字；
`VALID_ROUNDS=2 REQUIRED_ROUNDS=3` 保留 SUM_MEDIAN=29.0，最後 `FAIL: insufficient valid rounds`，
並重印第二輪 `invalid=20` 原因。有效輪數不足時不印驗收 PASS。
完整輸出節錄與兩種 floor 不同的原因見 `app/RESULTS-input-latency.md`。
Python 全套離線測試實際為 `44 passed in 0.27s`，涵蓋 ack 過濾、負值與存活者偏誤反例。
最後複驗為 `44 passed in 0.17s`；七支共用 shell 自我測試全部退出 0，
本輪三支 shell 檔語法檢查與 `git diff --check` 皆退出 0。
新增斷言也確認零個有效輪次必須紅燈，以及輪數不足時不得印出 PASS。
本輪 shell 完整輸出保存在 `/tmp/<檔名>.acceptance2-revision.log`。

## Commit 限制

曾嘗試將 Swift 修改分批提交，執行 `git add` 與 `git commit -m 'feat: measure transit and queued input latency'`，兩者退出碼皆 128：

```text
fatal: Unable to create '/Users/hanfourhuang/Projects/mirage/.git/worktrees/acceptance-2-input-latency/index.lock': Operation not permitted
```

worktree 的 git metadata 位於沙箱可寫目錄以外，且本回合不允許提高權限。沒有產生任何 commit；全部修改留在此 worktree。未嘗試改寫 git metadata 位置或繞過限制。
