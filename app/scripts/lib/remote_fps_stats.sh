#!/usr/bin/env bash
# 遙控 fps 對照的純解析：stdin 或字串輸入，不查裝置／時鐘。
set -uo pipefail

remote_median_of() { printf '%b' "$1" | awk 'NF' | sort -n | awk '{ v[NR]=$1 } END { if (NR) print v[int((NR+1)/2)] }'; }
remote_list_of() { printf '%b' "$1" | awk 'NF' | sort -n | tr '\n' ' ' | sed 's/ $//'; }
remote_min_of() { printf '%b' "$1" | awk 'NF' | sort -n | head -1; }
remote_max_of() { printf '%b' "$1" | awk 'NF' | sort -n | tail -1; }

# 只採計有尺寸收斂、有效輪次的摘要。拒絕重複／缺欄位，不將缺值當零。
remote_arm_summary() {
    awk -F= '
        /^MIRAGE_MEDIAN=/ { m=$2; mc++ }
        /^ROUNDS=/ { r=$2; rc++ }
        /^SIZE_OK=/ { s=$2; sc++ }
        END {
            if (mc != 1 || rc != 1 || sc != 1 || m !~ /^[0-9]+$/ ||
                r !~ /^[0-9]+$/ || r+0 < 1 || s != "1") exit 1
            print m, r
        }'
}

# 值域交集長度，嚴格大於容忍值才警告；相接或零寬度不算。
remote_ranges_overlap() {
    local off_min off_max on_min on_max
    off_min=$(remote_min_of "$1"); off_max=$(remote_max_of "$1")
    on_min=$(remote_min_of "$2"); on_max=$(remote_max_of "$2")
    [ -n "$off_min" ] && [ -n "$on_min" ] || return 1
    awk -v a="$off_min" -v b="$off_max" -v c="$on_min" -v d="$on_max" -v t="$3" \
        'BEGIN { lo=(a>c?a:c); hi=(b<d?b:d); exit !(hi-lo > t) }'
}

# viewer 每秒記錄一筆收幀時間。窗口兩端容許 2 秒，內部間隔最多 3 秒；
# 403／409、只連上沒收幀、半途斷線或靜止都不能冒充「有編碼負載」。
remote_viewer_window_ok() {
    awk -F= -v start="$1" -v end="$2" '
        /^LOOP_FRAME=[0-9]+$/ && $2 >= start-2 && $2 <= end {
            if (!n) first=$2
            if (n && $2-last > 3) bad=1
            last=$2; n++
        }
        /^LOOP_DISCONNECTED=[0-9]+$/ && $2 >= start && $2 <= end { bad=1 }
        END { exit !(end>=start && n>=2 && first<=start+2 && last>=end-2 && !bad) }'
}
