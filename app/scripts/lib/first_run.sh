#!/usr/bin/env bash
# 首次啟動驗證器的純 log 解析函式。

first_run_has_setup_activity() {
    [ -r "$1" ] || return 1
    awk '
        /^\[setup\] / && $0 !~ /^\[setup\] warning / { found = 1 }
        END { exit found ? 0 : 1 }
    ' "$1"
}

first_run_has_download_started() {
    [ -r "$1" ] || return 1
    awk '/^\[setup\] .+ 下載中([[:space:]]|$)/ { found = 1 }
         END { exit found ? 0 : 1 }' "$1"
}

first_run_has_completed_item() {
    [ -r "$1" ] || return 1
    awk -v item="$2" '$0 == "[setup] " item " 完成" { found = 1 }
                       END { exit found ? 0 : 1 }' "$1"
}

first_run_completed_in_order() {
    [ -r "$1" ] || return 1
    awk -v first="$2" -v second="$3" -v third="$4" '
        $0 == "[setup] " first " 完成" && firstLine == 0 { firstLine = NR }
        $0 == "[setup] " second " 完成" && secondLine == 0 { secondLine = NR }
        $0 == "[setup] " third " 完成" && thirdLine == 0 { thirdLine = NR }
        END {
            exit !(firstLine > 0 && firstLine < secondLine && secondLine < thirdLine)
        }
    ' "$1"
}

first_run_has_setup_done() {
    [ -r "$1" ] || return 1
    awk '$0 == "[setup] done" { found = 1 }
         END { exit found ? 0 : 1 }' "$1"
}

first_run_parse_gate_line() {
    printf '%s\n' "$1" | awk '
        $0 !~ /^\[setup\] gate canStart=(true|false) required=[0-9]+ available=[0-9]+$/ { exit 1 }
        {
            sub(/^\[setup\] gate /, "")
            split($0, fields, " ")
            split(fields[1], canStart, "=")
            split(fields[2], required, "=")
            split(fields[3], available, "=")
            print canStart[2], required[2], available[2]
        }
    '
}

first_run_gate_values() {
    [ -r "$1" ] || return 1
    local line
    line=$(awk '/^\[setup\] gate / { last = $0 } END { if (last != "") print last }' "$1")
    [ -n "$line" ] || return 1
    first_run_parse_gate_line "$line"
}

first_run_has_launch_requested() {
    [ -r "$1" ] || return 1
    awk '/^\[launcher\].*launchRequested/ { found = 1 }
         END { exit found ? 0 : 1 }' "$1"
}

first_run_has_running() {
    [ -r "$1" ] || return 1
    awk '/^\[launcher\].*--> running([[:space:]]|$)/ { found = 1 }
         END { exit found ? 0 : 1 }' "$1"
}
