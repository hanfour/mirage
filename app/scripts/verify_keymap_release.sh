#!/usr/bin/env bash
# D11／D23：真模擬器上的原始觸控轉移，判定 slot 是否停在 down。
# 只連到已啟動的模擬器，不負責啟動或關閉模擬器。
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/verify_common.sh"
source "${SCRIPT_DIR}/lib/getevent_touch.sh"

require_device "${ANDROID_SERIAL:-emulator-5554}"
require_grpc 8554

EVENT_LOG=$(mktemp /tmp/mirage-keymap-release-events.XXXXXX) || exit 1
TEST_LOG=$(mktemp /tmp/mirage-keymap-release-tests.XXXXXX) || exit 1
CAPTURE_PID=''
stop_capture() {
    if [ -n "$CAPTURE_PID" ]; then
        # guest 的 getevent 也要收掉，單殺主機 adb 可能留下孤兒。
        "$ADB" shell pkill getevent > /dev/null 2>&1 || true
        # 以父 PID 限定本腳本的擷取行程，避免誤殺其他 adb 工作。
        pkill -P "$$" -f 'adb.*shell getevent -lt /dev/input/event1' > /dev/null 2>&1 || true
        kill "$CAPTURE_PID" > /dev/null 2>&1 || true
        wait "$CAPTURE_PID" 2>/dev/null || true
        CAPTURE_PID=''
    fi
}
cleanup() {
    stop_capture
    echo "getevent 紀錄（佐證素材，檔案路徑本身不是斷言）：${EVENT_LOG}"
    echo "Swift 測試紀錄：${TEST_LOG}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

"$ADB" shell getevent -lt /dev/input/event1 > "$EVENT_LOG" 2>&1 &
CAPTURE_PID=$!
cd "${SCRIPT_DIR}/.." || exit 1
MIRAGE_LIVE=1 swift test --filter KeymapReleaseLiveTests 2>&1 | tee "$TEST_LOG"
assert_ok 'KeymapReleaseLiveTests' "${PIPESTATUS[0]}"

# 必須看見各測試的 passed 完成行；零測試、skip 或名稱不符都要紅。
for test_name in releasesJoystickTouchOnFocusLossAndReload resignKeyNotificationReleasesTouch; do
    grep -Eq "Test ${test_name}\\(\\) passed([[:space:]]|$)" "$TEST_LOG"
    assert_ok "${test_name} 確實 passed（不能 skip）" "$?"
done

stop_capture
read -r downs ups < <(touch_transition_count < "$EVENT_LOG")

# 兩個斷言的順序不能對調，而且理由不是風格問題。
#
# emulator 的觸控驅動只送轉移：觸點卡在 down 時，後續同狀態的幀不產生任何事件。
# 所以「按下次數不足」有兩種成因：注入根本沒到 guest，或是觸點卡住讓後續按下被吃掉。
# 實測（2026-09-09，把 releaseEverything 還原做故障注入）就是後者：按下次數掉到 1，
# 若先判次數，腳本會紅在「按下次數 1 < 3」上，而真正的缺陷是 slot 0 停在 down。
# 讀到那個訊息的人會去查注入路徑，查錯方向。
#
# 先判「有沒有卡住」之後，走到次數這一步就已經知道沒有東西卡著，
# 「次數不足」在那個位置只剩一種成因，訊息不再有歧義。
assert_equals 'guest 卡住的 slot' "$(touch_stuck_slots < "$EVENT_LOG")" ''
# 走到這裡代表沒有 slot 卡住，所以次數不足只可能是注入沒到 guest。
assert_at_least 'guest 按下次數（沒有卡住的 slot，故不足只可能是注入沒到）' "$downs" 3
echo "guest 轉移次數：按下 ${downs}，放開 ${ups}"
