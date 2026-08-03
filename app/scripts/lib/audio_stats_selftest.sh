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

TMPDIR=$(mktemp -d -t audio_stats_selftest)
trap 'rm -rf "$TMPDIR"' EXIT

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
cat > "$TMPDIR/case_a.log" <<'EOF'
[audio] pkt=0 sr=48000 ch=2 under=10 over=0 depth=0ms
[audio] pkt=0 sr=48000 ch=2 under=25 over=0 depth=0ms
[audio] pkt=40 sr=48000 ch=2 under=30 over=0 depth=90ms
[audio] pkt=42 sr=48000 ch=2 under=32 over=0 depth=95ms
[audio] pkt=41 sr=48000 ch=2 under=32 over=0 depth=96ms
[audio] pkt=0 sr=48000 ch=2 under=90 over=0 depth=0ms
[audio] pkt=39 sr=48000 ch=2 under=140 over=0 depth=80ms
[audio] pkt=40 sr=48000 ch=2 under=147 over=0 depth=88ms
EOF
check_case "案例 A：brief 原始 8 行（舊格式，無 primes=）" "$TMPDIR/case_a.log" \
    AUDIO_LINES:8 SOUND_SECS:5 USUM:9 UMAX:7 UWINDOWS:3 MALFORMED:0 PRIMES:0

# 案例 B：under 遞減，直接觸發「d<0 防禦性下限」那條分支——這條分支在案例 A
# 與三次真實量測裡都從未被觸發過（under 全程單調遞增），本案例補上這個空白。
# 手算：(2→3) 視窗 d=90-100=-10→clamp 0；(3→4) 視窗（此處為第 2、3 行）
# d=110-90=20。USUM=0+20=20，UMAX=20（clamp 後的 0 不會蓋過真正的 20）。
cat > "$TMPDIR/case_b.log" <<'EOF'
[audio] pkt=50 sr=48000 ch=2 under=100 over=0 depth=0ms
[audio] pkt=50 sr=48000 ch=2 under=90 over=0 depth=0ms
[audio] pkt=50 sr=48000 ch=2 under=110 over=0 depth=0ms
EOF
check_case "案例 B：under 遞減觸發 d<0 下限" "$TMPDIR/case_b.log" \
    AUDIO_LINES:3 SOUND_SECS:3 USUM:20 UMAX:20 UWINDOWS:2 MALFORMED:0

# 案例 C：第 2 行缺 under= 欄位。**這是本次修法的重點案例**：
#   - AUDIO_LINES 維持「總行數」語意，仍計入這行 → 3。
#   - 第 2 行整行跳過：不進 SOUND_SECS（維持 2，只有第 1、3 行）、不進
#     UWINDOWS（維持 1）、也不更新 prev_pkt/prev_under。
#   - 第 3 行的 delta 因此以「畸形行之前那一行」（第 1 行，under=100）為基準：
#     200-100=100。若沒有這個修法（畸形行的 under 停在初始值 0 且仍當作
#     prev_under 更新），第 3 行會算出 200-0=200 這個異常大的正 delta，
#     SOUND_SECS 與 UWINDOWS 也都會多算 1——這正是審查發現的原始缺陷。
cat > "$TMPDIR/case_c.log" <<'EOF'
[audio] pkt=50 sr=48000 ch=2 under=100 over=0 depth=0ms
[audio] pkt=60 sr=48000 ch=2 over=0 depth=0ms
[audio] pkt=70 sr=48000 ch=2 under=200 over=0 depth=0ms
EOF
check_case "案例 C：缺 under= 整行跳過、下一行以畸形行之前為基準" "$TMPDIR/case_c.log" \
    AUDIO_LINES:3 SOUND_SECS:2 USUM:100 UMAX:100 UWINDOWS:1 MALFORMED:1

# 案例 D：第 2 行缺 pkt= 欄位，同一套驗證邏輯（缺 pkt= 與缺 under= 都要能
# 被判為畸形，兩個欄位分開檢查、任一缺就整行跳過）。
cat > "$TMPDIR/case_d.log" <<'EOF'
[audio] pkt=50 sr=48000 ch=2 under=100 over=0 depth=0ms
[audio] sr=48000 ch=2 under=150 over=0 depth=0ms
[audio] pkt=60 sr=48000 ch=2 under=200 over=0 depth=0ms
EOF
check_case "案例 D：缺 pkt= 整行跳過" "$TMPDIR/case_d.log" \
    AUDIO_LINES:3 SOUND_SECS:2 USUM:100 UMAX:100 UWINDOWS:1 MALFORMED:1

# 案例 E：空檔案——全部為 0，不當機（awk 沒有任何 /\[audio\]/ 命中時，
# END 區塊仍要印出七個 0，不能因為變數從未初始化就印空字串或整個不輸出）。
: > "$TMPDIR/case_e.log"
check_case "案例 E：空檔案全部為 0" "$TMPDIR/case_e.log" \
    AUDIO_LINES:0 SOUND_SECS:0 USUM:0 UMAX:0 UWINDOWS:0 MALFORMED:0 PRIMES:0

# 案例 F：新格式日誌，帶 primes= 欄位。**2026-08-03 審查後新增**（Important-B）：
# PRIMES 要能從有 primes= 的日誌正確解析出「最後一行的值」（累積計數，不是 delta）。
# 手算：3 行皆有 pkt_found/under_found，非畸形。sound=3（三行 pkt 皆 >0）。
# under 序列 0→0→2：第 1→2 行 d=0-0=0，第 2→3 行 d=2-0=2，USUM=0+2=2，UMAX=2，
# UWINDOWS=2。primes 序列 1→1→2，取最後一行的值 → PRIMES=2（不是加總、不是次數）。
cat > "$TMPDIR/case_f.log" <<'EOF'
[audio] pkt=40 sr=48000 ch=2 under=0 over=0 primes=1 depth=90ms
[audio] pkt=42 sr=48000 ch=2 under=0 over=0 primes=1 depth=95ms
[audio] pkt=41 sr=48000 ch=2 under=2 over=0 primes=2 depth=10ms
EOF
check_case "案例 F：新格式，primes= 取最後一行的累積值" "$TMPDIR/case_f.log" \
    AUDIO_LINES:3 SOUND_SECS:3 USUM:2 UMAX:2 UWINDOWS:2 MALFORMED:0 PRIMES:2

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "全部通過"
    exit 0
fi
echo "${FAILURES} 項失敗"
exit 1
