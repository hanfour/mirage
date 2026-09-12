#!/usr/bin/env bash
# 驗收線 7 對照（spec 第 8 節）：verify_fps_fullscreen.sh 在遙控關與開各跑兩次（交錯：關、開、關、開），
# 斷言「開的中位數 ≥ 關的中位數 − 3」。開的那一臂用 remote_client.py --loop 當 viewer，否則
# 編碼器不拉幀，量到的是關的數字。
#
# 用法：./scripts/verify_remote_fps.sh [-s serial] [-p grpc_port] [-g package] [-P remote_port] [-r rounds] [-d seconds]
# 前置同 verify_fps_fullscreen.sh（phase0/harness/.venv-d45、螢幕邏輯解析度、遊戲在會動的畫面）。
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/verify_common.sh"
source "${SCRIPT_DIR}/lib/remote_venv.sh"
source "${SCRIPT_DIR}/lib/remote_fps_stats.sh"

SERIAL="emulator-5554"
GRPC_PORT="8554"
PACKAGE="com.loomgames.pixelflow"
REMOTE_PORT=8765
ROUNDS=2
DURATION=20
TOLERANCE=3

while getopts "s:p:g:P:r:d:h" opt; do
  case "$opt" in
    s) SERIAL="$OPTARG" ;;
    p) GRPC_PORT="$OPTARG" ;;
    g) PACKAGE="$OPTARG" ;;
    P) REMOTE_PORT="$OPTARG" ;;
    r) ROUNDS="$OPTARG" ;;
    d) DURATION="$OPTARG" ;;
    h) sed -n '2,/^set /{ /^#/p; }' "$0"; exit 0 ;;
    *) echo "用法：$0 [-s serial] [-p grpc_port] [-g package] [-P remote_port] [-r rounds] [-d seconds]" >&2; exit 2 ;;
  esac
done
for v in REMOTE_PORT ROUNDS DURATION; do
  eval "val=\$${v}"
  case "$val" in ''|*[!0-9]*) echo "❌ ${v} 只接受正整數：實測 '${val}'。" >&2; exit 2 ;; esac
done

[ "$SERIAL:$GRPC_PORT" = "emulator-5554:8554" ] || { echo "❌ 本驗證只接受 emulator-5554／8554" >&2; exit 2; }
[ -n "$PACKAGE" ] && [ "$REMOTE_PORT" -ge 1 ] && [ "$REMOTE_PORT" -le 65535 ] && [ "$ROUNDS" -ge 2 ] && [ "$DURATION" -ge 1 ] || {
    echo "❌ 需指定 package、有效埠、至少 2 輪及正整數秒數" >&2; exit 2;
}
if nc -z 127.0.0.1 "$REMOTE_PORT" 2>/dev/null; then
    echo "❌ 遙控埠 ${REMOTE_PORT} 已有人監聽" >&2; exit 1
fi
PY=$(remote_venv_python) || exit 1
TOKEN=$("$PY" -c 'import secrets; print(secrets.token_hex(16))') || exit 1
VIEWER_PID=''
stop_viewer() {
    if [ -n "$VIEWER_PID" ]; then
        kill "$VIEWER_PID" > /dev/null 2>&1 || true
        wait "$VIEWER_PID" 2>/dev/null || true
        VIEWER_PID=''
    fi
}
trap stop_viewer EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# 每臂一次呼叫；輸出存檔，只抓 MIRAGE_MEDIAN／MIRAGE_SPREAD／ROUNDS。
# 底層 ≥55 判定與本對照分開；仍驗尺寸收斂、有效摘要及異常退出。
run_arm() {
    local arm="$1" out
    out=$(mktemp -t mirage_remote_fps_"$arm") || exit 1
    if [ "$arm" = "on" ]; then
        REMOTE_VIEWER_LOG="$VIEWER_LOG" "$SCRIPT_DIR/verify_fps_fullscreen.sh" -s "$SERIAL" -p "$GRPC_PORT" -g "$PACKAGE" -r "$ROUNDS" -d "$DURATION" \
            -E "MIRAGE_HOST=127.0.0.1" -E "MIRAGE_REMOTE=1" -E "MIRAGE_REMOTE_PORT=$REMOTE_PORT" -E "MIRAGE_REMOTE_TOKEN=$TOKEN" > "$out" 2>&1
    else
        REMOTE_VIEWER_LOG="" "$SCRIPT_DIR/verify_fps_fullscreen.sh" -s "$SERIAL" -p "$GRPC_PORT" -g "$PACKAGE" -r "$ROUNDS" -d "$DURATION" -E "MIRAGE_HOST=127.0.0.1" -E "MIRAGE_REMOTE=0" > "$out" 2>&1
    fi
    local rc=$?
    local median rounds spread summary viewer_rejected
    summary=$(remote_arm_summary < "$out") || {
        echo "❌ ${arm} 沒有有效摘要（fps_script_rc=${rc}）：${out}"; tail -15 "$out"; exit 1;
    }
    # 1 可能只是既有 ≥55 門檻；訊號中止、工具錯誤不可當有效跑次。
    [ "$rc" -le 1 ] || { echo "❌ fps 腳本異常退出 ${rc}：${out}"; exit 1; }
    read -r median rounds viewer_rejected <<< "$summary"
    spread=$(sed -n 's/^MIRAGE_SPREAD=//p' "$out" | tail -1)
    echo "[arm=${arm}] median=${median} rounds=${rounds} spread=${spread:-無資料} viewer_rejected=${viewer_rejected} fps_script_rc=${rc} log=${out}"
    ARM_MEDIAN="$median"
    ARM_ROUNDS="$rounds"
    ARM_VIEWER_REJECTED="$viewer_rejected"
}

OFF_VALS=""
ON_VALS=""
OFF_ROUNDS=0
ON_ROUNDS=0
OFF_VIEWER_REJECTED=0
ON_VIEWER_REJECTED=0
for pass in 1 2; do
    echo ""
    echo "=== 第 ${pass}/2 對：遙控關 ==="
    run_arm off
    [ -n "$ARM_MEDIAN" ] && OFF_VALS="${OFF_VALS}${ARM_MEDIAN}\n"
    OFF_ROUNDS=$((OFF_ROUNDS + ARM_ROUNDS))
    OFF_VIEWER_REJECTED=$((OFF_VIEWER_REJECTED + ARM_VIEWER_REJECTED))

    echo ""
    echo "=== 第 ${pass}/2 對：遙控開（背景 viewer 反覆重連 127.0.0.1:${REMOTE_PORT}）==="
    VIEWER_LOG=$(mktemp -t mirage_remote_viewer) || exit 1
    echo "viewer 收幀紀錄：${VIEWER_LOG}"
    "$PY" "${SCRIPT_DIR}/lib/remote_client.py" --host 127.0.0.1 --port "$REMOTE_PORT" --token "$TOKEN" --loop > "$VIEWER_LOG" 2>&1 &
    VIEWER_PID=$!
    run_arm on
    stop_viewer
    [ -n "$ARM_MEDIAN" ] && ON_VALS="${ON_VALS}${ARM_MEDIAN}\n"
    ON_ROUNDS=$((ON_ROUNDS + ARM_ROUNDS))
    ON_VIEWER_REJECTED=$((ON_VIEWER_REJECTED + ARM_VIEWER_REJECTED))
done

OFF_MEDIAN=$(remote_median_of "$OFF_VALS")
ON_MEDIAN=$(remote_median_of "$ON_VALS")
echo ""
echo "===== 解析結果 ====="
echo "OFF_VALUES=$(remote_list_of "$OFF_VALS")"
echo "ON_VALUES=$(remote_list_of "$ON_VALS")"
echo "OFF_MEDIAN=${OFF_MEDIAN:-無資料}"
echo "ON_MEDIAN=${ON_MEDIAN:-無資料}"
echo "OFF_ROUNDS=${OFF_ROUNDS}"
echo "ON_ROUNDS=${ON_ROUNDS}"
echo "OFF_VIEWER_REJECTED=${OFF_VIEWER_REJECTED}"
echo "ON_VIEWER_REJECTED=${ON_VIEWER_REJECTED}"
echo "VIEWER_REJECTED=$((OFF_VIEWER_REJECTED + ON_VIEWER_REJECTED))"

echo ""
echo "===== 判定 ====="
assert_at_least "前置：遙控關的有效輪數" "$OFF_ROUNDS" 2
assert_at_least "前置：遙控開的有效輪數" "$ON_ROUNDS" 2
[ -n "$OFF_MEDIAN" ] && [ -n "$ON_MEDIAN" ] || { echo "❌ 有一臂沒有中位數，無法比較"; exit 1; }
if remote_ranges_overlap "$OFF_VALS" "$ON_VALS" "$TOLERANCE"; then
    echo "⚠️ 兩臂值域重疊超過 ${TOLERANCE} fps（關 $(remote_list_of "$OFF_VALS")／開 $(remote_list_of "$ON_VALS")）："
    echo "   變異大於效應，這次量測分不出遙控有沒有拖慢；下面的判定只代表這次抽樣，加輪數重跑（-r 4）。"
fi
assert_at_least "驗收線 7 對照：遙控開的中位數 ≥ 關的中位數 − ${TOLERANCE}" "$ON_MEDIAN" $((OFF_MEDIAN - TOLERANCE))
echo "全部通過"
