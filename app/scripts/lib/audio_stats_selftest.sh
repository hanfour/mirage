#!/usr/bin/env bash
# audio_stats（app/scripts/lib/audio_stats.sh）的自我測試。**不需要模擬器**——
# 這正是把這段 awk 抽成獨立檔案的目的：可以直接 source 驗證，不必再用 sed 從
# verify_audio_gui.sh 中段把函式挖出來（那是 Task 3 原本的驗法，脆弱）。
#
# 用法：./scripts/lib/audio_stats_selftest.sh（退出碼 0 = 全部通過）
set -uo pipefail
LIB="$(dirname "$0")/audio_stats.sh"
source "$LIB"
FAILURES=0

WORK=$(mktemp -d -t audio_stats_selftest)
trap 'rm -rf "$WORK"' EXIT

# 取 audio_stats 多行輸出裡某個 KEY 的值。
kv() {
    echo "$1" | grep "^${2}=" | cut -d= -f2
}

# 對一份 log 跑 audio_stats，逐一核對指定的 KEY 是否吻合期待值。
# 期待值以「KEY:VAL」的形式一次傳一串（空白分隔）。
check_case() {
    local desc="$1" logfile="$2"; shift 2
    local output kv_pair key want got
    output=$(audio_stats "$logfile")
    for kv_pair in "$@"; do
        key="${kv_pair%%:*}"
        want="${kv_pair#*:}"
        got=$(kv "$output" "$key")
        if [ "$got" = "$want" ]; then
            echo "✅ ${desc}：${key}=${got}"
        else
            echo "❌ ${desc}：${key} 實測 ${got:-（無輸出）}，期待 ${want}"
            FAILURES=$((FAILURES + 1))
        fi
    done
}

echo "=== audio_stats 自我測試 ==="

# 案例 A：task-3-brief.md Step 3 的原始 8 行案例。期待值不變，現在多驗
# MALFORMED=0——這 8 行全部欄位齊全，不應該被判為畸形。
# **這份 log 完全沒有 primes= 欄位**（Task 3 存檔時 pre-roll 還不存在）——
# 兼作「舊格式日誌向後相容」的驗證案例：PRIMES 應解析為 0，而不是被判為畸形
# 或讓其他既有欄位（USUM/SOUND_SECS 等）跟著壞掉。
cat > "$WORK/case_a.log" <<'EOF'
[audio] pkt=0 sr=48000 ch=2 under=10 over=0 depth=0ms
[audio] pkt=0 sr=48000 ch=2 under=25 over=0 depth=0ms
[audio] pkt=40 sr=48000 ch=2 under=30 over=0 depth=90ms
[audio] pkt=42 sr=48000 ch=2 under=32 over=0 depth=95ms
[audio] pkt=41 sr=48000 ch=2 under=32 over=0 depth=96ms
[audio] pkt=0 sr=48000 ch=2 under=90 over=0 depth=0ms
[audio] pkt=39 sr=48000 ch=2 under=140 over=0 depth=80ms
[audio] pkt=40 sr=48000 ch=2 under=147 over=0 depth=88ms
EOF
check_case "案例 A：brief 原始 8 行（舊格式，無 primes=）" "$WORK/case_a.log" \
    AUDIO_LINES:8 SOUND_SECS:5 USUM:9 UMAX:7 UWINDOWS:3 MALFORMED:0 PRIMES:0

# 案例 B：under 遞減，直接觸發「d<0 防禦性下限」那條分支——這條分支在案例 A
# 與三次真實量測裡都從未被觸發過（under 全程單調遞增），本案例補上這個空白。
# 手算：(2→3) 視窗 d=90-100=-10→clamp 0；(3→4) 視窗（此處為第 2、3 行）
# d=110-90=20。USUM=0+20=20，UMAX=20（clamp 後的 0 不會蓋過真正的 20）。
cat > "$WORK/case_b.log" <<'EOF'
[audio] pkt=50 sr=48000 ch=2 under=100 over=0 depth=0ms
[audio] pkt=50 sr=48000 ch=2 under=90 over=0 depth=0ms
[audio] pkt=50 sr=48000 ch=2 under=110 over=0 depth=0ms
EOF
check_case "案例 B：under 遞減觸發 d<0 下限" "$WORK/case_b.log" \
    AUDIO_LINES:3 SOUND_SECS:3 USUM:20 UMAX:20 UWINDOWS:2 MALFORMED:0

# 案例 C：第 2 行缺 under= 欄位。**這是本次修法的重點案例**：
#   - AUDIO_LINES 維持「總行數」語意，仍計入這行 → 3。
#   - 第 2 行整行跳過：不進 SOUND_SECS（維持 2，只有第 1、3 行）、不進
#     UWINDOWS（維持 1）、也不更新 prev_pkt/prev_under。
#   - 第 3 行的 delta 因此以「畸形行之前那一行」（第 1 行，under=100）為基準：
#     200-100=100。若沒有這個修法（畸形行的 under 停在初始值 0 且仍當作
#     prev_under 更新），第 3 行會算出 200-0=200 這個異常大的正 delta，
#     SOUND_SECS 與 UWINDOWS 也都會多算 1——這正是審查發現的原始缺陷。
cat > "$WORK/case_c.log" <<'EOF'
[audio] pkt=50 sr=48000 ch=2 under=100 over=0 depth=0ms
[audio] pkt=60 sr=48000 ch=2 over=0 depth=0ms
[audio] pkt=70 sr=48000 ch=2 under=200 over=0 depth=0ms
EOF
check_case "案例 C：缺 under= 整行跳過、下一行以畸形行之前為基準" "$WORK/case_c.log" \
    AUDIO_LINES:3 SOUND_SECS:2 USUM:100 UMAX:100 UWINDOWS:1 MALFORMED:1

# 案例 D：第 2 行缺 pkt= 欄位，同一套驗證邏輯（缺 pkt= 與缺 under= 都要能
# 被判為畸形，兩個欄位分開檢查、任一缺就整行跳過）。
cat > "$WORK/case_d.log" <<'EOF'
[audio] pkt=50 sr=48000 ch=2 under=100 over=0 depth=0ms
[audio] sr=48000 ch=2 under=150 over=0 depth=0ms
[audio] pkt=60 sr=48000 ch=2 under=200 over=0 depth=0ms
EOF
check_case "案例 D：缺 pkt= 整行跳過" "$WORK/case_d.log" \
    AUDIO_LINES:3 SOUND_SECS:2 USUM:100 UMAX:100 UWINDOWS:1 MALFORMED:1

# 案例 E：空檔案——全部為 0，不當機（awk 沒有任何 /\[audio\]/ 命中時，
# END 區塊仍要印出七個 0，不能因為變數從未初始化就印空字串或整個不輸出）。
: > "$WORK/case_e.log"
check_case "案例 E：空檔案全部為 0" "$WORK/case_e.log" \
    AUDIO_LINES:0 SOUND_SECS:0 USUM:0 UMAX:0 UWINDOWS:0 MALFORMED:0 PRIMES:0

# 案例 F：新格式日誌，帶 primes= 欄位。**2026-08-03 審查後新增**（Important-B）：
# PRIMES 要能從有 primes= 的日誌正確解析出「最後一行的值」（累積計數，不是 delta）。
# 手算：3 行皆有 pkt_found/under_found，非畸形。sound=3（三行 pkt 皆 >0）。
# under 序列 0→0→2：第 1→2 行 d=0-0=0，第 2→3 行 d=2-0=2，USUM=0+2=2，UMAX=2，
# UWINDOWS=2。primes 序列 1→1→2，取最後一行的值 → PRIMES=2（不是加總、不是次數）。
cat > "$WORK/case_f.log" <<'EOF'
[audio] pkt=40 sr=48000 ch=2 under=0 over=0 primes=1 depth=90ms
[audio] pkt=42 sr=48000 ch=2 under=0 over=0 primes=1 depth=95ms
[audio] pkt=41 sr=48000 ch=2 under=2 over=0 primes=2 depth=10ms
EOF
check_case "案例 F：新格式，primes= 取最後一行的累積值" "$WORK/case_f.log" \
    AUDIO_LINES:3 SOUND_SECS:3 USUM:2 UMAX:2 UWINDOWS:2 MALFORMED:0 PRIMES:2

# 案例 G／H：**2026-08-03 Task 6 審查後新增**（Important-1）。前面 A–F 全是手造的
# 幾行日誌，用來驗 awk 邏輯本身；G／H 改用**真實發生過的完整 60 秒日誌**（Task 3
# 的原始量測、Task 6 注入 2b 的原始量測，逐字存檔於 fixtures/，非手造），把「拿掉
# pre-roll 的日誌長什麼樣、A3 對它會不會紅」永久釘在測試裡——不然這個區別只活在
# RESULTS-d32.md 的文字說明裡，下次沒人回頭看文件就會被遺忘。
FIXTURES="$(dirname "$0")/fixtures"

# 案例 G：pre-roll 修法**之前**的真實量測（Task 3，`AudioRingBuffer.primeThresholdSamples`
# 尚不存在時的產品行為，見 app/RESULTS-d32.md §6）。遊戲全程有聲、`pkt` 恆為 90–100，
# 是「緩衝從未積過水」的真實指紋：`under` 幾乎每秒 +90，60 秒累積到 5481。
# 這份日誌若餵進 verify_audio_gui.sh 的 A3（門檻 `DURATION*350/60`，60 秒下是 350），
# 5481 遠超 350（超標近 16 倍）——**這就是 A3 這條斷言真的會紅的證據**，離線、
# 不需要模擬器、可重現。PRIMES=0 是預期值，不是遺漏：這份日誌是舊格式（無 primes=
# 欄位），驗的是「真實的舊格式資料」而不是案例 A 那種手造的舊格式資料。
check_case "案例 G：pre-roll 前真實日誌（Task 3）——USUM 遠超 A3 門檻 350" \
    "$FIXTURES/audio_preroll_before_real.log" \
    AUDIO_LINES:62 SOUND_SECS:62 USUM:5481 UMAX:92 UWINDOWS:61 MALFORMED:0 PRIMES:0

# 案例 H：Task 6 注入 2b 的真實量測——把 `primeThresholdSamples` 改回 0（拿掉
# pre-roll）之後跑出來的日誌，但**遊戲畫面當下停在不發聲的收集畫面**，`pkt` 全程
# 為 0（見 app/RESULTS-d32.md §3.1／附錄 C）。這份日誌解析出 USUM=0——若誤把它當
# A3 的證據餵進 `assert_at_most`，會印出**綠燈**，因為 `assert_at_most` 對 0 一律
# 通過。這正是 Important-1 的核心：`under == primes` 逐行相等（見下方 primes 欄位，
# 每行都跟 under 同值）是「完全沒有資料流過」的指紋，不是「拿掉 pre-roll」的指紋——
# 真正有資料時的指紋是案例 G 那種恆正的獨立遞增。
# 但這份日誌不是沒有訊號：PRIMES 取最後一行的累積值是 6093，遠超 A5 的上限 72
# （60 秒下）——超標 85 倍。這證明**這份日誌真正會讓斷言紅的是 A5，不是 A3**，
# 只是 A2（SOUND_SECS 0 < 門檻）先攔下，A5 排在 A3 之後同樣沒被腳本實際評估到。
check_case "案例 H：注入 2b 真實日誌（畫面靜音）——USUM=0 但 PRIMES 遠超 A5 門檻 72" \
    "$FIXTURES/audio_injection_2b_silent_screen.log" \
    AUDIO_LINES:63 SOUND_SECS:0 USUM:0 UMAX:0 UWINDOWS:0 MALFORMED:0 PRIMES:6093

# D44：SUPPLY_MEAN。**這是 A2b 前置閘門唯一的輸入**，解錯就等於那道閘門不存在。
WORK=$(mktemp -d -t audio_supply)
trap 'rm -rf "$WORK"' EXIT

# 稀疏音效的真實形狀：pkt 看起來很健康（每秒 90+），供應率只有 6%。
# A2 對這種日誌是綠的——那正是 A2b 存在的理由。
printf '[audio] pkt=92 smp=6322 supply=6%% sr=48000 ch=2 under=0 over=0 primes=0 depth=65ms\n%.0s' 1 2 3 > "$WORK/sparse.log"
check_case "案例 I：稀疏音效——pkt 健康但 SUPPLY_MEAN=6" \
    "$WORK/sparse.log" AUDIO_LINES:3 SOUND_SECS:3 MALFORMED:0 SUPPLY_MEAN:6

# 連續發聲：實測正弦波是 100%。
printf '[audio] pkt=84 smp=96000 supply=100%% sr=48000 ch=2 under=0 over=0 primes=1 depth=90ms\n%.0s' 1 2 > "$WORK/full.log"
check_case "案例 J：連續發聲——SUPPLY_MEAN=100" \
    "$WORK/full.log" AUDIO_LINES:2 SOUND_SECS:2 MALFORMED:0 SUPPLY_MEAN:100

# 平均要跨行算，不是取最後一行——不然一段安靜後的一秒好資料就能把閘門騙過去。
printf '[audio] pkt=92 smp=6322 supply=10%% sr=48000 ch=2 under=0 over=0 primes=0 depth=1ms\n' > "$WORK/mixed.log"
printf '[audio] pkt=84 smp=96000 supply=90%% sr=48000 ch=2 under=0 over=0 primes=0 depth=90ms\n' >> "$WORK/mixed.log"
check_case "案例 K：混合——取平均 50，不是取最後一行的 90" \
    "$WORK/mixed.log" AUDIO_LINES:2 SOUND_SECS:2 MALFORMED:0 SUPPLY_MEAN:50

# 2026-08-07 之前的日誌沒有 supply 欄位。缺它**不算畸形**（同 primes 的處理），
# 但 SUPPLY_MEAN 會是 0——A2b 因此擋下舊格式日誌，那是正確的：無從判定供應率。
printf '[audio] pkt=92 sr=48000 ch=2 under=3 over=0 primes=1 depth=46ms\n' > "$WORK/legacy.log"
check_case "案例 L：舊格式（無 supply 欄位）——不算畸形，SUPPLY_MEAN=0" \
    "$WORK/legacy.log" AUDIO_LINES:1 SOUND_SECS:1 MALFORMED:0 SUPPLY_MEAN:0

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "全部通過"
    exit 0
fi
echo "${FAILURES} 項失敗"
exit 1
