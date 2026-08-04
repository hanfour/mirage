# D32：驗收線 6 的自動化涵蓋 — 實作計畫

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 P1-e 驗收線 6（音訊健康）從 pending-human 變成一支會紅的自動化腳本。

**Architecture:** 照 `verify_game_fps.sh` 已驗證的手法——`package_app.sh` 打包 .app →
`open -a` 帶環境變數 → `osascript` 拉前景 → grep 每秒日誌。在同一次 60 秒量測裡同時開
`MIRAGE_AUDIO_LOG=1` 與 `MIRAGE_FPS_LOG=1`，一份 log 拿到音訊健康與畫面存活兩組證據。
判準重新表述：只統計「本秒與前一秒皆 `pkt>0`」的 underrun 增量。

**Tech Stack:** bash（`set -uo pipefail`）、`app/scripts/lib/verify_common.sh` 的斷言、
Android emulator gRPC、macOS `open`/`osascript`。

**設計文件：** `docs/specs/2026-08-03-d32-acceptance-6-automation-design.md`（commit `bf6ce82`）

## Global Constraints

- 工作目錄一律 `app/`。腳本內用 `cd "$(dirname "$0")/.."` 定錨，與既有腳本一致。
- 所有 `verify_*.sh` **一律 `source lib/verify_common.sh`**，不得各寫一份退出碼檢查（D9）。
- **裸變數不得緊接全形標點**：`echo "$rc，"` 在 `set -u` 下炸成未綁定變數。一律 `${rc}`。
  `ci.sh` 閘門 4 會擋，但寫的時候就要對。
- **`#expect` 不得拿 Bool 跟 `true`/`false` 比**（D35，`ci.sh` 閘門 5）。本計畫不寫 Swift
  測試，但改動若波及測試檔仍適用。
- 組 `.app` **一律用 `app/scripts/package_app.sh`**，不得自己 `cp` executable（D25）。
- 啟動 emulator **絕不可帶 `-no-audio`**。其他計畫的啟動範例常帶它（例如
  `docs/plans/2026-07-22-phase0c-sck-validation.md:70`），帶了本計畫整件事就沒有意義。
- 門檻數字**一律待 Task 5 實測後才填**。D32 本身就是「先定門檻再實測」踩出來的坑。
- **Task 4 是執行途中新增的**（Task 3 的實測揭露產品缺陷），原計畫只有 6 個 task。
  舊的 Task 4／5／6 已順延為 5／6／7。
- 提交訊息格式 `<type>: <description>`，型別限 feat/fix/refactor/docs/test/chore/perf/ci。
- **驗證步驟不得把待驗指令接管線**。`cmd | tail -5; echo "EXIT=$?"` 取到的是 `tail`
  的退出碼（永遠 0），腳本紅了也看不出來——正是 D9 修掉的那類假訊號。本計畫一律寫成
  「先重導向到檔案、立刻取 `$?`、再 `tail` 檔案」：

  ```bash
  cmd > /tmp/d32-step.log 2>&1; RC=$?; tail -12 /tmp/d32-step.log; echo "EXIT=$RC"
  ```

  ⚠️ **不要改用 `${PIPESTATUS[0]}`**。本專案的互動 shell 是 **zsh**，而 zsh 的陣列是
  1-indexed——`${PIPESTATUS[0]}` 在 zsh 下永遠是空字串（zsh 的對應變數是
  `${pipestatus[1]}`）。`verify_*.sh` 腳本內部用 `${PIPESTATUS[0]}` 是**正確的**，因為
  它們有 `#!/usr/bin/env bash` shebang、實際跑在 bash 上；但計畫裡給人逐字貼進終端機
  的指令跑在 zsh，同一個寫法就會靜默失效。
  （2026-08-03：本計畫先寫成 `$?`（Task 2 抓到），改成 `${PIPESTATUS[0]}` 後又發現
  zsh 問題，最終定為上面的重導向寫法——兩次都是「退出碼沒取對」，同一類坑踩兩次。）

## 環境前置（Task 2 起需要）

```bash
# 啟動 mirage-game（裝了 Pixel Flow 的那台）。-port 5556 / -grpc 8556 沿用
# docs/specs/2026-07-28-phase1-game-recon.md:137 已驗證的組合。
"$HOME/Library/Android/sdk/emulator/emulator" -avd mirage-game -port 5556 -grpc 8556 -gpu host &
# 等開機完成
"$HOME/Library/Android/sdk/platform-tools/adb" -s emulator-5556 wait-for-device
until [ "$("$HOME/Library/Android/sdk/platform-tools/adb" -s emulator-5556 shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do sleep 2; done
```

⚠️ **不要帶 `-no-window`**：本計畫要量真 GUI 合成下的 fps，而且 Pixel Flow 需要 GPU。
⚠️ **不要 `loadSnapshot`**：memory 記載它會崩潰模擬器。
⚠️ **拔掉實體 Android 手機**：插著會干擾 adb 選裝置（D9 記載的 `-s` 缺失本體）。

---

### Task 1: `assert_at_most` 與它的閘門

驗收線 6 的核心斷言是「underrun 增量 **不超過** 門檻」，而 `verify_common.sh` 現在只有
`assert_at_least`。這個 task 補上反向斷言，並解決一個既有缺口：`verify_common_selftest.sh`
存在但 `ci.sh` 六道閘門沒有一道跑它——新斷言若沒人跑就是不受保護的（與 D37「`tools/probe/tests`
的 13 個檔從未被跑過」同型）。

本 task **不需要模擬器**。

**Files:**
- Modify: `app/scripts/lib/verify_common.sh`（在檔尾 `assert_at_least` 之後追加）
- Modify: `app/scripts/lib/verify_common_selftest.sh:44`（在 `assert_equals` 案例之後插入）
- Modify: `app/scripts/ci.sh:236`（在閘門 6 結束後、總結之前插入閘門 7）

**Interfaces:**
- Produces: `assert_at_most "<描述>" "<實測值>" "<門檻>"` — 實測值 > 門檻時印 ❌ 並 `exit 1`；
  否則印 ✅ 後回傳 0。空字串實測值當作 0（視同通過）。Task 4 會用它。

- [ ] **Step 1: 先寫會紅的自我測試案例**

在 `app/scripts/lib/verify_common_selftest.sh` 第 43 行（`assert_equals 實測為空` 那筆）
之後、第 45 行的空行之前插入：

```bash
# assert_at_most 是 assert_at_least 的反向：驗收線 6 的 underrun 增量要的是上限。
# 邊界（剛好等於門檻）刻意與 assert_at_least 同樣視為通過——門檻是「可接受的最大值」，
# 不是「必須低於」。
check "assert_at_most 低於門檻 → 繼續"      "$(run_case 'assert_at_most "欠位" 3 5')"  0
check "assert_at_most 剛好等於門檻 → 繼續"  "$(run_case 'assert_at_most "欠位" 5 5')"  0
check "assert_at_most 超過門檻 → 中止"      "$(run_case 'assert_at_most "欠位" 6 5')"  1
# 空字串當作 0：解析 log 沒抓到數字時，`assert_at_least` 的既有語意是「當作 0 → 中止」，
# 反向斷言若照抄「當作 0」則會**通過**——那就是假綠燈。所以這裡的空字串必須是呼叫端
# 自己先擋掉的（Task 4 的 A1/A2 斷言負責），本函式只保證行為明確可預期，不自作聰明。
check "assert_at_most 值為空 → 當作 0 通過" "$(run_case 'assert_at_most "欠位" "" 5')" 0
check "assert_at_most 中止後不執行後續指令" \
      "$(run_case 'assert_at_most "欠位" 6 5; exit 0')" 1
```

- [ ] **Step 2: 跑自我測試，確認它紅**

```bash
cd app && ./scripts/lib/verify_common_selftest.sh; echo "EXIT=$?"
```

Expected: 5 項失敗（新加的 5 筆全部退出碼 127 —— `assert_at_most: command not found`
被 `run_case` 的子 shell 吞掉後回 127，與期待的 0／1 都不符），`EXIT=1`。

**若這一步是綠的就停下來**：代表 `assert_at_most` 已經存在，先查清楚再繼續。

- [ ] **Step 3: 實作 `assert_at_most`**

在 `app/scripts/lib/verify_common.sh` 檔尾（第 94 行 `assert_at_least` 的結尾大括號之後）
追加：

```bash

# 斷言某個數值不超過上限。`assert_at_least` 的反向。
#
# **為什麼空字串在這裡當作 0（通過），與 assert_at_least 相反**：at_least 把空字串
# 當 0 會中止，那是安全的方向（抓不到數字 → 紅）。at_most 若照抄，抓不到數字就會
# **通過**——正好是 D9 要修掉的那種假綠燈。這裡不加特殊分支去猜呼叫端的意圖，而是
# 把責任放在呼叫端：先用 assert_at_least 確認「有東西可量」（例如日誌行數 > 0），
# 再用本函式判上限。兩個斷言各自單純，組合起來才完整。
assert_at_most() {
    local desc="$1" actual="$2" threshold="$3"
    if [ "${actual:-0}" -gt "$threshold" ]; then
        echo "❌ ${desc}：實測 ${actual:-0}，上限 ${threshold}"
        exit 1
    fi
    echo "✅ ${desc}：${actual:-0}（上限 ${threshold}）"
}
```

- [ ] **Step 4: 跑自我測試，確認全綠**

```bash
cd app && ./scripts/lib/verify_common_selftest.sh; echo "EXIT=$?"
```

Expected: 最後一行「全部通過」，`EXIT=0`。

- [ ] **Step 5: 突變檢查——證明新斷言真的會紅**

把 `assert_at_most` 的 `exit 1` 暫時改成 `:`（不中止），重跑自我測試：

```bash
cd app && sed -i.bak 's/^        exit 1$/        :/' scripts/lib/verify_common.sh \
  && ./scripts/lib/verify_common_selftest.sh; echo "EXIT=$?"
```

Expected: **具名失敗**，至少要看到「assert_at_most 超過門檻 → 中止」與
「assert_at_most 中止後不執行後續指令」兩項印 ❌，`EXIT=1`。

⚠️ 這個 `sed` 會同時改到 `assert_ok`／`assert_equals`／`assert_at_least` 的 `exit 1`
（縮排相同），所以預期會看到更多項失敗——這是對的，代表整組斷言都有被測到。重點是
**新加的兩項必須在失敗清單裡**。若新加的項目沒出現在失敗清單，代表測試沒真的驗到它。

還原：

```bash
cd app && mv scripts/lib/verify_common.sh.bak scripts/lib/verify_common.sh \
  && ./scripts/lib/verify_common_selftest.sh | tail -2
```

Expected: 「全部通過」。

- [ ] **Step 6: 加閘門 7**

在 `app/scripts/ci.sh` 第 235 行（閘門 6 的 `fi`）之後、第 237 行的 `echo ""` 之前插入：

```bash

echo ""
echo "=== 閘門 7：verify_common.sh 的自我測試 ==="
# 2026-08-03 新增（D32）。**加這道閘門的理由與閘門 6 完全相同**：
# verify_common_selftest.sh 從 D9（2026-07-30）就存在、不需要模擬器、可以隨時跑，
# 但沒有任何 CI 步驟會執行它——寫了卻沒人跑的測試比沒有測試更糟，它讓人以為有涵蓋。
# 而 verify_common.sh 是五支 verify_* 腳本的共用判斷層，它壞掉等於那五支全部失去斷言。
if ./scripts/lib/verify_common_selftest.sh > /dev/null 2>&1; then
    ok "verify_common.sh 自我測試通過"
else
    fail "verify_common.sh 自我測試失敗（重跑 ./scripts/lib/verify_common_selftest.sh 看細節）："
    ./scripts/lib/verify_common_selftest.sh 2>&1 | grep "❌" | sed 's/^/   /'
fi
```

同時更新第 240 行的總結字串，在括號內結尾追加 `、共用斷言自我測試綠`：

```bash
    echo "全部通過（$RUNS 次跑次、0 行 NIO ERROR、無假 skip、無全形標點陷阱、無永不紅的 #expect、provision 測試綠、共用斷言自我測試綠）"
```

- [ ] **Step 7: 驗閘門 7 會紅**

```bash
cd app && sed -i.bak 's/^        exit 1$/        :/' scripts/lib/verify_common.sh
./scripts/ci.sh 2>&1 | grep -A5 "閘門 7"; echo "---"
mv scripts/lib/verify_common.sh.bak scripts/lib/verify_common.sh
```

Expected: 閘門 7 那一段印 ❌ 與具名失敗清單。

⚠️ `ci.sh` 會跑完整測試套件數次，這一步要幾分鐘。若只想驗閘門 7 本身，可先單獨跑
Step 5 的突變檢查（已涵蓋同一條邏輯），把本步驟留到最後一次完整 `ci.sh` 時一併確認。

- [ ] **Step 8: 跑完整 ci.sh 確認七道閘門全綠**

```bash
cd app && ./scripts/ci.sh > /tmp/d32-step.log 2>&1; RC=$?; tail -20 /tmp/d32-step.log; echo "EXIT=$RC"
```

Expected: 「全部通過」，`EXIT=0`，且輸出裡看得到「閘門 7」。

- [ ] **Step 9: Commit**

```bash
git add app/scripts/lib/verify_common.sh app/scripts/lib/verify_common_selftest.sh app/scripts/ci.sh
git commit -m "feat: assert_at_most 與閘門 7（共用斷言的自我測試終於有人跑）

驗收線 6 的核心斷言是 underrun 增量的「上限」，verify_common.sh 只有
assert_at_least。補上反向斷言。

空字串的處理刻意與 assert_at_least 相反並寫進註解：at_least 把空字串當 0
會中止（安全方向），at_most 照抄則會通過——那正是 D9 要修掉的假綠燈。責任
放在呼叫端先確認「有東西可量」，兩個斷言各自單純。

順帶補上閘門 7：verify_common_selftest.sh 從 D9 就存在、不需模擬器，卻沒有
任何 CI 步驟跑過它，與 D37（tools/probe/tests 的 13 個檔從未被跑過）同型。
而 verify_common.sh 是五支 verify_* 腳本的共用判斷層，它壞掉等於那五支同時
失去斷言。

已做突變檢查：把 exit 1 換成 : 之後，新增的兩項出現在具名失敗清單裡。"
```

---

### Task 2: 抽出 `lib/gui_session.sh`

`verify_audio_gui.sh` 的第四條斷言是 fps，跟 `verify_game_fps.sh` 需要同一套「打包 →
啟動 → 拉前景 → 解析 fps → cleanup」邏輯。不抽就要複製一份 awk 與診斷分支，而 D9 的
教訓寫得很明白：重複的檢查會漂移。`package_app.sh`（D25）已經為「怎麼組 .app」抽過
一次，這次是「怎麼啟動 GUI session 並收 log」。

本 task **需要模擬器**（見上方環境前置），因為驗證方式是行為對照。

**Files:**
- Create: `app/scripts/lib/gui_session.sh`
- Modify: `app/scripts/verify_game_fps.sh:69-101`（bundle 與 cleanup）、`:131-137`（啟動）、
  `:142-168`（fps 解析）

**Interfaces:**
- Consumes: `package_app.sh <目標目錄> <release|debug> [二進位覆寫路徑]`（既有）
- Produces:
  - `gui_session_start <log路徑> <bundle路徑> <二進位覆寫路徑或空字串> [env KEY=VAL ...]`
    — 打包並以 `.app` 啟動 MirageApp，stdout/stderr 導向 log，等待 6 秒後用 `osascript`
    拉前景。打包失敗回傳 1。第三個參數原樣轉給 `package_app.sh`，空字串表示用預設二進位。
  - `gui_session_cleanup <bundle路徑>` — `pkill -x MirageApp` 並移除 bundle。
  - `fps_summary <log路徑>` — 印「取樣 N 筆　平均 X fps　最低 A　最高 B」與串流尺寸；
    取樣為 0 時印診斷（分辨「幀有進來但視窗沒合成」vs「幀根本沒進來」）並回傳 1。
  - `fps_samples <log路徑>` — 只回傳取樣筆數（給斷言用）。
  - `fps_average <log路徑>` — 只回傳平均 fps 的整數值（給斷言用）。

- [ ] **Step 1: 先記錄改動前的行為基準**

```bash
cd app && ./scripts/verify_game_fps.sh -s emulator-5556 -p 8556 -n -d 20 2>&1 | tail -8
```

Expected: 看到「取樣 N 筆　平均 X fps」與「串流尺寸：」兩行。**把這組數字抄下來**——
Step 6 要拿它對照，確認重構沒改變行為。

若這一步取樣為 0，先照它印出的診斷把環境弄好再繼續。**不要**在基準拿不到的情況下
往下做重構——那樣就沒有東西可以對照了。

- [ ] **Step 2: 建立 `lib/gui_session.sh`**

```bash
#!/usr/bin/env bash
# 啟動 Mirage GUI session 並解析它的每秒日誌。
# 用法：source "$(dirname "$0")/lib/gui_session.sh"
#
# **存在的理由與 verify_common.sh 同一條**（D9）：「怎麼啟動 App 並收 log」原本只寫在
# verify_game_fps.sh 裡，D32 的 verify_audio_gui.sh 需要一模一樣的東西加上 fps 解析。
# 複製一份的下場已經有前例——D9 記載 coverage.sh 被修好而三支 verify_* 沒跟上。
#
# package_app.sh 由 D25 建立，是組 .app 的唯一入口；本檔只負責「啟動它、拉到前景、
# 收 log、解析」，不重複打包邏輯。

# 打包並啟動 MirageApp，把 stdout/stderr 導向 log。
#
# **必須以 .app bundle 啟動，不能直接跑 bare executable**：直接跑時 macOS 不一定把
# 視窗合成上螢幕，MTKView 的 currentDrawable 為 nil、Renderer 早退，present 一次都
# 不發生——而幀其實都正常進來了。2026-07-28 實測這是**不穩定**的（同樣的指令有時量
# 得到有時完全量不到），所以不是「偏低」而是「不可信」。包成 bundle 之後 activation
# policy 才是 .regular。
gui_session_start() {
    local log="$1" bundle="$2" app_override="$3"; shift 3
    if ! "$(dirname "${BASH_SOURCE[0]}")/../package_app.sh" \
            "$bundle" release "$app_override" > /dev/null; then
        echo "❌ 打包 .app 失敗（見上方訊息）" >&2
        return 1
    fi
    local env_args=()
    local kv
    for kv in "$@"; do env_args+=(--env "$kv"); done
    open -a "$bundle/Mirage.app" --stdout "$log" --stderr "$log" "${env_args[@]}"
    sleep 6
    # 視窗要在前景才會被合成。取不到就繼續——量測本身仍可能成功，而 fps_summary
    # 的診斷分辨得出來。
    osascript -e 'tell application "System Events" to set frontmost of process "MirageApp" to true' \
        > /dev/null 2>&1
}

gui_session_cleanup() {
    local bundle="${1:-}"
    pkill -x MirageApp 2>/dev/null
    [ -n "$bundle" ] && rm -rf "$bundle"
    return 0
}

# 取樣筆數。**`grep -c` 沒命中時已經會印 0 並回傳 1**，寫成 `|| echo 0` 會再補一個 0，
# 讓結果變成兩行、後面的 `-eq` 直接爆掉——而那正是沒量到幀時必然走到的路徑。
fps_samples() {
    grep -c 'fps=' "$1" 2>/dev/null || true
}

# 平均 fps（整數，無條件捨去）。沒有取樣時回 0。
fps_average() {
    local n
    n=$(fps_samples "$1")
    [ "$n" -eq 0 ] && { echo 0; return 0; }
    grep 'fps=' "$1" | sed 's/.*fps=//' | awk -v n="$n" '{ s += $1 } END { printf "%d\n", s/n }'
}

# 人看的摘要。取樣為 0 時印診斷並回傳 1。
fps_summary() {
    local log="$1" samples frames
    samples=$(fps_samples "$log")
    if [ "$samples" -eq 0 ]; then
        frames=$(grep -c '幀 #' "$log" 2>/dev/null || true)
        echo "取樣數 0——Mirage 沒有 present 任何一幀。"
        echo ""
        if [ "$frames" -gt 0 ]; then
            echo "但幀有進來（log 裡有 ${frames} 行「幀 #N」）。**所以問題不在串流，在視窗**："
            echo "視窗沒有被合成上螢幕，MTKView 的 currentDrawable 為 nil，Renderer 早退。"
            echo "檢查：Mirage 視窗有沒有真的出現在螢幕上、有沒有被其他視窗完全遮住、"
            echo "螢幕是否鎖定。這條路徑實測是不穩定的，重跑一次往往就好。"
        else
            echo "而且幀也沒進來（log 裡沒有「幀 #N」）。問題在串流或連線："
            head -3 "$log"
            echo "（若上面出現 [transport]，代表健康探測通過、狀態已連上，那就是串流不出幀；"
            echo "  記得 streamScreenshot 是變化驅動的，畫面靜止時本來就不出幀。）"
        fi
        echo "log：$log"
        return 1
    fi
    grep 'fps=' "$log" | sed 's/.*fps=//' | awk -v n="$samples" '
      { s += $1; if (min == "" || $1 < min) min = $1; if ($1 > max) max = $1 }
      END { printf "取樣 %d 筆　平均 %.1f fps　最低 %d　最高 %d\n", n, s/n, min, max }'
    # 沒有串流尺寸就無法解讀 fps：fps 對串流解析度敏感（launcher 上 540x1200 約 50fps、
    # 888x1972 約 20fps），而尺寸由視窗大小經 resizeDebounced 決定，會隨視窗變動。
    echo -n "串流尺寸："
    grep 'attachStream' "$log" | sed 's/.*請求 //' | sort -u | tr '\n' ' '
    echo ""
    return 0
}
```

- [ ] **Step 3: 讓它可執行**

```bash
chmod +x app/scripts/lib/gui_session.sh
```

- [ ] **Step 4: 改 `verify_game_fps.sh` 使用它**

在 `set -uo pipefail`（第 37 行）之後加一行 source：

```bash
source "$(dirname "$0")/lib/gui_session.sh"
```

把第 85-88 行的打包區塊改成只保留 bundle 路徑宣告（打包移進 `gui_session_start`）：

```bash
BUNDLE=$(mktemp -d -t mirage_fps_bundle)
```

把第 91-100 行的 `cleanup()` 改成：

```bash
cleanup() {
    [ -n "$ANIM_PID" ] && kill "$ANIM_PID" 2>/dev/null
    gui_session_cleanup "${BUNDLE:-}"
    # 還原：疊層是為了量測而開的，不還原會一直留在使用者的裝置上。
    case "$ORIG_POINTER" in
        ""|null) "$ADB" -s "$SERIAL" shell settings put system pointer_location 0 >/dev/null 2>&1 ;;
        *)       "$ADB" -s "$SERIAL" shell settings put system pointer_location "$ORIG_POINTER" >/dev/null 2>&1 ;;
    esac
}
```

把第 131-137 行的啟動區塊改成：

```bash
echo "[fps] 啟動 Mirage（.app bundle）→ localhost:${GRPC_PORT}，量測 ${DURATION}s"
if ! gui_session_start "$LOG" "$BUNDLE" "$APP_OVERRIDE" \
        "MIRAGE_PORT=$GRPC_PORT" "MIRAGE_FPS_LOG=1" "MIRAGE_CONN_LOG=1"; then
    exit 1
fi
sleep "$DURATION"
```

把第 142-173 行的解析區塊改成：

```bash
echo ""
echo "===== 結果 ====="
grep 'fps=' "$LOG" | tail -20
echo ""
if ! fps_summary "$LOG"; then
    exit 1
fi
```

⚠️ **第 103 行 `echo "[fps] 二進位：$APP"` 引用了一個從未被賦值的 `$APP`**——原碼在
`set -u` 下靠 `-a` 選項寫進 `APP_OVERRIDE` 卻印 `$APP`。改動時一併修成：

```bash
echo "[fps] 二進位：${APP_OVERRIDE:-（預設 .build/release/MirageApp）}"
```

⚠️ `-a` 的覆寫路徑走 `gui_session_start` 的第三個位置參數（見上方的啟動區塊
`gui_session_start "$LOG" "$BUNDLE" "$APP_OVERRIDE" ...`）。Step 7 會實測它沒有在重構
中變成死參數。

- [ ] **Step 5: 語法檢查**

```bash
cd app && bash -n scripts/lib/gui_session.sh && bash -n scripts/verify_game_fps.sh && echo "語法 OK"
```

Expected: 「語法 OK」。

- [ ] **Step 6: 行為對照——確認重構沒改變結果**

```bash
cd app && ./scripts/verify_game_fps.sh -s emulator-5556 -p 8556 -n -d 20 2>&1 | tail -8
```

Expected: 與 Step 1 抄下的數字**同一個量級**（fps 每次會有波動，不要求完全相同），
且「取樣 N 筆」「串流尺寸：」兩行都在。

若取樣變成 0 而 Step 1 不是 0，**停下來**：重構破壞了啟動路徑，先修好再繼續。

- [ ] **Step 7: 驗 `-a` 選項仍然有效**

```bash
cd app && ./scripts/verify_game_fps.sh -s emulator-5556 -p 8556 -n -d 10 \
    -a /nonexistent/MirageApp > /tmp/d32-step.log 2>&1; RC=$?; tail -5 /tmp/d32-step.log; echo "EXIT=$RC"
```

Expected: 打包失敗並 `EXIT=1`（不是靜默用了預設二進位）。這證明 `-a` 沒有在重構中
變成死參數。

- [ ] **Step 8: 跑 ci.sh 確認閘門 4 不擋新檔**

```bash
cd app && ./scripts/ci.sh 2>&1 | grep -A3 "閘門 4"
```

Expected: ✅（`gui_session.sh` 裡沒有裸變數緊接全形標點）。

- [ ] **Step 9: Commit**

```bash
git add app/scripts/lib/gui_session.sh app/scripts/verify_game_fps.sh
git commit -m "refactor: 抽出 lib/gui_session.sh，供 D32 的音訊 GUI 驗證共用

verify_audio_gui.sh（下一個 commit）需要同一套「打包 → open -a → osascript
拉前景 → 解析 fps → cleanup」。複製一份的下場已有前例：D9 記載 coverage.sh
被修好而三支 verify_* 帶著同型缺陷沒跟上。package_app.sh（D25）已為「怎麼組
.app」抽過一次，這次是「怎麼啟動 GUI session 並收 log」。

順手修掉兩個既有問題：
- verify_game_fps.sh:103 印的 \$APP 從未被賦值（-a 寫進的是 APP_OVERRIDE）
- -a 的覆寫路徑改走 GUI_SESSION_APP_OVERRIDE 傳進 package_app.sh，並實測
  指向不存在的二進位會讓打包失敗中止，證明它沒變成死參數

行為對照：重構前後各跑一次 verify_game_fps.sh -n -d 20，取樣筆數與 fps
同量級。"
```

---

### Task 3: `verify_audio_gui.sh` 探測版（零斷言）

**這個 task 刻意不加任何斷言。** 目的只有一個：拿到真實數字。D32 本身就是「先定門檻
再實測」踩出來的坑（D9 修訂時把 `under == 0` 做成硬斷言，跑出來才發現不成立），不能
用同一個姿勢再踩一次。

本 task **需要模擬器**。

**Files:**
- Create: `app/scripts/verify_audio_gui.sh`

**Interfaces:**
- Consumes: `gui_session_start`／`gui_session_cleanup`／`fps_samples`／`fps_average`／
  `fps_summary`（Task 2）、`require_adb`／`require_device`／`require_grpc`（既有）
- Produces: `audio_stats <log路徑>` — 印出四個可 eval 的 KEY=VAL：
  `AUDIO_LINES`（`[audio]` 行數）、`SOUND_SECS`（`pkt>0` 的秒數）、
  `USUM`（連續有聲期間的 underrun 增量總和）、`UMAX`（單秒最大增量）。Task 4 會斷言它們。

- [ ] **Step 1: 建立探測版腳本**

Create `app/scripts/verify_audio_gui.sh`：

```bash
#!/usr/bin/env bash
# P1-e 驗收線 6：真 GUI + 真 AudioPlayer 下的音訊健康與畫面存活。
#
# **與 verify_audio.sh 的分工**：那支驗 transport 層（封包率／驗收線 5，5 秒視窗，
# 消費端是測試裡的 Task.sleep 假件）；這支驗 playback 層（消費端健康／驗收線 6，
# 60 秒，消費端是真的 AVAudioSourceNode）。名字取 _gui 不取 _60s，因為關鍵差別
# 不是時長而是「需要真 GUI session」——那也是跑之前最需要知道的前置條件。
#
# **為什麼驗收線 6 的字面判準（underruns == 0）不能直接用**：
# spec §8-6 要求「連續 60 秒 underruns == 0」，但同一份 spec 的 §5 寫著「遊戲靜音時
# 本來就沒有封包」「緩衝欠位/溢位不是錯誤，是要被計數與觀測的正常現象」。render
# callback 每 ~10ms 要一次資料（AudioPlayer.swift:35），guest 只要有一刻不發聲，
# readStereo 就走 underrunCount.wrappingIncrement（AudioRingBuffer.swift:100）。
# 所以 == 0 在任何含靜音期的 60 秒裡結構上不可能。
# 本腳本改判「連續有聲期間的 underrun 增量」——見 audio_stats 的註解。
# 完整推導見 docs/specs/2026-08-03-d32-acceptance-6-automation-design.md §0。
#
# 用法：
#   ./scripts/verify_audio_gui.sh                                  # 預設 5556 / 8556 / Pixel Flow，量 60 秒
#   ./scripts/verify_audio_gui.sh -s emulator-5558 -p 8558 -d 90
#
# 前置：模擬器**不可**用 -no-audio 啟動。建議：
#   emulator -avd mirage-game -port 5556 -grpc 8556 -gpu host
set -uo pipefail
source "$(dirname "$0")/lib/verify_common.sh"
source "$(dirname "$0")/lib/gui_session.sh"

SERIAL="emulator-5556"
GRPC_PORT="8556"
PACKAGE="com.loomgames.pixelflow"
DURATION=60

while getopts "s:p:g:d:h" opt; do
  case "$opt" in
    s) SERIAL="$OPTARG" ;;
    p) GRPC_PORT="$OPTARG" ;;
    g) PACKAGE="$OPTARG" ;;
    d) DURATION="$OPTARG" ;;
    h) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "用法：$0 [-s serial] [-p grpc_port] [-g package] [-d seconds]" >&2; exit 2 ;;
  esac
done

# **空 package 一律拒絕。** 下面前景檢查用的 `case "$FG" in *"$PACKAGE"*)`，在 PACKAGE
# 為空時 pattern 變成 `**`，會匹配任何字串——前景檢查誤判通過，然後跑完一個沒有發聲源
# 的 60 秒量測。verify_game_fps.sh 允許 `-g ""`（量 launcher 的 fps 仍然有意義），
# 這支不行：沒有發聲源，A2/A3 就沒有意義。
if [ -z "$PACKAGE" ]; then
    echo "❌ -g 不接受空字串：本腳本必須有發聲來源。" >&2
    exit 2
fi

# 解析 MIRAGE_AUDIO_LOG 的每秒一行：
#   [audio] pkt=42 sr=48000 ch=2 under=0 over=0 depth=96ms
#
# **只統計「本秒 pkt>0 且前一秒也 pkt>0」的 underrun 增量**。這一刀砍掉兩個結構上
# 不可能的區間：
#   1. 啟動期——App 一啟動 AudioPlayer 就在 render，連線還沒建立，前幾秒必然狂
#      underrun。這是 D32 記載的「drain 從 t=0 就開始讀」在真 AudioPlayer 下的等價物，
#      換成真消費端並不會讓它消失。
#   2. 靜音期與它的過渡秒——spec §5 明說靜音沒封包是正常的。靜音秒本身 pkt=0 被排除；
#      緊接其後的第一個有聲秒，其增量包含靜音期末尾的欠位，靠「前一秒也有聲」一併排除。
#
# 用「前一秒也有聲」取代「固定丟掉前 N 秒的 warm-up」是刻意的：後者要選一個魔術數字，
# 前者自適應，消除特殊情況。
audio_stats() {
    awk '
      /\[audio\]/ {
          lines++
          pkt = 0; under = 0
          for (i = 1; i <= NF; i++) {
              if ($i ~ /^pkt=/)   { sub(/^pkt=/, "", $i);   pkt = $i + 0 }
              if ($i ~ /^under=/) { sub(/^under=/, "", $i); under = $i + 0 }
          }
          if (pkt > 0) sound++
          if (pkt > 0 && prev_pkt > 0) {
              d = under - prev_under
              if (d < 0) d = 0          # 累積計數理論上單調，防禦性下限
              usum += d
              if (d > umax) umax = d
              windows++
          }
          prev_pkt = pkt; prev_under = under
      }
      END {
          printf "AUDIO_LINES=%d\nSOUND_SECS=%d\nUSUM=%d\nUMAX=%d\nUWINDOWS=%d\n",
                 lines + 0, sound + 0, usum + 0, umax + 0, windows + 0
      }
    ' "$1"
}

require_device "$SERIAL"
require_grpc "$GRPC_PORT"

echo ""
echo "=== 啟動遊戲：$PACKAGE ==="
"$ADB" -s "$SERIAL" shell monkey -p "$PACKAGE" -c android.intent.category.LAUNCHER 1 \
    > /dev/null 2>&1
sleep 8
FG=$("$ADB" -s "$SERIAL" shell dumpsys activity activities 2>/dev/null \
     | grep topResumedActivity | tr -d '\r' | head -1)
echo "前景：${FG:-（查不到）}"
# **前景確認失敗一律中止**，不像 verify_game_fps.sh 只發警告：那支腳本沒有遊戲仍能量
# 到 launcher 的 fps，這支沒有發聲源則後面每一條斷言都失去意義，繼續跑只會產生一個
# 看起來像產品缺陷、其實是環境沒備好的紅燈。
case "$FG" in
  *"$PACKAGE"*) echo "✅ $PACKAGE 在前景" ;;
  *) echo "❌ $PACKAGE 不在前景——沒有發聲來源，後面的量測沒有意義。"; exit 1 ;;
esac

echo ""
echo "=== 媒體音量頂到最大 ==="
# `adb shell media volume` 在本機映像上不存在（verify_audio.sh:8 記載），
# 連按 15 次 KEYCODE_VOLUME_UP 是已驗證的替代手段。
for _ in $(seq 1 15); do "$ADB" -s "$SERIAL" shell input keyevent 24 > /dev/null; done
"$ADB" -s "$SERIAL" shell dumpsys audio 2>&1 | grep -A3 "STREAM_MUSIC:" | grep streamVolume

LOG=$(mktemp -t mirage_audio_gui)
BUNDLE=$(mktemp -d -t mirage_audio_bundle)
trap 'gui_session_cleanup "${BUNDLE:-}"' EXIT INT TERM

echo ""
echo "=== 啟動 Mirage（.app bundle）→ localhost:${GRPC_PORT}，量測 ${DURATION}s ==="
# 不注入動畫：遊戲進行中畫面本來就在變化，而注入器會真的去點畫面，可能叫出暫停選單
# 或退出關卡（verify_game_fps.sh:32-36 記載的同一個理由）。
if ! gui_session_start "$LOG" "$BUNDLE" "" \
        "MIRAGE_PORT=$GRPC_PORT" "MIRAGE_AUDIO_LOG=1" "MIRAGE_FPS_LOG=1" "MIRAGE_CONN_LOG=1"; then
    exit 1
fi
sleep "$DURATION"

echo ""
echo "===== 音訊每秒日誌（全部）====="
grep '\[audio\]' "$LOG"

echo ""
echo "===== 畫面 ====="
fps_summary "$LOG"

echo ""
echo "===== 解析結果 ====="
audio_stats "$LOG"
echo "FPS_SAMPLES=$(fps_samples "$LOG")"
echo "FPS_AVG=$(fps_average "$LOG")"

echo ""
echo "⚠️ 探測版：本腳本目前**沒有任何斷言**，退出碼永遠是 0。"
echo "   門檻要依這份輸出決定後才加（見 docs/plans/2026-08-03-d32-acceptance-6-automation.md Task 4）。"
echo "log：$LOG"
```

- [ ] **Step 2: 讓它可執行並語法檢查**

```bash
chmod +x app/scripts/verify_audio_gui.sh
cd app && bash -n scripts/verify_audio_gui.sh && echo "語法 OK"
```

Expected: 「語法 OK」。

- [ ] **Step 3: 單元驗證 `audio_stats` 的解析邏輯（不需模擬器）**

用一份手造的 log 驗那個 awk 真的照設計走。這一步很重要——`audio_stats` 是整個判準的
核心，它算錯的話後面所有斷言都建立在錯的數字上。

**不能 `source` 整支腳本**——那會連帶執行整個量測流程。用 `sed` 只抽出函式定義：

```bash
cd app && cat > /tmp/fake_audio.log <<'EOF'
[audio] pkt=0 sr=48000 ch=2 under=10 over=0 depth=0ms
[audio] pkt=0 sr=48000 ch=2 under=25 over=0 depth=0ms
[audio] pkt=40 sr=48000 ch=2 under=30 over=0 depth=90ms
[audio] pkt=42 sr=48000 ch=2 under=32 over=0 depth=95ms
[audio] pkt=41 sr=48000 ch=2 under=32 over=0 depth=96ms
[audio] pkt=0 sr=48000 ch=2 under=90 over=0 depth=0ms
[audio] pkt=39 sr=48000 ch=2 under=140 over=0 depth=80ms
[audio] pkt=40 sr=48000 ch=2 under=147 over=0 depth=88ms
EOF
sed -n '/^audio_stats()/,/^}/p' scripts/verify_audio_gui.sh > /tmp/audio_stats.sh \
  && source /tmp/audio_stats.sh && audio_stats /tmp/fake_audio.log
```

Expected（逐項手算對照）：

```
AUDIO_LINES=8
SOUND_SECS=5
USUM=9
UMAX=7
UWINDOWS=3
```

推導：8 行；`pkt>0` 的有第 3、4、5、7、8 行共 5 秒；連續有聲的窗有
(3→4)=32-30=2、(4→5)=32-32=0、(7→8)=147-140=7，共 3 窗、總和 9、最大 7。
**第 6 行的靜音期（under 從 32 跳到 90）與第 7 行的過渡秒（90→140）都被正確排除**——
這正是設計要驗的那一刀。

若數字對不上，**先修 awk 再往下**。

- [ ] **Step 4: 跑一次真實量測**

```bash
cd app && ./scripts/verify_audio_gui.sh 2>&1 | tee /tmp/d32-probe-1.txt | tail -40
```

Expected: 退出碼 0，輸出裡有「解析結果」那一段的五個 KEY=VAL 加 `FPS_SAMPLES`／`FPS_AVG`。

**若 `SOUND_SECS=0`**：Pixel Flow 沒有持續發聲。此時按設計文件 §1 決策 3 退回鈴聲方案
——改跑 `./scripts/verify_audio_gui.sh -g ""` 並在啟動 Mirage 前手動觸發
`am start -a android.intent.action.VIEW -d file:///product/media/audio/ringtones/Ring_Synth_04.ogg -t audio/ogg`，
把結論記進 Step 6 的報告。**不要**在沒有發聲源的情況下往下定門檻。

**若 `FPS_SAMPLES=0`**：先看 `fps_summary` 印的診斷。這條路徑實測不穩定，重跑一次往往
就好（`verify_game_fps.sh:155` 記載）。

- [ ] **Step 5: 再跑兩次，確認數字穩定**

```bash
cd app && for i in 2 3; do
  ./scripts/verify_audio_gui.sh 2>&1 | tee "/tmp/d32-probe-${i}.txt" | grep -E "^(AUDIO_LINES|SOUND_SECS|USUM|UMAX|UWINDOWS|PRIMES|MALFORMED|FPS_)"
  echo "--- 第 ${i} 次結束 ---"
done
```

Expected: 三次的 `USUM`／`UMAX` 落在同一個量級。

**這一步不可省略**：`RESULTS-p1e.md` 記載過同一份測試碼在不同排程條件下量到光譜兩端
（`under=3` 與 `under=426`）。只跑一次就定門檻，等於把一次抽樣當成分佈。

- [ ] **Step 6: 把三次結果寫成報告**

Create `app/RESULTS-d32-probe.md`，內容須含：三次的完整 KEY=VAL 表格、發聲來源實際
用了哪個（Pixel Flow 或退回鈴聲）、`[audio]` 原始日誌的前 10 行與後 10 行、以及一句
明確的結論「依這三次，A1–A4 的門檻建議定為 X／Y／Z／W」。

- [ ] **Step 7: Commit**

```bash
git add app/scripts/verify_audio_gui.sh app/RESULTS-d32-probe.md
git commit -m "test: D32 探測版——真 GUI 下的音訊健康量測，零斷言

刻意不加斷言。D32 就是「先定門檻再實測」踩出來的坑：D9 修訂時把
under == 0 做成硬斷言，跑出來才發現在該情境結構上不成立。

audio_stats 的核心是只統計「本秒與前一秒皆 pkt>0」的 underrun 增量，
砍掉啟動期與靜音過渡秒兩個結構上不可能的區間。已用手造 log 逐項手算
對照過解析邏輯（8 行 → SOUND_SECS=5 USUM=9 UMAX=7 UWINDOWS=3）。

三次獨立執行的數字見 RESULTS-d32-probe.md。跑三次而非一次，是因為
RESULTS-p1e.md 記載過同一份測試碼在不同排程條件下量到 under=3 與
under=426 的光譜兩端。"
```

---

### Task 4: `AudioRingBuffer` 的 pre-roll（產品修正）

**這個 task 是 Task 3 的實測結果逼出來的，原計畫沒有它。**

Task 3 三次量測全部呈現同一個病徵：

```
[audio] pkt=94 sr=48000 ch=2 under=96  over=0 depth=0ms
[audio] pkt=92 sr=48000 ch=2 under=183 over=0 depth=0ms
...
[audio] pkt=96 sr=48000 ch=2 under=5577 over=0 depth=0ms
```

`under` 每秒增加約 90、`depth` 全程 `0ms`、`over` 恆為 0。三個數字合起來只有一個解讀：
**環形緩衝從來沒有積過水**。生產端每秒送約 96 包（每包約 10ms 的資料），消費端每
約 10ms 要一次，兩者速率相等但**零裕度**——`readStereo` 幾乎每次都拿到不足的資料，
走 `if n < frames { underrunCount++ }` 那條路，然後由 `AudioPlayer` 補靜音。

這不是判準寫錯，是產品缺陷：**沒有任何 pre-roll 機制**。`AudioPlayer` 一啟動就開始
消費，緩衝一有資料就被立刻抽乾，穩態深度必然是 0。

修法放在 `AudioRingBuffer` 而不是 `AudioPlayer`，理由有二：

1. **水位管理本來就是緩衝的職責。** 放在播放器等於讓兩個地方管同一件事。
2. **`AudioPlayer` 在 `MirageShell`（executable target）裡，沒有任何單元測試能碰它**
   （`RESULTS-p1e.md` 記載的既有架構債）；`AudioRingBuffer` 在 `MirageCore`，有一份
   逐行 100% 覆蓋的測試檔。同樣一段邏輯，放對地方就能 TDD，放錯地方只能靠讀碼。

本 task **不需要模擬器**（純單元測試），但完成後 Task 5 會重新量測。

**Files:**
- Modify: `app/Sources/MirageCore/Audio/AudioRingBuffer.swift`（`init` 與 `readStereo`）
- Modify: `app/Tests/MirageCoreTests/AudioRingBufferTests.swift`（5 個既有 `readStereo`
  測試要顯式關掉蓄水；新增 4 個 pre-roll 測試）

**Interfaces:**
- Produces: `AudioRingBuffer(capacitySamples: Int = 19_200, primeThresholdSamples: Int = 9_600)`
  — 新增第二個參數。`readStereo` 在累積深度未達門檻前一律回 0 且**不計 underrun**
  （那不是欠位，是還沒開始播）；一旦達標就轉入正常供應；被排乾（`n == 0`）時回到
  未蓄水狀態重新積水。`read(into:count:)` 的行為**不變**。

⚠️ **既有的 5 個 `readStereo` 測試會全部變紅**（`AudioRingBufferTests.swift` 的第 130、
140、152、162、170 行附近）。它們用的容量是 16／16／16／16／6 samples，寫入 2–6 個
樣本就讀——加了預設門檻之後一律回 0。這是**預期的**，處理方式見 Step 3：那 5 個測試
驗的是「拆交錯機制」不是「蓄水策略」，要顯式傳 `primeThresholdSamples: 0` 並註明理由。

- [ ] **Step 1: 先寫會紅的 pre-roll 測試**

在 `app/Tests/MirageCoreTests/AudioRingBufferTests.swift` 的
`readStereoWrapAroundPreservesChannelOrder`（第 170 行那個測試）結尾大括號之後插入：

```swift

    // MARK: - pre-roll（蓄水）
    //
    // 為什麼需要它：生產端與消費端的速率相等（都是 48kHz），若不先積一段水就開始
    // 消費，穩態深度會停在 0——每次 render callback 都拿到不足的資料然後補靜音。
    // 2026-08-03 實測 60 秒：under 每秒增加約 90、depth 全程 0ms、over 恆為 0
    // （見 app/RESULTS-d32-probe.md）。pre-roll 讓深度從門檻起跳，把「幾乎每次都欠位」
    // 變成「只有真的斷流才欠位」。

    /// 未達門檻前一律不出貨，且**不計 underrun**——那不是欠位，是還沒開始播。
    /// 這個區分很重要：若計入，驗收指標會把正常的啟動蓄水期算成缺陷。
    @Test func primeWithheldBelowThresholdAndNotCountedAsUnderrun() {
        let ring = AudioRingBuffer(capacitySamples: 64, primeThresholdSamples: 16)
        ring.write([1, -1, 2, -2])                 // 4 samples < 門檻 16
        let (got, _, _) = readStereoSamples(ring, frames: 2)
        #expect(got == 0)
        #expect(ring.stats.underruns == 0)
        #expect(ring.stats.depthSamples == 4)      // 沒被消費掉
    }

    /// 達到門檻就開始正常供應。
    @Test func primeReleasesOnceThresholdReached() {
        let ring = AudioRingBuffer(capacitySamples: 64, primeThresholdSamples: 8)
        ring.write([1, -1, 2, -2])                 // 4 < 8：還不出貨
        #expect(readStereoSamples(ring, frames: 2).0 == 0)
        ring.write([3, -3, 4, -4])                 // 累積到 8：達標
        let (got, left, right) = readStereoSamples(ring, frames: 4)
        #expect(got == 4)
        #expect(Array(left.prefix(4)) == [1, 2, 3, 4])
        #expect(Array(right.prefix(4)) == [-1, -2, -3, -4])
    }

    /// 被排乾之後要重新蓄水，不能一路空轉供應——否則斷流時會退回沒有 pre-roll 的行為。
    @Test func primeResetsAfterBufferDrained() {
        let ring = AudioRingBuffer(capacitySamples: 64, primeThresholdSamples: 8)
        ring.write([1, -1, 2, -2, 3, -3, 4, -4])   // 達標
        #expect(readStereoSamples(ring, frames: 4).0 == 4)   // 全部讀走 → 空了
        #expect(readStereoSamples(ring, frames: 4).0 == 0)   // 空讀 → 計 underrun 並重置
        #expect(ring.stats.underruns == 1)
        ring.write([5, -5])                        // 2 < 8：重新蓄水中，不出貨
        #expect(readStereoSamples(ring, frames: 1).0 == 0)
        #expect(ring.stats.underruns == 1)         // 蓄水期不再累加 underrun
    }

    /// 門檻不得超過容量的一半：超過的話蓄水期就會先撞到 overrun，變成永遠 prime 不起來。
    /// 這條守的是「小容量緩衝配大門檻」這個組態陷阱，讓它降級成可用而不是靜默鎖死。
    @Test func primeThresholdIsClampedToHalfCapacity() {
        let ring = AudioRingBuffer(capacitySamples: 8, primeThresholdSamples: 9_600)
        ring.write([1, -1, 2, -2])                 // 4 samples == 容量 8 的一半
        let (got, _, _) = readStereoSamples(ring, frames: 2)
        #expect(got == 2)
    }
```

- [ ] **Step 2: 跑測試，確認新測試紅、且既有 5 個也紅**

```bash
cd app && swift test --filter AudioRingBufferTests > /tmp/d32-step.log 2>&1; RC=$?; tail -30 /tmp/d32-step.log; echo "EXIT=$RC"
```

Expected: 編譯失敗（`AudioRingBuffer` 還沒有 `primeThresholdSamples` 參數）。這是對的
起點——先讓它編不過，再實作。

- [ ] **Step 3: 讓既有 5 個 `readStereo` 測試顯式關掉蓄水**

這 5 個測試驗的是拆交錯、部分讀、半個 frame、空讀、環繞——都是**機制**，不是蓄水策略。
把它們的 `AudioRingBuffer(capacitySamples: N)` 改成
`AudioRingBuffer(capacitySamples: N, primeThresholdSamples: 0)`，並在 `MARK: - readStereo`
那段註解（第 122–128 行）的結尾追加一句：

```swift
    //
    // **為什麼這一組全部傳 `primeThresholdSamples: 0`**：它們驗的是拆交錯與邊界機制，
    // 不是蓄水策略。用生產預設值（9600）的話，這些容量只有 4–16 samples 的緩衝永遠
    // 達不到門檻，每個測試都只會讀到 0，驗不到任何它們該驗的東西。蓄水本身由下方
    // 「pre-roll」那一組專門涵蓋。
```

要改的 5 個測試：`readStereoSplitsInterleavedIntoChannels`（容量 16）、
`readStereoPartialReturnsWholeFramesAndCountsUnderrun`（16）、
`readStereoLeavesDanglingHalfFrameInBuffer`（16）、
`readStereoOnEmptyReturnsZeroAndCountsUnderrun`（16）、
`readStereoWrapAroundPreservesChannelOrder`（6）。

⚠️ **只改這 5 個。** `read(into:count:)` 那一組（檔案上半部）不受影響，因為本 task
不動 `read`。`EmulatorClientAudioTests.swift` 與 `ShellSmokeTests.swift` 裡的
`AudioRingBuffer(capacitySamples:)` 也不要動——它們只寫不用 `readStereo` 讀。

- [ ] **Step 4: 實作 pre-roll**

在 `app/Sources/MirageCore/Audio/AudioRingBuffer.swift`：

(a) 新增兩個儲存屬性，放在 `writeCount` 那一行之後：

```swift
    private let primeThreshold: Int
    /// 是否已蓄滿水並開始供應。生產者不碰它，只有消費者（即時執行緒）讀寫，
    /// 所以 relaxed 就夠——它不用來同步任何資料，只是消費端自己的狀態。
    private let primed = ManagedAtomic<Bool>(false)
```

(b) 改 `init`：

```swift
    /// 預設 19200 = 48kHz × 2ch × 200ms。這是**溢位前的天花板**，不是目標深度。
    ///
    /// `primeThresholdSamples` 預設 9600 = 100ms：消費端要等緩衝積到這個深度才開始
    /// 供應。**沒有它，穩態深度會是 0**——生產與消費速率相等時，每次 render callback
    /// 都拿到不足的資料然後補靜音，2026-08-03 實測 60 秒 under 每秒增加約 90、
    /// depth 全程 0ms（見 app/RESULTS-d32-probe.md）。傳 0 表示不蓄水（測試用）。
    public init(capacitySamples: Int = 19_200, primeThresholdSamples: Int = 9_600) {
        capacity = max(capacitySamples, 1)
        // 門檻不得超過容量的一半：超過的話蓄水期會先撞到 overrun，永遠 prime 不起來。
        primeThreshold = max(0, min(primeThresholdSamples, capacity / 2))
        storage = UnsafeMutableBufferPointer<Float>.allocate(capacity: capacity)
        storage.initialize(repeating: 0)
    }
```

(c) 改 `readStereo`，在既有的 `let n = min(...)` 之前插入蓄水判斷，並在空讀分支重置：

```swift
    public func readStereo(left: UnsafeMutablePointer<Float>,
                           right: UnsafeMutablePointer<Float>,
                           frames: Int) -> Int {
        guard frames > 0 else { return 0 }
        let r = readIndex.load(ordering: .relaxed)
        let w = writeIndex.load(ordering: .acquiring)
        // 蓄水期：還沒積到門檻就整塊不出貨（呼叫端補靜音），**且不計 underrun**——
        // 那不是欠位，是還沒開始播。把兩者混在一起，驗收指標就會把正常的啟動期
        // 算成缺陷。
        if !primed.load(ordering: .relaxed) {
            guard (w - r) >= primeThreshold else { return 0 }
            primed.store(true, ordering: .relaxed)
        }
        let n = min(frames, (w - r) / 2)
        guard n > 0 else {
            // 被排乾了：回到蓄水狀態。不重置的話，斷流之後就退回沒有 pre-roll 的行為。
            primed.store(false, ordering: .relaxed)
            underrunCount.wrappingIncrement(ordering: .relaxed)
            return 0
        }
        for i in 0..<n {
            left[i] = storage[(r + i * 2) % capacity]
            right[i] = storage[(r + i * 2 + 1) % capacity]
        }
        readIndex.store(r + n * 2, ordering: .releasing)
        if n < frames { underrunCount.wrappingIncrement(ordering: .relaxed) }
        return n
    }
```

⚠️ 保留 `readStereo` 既有的 doc comment（`AudioRingBuffer.swift:77-91` 那一大段），
只在它下面加上述蓄水邏輯。那段註解記載了 NSException 與「只讀完整 frame」的理由，
不可刪。

- [ ] **Step 5: 跑測試，確認全綠**

```bash
cd app && swift test --filter AudioRingBufferTests > /tmp/d32-step.log 2>&1; RC=$?; tail -10 /tmp/d32-step.log; echo "EXIT=$RC"
```

Expected: 全部通過，`EXIT=0`。

- [ ] **Step 6: 跑完整測試套件，確認沒有連帶破壞**

```bash
cd app && swift test > /tmp/d32-step.log 2>&1; RC=$?; tail -10 /tmp/d32-step.log; echo "EXIT=$RC"
```

Expected: 全綠。特別注意 `EmulatorClientAudioTests` 與 `ShellSmokeTests` ——它們建
`AudioRingBuffer` 但不透過 `readStereo` 讀，不該受影響；若它們紅了，代表 pre-roll
的影響範圍超出預期，**停下來回報**，不要改那些測試去遷就。

- [ ] **Step 7: 確認覆蓋率沒有掉**

```bash
cd app && ./scripts/coverage.sh 2>&1 | grep -E "AudioRingBuffer|TOTAL"
```

Expected: `AudioRingBuffer.swift` 維持 100%（新增的分支都有測試涵蓋）。

- [ ] **Step 8: Commit**

```bash
git add app/Sources/MirageCore/Audio/AudioRingBuffer.swift app/Tests/MirageCoreTests/AudioRingBufferTests.swift
git commit -m "fix: AudioRingBuffer 加上 pre-roll——緩衝從來沒有積過水

Task 3 的實測逼出來的產品修正，原計畫沒有這一項。

三次 60 秒量測全部同一個病徵：under 每秒增加約 90、depth 全程 0ms、
over 恆為 0（見 app/RESULTS-d32-probe.md）。生產端每秒送約 96 包、消費端
每約 10ms 要一次，速率相等但零裕度——readStereo 幾乎每次都拿到不足的資料
然後補靜音。沒有任何 pre-roll，AudioPlayer 一啟動就把緩衝抽乾，穩態深度
必然是 0。

修法放在 AudioRingBuffer 而非 AudioPlayer：水位管理是緩衝的職責，而且
AudioPlayer 在 executable target 裡沒有任何單元測試碰得到（RESULTS-p1e
記載的既有架構債），同樣一段邏輯放對地方就能 TDD。

蓄水期不計 underrun——那不是欠位是還沒開始播；混在一起會讓驗收指標把
正常的啟動期算成缺陷。被排乾時重置回蓄水狀態，否則斷流後就退回原行為。

既有 5 個 readStereo 測試顯式傳 primeThresholdSamples: 0 並註明理由：
它們驗的是拆交錯與邊界機制，容量只有 4-16 samples，用生產預設值的話
永遠達不到門檻、什麼都驗不到。"
```

---

### Task 5: 定門檻並加上 A1–A4 斷言

Task 4 改了產品行為，所以 Task 3 的探測數字**已經作廢**。這個 task 先重新量三次，
再依新數字定門檻。本 task **需要模擬器**。

**Files:**
- Modify: `app/scripts/verify_audio_gui.sh`（把「⚠️ 探測版」那一段換成斷言）
- Modify: `app/RESULTS-d32-probe.md`（追加 pre-roll 後的三次量測與前後對照）

**Interfaces:**
- Consumes: `audio_stats`（Task 3）、`assert_at_least`／`assert_at_most`（Task 1）、
  `fps_samples`／`fps_average`（Task 2）

**定門檻的規則**（不是隨意抓數字）：

| 斷言 | 門檻怎麼定 |
|---|---|
| A1 `AUDIO_LINES` | `DURATION` 的 80%。60 秒該有 ~60 行，留 20% 給啟動與收尾的抖動 |
| A2 `SOUND_SECS` | 三次的**最小值**再打 8 折。這條擋的是「完全沒發聲」，不是品質門檻 |
| A3 `USUM` | 三次的**最大值** × 2，且**至少** `UWINDOWS` 的 5%（每 20 秒容許 1 次）。取兩者較大者 |
| A4 `FPS_AVG` | 三次的**最小值**再打 8 折，且不高於 55（spec §8-7 的原始要求）|
| A5 `PRIMES` | 三次的**最大值** × 2，下限 2。見下方判讀表——這條擋的是「靠反覆蓄水把 underrun 藏起來」|
| A6 `MALFORMED` | **0**。畸形日誌行代表解析不可信，不是品質問題；有就該紅 |

### `PRIMES` 與 `USUM` 要一起讀，單看任一個都會誤判

Task 4 的審查指出一個會讓整個判準變成安慰劑的路徑：重新蓄水期間 `under` 不增加、
`depth` 從 0 一路長到門檻（每秒取樣看起來像水位健康）、`pkt` 照常 > 0——所以
`audio_stats` 的「本秒與前一秒都有封包」窗口**不會排除蓄水期**。一個反覆重新蓄水、
每次賠 100ms 靜音的緩衝，在只看 `USUM` 的判準下會顯示為「比修正前更健康」。

`PRIMES`（重新蓄水次數）就是拆開這個歧義的指標：

| `PRIMES` | `USUM` | 判讀 | 該怎麼辦 |
|---|---|---|---|
| 小（個位數） | 低 | **真的健康**。蓄水一次就穩住 | 驗收線 6 通過 |
| 小 | 仍高 | **pre-roll 形同虛設**——卡在「部分讀」的低水位帶，`n` 從沒歸零所以不重置 | 停下來回報。正解是低水位滯後（跌破門檻的某個分數就重置），不是把重置條件改成 `n < frames`（那會讓每次部分讀都賠一段靜音）|
| 大 | 低 | **假性健康**。靠反覆蓄水把 underrun 藏起來，聽感是週期性整段靜音，可能比修正前更差 | 停下來回報 |
| 大 | 高 | 兩種病都有 | 停下來回報 |

⚠️ **只有第一列可以宣稱驗收線 6 通過。** 其餘三列都要停下來回報，不要因為門檻套得上去
就當作過了——那正是 D32 這條債務一開始的形狀。

### 📌 已實測並裁決（2026-08-03）：落在第三列，驗收線 6 判「未通過」

控制端在 pre-roll 上樹後親自跑了兩次 60 秒量測：

| | pre-roll 前（Task 3） | pre-roll 後 |
|---|---|---|
| `USUM` | 5481 / 5467 / 5384 | **138 / 170** |
| `UMAX` | 92 / 161 / 92 | **8 / 9** |
| `depth` | 全程 0ms | **中位 46ms、最大 94ms、最小 0** |
| `PRIMES` | （當時無此指標） | **35 / 36** |
| `FPS_AVG` | 56 / 48 / 49 | **40 / 46** |

pre-roll 讓 underrun 總量降約 **97%**，緩衝終於會積水——這是真實且值得保留的改善。
但 `PRIMES≈35` 表示 60 秒內排乾 35 次、**平均每 1.7 秒一次**，每次賠約 100ms 靜音
≈ 全程 5.8% 在靜音。`depth` 呈鋸齒狀：蓄到 ~94ms 後被磨到 0，週而復始。從「蓄滿
100ms 到排乾要 1.7 秒」反推，生產端供應量長期約為消費需求的 94%——兩個獨立時鐘之間
沒有任何 rate adaptation。

**使用者裁決：驗收線 6 判「未通過（已大幅改善）」，不修到通過為止，改開一筆新債務。**

這對本 task 的直接影響——**腳本的綠燈語意必須寫清楚**：

- 六條斷言全部是**回歸偵測**（「不要變得比現在更糟」），**不是**驗收線 6 的通過判準
- 腳本 `exit 0` 代表「沒有回歸」，**不代表驗收線 6 通過**
- 判定段落最後必須印出這個區別與現況數字，任何人跑完都看得到

把這件事只寫在 `RESULTS` 而不寫進腳本輸出是不夠的——腳本是日後最常被單獨執行的東西，
它自己不說，綠燈就會被當成通過。

⚠️ **A3 不論實測多低都不要定成 0。** 生產端（emulator 音訊時鐘）與消費端（Mac
CoreAudio 時鐘）是兩個獨立時鐘，系統裡沒有任何 rate adaptation 機制對抗漂移；pre-roll
給的是 100ms 裕度，60 秒內漂移掉它只需要 0.17% 偏差。定成 0 就是把 D32 的錯誤換個
地方再犯一次。

- [ ] **Step 1: pre-roll 之後重新量三次**

```bash
cd app && swift build -c release 2>&1 | tail -3
for i in 1 2 3; do
  ./scripts/verify_audio_gui.sh > "/tmp/d32-postfix-${i}.txt" 2>&1
  echo "--- 第 ${i} 次 ---"
  grep -E "^(AUDIO_LINES|SOUND_SECS|USUM|UMAX|UWINDOWS|PRIMES|MALFORMED|FPS_)" "/tmp/d32-postfix-${i}.txt"
done
```

⚠️ **`swift build -c release` 不可省略**：`verify_audio_gui.sh` 透過 `package_app.sh`
打包 release 二進位，不重建的話量到的還是沒有 pre-roll 的舊版本，整個 task 就白做了。

⚠️ 若某次量到全 0（log 空白），那是 `verify_game_fps.sh:155` 記載的已知不穩定路徑，
重跑該次即可，但要在報告裡記下發生過幾次。

**控制端已跑過兩次**（見上方「已實測並裁決」那節）：
`USUM` 138／170、`UMAX` 8／9、`PRIMES` 35／36、`FPS_AVG` 40／46、`MALFORMED` 0／0、
`AUDIO_LINES` 60／61、`SOUND_SECS` 60／61、`UWINDOWS` 59／60。
**把你這三次跟這兩次合起來共五次算門檻**，樣本更穩。若你的三次與這兩次差異很大
（例如 `PRIMES` 掉到個位數或衝破 80），先回報再定門檻——那代表環境有變因沒被控制住。

- [ ] **Step 1b: 與 pre-roll 前的數字對照**

把三次的 `USUM`／`UMAX`／`depth` 跟 `RESULTS-d32-probe.md` 已記載的 pre-roll 前數字
（`USUM` 5481／5467／5384，`depth` 全程 0ms）並排，追加一節「pre-roll 前後對照」。

**這是 Task 4 是否真的有效的唯一證據。** 依上方「`PRIMES` 與 `USUM` 要一起讀」那張表
判讀，**只有「`PRIMES` 小且 `USUM` 低」那一列可以繼續往下做**。其餘三列一律停下來回報：

- `USUM` 沒有明顯下降、`depth` 仍貼 0ms、而 `PRIMES` 很小 → pre-roll 卡在低水位帶沒
  介入，病因不是缺蓄水
- `USUM` 下降但 `PRIMES` 很大 → 是靠反覆蓄水把 underrun 藏起來，聽感可能比修正前更差

繼續定門檻只會把一個沒被解決的問題包裝成通過。

依上表規則從**新的三次**算出六個門檻，寫進 `RESULTS-d32-probe.md` 的結論。

- [ ] **Step 2: 把探測版尾段換成斷言**

刪掉 `verify_audio_gui.sh` 尾端的「⚠️ 探測版」三行 echo，換成（`<A1>`–`<A4>` 用
Step 1 算出的數字取代，**不要留佔位字串**）：

```bash
echo ""
echo "===== 判定 ====="
eval "$(audio_stats "$LOG")"
FPS_N=$(fps_samples "$LOG")
FPS_A=$(fps_average "$LOG")

# A1：App 活到最後。**這行日誌的 Task 跑在 MainActor 上**（AppModel+Audio.swift:35）
# ——MainActor 被打死就是 0 行。P1-e 那個 interleaved 格式丟 NSException 打死 MainActor、
# 讓 Mirage 三個階段黑畫面的回歸，這條是直接守門。
assert_at_least "A1 音訊日誌行數（App 存活）" "$AUDIO_LINES" <A1>

# A2：串流真的活著。排除「App 活著但音訊根本沒進來」的假綠燈——沒有這條，
# 一個從頭到尾靜音的 60 秒會讓 A3 以 0 個取樣窗「通過」。
assert_at_least "A2 有封包的秒數" "$SOUND_SECS" <A2>

# A3：核心判準。只統計連續有聲期間的 underrun 增量（見 audio_stats 註解）。
# **必須排在 A2 之後**：assert_at_most 對空值/0 是通過的，A2 先確認「有東西可量」，
# 這條才有意義。兩個斷言各自單純，組合起來才完整（見 verify_common.sh 的
# assert_at_most 註解）。
assert_at_most "A3 連續有聲期間的 underrun 增量總和" "$USUM" <A3>

# A4：畫面沒被拖垮。同一個行程、同一份 log——音訊真的拖垮鏡像時，這條與 A1 會一起紅。
assert_at_least "A4 fps 取樣筆數" "$FPS_N" 1
assert_at_least "A4 平均 fps" "$FPS_A" <A4>

# A5：重新蓄水次數。**沒有這條，A3 可以靠反覆蓄水作弊**——蓄水期 under 不增加、
# depth 看起來在健康地爬升、pkt 照常 > 0，所以 audio_stats 的窗口不會排除它。
# 一個每 2 秒就重新蓄水一次、每次賠 100ms 靜音的緩衝，只看 A3 會顯示為「很健康」。
assert_at_most "A5 重新蓄水次數" "$PRIMES" <A5>

# A6：畸形日誌行。這不是品質門檻是**解析可信度**門檻——有畸形行代表這次量測的
# 數字本身不可信（缺欄位會讓 delta 跨越遺失的取樣點），該紅。
assert_at_most "A6 畸形日誌行" "$MALFORMED" 0

echo ""
echo "================================================================"
echo "⚠️  以上六條是**回歸偵測**，不是驗收線 6 的通過判準。"
echo "    全綠只代表「沒有比 2026-08-03 的基準更糟」。"
echo ""
echo "    驗收線 6（spec §8-6）目前判定為 **未通過（已大幅改善）**："
echo "    pre-roll（AudioRingBuffer.primeThresholdSamples）讓 underrun 總量降約 97%"
echo "    （USUM 5481 → ~150），但本次 PRIMES=${PRIMES} —— 每次重新蓄水都賠約 100ms"
echo "    靜音，實測平均每 1.7 秒排乾一次、全程約 5.8% 在靜音。"
echo ""
echo "    根因：生產端供應量長期約為消費需求的 94%，兩個獨立時鐘之間沒有任何"
echo "    rate adaptation。這不在 D32 範圍內，已記為獨立債務。"
echo "    完整推導見 docs/specs/2026-08-03-d32-acceptance-6-automation-design.md"
echo "    與 app/RESULTS-d32.md。"
echo "================================================================"
echo "log：$LOG"
```

- [ ] **Step 3: 跑一次，確認全綠**

```bash
cd app && ./scripts/verify_audio_gui.sh > /tmp/d32-step.log 2>&1; RC=$?; tail -20 /tmp/d32-step.log; echo "EXIT=$RC"
```

Expected: 五條 ✅（A1、A2、A3、A4 取樣、A4 平均），`EXIT=0`。

- [ ] **Step 4: 連跑兩次，確認不 flaky**

```bash
cd app && for i in 1 2; do ./scripts/verify_audio_gui.sh > /tmp/d32-assert-$i.log 2>&1; \
  echo "第 ${i} 次 EXIT=$?"; done
```

Expected: 兩次都 `EXIT=0`。**任一次紅就代表門檻定太緊**，回 Step 1 放寬並在
`RESULTS-d32-probe.md` 記下為什麼。

- [ ] **Step 5: Commit**

```bash
git add app/scripts/verify_audio_gui.sh app/RESULTS-d32-probe.md
git commit -m "feat: D32 驗收線 6 的四條斷言（門檻由三次實測決定）

A1 音訊日誌行數（App 存活）／A2 有封包秒數（串流活著）／
A3 連續有聲期間的 underrun 增量（核心判準）／A4 fps（畫面沒被拖垮）。

門檻一律由 Task 3 的三次探測算出，不從理論推導：A3 取三次最大值的兩倍
留裕度，因為 emulator 音訊時鐘與 Mac CoreAudio 時鐘之間沒有任何 rate
adaptation，60 秒漂移掉 200ms 緩衝只需 0.33% 偏差。把 A3 定成 0 就是把
D32 的錯誤換個地方再犯一次。

A3 刻意排在 A2 之後：assert_at_most 對 0 是通過的，靠 A2 先確認有東西
可量。"
```

---

### Task 6: 故障注入——證明它會紅

不證明會紅的斷言，跟沒有斷言沒有差別。這是 D42 立下的規矩。本 task **需要模擬器**。

**Files:**
- Modify（暫時，全部要還原）: `app/Sources/MirageShell/Audio/AudioPlayer.swift:30`
- Create: `app/RESULTS-d32.md`

- [ ] **Step 1: 注入 1——前景是個不發聲的 App**

用 `com.android.settings` 當前景：它一定存在（前景檢查會通過，所以真正被驗到的是 A2
而不是前置檢查），而且不發聲。

```bash
cd app && ./scripts/verify_audio_gui.sh -g com.android.settings -d 30 > /tmp/d32-step.log 2>&1
RC=$?; tail -12 /tmp/d32-step.log; echo "EXIT=$RC"
```

Expected: **A2 紅**（`SOUND_SECS` 為 0 或遠低於門檻），`EXIT=1`。A1 應該是綠的——
App 活著、日誌在印，只是沒有封包。這正是這條斷言存在的理由：沒有 A2，一個從頭到尾
靜音的 60 秒會讓 A3 以 0 個取樣窗「通過」。

- [ ] **Step 1b: 順帶驗空 package 被擋下**

```bash
cd app && ./scripts/verify_audio_gui.sh -g "" > /tmp/d32-step.log 2>&1; RC=$?; tail -3 /tmp/d32-step.log; echo "EXIT=$RC"
```

Expected: `❌ -g 不接受空字串`，`EXIT=2`。這條擋的是 `case "$FG" in *""*)` 會匹配
任何字串、讓前景檢查誤判通過的陷阱。

- [ ] **Step 2: 注入 2——關掉音訊日誌**

暫時把腳本裡的 `"MIRAGE_AUDIO_LOG=1"` 改成 `"MIRAGE_AUDIO_LOG=0"`：

```bash
cd app && sed -i.bak 's/"MIRAGE_AUDIO_LOG=1"/"MIRAGE_AUDIO_LOG=0"/' scripts/verify_audio_gui.sh
./scripts/verify_audio_gui.sh > /tmp/d32-step.log 2>&1; RC=$?; tail -8 /tmp/d32-step.log; echo "EXIT=$RC"
mv scripts/verify_audio_gui.sh.bak scripts/verify_audio_gui.sh
```

Expected: A1 紅（`AUDIO_LINES` 為 0），`EXIT=1`。

- [ ] **Step 2b: 注入 2b——把 pre-roll 關掉**

這條直接驗證 A3 守不守得住 Task 4 的產品修正。把 `AudioRingBuffer.swift` 的 `init`
預設門檻暫時改成 0（等同 pre-roll 前的行為），重建、重跑：

```bash
cd app && sed -i.bak 's/primeThresholdSamples: Int = 9_600/primeThresholdSamples: Int = 0/' \
    Sources/MirageCore/Audio/AudioRingBuffer.swift
grep -n "primeThresholdSamples: Int =" Sources/MirageCore/Audio/AudioRingBuffer.swift
swift build -c release 2>&1 | tail -3
./scripts/verify_audio_gui.sh > /tmp/d32-step.log 2>&1; RC=$?; tail -12 /tmp/d32-step.log; echo "EXIT=$RC"
```

Expected: **A3 紅**（`USUM` 回到數千的量級，遠超門檻），`EXIT=1`。

還原並重建：

```bash
cd app && mv Sources/MirageCore/Audio/AudioRingBuffer.swift.bak Sources/MirageCore/Audio/AudioRingBuffer.swift
grep -n "primeThresholdSamples: Int =" Sources/MirageCore/Audio/AudioRingBuffer.swift  # 必須是 9_600
swift build -c release 2>&1 | tail -3
git status --short   # 必須乾淨
```

⚠️ 這一步改的是**產品碼**。還原沒做乾淨會把已知的音訊缺陷放回樹上。`git status`
不乾淨就不要往下走。

- [ ] **Step 3: 注入 3——重現打死 MainActor 的那個回歸**

這是本設計的靈魂：證明這支腳本抓得住讓 Mirage 三個階段黑畫面的那個具體 bug。

```bash
cd app && sed -i.bak 's/interleaved: false/interleaved: true/' Sources/MirageShell/Audio/AudioPlayer.swift
grep -n "interleaved" Sources/MirageShell/Audio/AudioPlayer.swift   # 確認改到了
swift build -c release 2>&1 | tail -3
./scripts/verify_audio_gui.sh > /tmp/d32-step.log 2>&1; RC=$?; tail -12 /tmp/d32-step.log; echo "EXIT=$RC"
```

Expected: A1 紅（`AUDIO_LINES=0` —— NSException 打死 MainActor，那個每秒迴圈從未
啟動），且 fps 取樣為 0。`EXIT=1`。

**立刻還原並重建**：

```bash
cd app && mv Sources/MirageShell/Audio/AudioPlayer.swift.bak Sources/MirageShell/Audio/AudioPlayer.swift
grep -n "interleaved" Sources/MirageShell/Audio/AudioPlayer.swift   # 必須是 false
swift build -c release 2>&1 | tail -3
git status --short   # 必須乾淨（無 .bak、無殘留改動）
```

⚠️ 這一步改的是**產品碼**。還原沒做乾淨會把一個已知會打死 App 的 bug 留在樹上。
`git status` 不乾淨就不要往下走。

- [ ] **Step 4: 還原後再跑一次，確認回到綠**

```bash
cd app && ./scripts/verify_audio_gui.sh > /tmp/d32-step.log 2>&1; RC=$?; tail -12 /tmp/d32-step.log; echo "EXIT=$RC"
```

Expected: 五條 ✅，`EXIT=0`。這證明 Step 3 的紅燈來自注入的 bug，不是腳本壞了。

- [ ] **Step 5: 寫 `RESULTS-d32.md`**

Create `app/RESULTS-d32.md`，須含：

1. **驗收線 6 的判定**：附四條斷言的實際數字與門檻
2. **判準重新表述的理由**：字面 `underruns == 0` 與 spec §5 自相矛盾（引原文）
3. **故障注入表**：三條注入各自的預期與實際輸出，含注入 3 的 `AUDIO_LINES=0`
4. **pending-human 的理由已失效**：`RESULTS-p1e.md` 說 headless 不驅動 `.task`，
   而 `verify_game_fps.sh:11-16` 記載該歸因在 2026-07-28 被推翻
5. **已知限制**：本腳本需要真 GUI session 與模擬器，**不能進 `ci.sh`**；
   `verify_common_selftest.sh` 那部分已由閘門 7 涵蓋
6. **pre-roll 產品修正（Task 4）**：為什麼原計畫沒有它、Task 3 的實測揭露了什麼
   （`under` 每秒 +90、`depth` 全程 0ms、`over` 恆 0）、修法為何放在 `AudioRingBuffer`
   而非 `AudioPlayer`、以及 pre-roll 前後的 `USUM` 對照數字。**這一節是本次工作最
   重要的產出**——驗收線 6 原本被當成「缺自動化涵蓋」，實際上它一直是實質不通過，
   只是沒有人量過

- [ ] **Step 6: Commit**

```bash
git add app/RESULTS-d32.md
git commit -m "test: D32 故障注入——三條都證明會紅

注入 3 是關鍵：把 AudioPlayer.swift:30 的 interleaved 改回 true，重現
讓 Mirage 三個階段黑畫面的那個 NSException。腳本如預期 A1 紅
（AUDIO_LINES=0——那個每秒迴圈跑在被打死的 MainActor 上，一行都沒印）
且 fps 取樣為 0。還原後重跑回到全綠，證明紅燈來自注入而非腳本本身。

產品碼的暫時改動已還原並重建，git status 乾淨。"
```

---

### Task 7: 更新既有文件

把三份記載著過期事實的文件修正。本 task **不需要模擬器**。

**Files:**
- Modify: `docs/specs/2026-07-26-p1e-fullscreen-audio-design.md:253`（§8 第 6 條）
- Modify: `app/RESULTS-p1e.md:39`（驗收線 6 那列）、`:65-75`（pending-human 清單）、
  `:103`（已知限制第一項）
- Modify: `docs/specs/2026-07-29-project-review.md:130`（D32 那列）

- [ ] **Step 1: spec §8-6 加更正註記**

在 `docs/specs/2026-07-26-p1e-fullscreen-audio-design.md` 第 253 行
（`6. 活體：連續 60 秒 underruns == 0。`）之後插入，沿用 §5 既有的「⚠️ 更正」慣例：

```markdown

   > **⚠️ 更正（2026-08-03，D32）：這條字面判準與本文件 §5 自相矛盾，結構上不可能成立。**
   >
   > §5 寫著「`streamAudio` 無封包 ≠ 斷線。遊戲靜音時本來就沒有封包」與「緩衝欠位/
   > 溢位不是錯誤，是要被計數與觀測的正常現象」。而 `AudioPlayer` 的 render callback
   > 每 ~10ms 要一次資料（`AudioPlayer.swift:35`），guest 只要有一刻不發聲，
   > `readStereo` 就走 `underrunCount.wrappingIncrement`（`AudioRingBuffer.swift:100`）。
   > 所以 `== 0` 在任何含靜音期的 60 秒裡不可能成立。
   >
   > 這與 D32 原本記載的「drain 情境下不成立」是**不同的第二個原因**：前者出在測試
   > harness 的假消費端，後者在真 `AudioPlayer` 下一樣存在。把 harness 換成真的並
   > 不會讓這條判準變得可達。
   >
   > **新表述**：只統計「本秒與前一秒皆有封包」的 underrun 增量，並與「App 存活」
   > 「串流活著」「畫面 fps」三條一起判。自動化涵蓋在 `app/scripts/verify_audio_gui.sh`，
   > 完整推導見 `docs/specs/2026-08-03-d32-acceptance-6-automation-design.md`。
```

- [ ] **Step 2: `RESULTS-p1e.md` 驗收線 6 改判**

把第 39 行整列的判定從 `⬜ pending-human` 改成 **`❌ 未通過（已大幅改善）`**。

⚠️ **不要改成 PASS。** 使用者已裁決：pre-roll 讓 underrun 降約 97%，但實測每 1.7 秒
排乾一次、全程約 5.8% 在靜音，這不是通過。把它寫成 PASS 就是把 D32 這條債務的形狀
原封不動再做一次。

證據欄要含：(a) **本次終於量得到的理由**——pending-human 的原因（headless 不驅動
`.task`）在 2026-07-28 就失效了；(b) pre-roll 前後的對照數字（`USUM` 5481 → ~150、
`depth` 全程 0ms → 中位 46ms、`PRIMES`≈35）；(c) 為什麼判未通過（每 1.7 秒一次的
100ms 靜音）；(d) 指向 `app/RESULTS-d32.md` 與新開的債務編號。

保留原本記載的 7 次 `underruns` 3–426 那段歷史，在後面接「**2026-08-03 D32 補充**」
說明那批舊數字來自假消費端、未排除啟動期與靜音期，與本次的判準不可直接比較。

- [ ] **Step 3: `RESULTS-p1e.md` pending-human 清單移除第 6 項**

第 65 行的標題「pending-human 清單（spec §9 五項 + 驗收線 6、7）」改成
「（spec §9 五項 + 驗收線 7）」，刪掉第 74 行的第 6 項，並在第 67 行的「原因統一」
那段之後加一句：

```markdown
**⚠️ 2026-08-03 更正**：上面「headless 不驅動 `.task`」這個原因**對驗收線 6 已不成立**。
該歸因在 2026-07-28 被推翻——真因是 `AudioPlayer` 的 NSException 打死 MainActor
（見 `docs/specs/2026-07-28-mirror-never-rendered-investigation.md`），修好之後
`verify_game_fps.sh` 在非互動 session 一樣量得到 fps（見該檔 line 11-16）。
驗收線 6 已由 `app/scripts/verify_audio_gui.sh` 自動化涵蓋（D32）——但**該驗收線本身判定為未通過**，
殘餘缺陷記為 D44，見 `project-review.md`。
**驗收線 7 的 pending-human 理由同樣可疑，但本次未重驗**——見 `project-review.md` 的 D32 那列。
```

- [ ] **Step 4: `project-review.md` 標記 D32 已修，並新增 D44**

把 D32 那列的 `**D32**` 改成 `~~**D32**~~`，並在「修法」欄位結尾追加：

```markdown
**✅ 自動化涵蓋已建立（2026-08-03）；驗收線 6 本身判定為未通過。**
`app/scripts/verify_audio_gui.sh` 在真 GUI + 真 `AudioPlayer` 下量 60 秒，六條斷言
（App 存活／串流活著／連續有聲期間的 underrun 增量／fps／重新蓄水次數／畸形行），
四條故障注入皆證明會紅。

**真正的發現不是自動化本身**：第一次量出來就揭露驗收線 6 一直是**實質不通過**，而且
從來沒有人量過——`under` 每秒增加約 90、`depth` 全程 0ms、`over` 恆為 0，環形緩衝從來
沒有積過水。根因是**完全沒有 pre-roll**，已修（`AudioRingBuffer.primeThresholdSamples`
預設 100ms；修法放在緩衝而非播放器，因為 `AudioPlayer` 在 executable target 裡沒有
任何單元測試碰得到）。修正後 `USUM` 從 5481 降到約 150（**-97%**）、`depth` 中位 46ms。

**但仍判未通過**：`PRIMES`≈35，即 60 秒內排乾 35 次、平均每 1.7 秒一次，每次賠約
100ms 靜音 ≈ 全程 5.8% 在靜音。殘餘缺陷另記為 **D44**。`verify_audio_gui.sh` 的六條
斷言因此定位為**回歸偵測**（不要比 2026-08-03 的基準更糟），腳本自己會印出這個區別，
**綠燈不等於驗收線 6 通過**。

**另外發現三件事**：(1) pending-human 的理由（headless 不驅動 `.task`）在 2026-07-28
就被推翻了，沒人回頭驗；(2) 驗收線 6 的字面判準（`underruns == 0`）與 spec §5 自相
矛盾（靜音期必然欠位），已重新表述並在 spec 加更正註記；(3) `verify_common_selftest.sh`
從 D9 就存在卻從沒被 CI 跑過，已補為閘門 7（現在跑兩支自我測試）。**另記一筆**：
驗收線 7（fps ≥ 55）被列 pending-human 的理由與驗收線 6 完全相同、同樣已失效，而
`verify_game_fps.sh` 早就在量 fps，但本次未重驗。
```

然後在債務表**末尾新增 D44**（沿用該表既有的欄位格式：編號｜問題｜修法｜工時｜優先級）：

```markdown
| **D44** | **音訊每 1.7 秒靜音一次**：pre-roll（D32）讓 underrun 降 97%，但實測 `PRIMES`≈35／60 秒——緩衝蓄到約 94ms 後被磨到 0，週而復始，每次重新蓄水賠約 100ms 靜音，全程約 5.8% 在靜音。反推生產端供應量長期約為消費需求的 **94%**：emulator 的音訊時鐘與 Mac CoreAudio 時鐘是兩個獨立時鐘，系統裡**沒有任何 rate adaptation** 對抗漂移 | 三個方向，未定案：(a) 加大緩衝容量（現 200ms）並提高 pre-roll 門檻——治標，延長週期但仍會排乾；(b) 低水位滯後（跌破門檻某個分數就重置），能減少「排乾瞬間」的硬切但不解決供應不足；(c) 真正的 rate adaptation（消費端偵測水位持續偏低就輕微重採樣放慢）——正解但複雜度高。**決定前應先量清楚 94% 這個數字的來源**：是時鐘漂移、還是 guest 端本來就有丟包／靜音段落，兩者的解法完全不同 | 未估 | P2 |
```

- [ ] **Step 5: 確認沒有殘留的過期宣稱**

```bash
cd /Users/hanfourhuang/Projects/mirage && grep -rn "驗收線 6" app/RESULTS-p1e.md docs/specs/2026-07-29-project-review.md | grep -i "pending-human"
```

Expected: **無輸出**。有輸出代表還有地方寫著驗收線 6 是 pending-human。

- [ ] **Step 6: Commit**

```bash
git add docs/specs/2026-07-26-p1e-fullscreen-audio-design.md app/RESULTS-p1e.md docs/specs/2026-07-29-project-review.md
git commit -m "docs: D32 收尾——驗收線 6 改判，並修正兩處過期記載

驗收線 6 從 pending-human 改判 PASS，附四條斷言的實際數字。

一併修正兩處過期記載：
- RESULTS-p1e 把「headless 不驅動 .task」當阻礙——該歸因在 2026-07-28
  就被推翻（真因是 NSException 打死 MainActor），沒人回頭驗
- spec §8-6 的字面判準與 §5 自相矛盾，加更正註記並記下新表述

新記一筆債：驗收線 7 的 pending-human 理由與驗收線 6 完全相同、同樣已
失效，本次未重驗。"
```

---

## 完成檢查

全部 task 做完後：

```bash
cd app && ./scripts/ci.sh 2>&1 | tail -5          # 七道閘門全綠
./scripts/verify_audio_gui.sh 2>&1 | tail -12     # 五條 ✅
git status --short                                 # 乾淨
```

**不要**因為 `ci.sh` 綠了就宣稱驗收線 6 通過——`ci.sh` 不跑 `verify_audio_gui.sh`
（需要模擬器與 GUI）。兩者要分別跑、分別報告。

