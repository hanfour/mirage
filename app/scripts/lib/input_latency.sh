#!/bin/bash
# 活體量測與故障注入共用的解析及斷言。
source "$(dirname "${BASH_SOURCE[0]}")/gui_session.sh"

input_latency_load_retry() {
    local limit="$1" max="$2" gap="$3" attempt
    for ((attempt=1; attempt<=max; attempt++)); do
        load_gate "$limit" && return 0
        echo "   load_gate 攔下（第 ${attempt}/${max} 次），等 ${gap} 秒後重試本輪"
        sleep "$gap" || return 1
    done
    echo "   重試 ${max} 次仍被 load_gate 擋下，放棄本輪（如實記錄，不湊數）"
    return 1
}

input_latency_wait_load() {
    local limit="$1" timeout="$2" gap="$3" start=$SECONDS elapsed remaining
    while true; do
        elapsed=$((SECONDS - start))
        if load_gate "$limit"; then
            echo "建置後 load_gate 通過，已等 $((SECONDS - start)) 秒（上限 ${timeout} 秒）"
            return 0
        fi
        if [ "$elapsed" -ge "$timeout" ]; then
            echo "建置後 load_gate 等待逾時，已等 ${elapsed} 秒（上限 ${timeout} 秒）"
            return 1
        fi
        remaining=$((timeout - elapsed))
        [ "$gap" -le "$remaining" ] || gap=$remaining
        sleep "$gap" || return 1
    done
}

input_latency_cpu_gate() {
    if ! awk -v v="$1" 'BEGIN { exit !(v ~ /^[0-9]+([.][0-9]+)?$/ && v < 50) }'; then
        echo "FAIL: foreign CPU must be <50%, got $1"
        return 1
    fi
}

# 兩種 floor 使用同一量測窗口；只有 floor 10 參與判定。
input_latency_cpu_window() {
    local a="$1" b="$2" seconds="$3" round="$4" foreign10 foreign0
    foreign10=$(cpu_delta_total "$a" "$b" "$seconds" 'qemu-system|MirageApp|WindowServer' 10)
    foreign0=$(cpu_delta_total "$a" "$b" "$seconds" 'qemu-system|MirageApp|WindowServer' 0)
    echo "[round ${round}] foreign_cpu_floor10=${foreign10}% foreign_cpu_floor0=${foreign0}%"
    input_latency_cpu_gate "$foreign10"
}

# 保留每輪診斷與有效數字，失敗只淘汰當輪。
input_latency_collect() {
    local round="$1" work="$2"
    shift 2
    if "$@" > "$work/result-${round}.log" 2>&1; then
        printf '%s %s %s %s\n' "$INJECT" "$TRANSIT" "$RENDER" "$SUM" >> "$work/rounds.txt"
    else
        echo "[round ${round}] INVALID" >> "$work/rejected.txt"
        cat "$work/result-${round}.log" >> "$work/rejected.txt"
        echo "[round ${round}] INVALID; continuing"
    fi
    cat "$work/result-${round}.log"
}

input_latency_finish() {
    local work="$1" required="$2" valid rc=0
    valid=$(awk 'END { print NR }' "$work/rounds.txt")
    echo "VALID_ROUNDS=$valid REQUIRED_ROUNDS=$required"
    if [ "$valid" -gt 0 ]; then
        input_latency_summary "$work/rounds.txt" "$valid" "$required" || rc=1
    fi
    if [ "$valid" -lt "$required" ]; then
        echo "FAIL: insufficient valid rounds"
        cat "$work/rejected.txt"
        return 1
    fi
    return "$rc"
}

# 缺少欄位或格式錯誤就拒絕，避免 awk 自動轉成零。
input_latency_counts() {
    awk -v tag="$2" '
        $1 == "[app]" && $2 == tag {
            delete f
            for (i=3; i<=NF; i++) { split($i,p,"="); f[p[1]]=p[2] }
            if (f["n"] !~ /^[0-9]+$/) bad=1
            n+=f["n"]; lines++
            if (tag == "transit") {
                if (f["invalid"] !~ /^[0-9]+$/ || f["unavailable"] !~ /^[0-9]+$/) bad=1
                invalid+=f["invalid"]; unavailable+=f["unavailable"]
            }
            if (f["n"]+0 > 0 && (f["p50"] !~ /^[0-9]+([.][0-9]+)?ms$/ ||
                                  f["p95"] !~ /^[0-9]+([.][0-9]+)?ms$/)) bad=1
        }
        END {
            if (bad || !lines) exit 1
            printf "%d %d %d\n", n, invalid, unavailable
        }' "$1"
}

input_latency_round() {
    local log="$1" round="$2" counts inject_n transit_n invalid unavailable render_n
    counts=$(input_latency_counts "$log" inject) || { echo 'FAIL: inject log missing or malformed'; return 1; }
    read -r inject_n _ _ <<< "$counts"
    counts=$(input_latency_counts "$log" transit) || { echo 'FAIL: transit log missing or malformed'; return 1; }
    read -r transit_n invalid unavailable <<< "$counts"
    [ "$inject_n" -ge 30 ] || { echo "FAIL: inject_n=${inject_n} must be >=30"; return 1; }
    [ "$invalid" -eq 0 ] || { echo "FAIL: invalid=${invalid}; clock assumption failed"; return 1; }
    [ "$unavailable" -eq 0 ] || { echo "FAIL: unavailable=${unavailable}; MMAP cannot measure transit"; return 1; }
    [ "$transit_n" -ge 600 ] || { echo "FAIL: transit_n=${transit_n} must be >=600"; return 1; }
    counts=$(input_latency_counts "$log" lat) || { echo 'FAIL: render log missing or malformed'; return 1; }
    read -r render_n _ _ <<< "$counts"
    [ "$render_n" -gt 0 ] || { echo 'FAIL: no render samples'; return 1; }
    INJECT=$(tagged_median "$log" inject p50)
    TRANSIT=$(tagged_median "$log" transit p50)
    RENDER=$(latency_median "$log" p50)
    SUM=$(awk -v i="$INJECT" -v t="$TRANSIT" -v r="$RENDER" 'BEGIN { printf "%.1f", i+t+r }')
    echo "[round ${round}] inject_p50=${INJECT} transit_p50=${TRANSIT} render_p50=${RENDER} sum_p50=${SUM} inject_n=${inject_n} transit_n=${transit_n} invalid=${invalid} unavailable=${unavailable}"
}

input_latency_summary() {
    local rows="$1" summary
    summary=$(awk -v valid="${2:-1}" -v required="${3:-1}" '{ i[NR]=$1; t[NR]=$2; r[NR]=$3; s[NR]=$4 }
        function median(a, n, j,k,v) {
            for(j=1;j<=n;j++) for(k=j+1;k<=n;k++) if(a[k]<a[j]) {v=a[j];a[j]=a[k];a[k]=v}
            return n%2 ? a[(n+1)/2] : (a[n/2]+a[n/2+1])/2
        }
        END {
            if (!NR) exit 1
            im=median(i,NR); tm=median(t,NR); rm=median(r,NR); sm=median(s,NR)
            printf "INJECT_MEDIAN=%.1f\nTRANSIT_MEDIAN=%.1f\nRENDER_MEDIAN=%.1f\nSUM_MEDIAN=%.1f\nSUM_RANGE=%.1f..%.1f\n", im,tm,rm,sm,s[1],s[NR]
            if(sm>=80) {
                largest=(im>=tm && im>=rm) ? "inject" : (tm>=rm ? "transit" : "render")
                print "FAIL: SUM_MEDIAN must be <80ms; largest segment=" largest
                exit 1
            }
            if(valid>=required) print "PASS: acceptance 2 controllable segments <80ms"
        }' "$rows")
    local rc=$?
    printf '%s\n' "$summary"
    return "$rc"
}
