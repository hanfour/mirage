#!/usr/bin/env bash
# guest 回壓量測純函式的自我測試。
# 不需要模擬器、adb 或 Swift；故障注入時可用 BACKPRESSURE_SELFTEST_LIB 指向副本。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="${BACKPRESSURE_SELFTEST_LIB:-${HERE}/backpressure.sh}"
if [ ! -r "${LIB}" ]; then
    echo "❌ 找不到回壓函式庫：${LIB}"
    exit 1
fi
source "${LIB}"

FAILURES=0

check() {
    local desc="$1" got="$2" want="$3"
    if [ "${got}" = "${want}" ]; then
        echo "✅ ${desc}"
    else
        echo "❌ ${desc}：得到 ${got}，期待 ${want}"
        FAILURES=$((FAILURES + 1))
    fi
}

echo "=== rotate_conditions ==="
check "三條件第 1 輪" \
      "$(rotate_conditions 1 'none,pull,app')" "none,pull,app"
check "三條件第 2 輪" \
      "$(rotate_conditions 2 'none,pull,app')" "pull,app,none"
check "三條件第 3 輪" \
      "$(rotate_conditions 3 'none,pull,app')" "app,none,pull"
check "兩條件第 1 輪" \
      "$(rotate_conditions 1 'none,app')" "none,app"
check "兩條件第 2 輪" \
      "$(rotate_conditions 2 'none,app')" "app,none"
check "兩條件第 3 輪" \
      "$(rotate_conditions 3 'none,app')" "none,app"

echo ""
echo "=== median_delta ==="
VALUES_A='58\n60\n59'
VALUES_B='50\n52\n51'
check "中位數差值 A-B" \
      "$(median_delta "${VALUES_A}" "${VALUES_B}")" 8.0
check "左側無資料" \
      "$(median_delta '' "${VALUES_B}")" "無資料"
check "右側無資料" \
      "$(median_delta "${VALUES_A}" '')" "無資料"

echo ""
echo "=== FOREIGN_MAX 無效分流 ==="
check "guest 找不到優先判無效" \
      "$(backpressure_invalid_reason '' 10 60)" guest
check "foreign 超過上限判無效" \
      "$(backpressure_invalid_reason 59 60.1 60)" foreign
check "foreign 等於上限仍有效" \
      "$(backpressure_invalid_reason 59 60 60)" ""

echo ""
if [ "${FAILURES}" -eq 0 ]; then
    echo "全部通過"
    exit 0
fi
echo "${FAILURES} 項失敗"
exit 1
