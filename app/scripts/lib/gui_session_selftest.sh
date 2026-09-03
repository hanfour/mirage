#!/usr/bin/env bash
# gui_session.sh 的幀計數解析自我測試。
# 不需要模擬器、不需要 adb，故障時能直接驗證解析是否真的會失敗。
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/gui_session.sh"
FAILURES=0

check() {
    local desc="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then
        echo "✅ $desc"
    else
        echo "❌ ${desc}：得到 ${got}，期待 ${want}"
        FAILURES=$((FAILURES + 1))
    fi
}

WORK=$(mktemp -d -t frame_counter_selftest)
trap 'rm -rf "$WORK"' EXIT

printf '%s\n' \
    '[app] fps=61' \
    '[app] frames arrived=12 dropped=2 presented=10' \
    '[app] fps=59' \
    '[app] frames arrived=14 dropped=3 presented=11' \
    '[app] fps=57' \
    '[app] frames arrived=16 dropped=4 presented=12' \
    '[app] fps=55' \
    '[app] frames arrived=18 dropped=5 presented=13' \
    > "$WORK/mixed.log"

echo "=== frames_median ==="
check "frames_samples 計數" \
      "$(frames_samples "$WORK/mixed.log")" 4
check "fps 與 frames 樣本一對一" \
      "$(fps_samples "$WORK/mixed.log")" "$(frames_samples "$WORK/mixed.log")"
check "arrived 中位數" \
      "$(frames_median "$WORK/mixed.log" arrived)" 14
check "dropped 中位數" \
      "$(frames_median "$WORK/mixed.log" dropped)" 3
check "presented 中位數" \
      "$(frames_median "$WORK/mixed.log" presented)" 11
check "跳過前一筆後的 arrived 中位數" \
      "$(frames_median "$WORK/mixed.log" arrived 1)" 16
check "跳過前一筆後的 dropped 中位數" \
      "$(frames_median "$WORK/mixed.log" dropped 1)" 4
check "跳過前一筆後的 presented 中位數" \
      "$(frames_median "$WORK/mixed.log" presented 1)" 12
check "跳過全部樣本回 0" \
      "$(frames_median "$WORK/mixed.log" arrived 4)" 0

: > "$WORK/empty.log"
check "沒有幀樣本回 0" \
      "$(frames_median "$WORK/empty.log" arrived)" 0
check "沒有幀樣本時筆數為 0" \
      "$(frames_samples "$WORK/empty.log")" 0

echo ""
echo "=== fps_median 相容性 ==="
check "混入 frames 行不污染 fps_median" \
      "$(fps_median "$WORK/mixed.log")" 57

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "全部通過"
    exit 0
fi
echo "${FAILURES} 項失敗"
exit 1
