#!/bin/bash
# 驗收線 2：全螢幕量測到 present 的三個可控段，每輪 20 秒。
# 用法：verify_input_latency.sh [-r rounds] [-p grpc_port]
set -uo pipefail

source "$(dirname "$0")/lib/load_sentinel.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/verify_common.sh"
source "$HERE/lib/input_latency.sh"
ROUNDS=3
PORT=8556
LOAD_RETRY_MAX=6
LOAD_RETRY_WAIT=5
while getopts 'r:p:h' opt; do
    case "$opt" in
        r) ROUNDS="$OPTARG" ;;
        p) PORT="$OPTARG" ;;
        h) sed -n '2,3p' "$0"; exit 0 ;;
        *) exit 2 ;;
    esac
done
for value in "$ROUNDS" "$PORT"; do
    case "$value" in ''|*[!0-9]*) echo 'FAIL: positive integers required'; exit 2 ;; esac
    [ "$value" -gt 0 ] || exit 2
done
[ "$PORT" -le 65535 ] || exit 2
# D60(a)：參數解析與驗證完成後，量測前才檢查主機磁碟。
disk_preflight "$HERE" || exit 1

require_grpc "$PORT"
build_warm release 3 "$HERE/.." || exit 1
input_latency_wait_load 18 60 5 || echo '建置後等待已達上限，交由逐輪 load_gate 重試判定'
export MIRAGE_SKIP_BUILD=1
WORK=$(mktemp -d -t mirage_input_latency)
BUNDLE=""
CLICK_PID=""
cleanup() {
    if [ -n "$CLICK_PID" ]; then kill "$CLICK_PID" 2>/dev/null || true; wait "$CLICK_PID" 2>/dev/null || true; fi
    gui_session_cleanup "$BUNDLE"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
echo "Logs: ${WORK}"
measure_round() {
    input_latency_load_retry 18 "$LOAD_RETRY_MAX" "$LOAD_RETRY_WAIT" || return 1
    log="$WORK/round-${round}.log"
    BUNDLE="$WORK/bundle-${round}"
    mkdir -p "$BUNDLE"
    gui_session_start "$log" "$BUNDLE" '' "MIRAGE_PORT=$PORT" \
        MIRAGE_FPS_LOG=1 MIRAGE_CONN_LOG=1 MIRAGE_LATENCY_LOG=1 MIRAGE_INPUT_LATENCY=1 || return 1
    gui_session_fullscreen "$log" "$BUNDLE" "${FULLSCREEN_MIN_WIDTH:-896}" || return 1
    # 全螢幕穩定後，略過第一個不完整的延遲窗口。
    before=$(grep -c '^\[app\] lat ' "$log" || true)
    for ((poll=0; poll<50; poll++)); do
        current=$(grep -c '^\[app\] lat ' "$log" || true)
        [ "$current" -gt "$before" ] && break
        sleep 0.1
    done
    [ "$current" -gt "$before" ] || { echo 'FAIL: no render window'; return 1; }
    start_line=$(wc -l < "$log")
    snap_a=$(cpu_snapshot)
    # 點擊水平中央、由上往下 20% 的背景，避開 Play 與底部分頁。
    # AX 只讀座標，CGEvent 才會進入 MirrorView.mouseDown。
    local coordinates px py
    coordinates=$(osascript 2> "$WORK/click-${round}.log" <<'APPLESCRIPT'
tell application "System Events"
    tell process "MirageApp"
        set frontmost to true
        set pos to position of window 1
        set sz to size of window 1
        set px to (item 1 of pos) + (item 1 of sz) / 2
        set py to (item 2 of pos) + (item 2 of sz) * 0.20
    end tell
    return (px as text) & " " & (py as text)
end tell
APPLESCRIPT
    ) || { echo 'FAIL: window coordinates unavailable'; return 1; }
    read -r px py <<< "$coordinates"
    osascript -l JavaScript "$HERE/lib/cgclick.js" "$px" "$py" 40 0.5 >> "$WORK/click-${round}.log" 2>&1 &
    CLICK_PID=$!
    sleep 20
    snap_b=$(cpu_snapshot)
    end_line=$(wc -l < "$log")
    input_latency_cpu_window "$snap_a" "$snap_b" 20 "$round" || return 1
    wait "$CLICK_PID" || { echo 'FAIL: osascript clicks failed'; return 1; }
    CLICK_PID=""
    sed -n "$((start_line + 1)),${end_line}p" "$log" > "$WORK/window-${round}.log"
    input_latency_round "$WORK/window-${round}.log" "$round"
}
: > "$WORK/rounds.txt"
: > "$WORK/rejected.txt"
for ((round=1; round<=ROUNDS; round++)); do
    input_latency_collect "$round" "$WORK" measure_round
    cleanup
    CLICK_PID=""
    BUNDLE=""
done
input_latency_finish "$WORK" "$ROUNDS"
