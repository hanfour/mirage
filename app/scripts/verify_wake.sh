#!/bin/bash
# 驗收線 4。用法：/bin/bash app/scripts/verify_wake.sh [-r rounds] [-p grpc_port]
set -uo pipefail

source "$(dirname "$0")/lib/load_sentinel.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/verify_common.sh"
source "$HERE/lib/input_latency.sh"
ROUNDS=3
PORT=8556
while getopts 'r:p:h' opt; do
    case "$opt" in
        r) ROUNDS="$OPTARG" ;;
        p) PORT="$OPTARG" ;;
        h) sed -n '2p' "$0"; exit 0 ;;
        *) exit 2 ;;
    esac
done
for value in "$ROUNDS" "$PORT"; do
    case "$value" in ''|*[!0-9]*) echo 'FAIL: positive integers required'; exit 2 ;; esac
    [ "$value" -gt 0 ] || exit 2
done
[ "$ROUNDS" -ge 3 ] && [ "$PORT" -le 65535 ] || exit 2
# D60(a)：參數解析與驗證完成後，量測前才檢查主機磁碟。
disk_preflight "$HERE" || exit 1

if pgrep -x MirageApp >/dev/null; then
    echo 'FAIL: MirageApp 已在執行，請先正常退出'; exit 1
fi
require_grpc "$PORT"
build_warm release 3 "$HERE/.." || exit 1
export MIRAGE_SKIP_BUILD=1
WORK=$(mktemp -d -t mirage_wake)
BUNDLE="$WORK/bundle"
mkdir -p "$BUNDLE"
"$HERE/package_app.sh" "$BUNDLE" release > "$WORK/package.log" 2>&1 || exit 1
caffeinate -disu &
CAFFEINATE_PID=$!
cleanup() {
    gui_session_cleanup "$BUNDLE"
    kill "$CAFFEINATE_PID" 2>/dev/null || true
    wait "$CAFFEINATE_PID" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
echo "Logs: ${WORK}"
echo "wake_s=新 suspended-->waking 至其後第一幀（判定）；wake_applescript_s=送出 AppleScript 至第一幀（參考）；startup_s=open 至第一幀；wake_same_poll=兩筆在同次輪詢出現"
: > "$WORK/rounds.jsonl"
for ((round=1; round<=ROUNDS; round++)); do
    lock=$(gui_screen_lock_state "$(ioreg -n Root -d1 -a 2>/dev/null)")
    # 與 gui_session_start 一致：缺少鎖定 key 時為 unknown，仍繼續量測。
    if [ "$lock" = locked ]; then
        echo "[round ${round}] INVALID screen=${lock}"; continue
    fi
    snap_a=$(cpu_snapshot)
    start=$(python3 -c 'import time; print(time.monotonic())')
    rc=0
    python3 "$HERE/lib/wake_probe.py" round "$BUNDLE/Mirage.app" "$WORK/app-${round}.log" "$PORT" \
        > "$WORK/result-${round}.json" 2> "$WORK/error-${round}.log" || rc=1
    snap_b=$(cpu_snapshot)
    elapsed=$(python3 -c 'import sys,time; print(time.monotonic()-float(sys.argv[1]))' "$start")
    foreign10=$(cpu_delta_total "$snap_a" "$snap_b" "$elapsed" 'qemu-system|MirageApp|WindowServer' 10)
    foreign0=$(cpu_delta_total "$snap_a" "$snap_b" "$elapsed" 'qemu-system|MirageApp|WindowServer' 0)
    input_latency_cpu_gate "$foreign10" >> "$WORK/error-${round}.log" || rc=1
    if [ "$rc" -eq 0 ]; then
        python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); r.update(foreign10=float(sys.argv[2]),foreign0=float(sys.argv[3])); print(json.dumps(r))' \
            "$WORK/result-${round}.json" "$foreign10" "$foreign0" >> "$WORK/rounds.jsonl" || exit 1
        values=$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print("startup_s=%.3f wake_s=%.3f wake_applescript_s=%.3f wake_same_poll=%s quit=%s" % (r["startup"],r["wake"],r["wake_applescript"],r["wake_same_poll"],r["quit"]))' "$WORK/result-${round}.json")
        echo "[round ${round}] VALID ${values} foreign_cpu_floor10=${foreign10}% foreign_cpu_floor0=${foreign0}%"
    else
        echo "[round ${round}] INVALID startup_s=NA wake_s=NA wake_applescript_s=NA wake_same_poll=NA foreign_cpu_floor10=${foreign10}% foreign_cpu_floor0=${foreign0}%"
        cat "$WORK/error-${round}.log"
    fi
    # 輪間只清行程，保留已打包的 bundle 給下一輪；EXIT trap 才刪除 bundle。
    gui_session_cleanup ''
    if pgrep -x MirageApp >/dev/null; then
        echo 'FAIL: 清理後 MirageApp 仍在執行'; exit 1
    fi
done
python3 "$HERE/lib/wake_probe.py" summary "$WORK/rounds.jsonl" "$ROUNDS"
