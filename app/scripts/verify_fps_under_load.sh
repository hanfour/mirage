#!/usr/bin/env bash
# D64 診斷實驗：在人為 CPU 負載下執行全螢幕 fps 量測。
#
# 用法：
#   ./scripts/verify_fps_under_load.sh -n 2 -p 45999
#   ./scripts/verify_fps_under_load.sh -n 0 -p 8556
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY="${SCRIPT_DIR}/verify_fps_fullscreen.sh"
source "${SCRIPT_DIR}/lib/load_sentinel.sh"

BURNERS=""
VERIFY_ARGS=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        -n)
            if [ "$#" -lt 2 ]; then
                echo "用法：$0 -n <burner數> [其餘參數原樣傳給 verify_fps_fullscreen.sh]" >&2
                exit 2
            fi
            BURNERS="$2"
            shift 2
            ;;
        -n[0-9]*)
            BURNERS="${1#-n}"
            shift
            ;;
        --)
            shift
            VERIFY_ARGS+=("$@")
            break
            ;;
        *)
            VERIFY_ARGS+=("$1")
            shift
            ;;
    esac
done

if [ -z "$BURNERS" ]; then
    echo "用法：$0 -n <burner數> [其餘參數原樣傳給 verify_fps_fullscreen.sh]" >&2
    exit 2
fi
case "$BURNERS" in
    ''|*[!0-9]*)
        echo "❌ -n 只接受非負整數：實測 '${BURNERS}'。" >&2
        exit 2
        ;;
esac

BURNER_PIDS=()

cleanup_burners() {
    local pid attempt
    local failed=0

    if [ "${#BURNER_PIDS[@]}" -gt 0 ]; then
        for pid in "${BURNER_PIDS[@]}"; do
            kill "$pid" 2>/dev/null || true
        done

        for pid in "${BURNER_PIDS[@]}"; do
            for attempt in $(seq 1 40); do
                if ! kill -0 "$pid" 2>/dev/null; then
                    break
                fi
                sleep 0.05
            done
            if kill -0 "$pid" 2>/dev/null; then
                kill -KILL "$pid" 2>/dev/null || true
            fi
            wait "$pid" 2>/dev/null || true
            if kill -0 "$pid" 2>/dev/null; then
                echo "❌ burner pid=${pid} 清理失敗：kill -0 回檢仍存在。" >&2
                failed=1
            else
                echo "✅ burner pid=${pid} 已清理：kill -0 回檢不存在。"
            fi
        done
    fi

    return "$failed"
}

on_exit() {
    local rc="$?"
    trap - EXIT
    cleanup_burners || true
    exit "$rc"
}

on_int() {
    exit 130
}

trap on_exit EXIT
trap on_int INT

if [ "$BURNERS" -gt 0 ]; then
    # 人為負載會拖慢 GUI 啟動；對照組維持 verify_fps_fullscreen.sh 的預設逾時。
    FULLSCREEN_WINDOW_TIMEOUT="${FULLSCREEN_WINDOW_TIMEOUT:-60}"
    export FULLSCREEN_WINDOW_TIMEOUT
fi

LOAD_BEFORE=$(load_avg_1min)
echo "============================================================"
echo "D64 診斷實驗：人為 CPU 負載下的 draw 時序量測"
echo "數字只供診斷，不作驗收線 7 的判定。"
echo "burner 數：${BURNERS}"
if [ "$BURNERS" -gt 0 ]; then
    echo "負載模式：FULLSCREEN_WINDOW_TIMEOUT=${FULLSCREEN_WINDOW_TIMEOUT} 秒、ROUND_RETRY_MAX=${ROUND_RETRY_MAX:-3}"
fi
echo "load_avg_1min（啟動前）：${LOAD_BEFORE}"

if [ "$BURNERS" -gt 0 ]; then
    for _ in $(seq 1 "$BURNERS"); do
        yes > /dev/null &
        BURNER_PIDS+=("$!")
    done
fi

LOAD_AFTER=$(load_avg_1min)
echo "load_avg_1min（啟動後）：${LOAD_AFTER}"

if [ "$BURNERS" -eq 0 ]; then
    if [ "${#VERIFY_ARGS[@]}" -gt 0 ]; then
        "${VERIFY}" "${VERIFY_ARGS[@]}"
    else
        "${VERIFY}"
    fi
    rc="$?"
else
    if [ "${#VERIFY_ARGS[@]}" -gt 0 ]; then
        "${VERIFY}" -l 99 "${VERIFY_ARGS[@]}"
    else
        "${VERIFY}" -l 99
    fi
    rc="$?"
fi

exit "$rc"
