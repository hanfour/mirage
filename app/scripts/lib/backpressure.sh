#!/usr/bin/env bash
# guest 回壓量測共用的純函式。
# 用法：source "$(dirname "$0")/lib/backpressure.sh"

# 依輪次把逗號分隔的條件向左輪轉。第 1 輪從原始順序開始。
rotate_conditions() {
    local round="$1" list="$2"
    local -a conditions
    local count offset index i output

    case "${round}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    if [ "${round}" -lt 1 ]; then
        return 1
    fi

    IFS=',' read -r -a conditions <<< "${list}"
    count=${#conditions[@]}
    if [ "${count}" -eq 0 ] || [ -z "${conditions[0]}" ]; then
        return 1
    fi

    offset=$(( (round - 1) % count ))
    output=""
    for ((i = 0; i < count; i++)); do
        index=$(( (offset + i) % count ))
        if [ "${i}" -gt 0 ]; then
            output="${output},"
        fi
        output="${output}${conditions[${index}]}"
    done
    printf '%s\n' "${output}"
}

# 從一組以換行或 \n 分隔的數字取下位中位數，沒有資料時印空字串。
backpressure_median() {
    printf '%b\n' "$1" | awk '
        $1 ~ /^[0-9]+([.][0-9]+)?$/ { values[++n] = $1 + 0 }
        END {
            if (!n) { exit }
            for (i = 1; i <= n; i++) {
                for (j = i + 1; j <= n; j++) {
                    if (values[j] < values[i]) {
                        temp = values[i]
                        values[i] = values[j]
                        values[j] = temp
                    }
                }
            }
            printf "%.1f\n", values[int((n + 1) / 2)]
        }'
}

# 計算以換行或 \n 分隔的有效樣本數。
backpressure_count() {
    printf '%b\n' "$1" | awk '$1 ~ /^[0-9]+([.][0-9]+)?$/ { count++ } END { print count + 0 }'
}

# 印 A 的中位數減 B 的中位數；任一側沒有有效樣本時印「無資料」。
median_delta() {
    local median_a median_b
    median_a=$(backpressure_median "$1")
    median_b=$(backpressure_median "$2")
    if [ -z "${median_a}" ] || [ -z "${median_b}" ]; then
        echo "無資料"
        return 0
    fi
    awk -v a="${median_a}" -v b="${median_b}" 'BEGIN { printf "%.1f\n", a - b }'
}

# 對 cpu_delta_report 的輸出按行程 regex 加總，沒有命中時印 0.0。
backpressure_cpu_total() {
    printf '%s\n' "$1" | awk -v pattern="$2" \
        '$0 ~ pattern { total += $1 } END { printf "%.1f\n", total + 0 }'
}

# 回傳無效原因；空字串代表樣本有效。guest 的缺資料優先於 foreign 污染。
backpressure_invalid_reason() {
    local guest="$1" foreign="$2" foreign_max="$3"
    if [ -z "${guest}" ]; then
        echo "guest"
        return 0
    fi
    if ! awk -v foreign="${foreign}" -v limit="${foreign_max}" '
        BEGIN {
            valid = foreign ~ /^[0-9]+([.][0-9]+)?$/ \
                && limit ~ /^[0-9]+([.][0-9]+)?$/ \
                && (foreign + 0) <= (limit + 0)
            exit !valid
        }'; then
        echo "foreign"
    fi
}
