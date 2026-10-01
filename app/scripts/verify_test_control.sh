#!/usr/bin/env bash
# 測試控制通道的背景輸入與使用者游標隔離驗收。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/gui_session.sh"
source "${SCRIPT_DIR}/lib/verify_common.sh"

TARGET_SERIAL="${MIRAGE_ADB_SERIAL:-emulator-5554}"
TARGET_PORT="${MIRAGE_PORT:-8554}"
WORK="$(mktemp -d -t mirage-test-control)"
BUNDLE="${WORK}/app"
LOG="${WORK}/test-control.log"
NO_CONTROL_LOG="${WORK}/no-control.log"
SOCKET="${WORK}/control.sock"
EVENT_LOG="${WORK}/getevent.log"
UI_XML="${WORK}/launcher.xml"
GETEVENT_PID=""
SESSION_RUNNING=0

finish() {
    local exit_code=$?
    if [ -n "${GETEVENT_PID}" ]; then
        kill "${GETEVENT_PID}" 2>/dev/null || true
        wait "${GETEVENT_PID}" 2>/dev/null || true
        GETEVENT_PID=""
    fi
    if [ "${SESSION_RUNNING}" -eq 1 ]; then
        gui_session_cleanup "${BUNDLE}"
        SESSION_RUNNING=0
    fi
    if [ -n "${WORK}" ] && [ -d "${WORK}" ]; then
        if [ "${exit_code}" -eq 0 ]; then
            rm -rf "${WORK}"
        else
            echo "驗收失敗記錄：${WORK}"
        fi
    fi
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

frontmost_bundle() {
    osascript -e 'tell application "System Events" to get bundle identifier of first process whose frontmost is true' \
        2>/dev/null | tr -d '\r'
}

set_frontmost_bundle() {
    local bundle="$1"
    [[ "${bundle}" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    osascript -e "tell application id \"${bundle}\" to activate" >/dev/null 2>&1
}

host_cursor_position() {
    swift -e 'import CoreGraphics; let p = CGEvent(source: nil)!.location; print(String(format: "%.3f,%.3f", p.x, p.y))' \
        2>/dev/null
}

guest_focus() {
    "${ADB}" -s "${TARGET_SERIAL}" shell dumpsys window < /dev/null \
        | grep 'mCurrentFocus' | head -1 | tr -d '\r'
}

wait_for_focus() {
    local expected="$1" description="$2" focus="" attempt
    for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        focus="$(guest_focus)"
        if printf '%s' "${focus}" | grep -Eiq "${expected}"; then
            echo "✅ ${description}：${focus}"
            return 0
        fi
        sleep 0.5
    done
    echo "❌ ${description}：實測 '${focus}'"
    return 1
}

request_control() {
    python3 "${SCRIPT_DIR}/lib/mirage_ctl.py" "${SOCKET}" "$@"
}

require_device "${TARGET_SERIAL}"
require_grpc "${TARGET_PORT}"
if pgrep -x MirageApp >/dev/null 2>&1; then
    echo "❌ 已有 MirageApp 執行中，先關閉後再驗收，避免清理時結束既有工作階段。"
    exit 1
fi

ORIGINAL_FRONTMOST="$(frontmost_bundle)"
ORIGINAL_CURSOR="$(host_cursor_position)"
if [ -z "${ORIGINAL_FRONTMOST}" ] || [ -z "${ORIGINAL_CURSOR}" ]; then
    echo "❌ 無法記錄原本的前景 app 或游標位置。"
    exit 1
fi
echo "原本前景：${ORIGINAL_FRONTMOST}；游標：${ORIGINAL_CURSOR}"

echo "=== 啟動測試控制通道 ==="
if ! gui_session_start "${LOG}" "${BUNDLE}" "" \
    "MIRAGE_TEST_CONTROL=${SOCKET}" "MIRAGE_PORT=${TARGET_PORT}" \
    "MIRAGE_ADB_SERIAL=${TARGET_SERIAL}"; then
    exit 1
fi
SESSION_RUNNING=1
if [ ! -S "${SOCKET}" ]; then
    echo "❌ Mirage 啟動後沒有建立 Unix socket：${SOCKET}"
    exit 1
fi
assert_equals "Unix socket 權限" "$(stat -f '%Lp' "${SOCKET}")" "600"
if ! set_frontmost_bundle "${ORIGINAL_FRONTMOST}"; then
    echo "❌ 無法把前景 app 切回 ${ORIGINAL_FRONTMOST}"
    exit 1
fi
sleep 0.5
assert_equals "Mirage 在背景時的前景 app" "$(frontmost_bundle)" "${ORIGINAL_FRONTMOST}"

STATE="$(request_control state)" || exit 1
python3 - "${STATE}" <<'PY'
import json
import sys

state = json.loads(sys.argv[1])
assert state.get("ok") is True, state
assert isinstance(state.get("pid"), int) and state["pid"] > 0, state
assert isinstance(state.get("windowNumber"), int) and state["windowNumber"] > 0, state
assert state.get("connected") is True, state
assert state.get("contentSize", {}).get("width", 0) > 0, state
assert state.get("contentSize", {}).get("height", 0) > 0, state
for name in ("home", "recents"):
    frame = state.get("buttons", {}).get(name, {})
    assert all(frame.get(key, 0) > 0 for key in ("width", "height")), (name, frame)
print("✅ 視窗、連線狀態與標題列按鈕 frame")
PY
if [ "$?" -ne 0 ]; then exit 1; fi

echo "=== 背景鍵盤快捷鍵 ==="
request_control key --key-code 18 --modifiers cmd --action press >/dev/null || exit 1
wait_for_focus 'com\.google\.android\.apps\.nexuslauncher|com\.android\.launcher3' \
    "⌘1 回到 Android 主畫面" || exit 1
"${ADB}" -s "${TARGET_SERIAL}" shell am start -a android.settings.SETTINGS < /dev/null >/dev/null
sleep 2
request_control key --key-code 19 --modifiers cmd --action press >/dev/null || exit 1
wait_for_focus 'recents|overview|quickstep|systemui' "⌘2 開啟最近任務" || exit 1

echo "=== 標題列按鈕與觸控板捲動 ==="
request_control titlebar --visible true >/dev/null || exit 1
STATE="$(request_control state)" || exit 1
python3 - "${STATE}" <<'PY' || exit 1
import json
import sys

assert json.loads(sys.argv[1]).get("titlebarVisible") is True, "標題列沒有顯示"
PY
read -r HOME_X HOME_Y <<< "$(python3 - "${STATE}" <<'PY'
import json
import sys

state = json.loads(sys.argv[1])
frame = state["buttons"]["home"]
print(frame["x"] + frame["width"] / 2, frame["y"] + frame["height"] / 2)
PY
)"
if [ -z "${HOME_X:-}" ] || [ -z "${HOME_Y:-}" ]; then
    echo "❌ 無法讀取主畫面按鈕座標。"
    exit 1
fi
request_control mouse click --x "${HOME_X}" --y "${HOME_Y}" --unit pt >/dev/null || exit 1
wait_for_focus 'com\.google\.android\.apps\.nexuslauncher|com\.android\.launcher3' \
    "標題列主畫面按鈕" || exit 1

request_control titlebar --visible false >/dev/null || exit 1
STATE="$(request_control state)" || exit 1
python3 - "${STATE}" <<'PY' || exit 1
import json
import sys

assert json.loads(sys.argv[1]).get("titlebarVisible") is False, "標題列仍顯示"
PY
sleep 0.3
: > "${EVENT_LOG}"
"${ADB}" -s "${TARGET_SERIAL}" shell getevent -l /dev/input/event1 < /dev/null \
    > "${EVENT_LOG}" 2>&1 &
GETEVENT_PID=$!
sleep 0.5
request_control mouse click --x 0.5 --y 0.01 --unit norm >/dev/null || exit 1
sleep 0.5
kill "${GETEVENT_PID}" 2>/dev/null || true
wait "${GETEVENT_PID}" 2>/dev/null || true
GETEVENT_PID=""
python3 - "${EVENT_LOG}" <<'PY' || exit 1
import re
import sys

ids = re.findall(r"ABS_MT_TRACKING_ID\s+([0-9a-fA-F]+)", open(sys.argv[1], encoding="utf-8", errors="replace").read())
downs = [value for value in ids if value.lower() != "ffffffff"]
ups = [value for value in ids if value.lower() == "ffffffff"]
assert len(downs) == 1 and len(ups) == 1, f"上緣點擊沒有完整送達 guest：down={len(downs)} up={len(ups)}"
print("✅ 標題列隱藏後，上緣點擊送達 guest")
PY

: > "${EVENT_LOG}"
"${ADB}" -s "${TARGET_SERIAL}" shell getevent -l /dev/input/event1 < /dev/null \
    > "${EVENT_LOG}" 2>&1 &
GETEVENT_PID=$!
sleep 0.5
request_control scroll --x 0.5 --y 0.88 --dy -10 --steps 25 \
    --interval-ms 20 --unit norm >/dev/null || exit 1
sleep 1
kill "${GETEVENT_PID}" 2>/dev/null || true
wait "${GETEVENT_PID}" 2>/dev/null || true
GETEVENT_PID=""

python3 - "${EVENT_LOG}" <<'PY'
import re
import sys

downs = 0
ups = 0
tracking = False
positions = []
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    tracking_event = re.search(r"ABS_MT_TRACKING_ID\s+([0-9a-fA-F]+)", line)
    if tracking_event:
        value = tracking_event.group(1).lower()
        if value == "ffffffff":
            ups += 1
            tracking = False
        else:
            downs += 1
            tracking = True
    position_event = re.search(r"ABS_MT_POSITION_Y\s+([0-9a-fA-F]+)", line)
    if position_event:
        positions.append(int(position_event.group(1), 16))
assert downs == 1, f"ABS_MT_TRACKING_ID 按下數量為 {downs}，期待 1"
assert ups == 1, f"ABS_MT_TRACKING_ID 放開數量為 {ups}，期待 1"
assert positions and positions[-1] < positions[0], f"觸點 Y 沒有遞減：{positions[:1]} -> {positions[-1:]}"
assert not tracking, "guest 仍有按住的觸點"
print(f"✅ guest 收到一次按下與放開，ABS_MT_POSITION_Y {positions[0]} → {positions[-1]}，無殘留觸點")
PY
if [ "$?" -ne 0 ]; then exit 1; fi

"${ADB}" -s "${TARGET_SERIAL}" shell uiautomator dump /sdcard/mirage-test-control.xml < /dev/null >/dev/null
"${ADB}" -s "${TARGET_SERIAL}" pull /sdcard/mirage-test-control.xml "${UI_XML}" < /dev/null >/dev/null
STATE="$(request_control state)" || exit 1
read -r APP_X APP_Y <<< "$(python3 - "${UI_XML}" "${STATE}" <<'PY'
import json
import re
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
state = json.loads(sys.argv[2])
content = state["contentSize"]
drawer = False
settings = []
for node in root.iter("node"):
    text = (node.get("text") or "").strip()
    description = (node.get("content-desc") or "").strip()
    resource_id = (node.get("resource-id") or "").lower()
    label = f"{text} {description}".lower()
    if ("search" in label and ("phone" in label or "app" in label)) \
            or "all apps" in label or "search_container_all_apps" in resource_id:
        drawer = True
    if text.lower() == "settings" or description.lower() == "settings":
        match = re.fullmatch(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", node.get("bounds", ""))
        if match:
            settings.append(tuple(map(int, match.groups())))
assert drawer, "app 抽屜搜尋列沒有出現在 UI hierarchy"
assert settings, "app 抽屜裡找不到 Settings 圖示"
bounds = re.fullmatch(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", root.find("node").get("bounds", ""))
assert bounds, "無法解析 guest 螢幕尺寸"
screen_left, screen_top, screen_right, screen_bottom = map(int, bounds.groups())
x1, y1, x2, y2 = settings[0]
nx = ((x1 + x2) / 2 - screen_left) / (screen_right - screen_left)
ny = ((y1 + y2) / 2 - screen_top) / (screen_bottom - screen_top)
assert 0 <= nx <= 1 and 0 <= ny <= 1, (nx, ny)
print(nx, ny)
PY
)"
if [ -z "${APP_X:-}" ] || [ -z "${APP_Y:-}" ]; then
    echo "❌ 無法讀取 Settings app 圖示座標。"
    exit 1
fi
echo "✅ app 抽屜已開啟"
: > "${EVENT_LOG}"
"${ADB}" -s "${TARGET_SERIAL}" shell getevent -l /dev/input/event1 < /dev/null \
    > "${EVENT_LOG}" 2>&1 &
GETEVENT_PID=$!
sleep 0.5
request_control mouse click --x "${APP_X}" --y "${APP_Y}" --unit norm >/dev/null || exit 1
sleep 0.5
kill "${GETEVENT_PID}" 2>/dev/null || true
wait "${GETEVENT_PID}" 2>/dev/null || true
GETEVENT_PID=""
python3 - "${EVENT_LOG}" <<'PY' || exit 1
import re
import sys

ids = re.findall(r"ABS_MT_TRACKING_ID\s+([0-9a-fA-F]+)", open(sys.argv[1], encoding="utf-8", errors="replace").read())
downs = [value for value in ids if value.lower() != "ffffffff"]
ups = [value for value in ids if value.lower() == "ffffffff"]
assert len(downs) == 1 and len(ups) == 1, f"app 圖示點擊沒有完整送達 guest：down={len(downs)} up={len(ups)}"
print("✅ app 圖示點擊送達 guest，觸點已放開")
PY
wait_for_focus 'com\.android\.settings' "點選 Settings app 圖示" || exit 1

echo "=== 使用者狀態與通道清理 ==="
gui_session_cleanup "${BUNDLE}"
SESSION_RUNNING=0
for attempt in 1 2 3 4 5 6 7 8 9 10; do
    [ ! -e "${SOCKET}" ] && break
    sleep 0.2
done
if [ -e "${SOCKET}" ]; then
    echo "❌ Mirage 結束後 socket 仍存在：${SOCKET}"
    exit 1
fi
assert_equals "真實游標位置" "$(host_cursor_position)" "${ORIGINAL_CURSOR}"
assert_equals "前景 app" "$(frontmost_bundle)" "${ORIGINAL_FRONTMOST}"

echo "=== 未設定環境變數時不建立通道 ==="
unset MIRAGE_TEST_CONTROL
if ! gui_session_start "${NO_CONTROL_LOG}" "${BUNDLE}" "" \
    "MIRAGE_PORT=${TARGET_PORT}" "MIRAGE_ADB_SERIAL=${TARGET_SERIAL}"; then
    exit 1
fi
SESSION_RUNNING=1
if [ -e "${SOCKET}" ]; then
    echo "❌ 未設定 MIRAGE_TEST_CONTROL 卻建立了 socket。"
    exit 1
fi
gui_session_cleanup "${BUNDLE}"
SESSION_RUNNING=0
assert_equals "未開啟通道時 socket 不存在" "$(test ! -e "${SOCKET}" && printf absent)" "absent"
assert_equals "結束後真實游標位置" "$(host_cursor_position)" "${ORIGINAL_CURSOR}"
assert_equals "結束後前景 app" "$(frontmost_bundle)" "${ORIGINAL_FRONTMOST}"

echo "✅ 測試控制通道驗收完成"
