#!/usr/bin/env bash
# 純函式：只讀 stdin，不存取裝置。欄位搜尋同時接受有、無時間戳的 getevent。
_touch_transitions() {
    awk '
        BEGIN { slot = 0 }
        function hex(s, n, i) {
            s = tolower(s); sub(/^0x/, "", s); n = 0
            for (i = 1; i <= length(s); i++)
                n = n * 16 + index("0123456789abcdef", substr(s, i, 1)) - 1
            return n
        }
        {
            for (i = 1; i < NF; i++) {
                if ($i == "ABS_MT_SLOT") slot = hex($(i + 1))
                if ($i == "ABS_MT_TRACKING_ID") {
                    value = tolower($(i + 1)); sub(/^0x/, "", value)
                    print slot, (value == "ffffffff" ? "up" : "down")
                }
            }
        }
    '
}

# ABS_MT_SLOT 只在切換時出現，第一個 tracking ID 必須歸到隱含的 slot 0。
touch_slot_report() {
    _touch_transitions | awk '{ state[$1] = $2 } END { for (slot in state) print slot, state[slot] }' | sort -n
}

touch_stuck_slots() {
    touch_slot_report | awk '$2 == "down" { print $1 }'
}

touch_transition_count() {
    _touch_transitions | awk '$2 == "down" { down++ } $2 == "up" { up++ } END { print down+0, up+0 }'
}
