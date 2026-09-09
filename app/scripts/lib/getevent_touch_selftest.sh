#!/usr/bin/env bash
# 寫死事件格式，無須模擬器或 adb；任何失敗都非零退出。
set -uo pipefail
source "$(dirname "$0")/getevent_touch.sh"
FAILURES=0
check() {
    local desc="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then
        echo "✅ ${desc}"
    else
        echo "❌ ${desc}：得到 '${got}'，期待 '${want}'"
        FAILURES=$((FAILURES + 1))
    fi
}
normal='EV_ABS ABS_MT_TRACKING_ID 00000000
EV_ABS ABS_MT_PRESSURE 00000400
EV_SYN SYN_REPORT 00000000
EV_ABS ABS_MT_TRACKING_ID ffffffff   '
stuck='EV_ABS ABS_MT_SLOT 0000000a
EV_ABS ABS_MT_TRACKING_ID 00000012   '
implicit='[    91.052297] EV_ABS ABS_MT_TRACKING_ID 00000000   '
interleaved='[    91.052297] EV_ABS ABS_MT_TRACKING_ID 00000000
[    91.052298] EV_ABS ABS_MT_SLOT 00000001
[    91.052299] EV_ABS ABS_MT_TRACKING_ID 00000001
[    91.052300] EV_ABS ABS_MT_SLOT 00000000
[    91.052301] EV_ABS ABS_MT_TRACKING_ID ffffffff   '
check '單 slot 放開不卡住（無時間戳）' "$(printf '%s\n' "$normal" | touch_stuck_slots)" ''
check '單 slot 最終 up' "$(printf '%s\n' "$normal" | touch_slot_report)" '0 up'
check '正常按放計數' "$(printf '%s\n' "$normal" | touch_transition_count)" '1 1'
check '只有 down 卡住，slot 十六進位轉十進位' "$(printf '%s\n' "$stuck" | touch_stuck_slots)" '10'
check '首幀未指定 slot（有時間戳）' "$(printf '%s\n' "$implicit" | touch_slot_report)" '0 down'
check '交錯時只剩 slot 1 卡住' "$(printf '%s\n' "$interleaved" | touch_stuck_slots)" '1'
check '交錯最終狀態' "$(printf '%s\n' "$interleaved" | touch_slot_report)" $'0 up\n1 down'
check '交錯計數' "$(printf '%s\n' "$interleaved" | touch_transition_count)" '2 1'
check '空輸入不卡住' "$(printf '' | touch_stuck_slots)" ''
check '空輸入沒有 slot' "$(printf '' | touch_slot_report)" ''
check '空輸入零轉移' "$(printf '' | touch_transition_count)" '0 0'
check '大寫放開值與尾隨空白' "$(printf '%s\n' "$implicit" 'EV_ABS ABS_MT_TRACKING_ID FFFFFFFF   ' | touch_stuck_slots)" ''
if [ "$FAILURES" -ne 0 ]; then
    echo "${FAILURES} 項失敗"
    exit 1
fi
echo '全部通過'
