#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/remote_fps_stats.sh"
source "${SCRIPT_DIR}/verify_common.sh"
assert_equals '空集合無中位數' "$(remote_median_of '')" ''
assert_equals '合法零值' "$(remote_median_of '0\n4\n')" 0
assert_equals '偶數取下位中位數' "$(remote_median_of '60\n54\n')" 54
assert_equals '奇數中位數' "$(remote_median_of '60\n0\n54\n')" 54
assert_equals '排序值域' "$(remote_list_of '60\n54\n')" '54 60'
assert_equals '最小值' "$(remote_min_of '60\n54\n')" 54
assert_equals '最大值' "$(remote_max_of '60\n54\n')" 60
assert_equals '合法摘要含零' "$(printf 'MIRAGE_MEDIAN=0\nROUNDS=2\nSIZE_OK=1\n' | remote_arm_summary)" '0 2'
for bad in 'ROUNDS=2\nSIZE_OK=1' 'MIRAGE_MEDIAN=50\nROUNDS=0\nSIZE_OK=1' \
    'MIRAGE_MEDIAN=50\nROUNDS=2\nSIZE_OK=0' 'MIRAGE_MEDIAN=x\nROUNDS=2\nSIZE_OK=1' \
    'MIRAGE_MEDIAN=50\nMIRAGE_MEDIAN=51\nROUNDS=2\nSIZE_OK=1'; do
    if printf '%b\n' "$bad" | remote_arm_summary >/dev/null; then
        echo '❌ 無效摘要誤通過'; exit 1
    fi
done
remote_ranges_overlap '50\n60\n' '52\n58\n' 3
assert_ok '交集大於 3' "$?"
for on in '60\n70\n' '57\n63\n' '54\n54\n'; do
    if remote_ranges_overlap '50\n60\n' "$on" 3; then echo '❌ 交集警告誤報'; exit 1; fi
done
GOOD='LOOP_FRAME=99\nLOOP_FRAME=100\nLOOP_FRAME=102\nLOOP_FRAME=104\nLOOP_FRAME=106\n'
printf '%b' "$GOOD" | remote_viewer_window_ok 100 106
assert_ok 'viewer 覆蓋窗口' "$?"
for bad in '' 'LOOP_FRAME=90\nLOOP_FRAME=91\n' 'LOOP_FRAME=100\nLOOP_FRAME=106\n' \
    "${GOOD}LOOP_DISCONNECTED=103\n"; do
    if printf '%b' "$bad" | remote_viewer_window_ok 100 106; then echo '❌ viewer 缺席誤通過'; exit 1; fi
done
echo 'remote_fps_stats: 全部通過（含摘要／值域／viewer 負對照）'
