#!/usr/bin/env bash
# GUI 驗證截圖存檔與 guest 音量鍵。需要可操作的 macOS 桌面與 Android 模擬器。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/gui_session.sh"
source "${SCRIPT_DIR}/lib/verify_common.sh"
source "${SCRIPT_DIR}/lib/emu_instances.sh" || exit 1
cd "${SCRIPT_DIR}/.." || exit 1

ROUNDS=2
while [ "$#" -gt 0 ]; do
    case "$1" in
        --rounds)
            [ "$#" -ge 2 ] || { echo "用法：${BASH_SOURCE[0]} [--rounds N]" >&2; exit 2; }
            ROUNDS="$2"
            shift 2
            ;;
        *) echo "用法：${BASH_SOURCE[0]} [--rounds N]" >&2; exit 2 ;;
    esac
done
case "$ROUNDS" in
    ''|*[!0-9]*|0) echo "--rounds 必須是大於零的整數：${ROUNDS}" >&2; exit 2 ;;
esac

require_adb
unset MIRAGE_HOST MIRAGE_PORT MIRAGE_AVD MIRAGE_GRPC

EMU_SCRIPT="${SCRIPT_DIR}/emu.sh"
EMU_SERIAL="emulator-5554"
WORK="$(mktemp -d -t mirage_screenshot_volume)" || exit 1
EMU_STARTED=0
GETEVENT_PID=""
ACTIVE_BUNDLE=""
ACTIVE_LOG=""
ACTIVE_SCREEN_DIR=""
CONTROL_DIR=""
CONTROL_SOCKET=""
ROUND=0
TOTAL_FAILURES=0
RESULT_ROUNDS=()
RESULT_CHECKS=()
RESULT_STATUS=()
RESULT_DETAILS=()

stop_getevent() {
    if [ -n "${GETEVENT_PID}" ]; then
        kill "${GETEVENT_PID}" >/dev/null 2>&1 || true
        wait "${GETEVENT_PID}" 2>/dev/null || true
        GETEVENT_PID=""
    fi
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    stop_getevent
    if [ -n "${ACTIVE_BUNDLE}" ]; then
        gui_session_cleanup "${ACTIVE_BUNDLE}"
        ACTIVE_BUNDLE=""
    fi
    if [ -n "${CONTROL_DIR}" ]; then
        rm -rf "${CONTROL_DIR}"
        CONTROL_DIR=""
        CONTROL_SOCKET=""
    fi
    if [ "${EMU_STARTED}" -eq 1 ]; then
        "${EMU_SCRIPT}" stop || status=1
    fi
    rm -rf "${WORK}"
    exit "${status}"
}
trap cleanup EXIT INT TERM

INITIAL_QEMU="$(pgrep -fl qemu-system 2>/dev/null || true)"
if emu_is_running "${INITIAL_QEMU}" 5554; then
    echo "模擬器 emulator-5554 已在執行；驗證結束時會保留。"
else
    EMU_STARTED=1
fi
if ! "${EMU_SCRIPT}" start; then
    echo "❌ emu.sh start 失敗"
    exit 1
fi
require_device "${EMU_SERIAL}"
require_grpc 8554

print_evidence() {
    echo "--- 回合 ${ROUND} 證據 ---"
    echo "app log：${ACTIVE_LOG:-（尚未建立）}"
    if [ -r "${ACTIVE_LOG}" ]; then
        grep -E '\[conn\]|\[screenshot\]' "${ACTIVE_LOG}" | tail -40 || true
    else
        echo "（app log 不存在）"
    fi
    if [ -n "${GETEVENT_LOG:-}" ] && [ -r "${GETEVENT_LOG}" ]; then
        echo "getevent log：${GETEVENT_LOG}"
        grep -E 'KEY_VOLUME(UP|DOWN)' "${GETEVENT_LOG}" | tail -80 || true
    else
        echo "getevent log：（尚未建立）"
    fi
    if [ -n "${ACTIVE_SCREEN_DIR}" ] && [ -d "${ACTIVE_SCREEN_DIR}" ]; then
        echo "截圖暫存目錄：${ACTIVE_SCREEN_DIR}"
        find "${ACTIVE_SCREEN_DIR}" -maxdepth 1 -print
    else
        echo "截圖暫存目錄：（尚未建立）"
    fi
    echo "--- 證據結束 ---"
}

record_result() {
    local check="$1" status="$2" details="$3"
    RESULT_ROUNDS+=("${ROUND}")
    RESULT_CHECKS+=("${check}")
    RESULT_STATUS+=("${status}")
    RESULT_DETAILS+=("${details}")
    if [ "${status}" != PASS ]; then TOTAL_FAILURES=$((TOTAL_FAILURES + 1)); fi
}

wait_for_control_socket() {
    local poll=0
    while [ "${poll}" -lt 100 ]; do
        [ -S "${CONTROL_SOCKET}" ] && return 0
        sleep 0.1
        poll=$((poll + 1))
    done
    return 1
}

send_control_key() {
    local key_code="$1"
    wait_for_control_socket || return 1
    python3 "${SCRIPT_DIR}/lib/mirage_ctl.py" "${CONTROL_SOCKET}" key \
        --key-code "${key_code}" --modifiers cmd --action press
}

wait_for_connection() {
    local elapsed=0
    while [ "${elapsed}" -lt 60 ]; do
        if grep -qE 'connectSucceeded.*connected' "${ACTIVE_LOG}" 2>/dev/null; then return 0; fi
        if ! gui_session_app_is_running "${ACTIVE_BUNDLE}/Mirage.app"; then return 1; fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    return 1
}

png_count() {
    find "$1" -maxdepth 1 -type f -name '*.png' -print | wc -l | tr -d '[:space:]'
}

verify_screenshot() {
    local ok=1 details="" poll count png dimensions
    if ! send_control_key 1 >/dev/null; then
        ok=0
        details="測試控制通道未能送出 ⌘S"
    else
        poll=0
        count=0
        while [ "${poll}" -lt 20 ]; do
            count="$(png_count "${ACTIVE_SCREEN_DIR}")"
            [ "${count}" -gt 0 ] && break
            sleep 0.5
            poll=$((poll + 1))
        done
        [ "${count}" -gt 0 ] && sleep 0.5
        count="$(png_count "${ACTIVE_SCREEN_DIR}")"
        png="$(find "${ACTIVE_SCREEN_DIR}" -maxdepth 1 -type f -name '*.png' -print | head -1)"
        if [ "${count}" -ne 1 ]; then
            ok=0
            details="10 秒內 PNG 數量為 ${count}，預期 1"
        elif ! grep -q '\[screenshot\] saved' "${ACTIVE_LOG}"; then
            ok=0
            details="app log 沒有 [screenshot] saved"
        else
            dimensions="$(sips -g pixelWidth -g pixelHeight "${png}" 2>/dev/null \
                | awk '/pixelWidth/ { width = $2 } /pixelHeight/ { height = $2 } \
                    END { if (width != "" && height != "") print width "x" height }')"
            if [ "${dimensions}" != 1080x2400 ]; then
                ok=0
                details="PNG 尺寸為 ${dimensions:-（無法讀取）}，預期 1080x2400"
            else
                details="${png} ${dimensions}"
            fi
        fi
    fi

    if [ "${ok}" -eq 1 ]; then
        record_result "V1 截圖" PASS "${details}"
        echo "✅ 回合 ${ROUND} V1 截圖：${details}"
    else
        record_result "V1 截圖" FAIL "${details}"
        echo "❌ 回合 ${ROUND} V1 截圖：${details}"
        print_evidence
    fi
}

volume_pairs_present() {
    # Same pure-log-parser shape as getevent_touch.sh; this only reads the captured event stream.
    awk '
        $2 == "EV_KEY" && $3 == "KEY_VOLUMEUP" && $4 == "DOWN" { up_down++ }
        $2 == "EV_KEY" && $3 == "KEY_VOLUMEUP" && $4 == "UP" { up_up++ }
        $2 == "EV_KEY" && $3 == "KEY_VOLUMEDOWN" && $4 == "DOWN" { down_down++ }
        $2 == "EV_KEY" && $3 == "KEY_VOLUMEDOWN" && $4 == "UP" { down_up++ }
        END { exit !(up_down && up_up && down_down && down_up) }
    ' "$1"
}

# 測試控制通道直接投遞 NSEvent；keyCode 126/125 分別是方向鍵上／下。
verify_volume() {
    local ok=1 details="" poll
    GETEVENT_LOG="${WORK}/getevent-${ROUND}.log"
    "${ADB}" -s "${EMU_SERIAL}" shell getevent -l >"${GETEVENT_LOG}" 2>&1 &
    GETEVENT_PID=$!
    sleep 1
    if ! kill -0 "${GETEVENT_PID}" >/dev/null 2>&1; then
        ok=0
        details="adb shell getevent -l 未持續執行"
    elif ! send_control_key 126 >/dev/null || ! send_control_key 125 >/dev/null; then
        ok=0
        details="測試控制通道未能送出 ⌘方向鍵"
    else
        poll=0
        while [ "${poll}" -lt 25 ]; do
            if volume_pairs_present "${GETEVENT_LOG}"; then break; fi
            sleep 0.2
            poll=$((poll + 1))
        done
        if volume_pairs_present "${GETEVENT_LOG}"; then
            details="KEY_VOLUMEUP 與 KEY_VOLUMEDOWN 均有 DOWN/UP"
        else
            ok=0
            details="5 秒內未觀察到兩組音量鍵 DOWN/UP"
        fi
    fi
    stop_getevent

    if [ "${ok}" -eq 1 ]; then
        record_result "V2 音量" PASS "${details}"
        echo "✅ 回合 ${ROUND} V2 音量：${details}"
    else
        record_result "V2 音量" FAIL "${details}"
        echo "❌ 回合 ${ROUND} V2 音量：${details}"
        print_evidence
    fi
}

quit_mirage() {
    local pid
    pid="$(gui_session_pid_for_app "${ACTIVE_BUNDLE}/Mirage.app")"
    [ -z "${pid}" ] || gui_session_quit_gracefully "${pid}"
}

for ((ROUND = 1; ROUND <= ROUNDS; ROUND++)); do
    ACTIVE_LOG="${WORK}/round-${ROUND}.log"
    ACTIVE_BUNDLE="${WORK}/round-${ROUND}-bundle"
    GETEVENT_LOG=""
    ACTIVE_SCREEN_DIR="$(mktemp -d "${WORK}/screenshots-${ROUND}.XXXXXX")" || exit 1
    CONTROL_DIR="$(mktemp -d /tmp/mtc.XXXXXX)" || exit 1
    CONTROL_SOCKET="${CONTROL_DIR}/c"
    echo "=== 回合 ${ROUND}/${ROUNDS}：啟動 MirageApp ==="
    if ! gui_session_start "${ACTIVE_LOG}" "${ACTIVE_BUNDLE}" "" \
        --preserve-frontmost \
        "MIRAGE_SCREENSHOT_DIR=${ACTIVE_SCREEN_DIR}" "MIRAGE_CONN_LOG=1" \
        "MIRAGE_TEST_CONTROL=${CONTROL_SOCKET}"; then
        record_result "V1 截圖" FAIL "gui_session_start 失敗"
        record_result "V2 音量" FAIL "gui_session_start 失敗"
        print_evidence
    elif ! wait_for_control_socket; then
        record_result "V1 截圖" FAIL "10 秒內沒有建立測試控制 socket"
        record_result "V2 音量" FAIL "10 秒內沒有建立測試控制 socket"
        print_evidence
    elif ! wait_for_connection; then
        record_result "V1 截圖" FAIL "60 秒內未見連線成功 log"
        record_result "V2 音量" FAIL "60 秒內未見連線成功 log"
        print_evidence
    else
        echo "✅ MirageApp 已連線"
        verify_screenshot
        verify_volume
    fi

    if ! quit_mirage; then
        record_result "退出 MirageApp" FAIL "10 秒內未能正常結束 MirageApp"
        echo "❌ 回合 ${ROUND} 未能正常結束 MirageApp"
        print_evidence
    else
        record_result "退出 MirageApp" PASS "正常結束要求後 MirageApp 已結束"
        echo "✅ 回合 ${ROUND} 已正常結束 MirageApp"
    fi
    gui_session_cleanup "${ACTIVE_BUNDLE}"
    ACTIVE_BUNDLE=""
    rm -rf "${CONTROL_DIR}"
    CONTROL_DIR=""
    CONTROL_SOCKET=""
done

echo ""
echo "===== 驗證結果 ====="
printf '%-8s %-18s %-8s %s\n' "回合" "項目" "結果" "說明"
for index in "${!RESULT_ROUNDS[@]}"; do
    printf '%-8s %-18s %-8s %s\n' \
        "${RESULT_ROUNDS[$index]}" "${RESULT_CHECKS[$index]}" \
        "${RESULT_STATUS[$index]}" "${RESULT_DETAILS[$index]}"
done
if [ "${TOTAL_FAILURES}" -gt 0 ]; then
    echo "❌ 共 ${TOTAL_FAILURES} 項失敗"
    exit 1
fi
echo "✅ 全部通過"
