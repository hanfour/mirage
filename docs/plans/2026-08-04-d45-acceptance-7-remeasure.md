# D45：重驗驗收線 7（fps）— 實作計畫

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在全螢幕串流解析度上限（900×2000）下重量 fps，並把驗收線 7 從「`≥ 55` 的死線」
改成兩條會綠也會紅的相對判準。

**Architecture:** 交錯量測兩個數字——Mirage 側的 `MIRAGE_FPS_LOG`（經既有
`lib/gui_session.sh`）與不經過 Mirage 的對照組（新寫的精簡 gRPC 消費者）。短區間 A/B/A/B
輪流、各取中位數，讓 CPU 負載波動同時打在分子分母上。判準改成 7a（對照組線）與
7b（歷史基準線）。

**Tech Stack:** bash（`set -uo pipefail`）、`app/scripts/lib/` 的既有斷言與 GUI session
封裝、Python 3 + grpcio（venv 隔離）、Android emulator gRPC `streamScreenshot`。

**設計文件：** `docs/specs/2026-08-04-d45-acceptance-7-remeasure-design.md`（commit `d2b7a60`）

## Global Constraints

- 工作目錄一律 `app/`（shell 部分）。腳本內用 `cd "$(dirname "$0")/.."` 定錨。
- 所有 `verify_*.sh` **一律 `source lib/verify_common.sh`**，不得各寫一份退出碼檢查（D9）。
- **裸變數不得緊接全形標點**：`echo "$rc，"` 在 `set -u` 下炸成未綁定變數。一律 `${rc}`。
  `ci.sh` 閘門 4 會擋。
- **`#expect` 不得拿 Bool 跟 `true`/`false` 比**（D35，`ci.sh` 閘門 5）。
- 組 `.app` **一律用 `app/scripts/package_app.sh`**（D25）。
- 啟動 emulator **絕不可帶 `-no-audio`**（無關本計畫但沿用既有慣例）、**絕不可帶
  `-no-window`**（要真 GUI 合成）。
- **驗證步驟不得把待驗指令接管線**。一律：
  ```bash
  cmd > /tmp/d45-step.log 2>&1; RC=$?; tail -12 /tmp/d45-step.log; echo "EXIT=$RC"
  ```
  ⚠️ 不要用 `${PIPESTATUS[0]}`——本專案互動 shell 是 **zsh**，陣列 1-indexed，該值永遠是
  空字串。`verify_*.sh` 腳本**內部**用它是對的（有 bash shebang）。
- **中位數，不是平均**。既有 `gui_session.sh` 只提供 `fps_average`（`awk` 的 `s/n`），
  **不可沿用**——一次 load 尖峰量到的 0 fps 會把整組拖歪。
- **門檻（N、M）一律待實測後才填**。D32 的教訓：先定門檻再實測會定出結構上不可能成立的
  判準。
- 提交訊息格式 `<type>: <description>`，型別限 feat/fix/refactor/docs/test/chore/perf/ci。
- 註解與文件一律繁體中文台灣用語。

## 環境前置（Task 3 起需要）

```bash
# 啟動 mirage-game（裝了 Pixel Flow 的那台）
"$HOME/Library/Android/sdk/emulator/emulator" -avd mirage-game -port 5556 -grpc 8556 -gpu host &
"$HOME/Library/Android/sdk/platform-tools/adb" -s emulator-5556 wait-for-device
until [ "$("$HOME/Library/Android/sdk/platform-tools/adb" -s emulator-5556 shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do sleep 2; done
```

⚠️ **不要帶 `-no-window`**：要量真 GUI 合成下的 fps。
⚠️ **拔掉實體 Android 手機**：插著會干擾 adb 選裝置。
⚠️ **本機螢幕須為 2560×1600（或更大）**：全螢幕才算得到 900×2000。若換機器要重新確認。

---

### Task 1: 對照組工具（venv + 精簡的 fps baseline）

驗收線 7 的新判準 7a 要跟「不經過 Mirage 的直接消費者」比，所以必須有一支能在指定解析度
下量 `streamScreenshot` fps 的工具。

**既有的 `phase0/harness/bench_mmap_vs_rgba.py` 不能直接用**，兩個理由：

1. **它會自己 `subprocess.Popen` 啟動 `animate.py`** 當動畫來源——那是 launcher 上的人造
   滑動。而 §11.3 陷阱 3 明說不能拿 launcher 當對照組：對照組必須量**跟 Mirage 側同一個
   遊戲畫面**，否則兩個數字比的不是同一件事。
2. 它一次跑三個 mode（rgba／mmap-copy／mmap-touch），D45 只要 rgba，跑三倍時間沒有意義。

而且整個 `phase0/harness/` 目前**跑不起來**：11 個檔案 import `gen/emulator_controller_pb2.py`，
該產生碼標記 `Protobuf Python Version: 7.35.0` 且開頭就呼叫
`_runtime_version.ValidateProtobufRuntimeVersion`，本機裝的是 **4.25.4**，`import` 直接炸。

本 task **不需要模擬器**（除了最後一步的煙霧測試）。

**Files:**
- Create: `phase0/harness/fps_baseline.py`
- Create: `phase0/harness/requirements-d45.txt`
- Create: `phase0/harness/README-venv.md`

**Interfaces:**
- Produces: `python fps_baseline.py --seconds N --width W --height H [--json]`
  —— 連 `localhost:8556` 的 emulator gRPC，請求 `W×H` 的 `streamScreenshot`，跑 `N` 秒，
  印一行 `fps=<float> frames=<int> elapsed=<float>`；帶 `--json` 則印單行 JSON。
  **不啟動任何動畫來源**——畫面由呼叫端負責（Task 3 會讓遊戲在跑）。

- [ ] **Step 1: 建立 venv 並確認 protobuf 版本相容**

```bash
cd /Users/hanfourhuang/Projects/mirage/phase0/harness
python3 -m venv .venv-d45
./.venv-d45/bin/pip install --quiet --upgrade pip
./.venv-d45/bin/pip install --quiet 'protobuf>=5.29,<7' grpcio grpcio-tools numpy
./.venv-d45/bin/python -c "import google.protobuf; print('protobuf', google.protobuf.__version__)"
```

Expected: 印出 protobuf 5.x 或 6.x 的版本號。

⚠️ **不要 `pip install` 到系統 Python**。這台機器上還有別的東西依賴 protobuf 4.25。

⚠️ `.venv-d45/` 必須進 `.gitignore`。先確認 repo 根目錄的 `.gitignore` 有沒有涵蓋
`.venv*`；沒有的話這一步要補上（改 `.gitignore` 也算本 task 的產出）。

- [ ] **Step 2: 確認產生碼在 venv 裡 import 得動**

```bash
cd /Users/hanfourhuang/Projects/mirage/phase0/harness
./.venv-d45/bin/python -c "
import sys; sys.path.insert(0, 'gen')
import emulator_controller_pb2 as pb
print('import OK, ImageFormat:', pb.ImageFormat.DESCRIPTOR.name)
"
```

Expected: `import OK, ImageFormat: ImageFormat`

**若這步失敗**：讀錯誤訊息判斷是版本太低還是太高，調整 Step 1 的版本範圍重試。
`ValidateProtobufRuntimeVersion` 的錯誤訊息會明講它要什麼版本區間。

- [ ] **Step 3: 寫 `requirements-d45.txt`**

把 Step 1 實際裝成功的版本鎖進去（用 `./.venv-d45/bin/pip freeze` 取實際版本，
**不要憑記憶寫**）：

```bash
cd /Users/hanfourhuang/Projects/mirage/phase0/harness
./.venv-d45/bin/pip freeze | grep -iE '^(protobuf|grpcio|numpy)' > requirements-d45.txt
cat requirements-d45.txt
```

- [ ] **Step 4: 寫 `fps_baseline.py`**

Create `phase0/harness/fps_baseline.py`：

```python
#!/usr/bin/env python3
"""D45 對照組：不經過 Mirage，直接消費 streamScreenshot 量 fps。

驗收線 7 的新判準 7a 要比「Mirage 的 fps」與「同條件下不經過 Mirage 的 fps」，
這支就是後者。

**為什麼不用 bench_mmap_vs_rgba.py**：那支會自己 Popen 啟動 animate.py 當動畫來源
（launcher 上的人造滑動），而 D45 的對照組必須量**跟 Mirage 側同一個遊戲畫面**——
`docs/specs/2026-07-28-mirror-never-rendered-investigation.md` §11.3 陷阱 3 記載過
「拿 launcher 當對照組」會量到靜止期。本檔刻意**不啟動任何動畫來源**，畫面由呼叫端
負責（D45 的量測腳本會讓 Pixel Flow 跑著）。

它也只跑 rgba 一種模式——D45 不關心 MMAP。

用法：
    python fps_baseline.py --seconds 20 --width 900 --height 2000
    python fps_baseline.py --seconds 20 --json
"""
import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "gen"))

import grpc
import emulator_controller_pb2 as pb
import emulator_controller_pb2_grpc as pbg


def measure(endpoint: str, seconds: int, width: int, height: int) -> dict:
    """跑 `seconds` 秒，回傳 fps 與原始計數。

    只計「真的收到的幀」——streamScreenshot 是變化驅動的，畫面靜止時本來就不出幀，
    所以呼叫端必須保證畫面在動，否則量到的是靜止期而不是效能。
    """
    channel = grpc.insecure_channel(endpoint, options=[
        ("grpc.max_receive_message_length", 64 * 1024 * 1024),
    ])
    stub = pbg.EmulatorControllerStub(channel)
    req = pb.ImageFormat(format=pb.ImageFormat.RGBA8888,
                         width=width, height=height)
    frames = 0
    t0 = time.perf_counter()
    deadline = t0 + seconds
    try:
        for _ in stub.streamScreenshot(req):
            frames += 1
            if time.perf_counter() >= deadline:
                break
    except grpc.RpcError as err:
        print(f"gRPC {err.code().name}: {err.details()}", file=sys.stderr)
    elapsed = time.perf_counter() - t0
    channel.close()
    return {
        "fps": frames / elapsed if elapsed else 0.0,
        "frames": frames,
        "elapsed": elapsed,
        "width": width,
        "height": height,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--endpoint", default="localhost:8556")
    ap.add_argument("--seconds", type=int, default=20)
    ap.add_argument("--width", type=int, default=900)
    ap.add_argument("--height", type=int, default=2000)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    r = measure(args.endpoint, args.seconds, args.width, args.height)
    if args.json:
        print(json.dumps(r))
    else:
        print(f"fps={r['fps']:.2f} frames={r['frames']} elapsed={r['elapsed']:.2f} "
              f"size={r['width']}x{r['height']}")
    # 一幀都沒收到 → 呼叫端該知道這次不可信。
    return 0 if r["frames"] > 0 else 1


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 5: 語法與介面檢查（不需模擬器）**

```bash
cd /Users/hanfourhuang/Projects/mirage/phase0/harness
./.venv-d45/bin/python -c "import ast; ast.parse(open('fps_baseline.py').read()); print('語法 OK')"
./.venv-d45/bin/python fps_baseline.py --help
```

Expected: 「語法 OK」，然後印出 `--endpoint/--seconds/--width/--height/--json` 五個參數。

- [ ] **Step 6: 煙霧測試（需要模擬器）**

若模擬器已在跑（`nc -z localhost 8556`）：

```bash
cd /Users/hanfourhuang/Projects/mirage/phase0/harness
./.venv-d45/bin/python fps_baseline.py --seconds 5 > /tmp/d45-smoke.log 2>&1
RC=$?; cat /tmp/d45-smoke.log; echo "EXIT=$RC"
```

Expected: 印出 `fps=... frames=... elapsed=... size=900x2000`。

**`frames=0` 且 `EXIT=1` 是預期的**，只要當下 guest 畫面是靜止的——`streamScreenshot`
變化驅動。此時用 `adb -s emulator-5556 shell input swipe 400 900 700 1500 250` 製造變化再
跑一次確認拿得到幀。**這一步只驗「工具能連上並收到幀」，不是量效能**。

若模擬器沒在跑，跳過本步並在報告中標明未做煙霧測試。

- [ ] **Step 7: 寫 `README-venv.md`**

Create `phase0/harness/README-venv.md`，說明：為什麼需要 venv（`gen/` 的產生碼要
protobuf 7.35，系統裝的是 4.25，11 個 harness 檔案全部 import 不動）、怎麼建、
`requirements-d45.txt` 鎖的是什麼版本、以及**這只解決 D45 用得到的那條路徑，
`phase0/harness/` 其餘 10 個檔案仍是死的**（另記債務，不在 D45 範圍）。

- [ ] **Step 8: Commit**

```bash
cd /Users/hanfourhuang/Projects/mirage
git add phase0/harness/fps_baseline.py phase0/harness/requirements-d45.txt \
        phase0/harness/README-venv.md .gitignore
git commit -m "feat: D45 對照組——精簡的 streamScreenshot fps 量測

驗收線 7 的新判準 7a 要跟「不經過 Mirage 的直接消費者」比，這支就是後者。

不用既有的 bench_mmap_vs_rgba.py，兩個理由：
1. 它會自己 Popen 啟動 animate.py（launcher 上的人造滑動），而 D45 的對照組
   必須量跟 Mirage 側同一個遊戲畫面——investigation §11.3 陷阱 3 記載過
   「拿 launcher 當對照組」會量到靜止期
2. 它一次跑三個 mode，D45 只要 rgba

順帶解掉 phase0/harness 跑不起來的問題：gen/ 的產生碼要 protobuf 7.35，
系統裝的是 4.25，11 個檔案全部 import 不動。用 venv 隔離，不動系統環境
（這台機器還有別的東西依賴 4.25）。其餘 10 個檔案仍是死的，另記債務。"
```

---

### Task 2: 中位數與環境哨兵（lib 層，不需模擬器）

新判準用**中位數**而非平均，而既有 `gui_session.sh` 只有 `fps_average`。另外 D32 踩過
「load average 20+ 時量到全 0」的坑，這次要在量測前後設哨兵。

兩者都放進共用函式庫並加自我測試——`ci.sh` 閘門 7 已經在跑 `lib/` 底下的兩支 selftest，
新增的第三支要一併掛上去。

本 task **不需要模擬器**。

**Files:**
- Modify: `app/scripts/lib/gui_session.sh`（追加 `fps_median`）
- Create: `app/scripts/lib/load_sentinel.sh`
- Create: `app/scripts/lib/load_sentinel_selftest.sh`
- Modify: `app/scripts/ci.sh`（閘門 7 加跑第三支 selftest）

**Interfaces:**
- Produces:
  - `fps_median <log路徑>` — 從 log 的 `fps=` 行取**中位數**（整數，無條件捨去）。
    無取樣時回 `0`。偶數筆時取中間兩筆的下位（不做內插——樣本是整數 fps，內插只會製造
    假精度）。
  - `load_avg_1min` — 印出當下 1 分鐘 load average（浮點數字串）。
  - `load_gate <上限>` — load average 超過上限時印警告並回傳 1，否則回傳 0。
    **只回傳碼、不 exit**——呼叫端決定要重測還是中止。

- [ ] **Step 1: 先寫會紅的 `fps_median` 測試**

`gui_session.sh` 目前沒有自我測試。本 task 把 `fps_median` 的測試放進**新建的**
`load_sentinel_selftest.sh`（它同時測兩個函式，名字以哨兵為主是因為那是新檔的主體）。

Create `app/scripts/lib/load_sentinel_selftest.sh`：

```bash
#!/usr/bin/env bash
# load_sentinel.sh 與 gui_session.sh 的 fps_median 的自我測試。
# **不需要模擬器、不需要 adb**——比照 verify_common_selftest.sh 的既有結構。
#
# 用法：./scripts/lib/load_sentinel_selftest.sh（退出碼 0 = 全部通過）
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/load_sentinel.sh"
source "$HERE/gui_session.sh"
FAILURES=0

check() {
    local desc="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then
        echo "✅ $desc"
    else
        # 變數一律用 ${} 包起來——`$desc：`（裸變數緊接全形字元）會被 bash 當成變數名的
        # 一部分，`set -u` 當場報「未綁定的變數」。ci.sh 閘門 4 擋的就是這個。
        echo "❌ ${desc}：得到 ${got}，期待 ${want}"
        FAILURES=$((FAILURES + 1))
    fi
}

WORK=$(mktemp -d -t d45_selftest)
trap 'rm -rf "$WORK"' EXIT

echo "=== fps_median ==="

# 奇數筆：正中間那筆。刻意亂序，驗證它有排序。
printf '[fps] fps=30\n[fps] fps=10\n[fps] fps=20\n' > "$WORK/odd.log"
check "奇數筆取正中間"        "$(fps_median "$WORK/odd.log")"  20

# 偶數筆：取中間兩筆的下位，不內插。10/20/30/40 → 20（不是 25）。
printf '[fps] fps=40\n[fps] fps=10\n[fps] fps=30\n[fps] fps=20\n' > "$WORK/even.log"
check "偶數筆取下位不內插"    "$(fps_median "$WORK/even.log")" 20

# **這是 fps_median 存在的理由**：一次 load 尖峰量到的 0 會把平均拖歪，中位數不受影響。
# 平均 = (60+58+0+59+61)/5 = 47.6 → 47；中位數 = 59。
printf '[fps] fps=60\n[fps] fps=58\n[fps] fps=0\n[fps] fps=59\n[fps] fps=61\n' > "$WORK/spike.log"
check "離群的 0 不影響中位數"  "$(fps_median "$WORK/spike.log")" 59
check "同一份資料的平均被拖歪"  "$(fps_average "$WORK/spike.log")" 47

# 單筆與空檔案的邊界。
printf '[fps] fps=42\n' > "$WORK/one.log"
check "單筆"                  "$(fps_median "$WORK/one.log")"   42
: > "$WORK/empty.log"
check "空檔案回 0"            "$(fps_median "$WORK/empty.log")"  0

echo ""
echo "=== load_gate ==="

# load_gate 用實際的 load average，測不了固定值；改測它的判定邏輯：
# 上限給一個絕不可能超過的值 → 必過；給 0 → 必不過（load average 不會是負的）。
( load_gate 100000 > /dev/null 2>&1 ); check "上限極高 → 回 0（通過）" "$?" 0
( load_gate 0      > /dev/null 2>&1 ); check "上限為 0 → 回 1（擋下）" "$?" 1

# load_avg_1min 必須印出一個可被 awk 當數字比較的東西。
LA=$(load_avg_1min)
check "load_avg_1min 印出數字" \
      "$(awk -v v="$LA" 'BEGIN { print (v + 0 == v && v >= 0) ? "yes" : "no" }')" "yes"

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "全部通過"
    exit 0
fi
echo "$FAILURES 項失敗"
exit 1
```

```bash
chmod +x app/scripts/lib/load_sentinel_selftest.sh
```

- [ ] **Step 2: 跑自我測試，確認它紅**

```bash
cd app && ./scripts/lib/load_sentinel_selftest.sh > /tmp/d45-step.log 2>&1
RC=$?; tail -20 /tmp/d45-step.log; echo "EXIT=$RC"
```

Expected: 失敗——`load_sentinel.sh` 還不存在，`source` 會直接讓腳本中止（`set -u` 下
source 不存在的檔案會報錯）。`EXIT` 非 0。

**若這一步是綠的就停下來**：代表 `load_sentinel.sh` 或 `fps_median` 已經存在，先查清楚。

- [ ] **Step 3: 實作 `load_sentinel.sh`**

Create `app/scripts/lib/load_sentinel.sh`：

```bash
#!/usr/bin/env bash
# 量測前後的環境哨兵。用法：source "$(dirname "$0")/lib/load_sentinel.sh"
#
# **存在的理由是 D32 踩過的坑**：這台開發機是共用的，load average 20+ 時
# `MirageScene` 的 `.task` 根本不觸發、視窗從未建立，連續四次量到全 0 fps，
# 當時誤以為是程式問題查了很久（見 app/RESULTS-d32.md 附錄）。
#
# D45 的量測是比值（Mirage vs 對照組），負載尖峰會讓分子分母不對等地失真，
# 所以規則是**寧可重測，不要留一筆自己都不相信的數字**。

# 當下 1 分鐘 load average。macOS 的 uptime 格式：
#   ... load averages: 2.51 3.02 3.41
load_avg_1min() {
    uptime | sed 's/.*load averages*: *//' | awk '{ print $1 }'
}

# load average 超過上限 → 印警告、回傳 1。否則回傳 0。
#
# **只回傳碼、不 exit**：呼叫端才知道該重測還是中止。量測腳本通常要重測，
# 但一次性的診斷指令可能只想知道環境髒不髒。
load_gate() {
    local limit="$1" la
    la=$(load_avg_1min)
    if awk -v a="$la" -v l="$limit" 'BEGIN { exit !(a > l) }'; then
        echo "⚠️ load average ${la} 超過上限 ${limit}——本次樣本不可信，建議重測。" >&2
        return 1
    fi
    return 0
}
```

```bash
chmod +x app/scripts/lib/load_sentinel.sh
```

- [ ] **Step 4: 實作 `fps_median`**

在 `app/scripts/lib/gui_session.sh` 的 `fps_average` 函式之後追加：

```bash

# fps 中位數（整數，無條件捨去）。沒有取樣時回 0。
#
# **為什麼 D45 要中位數而不是 fps_average**：這台開發機是共用的，一次 CPU 負載尖峰
# 會讓某一秒量到 0，平均被整組拖歪而中位數不受影響（見 lib/load_sentinel_selftest.sh
# 的「離群的 0」案例：同一份資料平均 47、中位數 59）。D45 的判準是比值，被拖歪的
# 分子或分母會直接變成錯誤的結論。
#
# 偶數筆取中間兩筆的**下位**，不做內插——樣本本身是整數 fps，內插只會製造假精度。
fps_median() {
    local n
    n=$(fps_samples "$1")
    [ "$n" -eq 0 ] && { echo 0; return 0; }
    grep 'fps=' "$1" | sed 's/.*fps=//' | sort -n | awk -v n="$n" '
        { v[NR] = $1 }
        END { printf "%d\n", v[int((n + 1) / 2)] }'
}
```

- [ ] **Step 5: 跑自我測試，確認全綠**

```bash
cd app && ./scripts/lib/load_sentinel_selftest.sh > /tmp/d45-step.log 2>&1
RC=$?; tail -20 /tmp/d45-step.log; echo "EXIT=$RC"
```

Expected: 最後一行「全部通過」，`EXIT=0`。

⚠️ 特別確認「同一份資料的平均被拖歪」那條也是綠的——它釘住的是 `fps_average` 的既有
行為，若它紅了代表 `fps_average` 被改動過，要先查清楚。

- [ ] **Step 6: 突變檢查——證明 `fps_median` 真的在取中位數**

把 `fps_median` 的 `sort -n` 拿掉（不排序就取「中間那筆」），重跑：

```bash
cd app && sed -i.bak 's/| sort -n | awk -v n="\$n"/| awk -v n="$n"/' scripts/lib/gui_session.sh
./scripts/lib/load_sentinel_selftest.sh > /tmp/d45-step.log 2>&1
RC=$?; grep "❌" /tmp/d45-step.log; echo "EXIT=$RC"
mv scripts/lib/gui_session.sh.bak scripts/lib/gui_session.sh
```

Expected: **具名失敗**——至少「奇數筆取正中間」與「離群的 0 不影響中位數」兩項印 ❌
（測資刻意亂序就是為了讓這個突變被抓到），`EXIT=1`。

還原後重跑一次確認回到「全部通過」。

- [ ] **Step 7: 閘門 7 加跑第三支 selftest**

`app/scripts/ci.sh` 的閘門 7 目前跑 `verify_common_selftest.sh` 與
`audio_stats_selftest.sh`。**先讀那一段**確認它的既有寫法（`ok`/`fail` 的用法、
迴圈還是逐支列出），照同樣風格加上 `load_sentinel_selftest.sh`，並更新總結字串裡的
「兩支共用函式庫自我測試」為三支。

- [ ] **Step 8: 跑完整 ci.sh 確認八道閘門全綠**

```bash
cd app && ./scripts/ci.sh > /tmp/d45-ci.log 2>&1
RC=$?; echo "閘門數：$(grep -c '=== 閘門' /tmp/d45-ci.log)"; tail -4 /tmp/d45-ci.log; echo "EXIT=$RC"
```

Expected: 閘門數 **8**、最後一行「全部通過」、`EXIT=0`。

⚠️ 閘門 5 的 `echo` 用單引號，`grep '^echo "=== 閘門'` 會漏數它——用上面這個
`grep -c '=== 閘門'` 對執行輸出數才正確。

- [ ] **Step 9: Commit**

```bash
git add app/scripts/lib/gui_session.sh app/scripts/lib/load_sentinel.sh \
        app/scripts/lib/load_sentinel_selftest.sh app/scripts/ci.sh
git commit -m "feat: fps_median 與環境哨兵，閘門 7 加跑第三支自我測試

D45 的判準是比值（Mirage vs 對照組），一次 CPU 負載尖峰會讓分子或分母
不對等地失真。既有的 fps_average 是平均，一筆 0 就把整組拖歪——自我測試
釘住了這個差異：同一份資料平均 47、中位數 59。

load_sentinel 是 D32 踩過的坑的直接對策：那次 load average 20+ 時
MirageScene 的 .task 根本不觸發、連續四次量到全 0，誤以為是程式問題。
load_gate 只回傳碼不 exit——呼叫端才知道該重測還是中止。

已做突變檢查：拿掉 fps_median 的 sort -n 之後，「奇數筆取正中間」與
「離群的 0 不影響中位數」兩項具名失敗（測資刻意亂序就是為了抓這個）。"
```

---

### Task 3: `verify_fps_fullscreen.sh` 探測版（零斷言）

**這個 task 刻意不加任何斷言。** 目的只有一個：拿到 1.8 MP 這一格的真實數字。門檻由
Task 5 依實測決定——D32 就是「先定門檻再實測」踩出來的坑。

本 task **需要模擬器**。

**Files:**
- Create: `app/scripts/verify_fps_fullscreen.sh`
- Create: `app/RESULTS-d45-probe.md`

**Interfaces:**
- Consumes: `gui_session_start`／`gui_session_cleanup`／`fps_samples`／`fps_median`
  （`lib/gui_session.sh`）、`load_gate`（`lib/load_sentinel.sh`，Task 2）、
  `require_device`／`require_grpc`／`assert_at_least`（`lib/verify_common.sh`）、
  `phase0/harness/fps_baseline.py`（Task 1）
- Produces: 每輪印一行 `[round N] mirage=<中位數> baseline=<fps> ratio=<百分比>`，
  結尾印彙總的 `MIRAGE_MEDIAN=`／`BASELINE_MEDIAN=`／`RATIO_PCT=`／`ROUNDS=`／`SIZE_OK=`
  五個可 eval 的 KEY=VAL。Task 5 會斷言它們。

#### 為什麼是「每輪重啟 Mirage」而不是讓它一直跑

spec §3.3 要求交錯量測且**不並行**。但 Mirage 是持續運行的 App，它的 `[fps]` 日誌行
**沒有時間戳**，無法事後切出「對照組沒在跑的那幾秒」；而且只要 Mirage 還開著，它就一直
在拉串流——對照組同時跑就是並行，兩個 client 各自請求一份串流，emulator 得做兩份工。

所以交錯的單位是**輪**：每輪「啟動 Mirage → 量 → 關掉 Mirage → 量對照組」，重複 N 輪。
輪內先後、跨輪交錯，CPU 負載波動在輪之間被平均。代價是每輪多約 20 秒的啟動開銷。

- [ ] **Step 1: 建立腳本**

Create `app/scripts/verify_fps_fullscreen.sh`：

```bash
#!/usr/bin/env bash
# D45：驗收線 7 的重驗——全螢幕串流解析度上限（900×2000）下的 fps。
#
# **與 verify_game_fps.sh 的分工**：那支量「當下視窗尺寸下的 fps」，用途是日常除錯；
# 這支專為驗收線 7，強制全螢幕、斷言串流尺寸真的收斂到上限、並同時量不經過 Mirage 的
# 對照組。判準是比值不是絕對值——完整推導見
# docs/specs/2026-08-04-d45-acceptance-7-remeasure-design.md。
#
# **為什麼要對照組**：不經過 Mirage 的直接消費者在 540×1200 也只有 30.4 fps
# （investigation §11.1），Mirage 側 20–35，兩者一致。絕對 fps 衡量的是這台模擬器產生
# 畫面的能力，不是 Mirage 的效能。
#
# 用法：
#   ./scripts/verify_fps_fullscreen.sh                       # 預設 5556/8556/Pixel Flow，3 輪各 20 秒
#   ./scripts/verify_fps_fullscreen.sh -r 5 -d 30
#
# 前置：
#   - 模擬器不可帶 -no-window（要真 GUI 合成）
#   - 本機螢幕須 2560×1600 以上，否則全螢幕算不到 900×2000
#   - 遊戲必須停在**會持續變化**的畫面（streamScreenshot 是變化驅動的）
#   - phase0/harness/.venv-d45 已建好（見 phase0/harness/README-venv.md）
set -uo pipefail
source "$(dirname "$0")/lib/verify_common.sh"
source "$(dirname "$0")/lib/gui_session.sh"
source "$(dirname "$0")/lib/load_sentinel.sh"

SERIAL="emulator-5556"
GRPC_PORT="8556"
PACKAGE="com.loomgames.pixelflow"
ROUNDS=3
DURATION=20
LOAD_LIMIT=8

while getopts "s:p:g:r:d:l:h" opt; do
  case "$opt" in
    s) SERIAL="$OPTARG" ;;
    p) GRPC_PORT="$OPTARG" ;;
    g) PACKAGE="$OPTARG" ;;
    r) ROUNDS="$OPTARG" ;;
    d) DURATION="$OPTARG" ;;
    l) LOAD_LIMIT="$OPTARG" ;;
    h) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "用法：$0 [-s serial] [-p port] [-g package] [-r rounds] [-d seconds] [-l load上限]" >&2; exit 2 ;;
  esac
done

for v in ROUNDS DURATION; do
  eval "val=\$${v}"
  case "$val" in ''|*[!0-9]*) echo "❌ -${v} 只接受正整數：實測 '${val}'。" >&2; exit 2 ;; esac
done
[ "$DURATION" -lt 10 ] && { echo "❌ -d 不得低於 10 秒：太短的取樣窗拿不到穩定的中位數。" >&2; exit 2; }

VENV="$(dirname "$0")/../../phase0/harness/.venv-d45/bin/python"
BASELINE="$(dirname "$0")/../../phase0/harness/fps_baseline.py"
[ -x "$VENV" ] || { echo "❌ 找不到 venv：${VENV}（見 phase0/harness/README-venv.md）" >&2; exit 2; }

require_device "$SERIAL"
require_grpc "$GRPC_PORT"

echo ""
echo "=== 啟動遊戲：$PACKAGE ==="
"$ADB" -s "$SERIAL" shell monkey -p "$PACKAGE" -c android.intent.category.LAUNCHER 1 > /dev/null 2>&1
sleep 8
FG=$("$ADB" -s "$SERIAL" shell dumpsys activity activities 2>/dev/null \
     | grep topResumedActivity | tr -d '\r' | head -1)
case "$FG" in
  *"$PACKAGE"*) echo "✅ $PACKAGE 在前景" ;;
  *) echo "❌ $PACKAGE 不在前景——沒有畫面來源，量測沒有意義。"; exit 1 ;;
esac

MIRAGE_VALS=""
BASE_VALS=""
SIZE_OK=1

for round in $(seq 1 "$ROUNDS"); do
    echo ""
    echo "=== 第 ${round}/${ROUNDS} 輪 ==="
    if ! load_gate "$LOAD_LIMIT"; then
        echo "   跳過本輪並重試（不把髒樣本算進去）"
        continue
    fi

    LOG=$(mktemp -t d45_mirage)
    BUNDLE=$(mktemp -d -t d45_bundle)
    if ! gui_session_start "$LOG" "$BUNDLE" "" \
            "MIRAGE_PORT=$GRPC_PORT" "MIRAGE_FPS_LOG=1" "MIRAGE_CONN_LOG=1"; then
        gui_session_cleanup "$BUNDLE"; rm -f "$LOG"; exit 1
    fi

    # 進全螢幕。⌃⌘F 是產品的既有快捷鍵（AppModel+FullScreen.swift 綁在選單列）。
    osascript -e 'tell application "System Events" to keystroke "f" using {control down, command down}' \
        > /dev/null 2>&1
    # resizeDebounced 有 300ms 去抖，再加一次 setStreamSize 往返——給它足夠時間收斂。
    sleep 5

    # **斷言串流尺寸真的到上限**。全螢幕若沒進去（或螢幕太小），這裡就會是別的數字，
    # 那樣量到的 fps 不是驗收線 7 要的東西。D32 的失敗正是尺寸沒收斂就開始計時。
    if grep -q 'attachStream.*900x2000' "$LOG"; then
        echo "✅ 串流尺寸已收斂到 900x2000（解析度上限）"
    else
        echo "⚠️ 串流尺寸不是 900x2000，本輪數字不代表解析度上限："
        grep 'attachStream' "$LOG" | sed 's/.*請求 /   請求 /' | sort -u
        SIZE_OK=0
    fi

    BEFORE=$(fps_samples "$LOG")
    sleep "$DURATION"
    M=$(fps_median "$LOG")
    echo "   Mirage 側：中位數 ${M} fps（取樣 $(fps_samples "$LOG") 筆，量測前已有 ${BEFORE} 筆）"

    # **關掉 Mirage 再量對照組**——不並行。兩個 client 同時拉同一條串流，
    # emulator 得做兩份工，量到的是「兩個消費者下的幀率」而非任一方的能力。
    gui_session_cleanup "$BUNDLE"
    sleep 3

    B=$("$VENV" "$BASELINE" --endpoint "localhost:${GRPC_PORT}" \
        --seconds "$DURATION" --width 900 --height 2000 2>/dev/null \
        | sed 's/.*fps=\([0-9.]*\).*/\1/')
    echo "   對照組：${B:-（失敗）} fps"

    if [ -n "$M" ] && [ -n "$B" ]; then
        R=$(awk -v m="$M" -v b="$B" 'BEGIN { printf "%d", (b > 0) ? m * 100 / b : 0 }')
        echo "[round ${round}] mirage=${M} baseline=${B} ratio=${R}%"
        MIRAGE_VALS="${MIRAGE_VALS}${M}\n"
        BASE_VALS="${BASE_VALS}${B}\n"
    fi
    rm -f "$LOG"
done

median_of() { printf "%b" "$1" | grep -v '^$' | sort -n | awk '{ v[NR]=$1 } END { if (NR) printf "%d\n", v[int((NR+1)/2)]; else print 0 }'; }

echo ""
echo "===== 解析結果 ====="
MM=$(median_of "$MIRAGE_VALS")
BM=$(median_of "$BASE_VALS")
echo "MIRAGE_MEDIAN=${MM}"
echo "BASELINE_MEDIAN=${BM}"
echo "RATIO_PCT=$(awk -v m="$MM" -v b="$BM" 'BEGIN { printf "%d", (b > 0) ? m * 100 / b : 0 }')"
echo "ROUNDS=$(printf "%b" "$MIRAGE_VALS" | grep -cv '^$')"
echo "SIZE_OK=${SIZE_OK}"

echo ""
echo "⚠️ 探測版：本腳本目前**沒有任何斷言**，退出碼永遠是 0。"
echo "   門檻要依這份輸出決定後才加（見 docs/plans/2026-08-04-d45-acceptance-7-remeasure.md Task 5）。"
```

```bash
chmod +x app/scripts/verify_fps_fullscreen.sh
```

- [ ] **Step 2: 語法檢查與閘門 4**

```bash
cd app && bash -n scripts/verify_fps_fullscreen.sh && echo "語法 OK"
./scripts/ci.sh > /tmp/d45-ci.log 2>&1; grep -A3 "閘門 4" /tmp/d45-ci.log
```

Expected: 「語法 OK」，閘門 4 ✅。

- [ ] **Step 2b: 確認量到的是 release build**

§11.3 陷阱 2：**debug build 慢 3–4 倍**，拿 debug 量到的 fps 全部作廢。

`gui_session_start` 內部透過 `package_app.sh` 打包，第二個參數固定是 `release`——所以路徑
是對的，但**二進位必須存在且是最新的**：

```bash
cd app && swift build -c release > /tmp/d45-build.log 2>&1
RC=$?; tail -3 /tmp/d45-build.log; echo "BUILD_EXIT=$RC"
ls -la .build/release/MirageApp
```

Expected: `Build complete!`、`BUILD_EXIT=0`，且 `MirageApp` 的時間戳是剛剛。

⚠️ **每次改動產品碼後都要重建再量**，否則打包到的是舊二進位。本計畫不改產品碼，但
Task 4 若為了診斷而動過任何 Swift 檔，重量之前必須重跑這一步。

- [ ] **Step 3: 跑一次，確認全螢幕與尺寸斷言真的運作**

```bash
cd app && ./scripts/verify_fps_fullscreen.sh -r 1 -d 20 > /tmp/d45-step.log 2>&1
RC=$?; tail -25 /tmp/d45-step.log; echo "EXIT=$RC"
```

Expected: 看到「✅ 串流尺寸已收斂到 900x2000」與 `MIRAGE_MEDIAN=`／`BASELINE_MEDIAN=`／
`RATIO_PCT=`／`SIZE_OK=1`。

**若 `SIZE_OK=0`**：全螢幕沒進去。先確認 ⌃⌘F 對這個 App 有沒有效（手動按一次看看）、
Mirage 視窗是不是在前景。**不要在 `SIZE_OK=0` 的情況下往下做**——那樣量的不是解析度上限。

**若對照組印「（失敗）」**：手動跑一次 `phase0/harness/fps_baseline.py` 看錯誤訊息
（Task 1 Step 6 的煙霧測試）。

- [ ] **Step 4: 跑三輪，取得正式數字**

```bash
cd app && ./scripts/verify_fps_fullscreen.sh -r 3 -d 20 > /tmp/d45-probe-1.log 2>&1
RC=$?; grep -E "^\[round|^(MIRAGE_MEDIAN|BASELINE_MEDIAN|RATIO_PCT|ROUNDS|SIZE_OK)=" /tmp/d45-probe-1.log
echo "EXIT=$RC"
```

- [ ] **Step 5: 再跑兩次，確認數字穩定**

```bash
cd app && for i in 2 3; do
  ./scripts/verify_fps_fullscreen.sh -r 3 -d 20 > "/tmp/d45-probe-${i}.log" 2>&1
  echo "--- 第 ${i} 次 ---"
  grep -E "^(MIRAGE_MEDIAN|BASELINE_MEDIAN|RATIO_PCT|ROUNDS|SIZE_OK)=" "/tmp/d45-probe-${i}.log"
done
```

Expected: 三次的 `RATIO_PCT` 落在同一個量級。

**這一步不可省略**：`RESULTS-p1e.md` 記載過同一份測試碼在不同排程條件下量到光譜兩端。
只跑一次就定門檻，等於把一次抽樣當成分佈。

- [ ] **Step 6: 寫 `app/RESULTS-d45-probe.md`**

須含：三次的完整 KEY=VAL 表格、每輪的 `[round N]` 原始行、**對照組的版本組合**
（emulator 版本、system image、AVD 名稱、遊戲版本、機器型號——spec §3.5 的要求）、
以及一句結論「依這三次，7a 的 N 與 7b 的 M 建議定為 X／Y」。

取版本資訊：

```bash
"$HOME/Library/Android/sdk/emulator/emulator" -version | head -2
"$HOME/Library/Android/sdk/platform-tools/adb" -s emulator-5556 shell getprop ro.build.fingerprint
"$HOME/Library/Android/sdk/platform-tools/adb" -s emulator-5556 shell dumpsys package com.loomgames.pixelflow | grep -E "versionName|versionCode" | head -2
system_profiler SPHardwareDataType | grep -E "Model Name|Chip|Memory"
```

- [ ] **Step 7: Commit**

```bash
git add app/scripts/verify_fps_fullscreen.sh app/RESULTS-d45-probe.md
git commit -m "test: D45 探測版——全螢幕解析度上限下的 fps，零斷言

刻意不加斷言。D32 就是「先定門檻再實測」踩出來的坑。

1.8 MP（900×2000）這一格從來沒有量測資料——既有的量測點是 0.16／0.65／
2.59 MP，而那正是唯一會出貨的解析度。spec 明訂不得從既有點外插。

交錯的單位是「輪」而不是秒：Mirage 的 [fps] 日誌行沒有時間戳，無法事後
切出「對照組沒在跑的那幾秒」，而且只要 Mirage 開著就一直在拉串流。所以
每輪「啟動 Mirage → 量 → 關掉 → 量對照組」，輪內先後、跨輪交錯，CPU
負載波動在輪之間被平均。

斷言串流尺寸真的收斂到 900x2000 才算數——D32 的失敗正是尺寸沒收斂就
開始計時，量到的 fps 是 540x1200／888x1972／900x2000 的混合值。"
```

---

### Task 4: 坐實 guest render fps（7a 的前提）

spec §5.1：**對照組沒有隔離出它宣稱要隔離的變數。** 分母是在「Mirage 沒有跑」的狀態下量
的，它假設 Mirage 的存在不影響 guest 的畫面產生速率——而這個假設從未被檢驗。

要檢驗它，就得能直接量 guest 端的 render 速率，然後比較兩個狀態下它是否一致。

本 task **需要模擬器**。**時間上限：三個方法，試到第一個給得出可用數字的為止。**

**Files:**
- Create: `app/RESULTS-d45-guest-render.md`

**「可用」的判準**：那個數字必須真的對應到 Pixel Flow 的出幀速率。例如 `gfxinfo` 若回了
資料但那是系統 UI 的幀、不含 Unity 自繪的 SurfaceView，就**不算數**，要往下一個方法試。

- [ ] **Step 1: 方法一 —— `dumpsys gfxinfo framestats`**

```bash
ADB="$HOME/Library/Android/sdk/platform-tools/adb"
"$ADB" -s emulator-5556 shell dumpsys gfxinfo com.loomgames.pixelflow framestats \
  > /tmp/d45-gfxinfo.txt 2>&1
head -40 /tmp/d45-gfxinfo.txt
echo "--- 有沒有 framestats 區塊 ---"
grep -c "PROFILEDATA" /tmp/d45-gfxinfo.txt
```

**判定可用性**：`PROFILEDATA` 區塊存在**且**「Total frames rendered」不為 0。
若 Total frames rendered 是 0 或找不到區塊，代表 Unity 的 SurfaceView 沒被計入 → **不可用**，
記錄實際輸出後往 Step 2。

- [ ] **Step 2: 方法二 —— `dumpsys SurfaceFlinger --timestats`**

```bash
ADB="$HOME/Library/Android/sdk/platform-tools/adb"
"$ADB" -s emulator-5556 shell dumpsys SurfaceFlinger --timestats -clear > /dev/null 2>&1
"$ADB" -s emulator-5556 shell dumpsys SurfaceFlinger --timestats -enable > /dev/null 2>&1
sleep 20
"$ADB" -s emulator-5556 shell dumpsys SurfaceFlinger --timestats -dump > /tmp/d45-timestats.txt 2>&1
"$ADB" -s emulator-5556 shell dumpsys SurfaceFlinger --timestats -disable > /dev/null 2>&1
head -50 /tmp/d45-timestats.txt
```

**判定可用性**：輸出裡要能找到 Pixel Flow 的 layer（名稱含 `pixelflow` 或 `SurfaceView`）
**且**該 layer 有 `totalFrames` 或 frame duration histogram。找不到就 **不可用**，往 Step 3。

⚠️ 這與已知失敗的 `--latency` 是不同的子系統，值得單獨試。

- [ ] **Step 3: 方法三 —— emulator gRPC 是否暴露統計**

```bash
cd /Users/hanfourhuang/Projects/mirage/phase0/harness
grep -n "rpc " gen/emulator_controller_pb2_grpc.py | head -30
grep -inE "fps|frame|stat|perf" gen/emulator_controller_pb2_grpc.py | head -20
```

在 proto 的 service 定義裡找有沒有回報幀率／效能統計的 RPC。**找到才試呼叫**；沒有就是
**不可用**。

- [ ] **Step 4: 若某個方法可用——做 A/B 對照**

這才是本 task 的目的。用可用的方法各量一次：

- **A：Mirage 沒有跑**（只有遊戲在跑）
- **B：Mirage 跑著並全螢幕拉串流**

比較兩者的 guest render fps。**若 B 明顯低於 A**，代表 `streamScreenshot` 確實會拖慢
guest，spec §5.1 的疑慮成立，7a 的分母不是乾淨基準——這要寫進結論並影響 Task 5 的解讀。

- [ ] **Step 5: 寫 `app/RESULTS-d45-guest-render.md`**

無論成功與否都要寫。須含：三個方法各自的**實際輸出片段**與可用性判定、若成功則附 A/B 對照
數字與結論、若三個全失敗則明確寫「**guest render fps 仍未坐實，§11.2 的推論維持推論**」，
並列出試過什麼、為什麼不可用——**下一個人才不會重試同樣的死路**。

⚠️ **不要用間接數字硬湊成結論。** investigation §11.2 從 2026-07-28 起就誠實標著這條限制，
D45 不該為了讓報告好看而降低那個標準。

- [ ] **Step 6: Commit**

```bash
git add app/RESULTS-d45-guest-render.md
git commit -m "test: D45 坐實 guest render fps 的三次嘗試

7a（對照組線）的分母是在「Mirage 沒有跑」時量的，它假設 Mirage 的存在
不影響 guest 的畫面產生速率——而這個假設從未被檢驗。若 streamScreenshot
本身會讓 guest 多做工，兩個狀態下的 fps 相除就沒有意義。

這是 spec §5.1 把坐實從「加碼」升格為「前提」的理由。"
```

---

### Task 5: 定門檻並加上 7a／7b 斷言

依 Task 3 的三次探測數字填門檻。本 task **需要模擬器**。

**Files:**
- Modify: `app/scripts/verify_fps_fullscreen.sh`（把「⚠️ 探測版」那段換成斷言）
- Modify: `app/RESULTS-d45-probe.md`（追加門檻推導）

**Interfaces:**
- Consumes: `assert_at_least`／`assert_equals`（`lib/verify_common.sh`）、Task 3 的五個 KEY=VAL

**定門檻的規則**（不是隨意抓數字）：

| 斷言 | 門檻怎麼定 |
|---|---|
| 前置 `SIZE_OK` | 固定 `1`。尺寸沒到上限，量的就不是驗收線 7 要的東西 |
| 前置 `ROUNDS` | 固定 `2`。至少兩輪有效樣本，中位數才有意義 |
| **7a** `RATIO_PCT` | 三次探測的**最小值** × 0.9（留一成裕度） |
| **7b** `MIRAGE_MEDIAN` | 三次探測 `MIRAGE_MEDIAN` 的**最小值** × 0.8，寫成 `基準常數 × M%` 的形式 |

⚠️ **7b 的基準常數就是本次量到的數字。** 首次量測沒有「前次基準」可比——本次量到的
**就是**基準。這一點要寫進腳本註解，否則下一個人會以為那個數字有更早的來源。

⚠️ **7a 的門檻不得高於 100%。** 若三次探測的 `RATIO_PCT` 超過 100（Mirage 比對照組快），
那多半是量測條件不對等（例如對照組那段剛好負載高），先回頭查，不要直接把門檻訂在 100 以上。

- [ ] **Step 1: 從三次探測算出門檻**

```bash
cd app && grep -hE "^(MIRAGE_MEDIAN|BASELINE_MEDIAN|RATIO_PCT|ROUNDS|SIZE_OK)=" \
    /tmp/d45-probe-1.log /tmp/d45-probe-2.log /tmp/d45-probe-3.log | sort | uniq -c
```

依上表規則手算出兩個門檻與一個基準常數，寫進 `RESULTS-d45-probe.md` 的結論。

- [ ] **Step 2: 把探測版尾段換成斷言**

刪掉 `verify_fps_fullscreen.sh` 尾端的「⚠️ 探測版」三行 echo，換成（`<N>`、`<M>`、
`<BASE>` 用 Step 1 算出的數字取代，**不要留佔位字串**）：

```bash
echo ""
echo "===== 判定 ====="

# 前置：尺寸沒到上限，量的就不是驗收線 7 要的東西。**必須排在最前面**——
# 尺寸不對的話，後面兩條斷言就算綠了也沒有意義。
assert_equals "前置：串流尺寸收斂到上限" "$SIZE_OK" 1
assert_at_least "前置：有效輪數" "$(printf "%b" "$MIRAGE_VALS" | grep -cv '^$')" 2

# 7a（對照組線）：Mirage 有沒有造成額外損失。**這是 Mirage 唯一可控、也唯一該被問責
# 的量**——不經過 Mirage 的對照組在 540×1200 也只有 30.4 fps（investigation §11.1），
# 絕對 fps 衡量的是模擬器產生畫面的能力，不是 Mirage 的效能。
assert_at_least "7a Mirage/對照組比值（%）" "$(awk -v m="$MM" -v b="$BM" 'BEGIN { printf "%d", (b > 0) ? m * 100 / b : 0 }')" <N>

# 7b（歷史基準線）：整體體驗有沒有退步，含 guest、模擬器版本、機器狀態的全鏈路。
# **沒有這條，7a 會被「分子分母同步下墜」騙過**——emulator 升級後對照組一起變慢，
# 比值不變、燈號永遠綠，而使用者體感已經退步。
#
# 基準 <BASE> 是 2026-08-04 首次量到的數字（見 app/RESULTS-d45-probe.md）。
# **更新這個基準必須是有意識的決定**：改這一行並在 commit message 寫明理由，
# 不要因為某次量測沒過就往下調。
D45_BASELINE=<BASE>
assert_at_least "7b 絕對 fps（對 2026-08-04 基準 ${D45_BASELINE}）" \
    "$MM" "$((D45_BASELINE * <M> / 100))"

echo ""
echo "================================================================"
echo "驗收線 7 的判準已於 2026-08-04 重新表述（D45）：從「≥ 55」改為上面兩條相對線。"
echo "理由：不經過 Mirage 的對照組在同條件下也只有 ${BM} fps——絕對值 55 衡量的是這台"
echo "模擬器產生畫面的能力，不是 Mirage 的效能，Mirage 沒有任何辦法讓它變成 55。"
echo "完整推導與四方表決記錄見 docs/specs/2026-08-04-d45-acceptance-7-remeasure-design.md。"
echo "================================================================"
```

- [ ] **Step 3: 跑一次，確認全綠**

```bash
cd app && ./scripts/verify_fps_fullscreen.sh -r 3 -d 20 > /tmp/d45-step.log 2>&1
RC=$?; tail -20 /tmp/d45-step.log; echo "EXIT=$RC"
```

Expected: 四條 ✅（兩條前置 + 7a + 7b），`EXIT=0`。

- [ ] **Step 4: 故障注入——證明斷言會紅**

不證明會紅的斷言，跟沒有斷言沒有差別（D42 立下的規矩）。三條注入：

**注入 1：尺寸前置**——把全螢幕那行 `osascript` 暫時註解掉，重跑 `-r 1`：

```bash
cd app && sed -i.bak 's|^    osascript -e .tell application "System Events" to keystroke "f"|    : # 注入：不進全螢幕 \&\& osascript -e ... |' scripts/verify_fps_fullscreen.sh
./scripts/verify_fps_fullscreen.sh -r 1 -d 15 > /tmp/d45-inject1.log 2>&1
RC=$?; tail -12 /tmp/d45-inject1.log; echo "EXIT=$RC"
mv scripts/verify_fps_fullscreen.sh.bak scripts/verify_fps_fullscreen.sh
```

Expected: 「前置：串流尺寸收斂到上限」紅，`EXIT=1`。

**注入 2：7a**——把 7a 的門檻暫時改成 `200`（要求 Mirage 比對照組快一倍，不可能達成）。
用 `git stash` 而不是 `sed`，因為要改的是行尾一個由 Step 1 填入的數字，`sed` 的 pattern
會依你填的值而異：

```bash
cd app
# 1. 用編輯器把 7a 那行的門檻數字改成 200
# 2. 確認改對了：
grep -n "7a Mirage" scripts/verify_fps_fullscreen.sh
# 3. 跑
./scripts/verify_fps_fullscreen.sh -r 1 -d 15 > /tmp/d45-inject2.log 2>&1
RC=$?; tail -12 /tmp/d45-inject2.log; echo "EXIT=$RC"
# 4. 還原
git checkout scripts/verify_fps_fullscreen.sh
```

Expected: 7a 紅（實測比值遠低於 200），`EXIT=1`。

**注入 3：7b**——同樣手法，把 `D45_BASELINE=` 那行的數字暫時改成實測值的 3 倍：

```bash
cd app
# 1. 用編輯器把 D45_BASELINE 改成實測 MIRAGE_MEDIAN 的 3 倍
grep -n "D45_BASELINE=" scripts/verify_fps_fullscreen.sh
# 2. 跑
./scripts/verify_fps_fullscreen.sh -r 1 -d 15 > /tmp/d45-inject3.log 2>&1
RC=$?; tail -12 /tmp/d45-inject3.log; echo "EXIT=$RC"
# 3. 還原
git checkout scripts/verify_fps_fullscreen.sh
```

Expected: 7b 紅，`EXIT=1`。**7a 應該仍是綠的**——這證明兩條線互相獨立，不是同一個東西
的兩種寫法。

⚠️ 每次注入後都要 `git status --short` 確認還原乾淨、無 `.bak` 殘留。
⚠️ 注入 1 用 `sed` 是安全的（改的是固定字串），注入 2／3 改的是你自己填的數字，
**用 `git checkout` 還原比 `.bak` 可靠**。

- [ ] **Step 5: 連跑兩次，確認不 flaky**

```bash
cd app && for i in 1 2; do
  ./scripts/verify_fps_fullscreen.sh -r 3 -d 20 > "/tmp/d45-stable-${i}.log" 2>&1
  echo "第 ${i} 次 EXIT=$?"
done
```

Expected: 兩次都 `EXIT=0`。**任一次紅就代表門檻定太緊**，回 Step 1 放寬並在
`RESULTS-d45-probe.md` 記下為什麼。

- [ ] **Step 6: Commit**

```bash
git add app/scripts/verify_fps_fullscreen.sh app/RESULTS-d45-probe.md
git commit -m "feat: D45 驗收線 7 的兩條相對判準線（門檻由三次實測決定）

7a 對照組線：Mirage 的 fps 中位數 ≥ 對照組的 N%（抓 Mirage 的額外損失）
7b 歷史基準線：絕對 fps 中位數 ≥ 2026-08-04 基準的 M%（抓全鏈路退步）

兩條都是相對的，但比的對象不同，各自擋住對方擋不住的失敗：Mirage 顯示
路徑退步時兩條都紅；emulator 升級讓對照組一起變慢時 7a 不動而 7b 紅；
換了更快的機器但 Mirage 開始有損失時 7a 紅而 7b 不動。

前置兩條排在最前面：尺寸沒收斂到 900x2000 的話，後面兩條就算綠了也沒有
意義——量的不是驗收線 7 要的東西。

三條故障注入皆證明會紅。"
```

---

### Task 6: 更新既有文件

把驗收線 7 的判定與新判準落實到三份既有文件，並開新債務。本 task **不需要模擬器**。

**Files:**
- Modify: `docs/specs/2026-07-26-p1e-fullscreen-audio-design.md`（§8 第 7 條）
- Modify: `app/RESULTS-p1e.md`（驗收表第 7 列、pending-human 清單、判定段落）
- Modify: `docs/specs/2026-07-29-project-review.md`（D45 標記已修、D47 補一句、新增債務）

- [ ] **Step 1: spec §8-7 加更正註記**

在 `docs/specs/2026-07-26-p1e-fullscreen-audio-design.md` 的第 7 條之後插入，沿用 §5 與
§8-6 既有的「⚠️ 更正」慣例：

```markdown

   > **⚠️ 更正（2026-08-04，D45）：`≥ 55` 衡量錯了東西，已改為兩條相對線。**
   >
   > 本條的標題是「fps **不回歸**」——不回歸本來就是相對概念，是後面那個 `≥ 55` 把它
   > 偷換成絕對值。而 `2026-07-28-mirror-never-rendered-investigation.md` §11.1 已經
   > 證明：用 Python harness 直接消費同一條串流（**完全不經過 Mirage**）也只有
   > 30.4 fps，Mirage 側 20–35，兩者一致。**這個絕對數字衡量的是這台模擬器產生畫面
   > 的能力，不是 Mirage 的效能**，Mirage 沒有任何辦法讓它變成 55。
   >
   > **新表述**（完整推導與四方表決記錄見
   > `docs/specs/2026-08-04-d45-acceptance-7-remeasure-design.md`）：
   >
   > - **7a（對照組線）**：`MIRAGE_FPS_LOG` 中位數不低於同條件對照組的 N%
   >   —— 抓「Mirage 有沒有造成額外損失」，這是 Mirage 唯一可控的量
   > - **7b（歷史基準線）**：絕對 fps 中位數不低於前次記錄基準的 M%
   >   —— 抓「整體體驗有沒有退步」，含 guest、模擬器、機器在內的全鏈路
   >
   > 兩條都是相對的但比的對象不同。缺 7b，「emulator 升級後對照組一起變慢、分子分母
   > 同步下墜」會讓 7a 永遠綠而使用者體感已退步。
   >
   > 自動化涵蓋在 `app/scripts/verify_fps_fullscreen.sh`。
```

- [ ] **Step 2: `RESULTS-p1e.md` 驗收表第 7 列改判**

該列目前的證據欄寫著「證實 headless／螢幕關閉下 `.task` 未被驅動」——**那個歸因已被推翻**
（`StreamSize.swift` 的 doc comment 從 2026-07-29 起就記載著這件事，`verify_game_fps.sh:11-16`
也是）。

把判定從 `⬜ pending-human` 改成依實測結果的判定，證據欄要含：(a) 本次終於量得到的理由；
(b) 全螢幕解析度上限（900×2000）下的實測數字與對照組數字；(c) 判準已重新表述為 7a／7b；
(d) 指向 `app/RESULTS-d45-probe.md` 與 spec 的更正註記。

⚠️ **判定要如實反映 Task 5 的實測結果**。若 7a／7b 都過就是通過；但**通過的是新判準**，
證據欄必須寫明「原 `≥ 55` 的字面判準未達成（實測 X fps），該判準已於 D45 重新表述」——
不要讓讀者以為 55 達成了。

- [ ] **Step 3: `RESULTS-p1e.md` 的 pending-human 清單與判定段落**

驗收線 7 從 pending-human 清單移除；「已知限制」與「判定」兩節裡凡是稱驗收線 7 為
pending-human 的敘述都要更新。

```bash
cd /Users/hanfourhuang/Projects/mirage && grep -n "驗收線 7" app/RESULTS-p1e.md
```

逐一檢視每一處，確認沒有殘留的舊歸因。

- [ ] **Step 4: `project-review.md` 標記 D45 已修並補兩處**

1. D45 那列的 `**D45**` 改成 `~~**D45**~~`，修法欄追加本次結論（實測數字、判準已重新
   表述為 7a／7b、自動化涵蓋在哪支腳本、以及 guest render fps 有沒有坐實）
2. **D47 那列補一句**：「D45 已定案，A4 的 `FPS_AVG ≥ 27` 應對齊 7b 的形式（比歷史基準
   而非比固定值）」
3. **新增一筆債務**（編號接在現有最大號之後，先自己確認最大號是多少）：
   `phase0/harness/` 的 11 個檔案全部 import 需要 protobuf 7.35 的產生碼，而系統裝的是
   4.25，整批 import 不動。D45 用 venv 讓其中一條路徑（`fps_baseline.py`）跑得起來，
   其餘 10 個仍是死的。與 D37（`tools/probe/tests` 從未被跑過）同型。

- [ ] **Step 5: 確認沒有殘留的過期宣稱**

```bash
cd /Users/hanfourhuang/Projects/mirage && grep -rn "驗收線 7" app/RESULTS-p1e.md docs/specs/2026-07-29-project-review.md | grep -iE "pending-human|headless"
```

Expected: **無輸出**，或僅剩描述歷史的行（那些行必須明確標為「已被推翻的舊歸因」）。

⚠️ 若某一行必須同時提到「驗收線 7」與「pending-human」（例如描述這段歷史），**不要為了
讓 grep 過關而改寫專業術語**——D32 的 Task 7 犯過這個錯，把 `pending-human` 換成中文導致
日後搜不到。保留術語，在報告裡說明這幾行是歷史敘述。

- [ ] **Step 6: 跑 ci.sh 確認沒有連帶破壞**

```bash
cd app && ./scripts/ci.sh > /tmp/d45-ci.log 2>&1
RC=$?; echo "閘門數：$(grep -c '=== 閘門' /tmp/d45-ci.log)"; tail -4 /tmp/d45-ci.log; echo "EXIT=$RC"
```

Expected: 閘門數 8、「全部通過」、`EXIT=0`。

- [ ] **Step 7: Commit**

```bash
git add docs/specs/2026-07-26-p1e-fullscreen-audio-design.md app/RESULTS-p1e.md \
        docs/specs/2026-07-29-project-review.md
git commit -m "docs: D45 收尾——驗收線 7 改判並重新表述判準

驗收線 7 從 pending-human 改判，判準從「≥ 55」改為兩條相對線（7a 對照組
線、7b 歷史基準線）。原字面判準未達成，且不經過 Mirage 的對照組也只有
30.4 fps——那個絕對數字衡量的是模擬器產生畫面的能力，不是 Mirage 的效能。

一併修正 RESULTS-p1e 第 7 列仍掛著的舊歸因（「headless 不驅動 .task」），
那個歸因在 2026-07-28 就被推翻、StreamSize.swift 的註解從 2026-07-29 起
就記載著這件事，只是沒有人回頭改文件。

D47 補一句：A4 的 FPS_AVG ≥ 27 應對齊 7b 的形式。
新記一筆：phase0/harness 的 11 個檔案因 protobuf 版本全部 import 不動，
D45 只讓其中一條路徑跑得起來，其餘 10 個仍是死的（與 D37 同型）。"
```

---

## 完成檢查

```bash
cd app && ./scripts/ci.sh 2>&1 | tail -4              # 八道閘門全綠
./scripts/verify_fps_fullscreen.sh -r 3 -d 20 2>&1 | tail -12   # 四條 ✅
git status --short                                     # 乾淨
```

**不要因為 `ci.sh` 綠了就宣稱驗收線 7 通過**——`ci.sh` 不跑
`verify_fps_fullscreen.sh`（需要模擬器與 GUI）。兩者要分別跑、分別報告。
