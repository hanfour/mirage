#!/usr/bin/env bash
# 手機遙控活體驗證（spec 第 8 節）：六條斷言
#   R1 手機端（Python 用戶端）60 秒內收到 keyframe
#   R2 幀序連續（SEQ_GAPS == 0）
#   R3 送一組 down/move/up 後 guest 的 getevent 出現 ABS_MT_TRACKING_ID，且沒有 slot 卡在 down
#   R4 GoHome 後前景為 HOME resolver 指定的 launcher
#   R5 AppSwitch 在 guest evdev 出現 KEY_APPSELECT DOWN 與 UP
#   R6 遠端文字提交後，設定搜尋欄位的新鮮 UI dump 精確回讀相等
# 之前先跑兩條 Swift 活體測試：RemoteVideoEncoderLiveTests（硬體編碼器＋SPS 改寫）與
# RemoteInputLiveTests（server → InputQueue → 真模擬器），並斷言它們是 passed 不是 skipped。
#
# 用法：
#   ./scripts/verify_remote_mirror.sh                      # 預設 5554 / 8554 / Pixel Flow / 遙控埠 8765
#   ./scripts/verify_remote_mirror.sh -s emulator-5554 -p 8554 -P 8770 -w 60 -d 10
#
# 前置：模擬器在跑、遊戲能停在**會持續變化**的畫面（streamScreenshot 是變化驅動的，畫面靜止
# 時編碼器根本沒有幀可拉，R1 會紅——那是環境的紅燈，不是產品的）；遙控埠沒被佔用。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/load_sentinel.sh"
source "${SCRIPT_DIR}/lib/verify_common.sh"
source "${SCRIPT_DIR}/lib/gui_session.sh"
source "${SCRIPT_DIR}/lib/getevent_touch.sh"
source "${SCRIPT_DIR}/lib/remote_venv.sh"

SERIAL="emulator-5554"
GRPC_PORT="8554"
PACKAGE="com.loomgames.pixelflow"
REMOTE_PORT=8765
WAIT_KEYFRAME=60
DURATION=10

while getopts "s:p:g:P:w:d:h" opt; do
  case "$opt" in
    s) SERIAL="$OPTARG" ;;
    p) GRPC_PORT="$OPTARG" ;;
    g) PACKAGE="$OPTARG" ;;
    P) REMOTE_PORT="$OPTARG" ;;
    w) WAIT_KEYFRAME="$OPTARG" ;;
    d) DURATION="$OPTARG" ;;
    h) sed -n '2,/^set /{ /^#/p; }' "$0"; exit 0 ;;
    *) echo "用法：$0 [-s serial] [-p grpc_port] [-g package] [-P remote_port] [-w keyframe_wait] [-d seconds]" >&2; exit 2 ;;
  esac
done
for v in REMOTE_PORT WAIT_KEYFRAME DURATION; do
  eval "val=\$${v}"
  case "$val" in ''|*[!0-9]*) echo "❌ ${v} 只接受正整數：實測 '${val}'。" >&2; exit 2 ;; esac
done
[ -z "$PACKAGE" ] && { echo "❌ -g 不接受空字串：需要會變化的畫面來源。" >&2; exit 2; }

[ "$SERIAL:$GRPC_PORT" = "emulator-5554:8554" ] || { echo "❌ 本驗證只接受 emulator-5554／8554" >&2; exit 2; }
[ "$REMOTE_PORT" -ge 1 ] && [ "$REMOTE_PORT" -le 65535 ] && [ "$WAIT_KEYFRAME" -ge 1 ] && [ "$WAIT_KEYFRAME" -le 60 ] && [ "$DURATION" -ge 1 ] || {
    echo "❌ 埠需為 1–65535，等待需為 1–60 秒，取樣秒數需大於零" >&2; exit 2;
}
disk_preflight "$SCRIPT_DIR" || exit 1
PY=$(remote_venv_python) || exit 1
require_device "$SERIAL"
require_grpc "$GRPC_PORT"
if nc -z 127.0.0.1 "$REMOTE_PORT" 2>/dev/null; then
    echo "❌ 遙控埠 ${REMOTE_PORT} 已有人監聽；換一個埠：-P <埠>。" >&2
    exit 1
fi

EVENT_LOG=$(mktemp -t mirage_remote_events) || exit 1
TEST_LOG=$(mktemp -t mirage_remote_tests) || exit 1
CLIENT_LOG=$(mktemp -t mirage_remote_client) || exit 1
LOG=$(mktemp -t mirage_remote_app) || exit 1
BUNDLE=$(mktemp -d -t mirage_remote_bundle) || exit 1
CAPTURE_PID=''
KEY_CAPTURE_PID=''
start_capture() {
    : > "$EVENT_LOG"
    "$ADB" shell getevent -lt /dev/input/event1 > "$EVENT_LOG" 2>&1 &
    CAPTURE_PID=$!
    sleep 1
    kill -0 "$CAPTURE_PID" 2>/dev/null || { echo "❌ getevent 擷取未啟動"; exit 1; }
}
stop_capture() {
    if [ -n "$CAPTURE_PID" ]; then
        "$ADB" shell pkill getevent > /dev/null 2>&1 || true
        pkill -P "$$" -f 'adb.*shell getevent -lt /dev/input/event1' > /dev/null 2>&1 || true
        kill "$CAPTURE_PID" > /dev/null 2>&1 || true
        wait "$CAPTURE_PID" 2>/dev/null || true
        CAPTURE_PID=''
    fi
}
stop_key_capture() {
    if [ -n "$KEY_CAPTURE_PID" ]; then
        kill "$KEY_CAPTURE_PID" 2>/dev/null || true
        wait "$KEY_CAPTURE_PID" 2>/dev/null || true
        KEY_CAPTURE_PID=''
    fi
}
cleanup() {
    stop_capture
    stop_key_capture
    gui_session_cleanup "${BUNDLE:-}"
    echo "getevent 紀錄：${EVENT_LOG}　Swift 測試紀錄：${TEST_LOG}　用戶端輸出：${CLIENT_LOG}　App log：${LOG}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo ""
echo "=== 第一段：Swift 活體測試（編碼器＋觸控路徑；觸控路徑期間擷取 getevent）==="
cd "${SCRIPT_DIR}/.." || exit 1
start_capture
MIRAGE_LIVE=1 MIRAGE_LIVE_REMOTE=1 MIRAGE_HOST=127.0.0.1 MIRAGE_PORT="$GRPC_PORT" ANDROID_SERIAL="$SERIAL" \
    swift test --filter "RemoteVideoEncoderLiveTests|RemoteInputLiveTests" 2>&1 | tee "$TEST_LOG" | tail -5
assert_ok 'Swift 活體測試' "${PIPESTATUS[0]}"
stop_capture
# 必須看見各測試的 passed 完成行；零測試、skip 或名稱不符都要紅（打錯 env 名會變成永遠 skip）。
for test_name in emitsOneRewrittenAccessUnitPerFrameAndRecreatesOnResize invalidFrameThrowsBeforeCreatingSession remoteTouchReachesEmulatorThroughInputQueue; do
    grep -Eq "Test ${test_name}\\(\\) passed([[:space:]]|$)" "$TEST_LOG"
    assert_ok "${test_name} 確實 passed（不能 skip）" "$?"
done
read -r swift_downs swift_ups < <(touch_transition_count < "$EVENT_LOG")
assert_equals "S1 Swift 觸控路徑：沒有 slot 卡在 down" "$(touch_stuck_slots < "$EVENT_LOG" | tr '\n' ' ')" ""
assert_at_least "S2 Swift 觸控路徑：guest 收到按下" "$swift_downs" 1
assert_at_least "S2 Swift 觸控路徑：guest 收到放開" "$swift_ups" 1

echo ""
cp "$EVENT_LOG" "${EVENT_LOG}.swift" || exit 1

echo "=== 第二段：啟動遊戲：$PACKAGE ==="
"$ADB" -s "$SERIAL" shell monkey -p "$PACKAGE" -c android.intent.category.LAUNCHER 1 > /dev/null 2>&1
sleep 8
FG=$("$ADB" -s "$SERIAL" shell dumpsys activity activities 2>/dev/null | grep topResumedActivity | tr -d '\r' | head -1)
case "$FG" in
  *"$PACKAGE"*) echo "✅ $PACKAGE 在前景" ;;
  *) echo "❌ $PACKAGE 不在前景——沒有會變化的畫面來源，R1 沒有意義。"; exit 1 ;;
esac

echo ""
echo "=== 第三段：以 .app bundle 啟動 Mirage，遙控自動開啟（埠 ${REMOTE_PORT}）==="
TOKEN=$("$PY" -c 'import secrets; print(secrets.token_hex(16))') || exit 1
if ! gui_session_start "$LOG" "$BUNDLE" "" \
        "MIRAGE_HOST=127.0.0.1" "MIRAGE_PORT=$GRPC_PORT" "MIRAGE_CONN_LOG=1" \
        "MIRAGE_REMOTE=1" "MIRAGE_REMOTE_PORT=$REMOTE_PORT" "MIRAGE_REMOTE_TOKEN=$TOKEN"; then
    exit 1
fi
LISTEN_LINE=""
for _ in $(seq 1 40); do
    LISTEN_LINE=$(grep '^\[remote\] listening port=' "$LOG" | tail -1)
    [ -n "$LISTEN_LINE" ] && break
    sleep 0.5
done
if [ -z "$LISTEN_LINE" ]; then
    echo "❌ 20 秒內 App 沒印 [remote] listening——遙控沒開起來。App log 前 20 行："
    head -20 "$LOG"
    grep '^\[remote\]' "$LOG" || true
    exit 1
fi
echo "   $LISTEN_LINE"
assert_equals "App 綁到指定的遙控埠" "$(printf '%s' "$LISTEN_LINE" | sed -n 's/.*port=\([0-9]*\).*/\1/p')" "$REMOTE_PORT"

echo ""
echo "=== 第四段：Python 用戶端連線，等 keyframe（上限 ${WAIT_KEYFRAME}s）、收 ${DURATION}s、送觸控 ==="
start_capture
"$PY" "${SCRIPT_DIR}/lib/remote_client.py" --host 127.0.0.1 --port "$REMOTE_PORT" --token "$TOKEN" \
    --wait-keyframe "$WAIT_KEYFRAME" --seconds "$DURATION" --touch 2>&1 | tee "$CLIENT_LOG"
CLIENT_RC=${PIPESTATUS[0]}
sleep 1
stop_capture
case "$CLIENT_RC" in
    0) ;;
    2) echo "❌ 用戶端連不上（見上方 CONNECT_ERROR）。token 或埠不對、或 server 拒絕。"; exit 1 ;;
    3) echo "❌ ${WAIT_KEYFRAME} 秒內沒有 keyframe。先分辨：App log 有沒有「幀 #」（畫面在動嗎）？"
       echo "   沒有 → 畫面靜止，環境的紅燈；有 → 編碼器或 server 沒送，看 App log 的 [remote] 行。"
       grep -c '幀 #' "$LOG" || true
       grep '^\[remote\]' "$LOG" || true
       exit 1 ;;
    *) echo "❌ 用戶端異常結束（退出碼 ${CLIENT_RC}）"; exit 1 ;;
esac
KEYFRAME_SECONDS="" FRAMES="" KEYFRAMES="" SEQ_GAPS="" TOUCH_SENT="" PING_ECHO_OK="" PING_RTT_MS=""
eval "$(grep -E '^[A-Z_]+=[0-9.]*$' "$CLIENT_LOG")"

echo ""
echo "===== 判定 ====="
# R1：`assert_at_most` 對空值視為 0 通過，所以先確認 KEYFRAME_SECONDS 有值（退出碼 0 已保證，再守一次）。
[ -n "${KEYFRAME_SECONDS:-}" ] || { echo "❌ R1 用戶端沒回報 KEYFRAME_SECONDS"; exit 1; }
assert_at_most "R1 第一個 keyframe 的秒數" "${KEYFRAME_SECONDS%%.*}" "$WAIT_KEYFRAME"
assert_at_least "R2 前置：收到的幀數" "${FRAMES:-0}" 2
assert_equals "R2 幀序缺口" "$SEQ_GAPS" 0
assert_equals "R3 前置：三則觸控都送出" "${TOUCH_SENT:-0}" 3
assert_equals "R3 前置：ping 原封 echo" "${PING_ECHO_OK:-0}" 1
# R3 的兩條順序不能對調：觸點卡住會吃掉後續按下，先判卡住（guest-touch-state-via-getevent）。
assert_equals "R3 沒有 slot 卡在 down" "$(touch_stuck_slots < "$EVENT_LOG" | tr '\n' ' ')" ""
read -r downs ups < <(touch_transition_count < "$EVENT_LOG")
assert_at_least "R3 guest 收到按下（ABS_MT_TRACKING_ID）" "$downs" 1
assert_at_least "R3 guest 收到放開" "$ups" 1
echo "ping 往返：${PING_RTT_MS:-?} ms（loopback，只是工具健康度，不是手機的數字）"
echo ""
MAC_SUMMARY=$(sed -n 's/^MAC_STATS_LAST=//p' "$CLIENT_LOG" | tail -1)
echo "Mac 延遲摘要（最後一窗，毫秒）：${MAC_SUMMARY:-未收到 stats，無法量測}"
# 每個有新幀的窗口都須 age p95 < 10 ms；空樣本不得當成零通過。
"$PY" "${SCRIPT_DIR}/lib/remote_latency_verify.py" "$CLIENT_LOG"
assert_ok "R3 Mac age p95 < 10 ms" "$?"
echo "=== 第五段：遠端導覽鍵 → guest 前景活動 ==="
# 沿用 emu.sh foreground_on：只看第一條 topResumedActivity，不能把歷史 task 當前景。
# 解析完整 component，保留套件數字／底線；每次採樣都印出原始證據。
foreground_evidence() {
    local dump
    dump=$("$ADB" -s "$SERIAL" shell dumpsys activity activities 2>&1) || {
        echo "❌ dumpsys 失敗：$dump" >&2; return 1;
    }
    FG_LINE=$(printf '%s\n' "$dump" | grep -m1 topResumedActivity | tr -d '\r')
    FG_COMPONENT=$(printf '%s\n' "$FG_LINE" | grep -oE '[A-Za-z0-9_.]+/[A-Za-z0-9_.$]+' | head -1)
    echo "   topResumedActivity 證據：${FG_LINE:-<空>}"
}
HOME_RESOLVER=$("$ADB" -s "$SERIAL" shell cmd package resolve-activity --brief \
    -a android.intent.action.MAIN -c android.intent.category.HOME 2>&1) || exit 1
echo "   HOME resolver 證據：$HOME_RESOLVER"
HOME_COMPONENT=$(printf '%s\n' "$HOME_RESOLVER" | tr -d '\r' | grep -E '^[A-Za-z0-9_.]+/[A-Za-z0-9_.$]+$' | tail -1)
[ -n "$HOME_COMPONENT" ] || { echo "❌ 無法解析 launcher component"; exit 1; }
HOME_PACKAGE=${HOME_COMPONENT%%/*}
send_navigation_key() {
    local key="$1" output rc
    # 前一組 viewer 的 close 由 server 非同步清理；有限重試僅限 409，未連線不會重送按鍵。
    for _ in 1 2 3 4 5; do
        output=$("$PY" "${SCRIPT_DIR}/lib/remote_client.py" --host 127.0.0.1 \
            --port "$REMOTE_PORT" --token "$TOKEN" --wait-keyframe "$WAIT_KEYFRAME" --seconds 0 --key "$key" 2>&1)
        rc=$?
        printf '%s\n' "$output" | tee -a "$CLIENT_LOG"
        if [ "$rc" -eq 0 ]; then
            printf '%s\n' "$output" | grep -qx "KEY_SENT=$key" || return 1
            printf '%s\n' "$output" | grep -qx 'PING_ECHO_OK=1'
            return $?
        fi
        if [ "$rc" -eq 2 ] && [[ "$output" == *"HTTP 409"* ]]; then sleep 0.2; else return "$rc"; fi
    done
    return 1
}
send_navigation_key GoHome || { echo "❌ GoHome 傳送失敗"; exit 1; }
HOME_SEEN=0
for _ in $(seq 1 20); do
    foreground_evidence || exit 1
    if [ -n "$FG_COMPONENT" ] && [ "${FG_COMPONENT%%/*}" = "$HOME_PACKAGE" ]; then HOME_SEEN=1; break; fi
    sleep 0.25
done
assert_equals "R4 GoHome 後前景為 launcher $HOME_PACKAGE" "$HOME_SEEN" 1
# Quickstep 的 overview 留在 launcher activity；以 evdev 的完整按放證明按鍵送達。
KEY_EVENT_LOG=$(mktemp -t mirage_remote_keys) || exit 1
"$ADB" -s "$SERIAL" shell getevent -l > "$KEY_EVENT_LOG" 2>&1 &
KEY_CAPTURE_PID=$!
sleep 1
kill -0 "$KEY_CAPTURE_PID" 2>/dev/null || { echo "❌ getevent 未啟動：$(cat "$KEY_EVENT_LOG")"; exit 1; }
send_navigation_key AppSwitch || { echo "❌ AppSwitch 傳送失敗"; exit 1; }
sleep 1
stop_key_capture
echo "   KEY_APPSELECT 證據（${KEY_EVENT_LOG}）："
grep -E ' KEY_APPSELECT +(DOWN|UP)' "$KEY_EVENT_LOG" || true
key_downs=$(grep -Ec ' KEY_APPSELECT +DOWN' "$KEY_EVENT_LOG" || true)
key_ups=$(grep -Ec ' KEY_APPSELECT +UP' "$KEY_EVENT_LOG" || true)
assert_at_least "R5 KEY_APPSELECT DOWN" "$key_downs" 1
assert_at_least "R5 KEY_APPSELECT UP" "$key_ups" 1
# R6：此段只準備設定搜尋欄位；受測文字全部經 /ws/input 與既有提交交易。
TEXT_EVIDENCE=$(mktemp -d -t mirage_remote_text) || exit 1
echo "=== 第六段：遠端文字 → 設定搜尋欄位（證據：${TEXT_EVIDENCE}）==="
"$PY" "${SCRIPT_DIR}/lib/remote_text_verify.py" --serial "$SERIAL" --port "$REMOTE_PORT" \
    --token "$TOKEN" --wait-keyframe "$WAIT_KEYFRAME" --evidence "$TEXT_EVIDENCE" || exit 1
echo "全部通過"
