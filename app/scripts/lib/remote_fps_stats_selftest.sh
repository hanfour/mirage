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
assert_equals '合法摘要含零' "$(printf 'MIRAGE_MEDIAN=0\nROUNDS=2\nSIZE_OK=1\nVIEWER_REJECTED=0\n' | remote_arm_summary)" '0 2 0'
for bad in 'ROUNDS=2\nSIZE_OK=1' 'MIRAGE_MEDIAN=50\nROUNDS=0\nSIZE_OK=1' \
    'MIRAGE_MEDIAN=50\nROUNDS=2\nSIZE_OK=0' 'MIRAGE_MEDIAN=x\nROUNDS=2\nSIZE_OK=1' \
    'MIRAGE_MEDIAN=50\nMIRAGE_MEDIAN=51\nROUNDS=2\nSIZE_OK=1'; do
    if printf '%b\nVIEWER_REJECTED=0\n' "$bad" | remote_arm_summary >/dev/null; then
        echo '❌ 無效摘要誤通過'; exit 1
    fi
done
assert_equals '淘汰 viewer 輪次不扣已採計的有效輪數' \
    "$(printf 'MIRAGE_MEDIAN=57\nROUNDS=2\nSIZE_OK=1\nVIEWER_REJECTED=3\n' | remote_arm_summary)" '57 2 3'
for field in '' 'VIEWER_REJECTED=' 'VIEWER_REJECTED=-1' 'VIEWER_REJECTED=x' \
    'VIEWER_REJECTED=1\nVIEWER_REJECTED=2'; do
    if printf 'MIRAGE_MEDIAN=57\nROUNDS=2\nSIZE_OK=1\n%b\n' "$field" | remote_arm_summary >/dev/null; then
        echo '❌ viewer 淘汰欄位異常卻通過'; exit 1
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
# 執行正式腳本的兩段 viewer 判斷；裝置／時鐘全是假件，驗證 continue 真正回到下一輪。
(
    CHECKS=$(awk '/    # 由 verify_remote_fps.sh 開啟/ { copy=1 } /    # `mirage=M`/ { copy=0 } copy' \
        "${SCRIPT_DIR}/../verify_fps_fullscreen.sh")
    [ -n "$CHECKS" ] || { echo '❌ 找不到正式 viewer 判斷'; exit 1; }
    LOG=$(mktemp -t remote_viewer_round_selftest) || exit 1
    trap 'rm -f "$LOG"' EXIT
    BUNDLE='fake-bundle'
    REMOTE_VIEWER_LOG="$LOG"
    SERIAL='fake-serial' PACKAGE='fake-package' DURATION=1
    VIEWER_REJECTED=0 CLEANUPS=0 COMPLETED=0 STARTS=0
    gui_session_cleanup() { CLEANUPS=$((CLEANUPS + 1)); }
    sleep() { :; }
    date() { echo 100; }
    fps_samples() { echo 0; }
    guest_window_start() { STARTS=$((STARTS + 1)); }
    guest_window_end() { echo fake; }
    load_watch_sleep() { echo 0; }
    remote_viewer_window_ok() {
        [ "$MODE" != not_ready ] || return 1
        if [ "$MODE" = interrupted ] && [ "$1" -eq 100 ]; then return 1; fi
        return 0
    }
    for MODE in not_ready interrupted healthy; do
        : > "$LOG"
        eval "$CHECKS"
        COMPLETED=$((COMPLETED + 1))
        assert_equals '後續健康輪次照常執行' "$MODE" healthy
        [ -f "$LOG" ] || { echo '❌ 健康輪次 log 被刪除'; exit 1; }
    done
    assert_equals '兩種 viewer 失敗各計一次' "$VIEWER_REJECTED" 2
    assert_equals '兩種 viewer 失敗都清理 GUI' "$CLEANUPS" 2
    assert_equals 'viewer 未就緒不得啟動 guest 窗口' "$STARTS" 2
    assert_equals '無效輪次不得採計、後續輪次繼續' "$COMPLETED" 1
) || exit 1
echo 'remote_fps_stats: 全部通過（含摘要／值域／viewer 負對照）'
