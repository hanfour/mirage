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
