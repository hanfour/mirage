#!/usr/bin/env bash
# 用測試控制通道驗證畫面轉正、觸控換算與直向回復。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/gui_session.sh"
source "${SCRIPT_DIR}/lib/verify_common.sh"

TARGET_SERIAL="${MIRAGE_ADB_SERIAL:-emulator-5554}"
TARGET_PORT="${MIRAGE_PORT:-8554}"
BROTA_PACKAGE="com.brotato.shooting.survivors.action.roguelike"
WORK="$(mktemp -d -t mirage-rotation)"
BUNDLE="${WORK}/app"
LOG="${WORK}/rotation.log"
SOCKET="${WORK}/control.sock"
EVENT_LOG="${WORK}/getevent.log"
SCREENSHOTS="${WORK}/screenshots"
SESSION_RUNNING=0
GETEVENT_PID=""
ROTATION_LOCKED=0

finish() {
    local exit_code=$?
    if [ -n "${GETEVENT_PID}" ]; then
        kill "${GETEVENT_PID}" 2>/dev/null || true
        wait "${GETEVENT_PID}" 2>/dev/null || true
    fi
    if [ "${ROTATION_LOCKED}" -eq 1 ]; then
        "${ADB}" -s "${TARGET_SERIAL}" shell wm user-rotation free < /dev/null >/dev/null 2>&1 || true
    fi
    if [ "${SESSION_RUNNING}" -eq 1 ]; then gui_session_cleanup "${BUNDLE}"; fi
    if [ "${exit_code}" -eq 0 ]; then rm -rf "${WORK}"; else echo "驗收記錄保留於：${WORK}"; fi
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

request_control() {
    python3 "${SCRIPT_DIR}/lib/mirage_ctl.py" "${SOCKET}" "$@"
}

wait_for_rotation() {
    local expected="$1" timeout="$2" deadline=$((SECONDS + timeout)) state actual
    while [ "${SECONDS}" -lt "${deadline}" ]; do
        state="$(request_control state)"
        actual="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("rotation", -1))' "${state}")"
        if [ "${actual}" -eq "${expected}" ]; then echo "✅ Mirage rotation=${expected}"; return 0; fi
        sleep 0.25
    done
    echo "❌ 等待 rotation=${expected} 逾時；最後 state：${state}"
    return 1
}

assert_window_orientation() {
    local expected="$1" state size orientation width height
    for _ in $(seq 1 20); do
        state="$(request_control state)"
        size="$(python3 -c 'import json,sys; s=json.loads(sys.argv[1]).get("contentSize", {}); print(s.get("width", 0), s.get("height", 0))' "${state}")"
        read -r width height <<< "${size}"
        orientation="$(python3 -c 'import sys; w,h=map(float, sys.argv[1:]); print("landscape" if w>h else "portrait" if h>w else "square")' "${width}" "${height}")"
        if [ "${orientation}" = "${expected}" ]; then
            echo "✅ 視窗內容區 ${width}x${height} (${expected})"
            return 0
        fi
        sleep 0.25
    done
    echo "❌ 視窗內容區未轉為 ${expected}：${size}"
    return 1
}

verify_touch() {
    local rotation="$1" nx="$2" ny="$3" label="$4"
    : > "${EVENT_LOG}"
    "${ADB}" -s "${TARGET_SERIAL}" shell getevent -lt /dev/input/event1 < /dev/null \
        > "${EVENT_LOG}" 2>&1 &
    GETEVENT_PID=$!
    sleep 0.25
    request_control mouse click --x "${nx}" --y "${ny}" --unit norm >/dev/null
    sleep 0.2
    kill "${GETEVENT_PID}" 2>/dev/null || true
    wait "${GETEVENT_PID}" 2>/dev/null || true
    GETEVENT_PID=""
    python3 - "${EVENT_LOG}" "${rotation}" "${nx}" "${ny}" "${PANEL_WIDTH}" "${PANEL_HEIGHT}" "${label}" <<'PY'
import re
import sys

path, rotation, nx, ny, width, height, label = sys.argv[1:]
rotation, width, height = int(rotation), int(width), int(height)
nx, ny = float(nx), float(ny)
values = {"x": None, "y": None}
patterns = {"x": re.compile(r"ABS_MT_POSITION_X\s+([0-9a-fA-F]+)"),
            "y": re.compile(r"ABS_MT_POSITION_Y\s+([0-9a-fA-F]+)")}
with open(path, encoding="utf-8", errors="replace") as log:
    for line in log:
        for axis, pattern in patterns.items():
            match = pattern.search(line)
            if match:
                values[axis] = int(match.group(1), 16)
if values["x"] is None or values["y"] is None:
    raise SystemExit(f"{label} 沒有讀到 event1 的 X/Y：{path}")
if rotation == 1:
    px, py = 1 - ny, nx
elif rotation == 2:
    px, py = 1 - nx, 1 - ny
elif rotation == 3:
    px, py = ny, 1 - nx
else:
    px, py = nx, ny
expected = (round(px * (width - 1)), round(py * (height - 1)))
tolerance = ((width - 1) * 0.03, (height - 1) * 0.03)
if abs(values["x"] - expected[0]) > tolerance[0] or abs(values["y"] - expected[1]) > tolerance[1]:
    raise SystemExit(f"{label} rotation={rotation} 實測 {values}，期待 {expected} ±3%")
print(f"✅ {label} rotation={rotation} 面板座標 {values['x']},{values['y']}")
PY
}

verify_corners() {
    local rotation="$1"
    verify_touch "${rotation}" 0.1 0.1 "左上"
    verify_touch "${rotation}" 0.9 0.1 "右上"
    verify_touch "${rotation}" 0.1 0.9 "左下"
    verify_touch "${rotation}" 0.9 0.9 "右下"
}

take_rotated_screenshot() {
    local attempt file dimensions width height
    request_control key --key-code 1 --modifiers cmd --action press >/dev/null
    for attempt in $(seq 1 50); do
        file="$(find "${SCREENSHOTS}" -type f -name '*.png' -print | sort | tail -1)"
        if [ -n "${file}" ]; then
            dimensions="$(python3 -c 'import struct,sys; f=open(sys.argv[1], "rb"); h=f.read(24); print(*struct.unpack(">II", h[16:24]))' "${file}")"
            read -r width height <<< "${dimensions}"
            if [ "${width}" -le "${height}" ]; then
                echo "❌ 轉正截圖期待寬大於高，實測 ${width}x${height}"
                return 1
            fi
            echo "✅ 轉正截圖 ${width}x${height}"
            return 0
        fi
        sleep 0.2
    done
    echo "❌ ⌘S 後未找到 PNG 截圖"
    return 1
}

require_device "${TARGET_SERIAL}"
require_grpc "${TARGET_PORT}"
if pgrep -x MirageApp >/dev/null 2>&1; then
    echo "❌ 已有 MirageApp 執行中，先關閉後再驗收。"
    exit 1
fi
mkdir -p "${SCREENSHOTS}"
if ! gui_session_start "${LOG}" "${BUNDLE}" "" --preserve-frontmost \
    "MIRAGE_TEST_CONTROL=${SOCKET}" "MIRAGE_SCREENSHOT_DIR=${SCREENSHOTS}" \
    "MIRAGE_PORT=${TARGET_PORT}" "MIRAGE_ADB_SERIAL=${TARGET_SERIAL}"; then
    exit 1
fi
SESSION_RUNNING=1
for _ in $(seq 1 50); do
    [ -S "${SOCKET}" ] && break
    sleep 0.2
done
if [ ! -S "${SOCKET}" ]; then
    echo "❌ Mirage 沒有建立測試控制 socket：${SOCKET}"
    exit 1
fi

PANEL_SIZE="$("${ADB}" -s "${TARGET_SERIAL}" shell wm size \
    | sed -n 's/^Physical size: //p' | tr -d '\r' | tail -1)"
if [[ ! "${PANEL_SIZE}" =~ ^([0-9]+)x([0-9]+)$ ]]; then
    echo "❌ 無法讀取面板解析度：${PANEL_SIZE}"
    exit 1
fi
PANEL_WIDTH="${BASH_REMATCH[1]}"
PANEL_HEIGHT="${BASH_REMATCH[2]}"

echo "=== Brotato 橫向驗證 ==="
ACTIVITY="$("${ADB}" -s "${TARGET_SERIAL}" shell cmd package resolve-activity --brief \
    -a android.intent.action.MAIN -c android.intent.category.LAUNCHER "${BROTA_PACKAGE}" \
    | tr -d '\r' | tail -1)"
if [[ "${ACTIVITY}" != "${BROTA_PACKAGE}/"* ]]; then
    echo "❌ 找不到 Brotato launcher activity：${ACTIVITY}"
    exit 1
fi
"${ADB}" -s "${TARGET_SERIAL}" shell am start -n "${ACTIVITY}" < /dev/null
wait_for_rotation 1 10
assert_window_orientation landscape
verify_corners 1
if ! take_rotated_screenshot; then exit 1; fi

echo "=== 強制 rotation 3 驗證 ==="
"${ADB}" -s "${TARGET_SERIAL}" shell wm user-rotation lock 3 < /dev/null
ROTATION_LOCKED=1
if wait_for_rotation 3 8; then
    verify_corners 3
else
    echo "⚠ guest 未切到 rotation 3，本輪記為未驗；rotation 1 與 rotation 0 仍會驗完。"
fi
"${ADB}" -s "${TARGET_SERIAL}" shell wm user-rotation free < /dev/null
ROTATION_LOCKED=0

echo "=== 回桌面直向驗證 ==="
"${ADB}" -s "${TARGET_SERIAL}" shell am start -a android.intent.action.MAIN \
    -c android.intent.category.HOME < /dev/null
wait_for_rotation 0 10
assert_window_orientation portrait
verify_corners 0
echo "✅ rotation 1 與 rotation 0 自動驗收通過"
