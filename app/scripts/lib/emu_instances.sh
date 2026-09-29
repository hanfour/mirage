#!/usr/bin/env bash
# emu.sh 的實例表與純函式層。用法：source "$(dirname "$0")/lib/emu_instances.sh"
#
# 除了載入共用 instances.conf，不呼叫 pgrep、lsof、adb。emu.sh 把真實的
# `pgrep -fl qemu-system` 輸出餵進來，emu_selftest.sh 餵假的。
#
# 一台實例由三個值決定：AVD 名稱、console 埠（5554、5556、……偶數）、gRPC 埠。
# 實例名稱就是 AVD 名稱：規格 §3.1 要求每台各自一個 AVD，所以名稱與 AVD 一對一，
# 不需要第四個識別字。

# 預設實例表來自 MirageCore 的 bundle 資源。MIRAGE_INSTANCES_FILE 只供測試注入路徑。
if [ "${MIRAGE_INSTANCES_FILE+x}" = x ]; then
    EMU_INSTANCES_PATH="$MIRAGE_INSTANCES_FILE"
else
    EMU_INSTANCES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../Sources/MirageCore/Resources" && pwd)" || {
        echo "❌ 無法定位 instances.conf" >&2
        return 1
    }
    EMU_INSTANCES_PATH="${EMU_INSTANCES_DIR}/instances.conf"
fi
if [ ! -r "$EMU_INSTANCES_PATH" ]; then
    echo "❌ 無法讀取實例表：${EMU_INSTANCES_PATH}" >&2
    return 1
fi
EMU_DEFAULT_INSTANCES="$(awk '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    {
        row = $0
        sub(/^[[:space:]]+/, "", row)
        sub(/[[:space:]]+$/, "", row)
        printf "%s%s", separator, row
        separator = " "
    }
' "$EMU_INSTANCES_PATH")" || {
    echo "❌ 讀取實例表失敗：${EMU_INSTANCES_PATH}" >&2
    return 1
}

# 三元組驗證。console 埠必須是 5554–5682 的偶數（emulator -port 的限制，奇數是 adb 埠）。
emu_decimal_value() {
    local value="$1"
    while [ "${value#0}" != "$value" ]; do value="${value#0}"; done
    printf '%s' "${value:-0}"
}

emu_validate_triplet() {
    local avd="$1" port="$2" grpc="$3" port_value grpc_value
    if [ -z "$avd" ]; then
        echo "❌ 實例表項目缺 AVD 名稱" >&2; return 1
    fi
    case "$port" in
        ''|*[!0-9]*) echo "❌ ${avd}：console 埠 '${port}' 不是整數" >&2; return 1 ;;
    esac
    port_value="$(emu_decimal_value "$port")"
    if [ "${#port_value}" -gt 5 ]; then
        echo "❌ ${avd}：console 埠 ${port} 必須是 5554–5682 的偶數" >&2; return 1
    fi
    port_value=$((10#$port_value))
    if [ "$port_value" -lt 5554 ] || [ "$port_value" -gt 5682 ] || [ $((port_value % 2)) -ne 0 ]; then
        echo "❌ ${avd}：console 埠 ${port} 必須是 5554–5682 的偶數" >&2; return 1
    fi
    case "$grpc" in
        ''|*[!0-9]*) echo "❌ ${avd}：gRPC 埠 '${grpc}' 不是整數" >&2; return 1 ;;
    esac
    grpc_value="$(emu_decimal_value "$grpc")"
    if [ "${#grpc_value}" -gt 5 ]; then
        echo "❌ ${avd}：gRPC 埠 ${grpc} 不在 1–65535" >&2; return 1
    fi
    grpc_value=$((10#$grpc_value))
    if [ "$grpc_value" -lt 1 ] || [ "$grpc_value" -gt 65535 ]; then
        echo "❌ ${avd}：gRPC 埠 ${grpc} 不在 1–65535" >&2; return 1
    fi
    return 0
}

# emu_resolve <名稱> [實例表] → stdout "avd console grpc"；找不到回 1。
emu_resolve() {
    local name="$1" table="${2:-$EMU_DEFAULT_INSTANCES}" entry avd port grpc
    for entry in $table; do
        IFS=: read -r avd port grpc <<< "$entry"
        [ "$avd" = "$name" ] || continue
        emu_validate_triplet "$avd" "${port:-}" "${grpc:-}" || return 1
        printf '%s %s %s\n' "$avd" "$port" "$grpc"
        return 0
    done
    echo "❌ 未知的實例名稱：${name}。可用：$(emu_names "$table")" >&2
    return 1
}

# emu_select_triplet <名稱或空字串> [表格] [AVD覆寫] [console覆寫] [gRPC覆寫]
# 空名稱代表未帶 -n：選第一台，再套用非空覆寫；具名時只使用表格。
# 不讀環境，呼叫端負責傳 MIRAGE_* 並提醒被忽略的覆寫。失敗回 1。
emu_select_triplet() {
    local name="${1:-}" table="${2:-$EMU_DEFAULT_INSTANCES}" entry triplet avd port grpc
    emu_table_check "$table" || return 1
    if [ -n "$name" ]; then
        emu_resolve "$name" "$table"
        return $?
    fi
    for entry in $table; do
        name="${entry%%:*}"
        break
    done
    if [ -z "$name" ]; then echo "❌ 實例表不能是空白" >&2; return 1; fi
    triplet=$(emu_resolve "$name" "$table") || return 1
    read -r avd port grpc <<< "$triplet"
    avd="${3:-$avd}"; port="${4:-$port}"; grpc="${5:-$grpc}"
    emu_validate_triplet "$avd" "$port" "$grpc" || return 1
    printf '%s %s %s\n' "$avd" "$port" "$grpc"
}

# 列出表格裡的名稱（給錯誤訊息用）。
emu_names() {
    local entry names=""
    for entry in $1; do
        names="${names}${names:+, }${entry%%:*}"
    done
    printf '%s\n' "$names"
}

# emu_table_check [實例表] → AVD／console 埠／gRPC 埠任一重複，或任一三元組無效，回 1。
emu_table_check() {
    local table="${1-$EMU_DEFAULT_INSTANCES}" entry avd port grpc port_value grpc_value has_entry=0
    local avds="" ports="" grpcs=""
    for entry in $table; do
        has_entry=1
        IFS=: read -r avd port grpc <<< "$entry"
        emu_validate_triplet "${avd:-}" "${port:-}" "${grpc:-}" || return 1
        port_value="$(emu_decimal_value "$port")"
        grpc_value="$(emu_decimal_value "$grpc")"
        case " $avds " in *" $avd "*) echo "❌ 實例表裡 AVD ${avd} 出現兩次；每台要各自一個 AVD" >&2; return 1 ;; esac
        case " $ports " in *" $port_value "*) echo "❌ 實例表裡 console 埠 ${port} 出現兩次" >&2; return 1 ;; esac
        case " $grpcs " in *" $grpc_value "*) echo "❌ 實例表裡 gRPC 埠 ${grpc} 出現兩次" >&2; return 1 ;; esac
        avds="$avds $avd"; ports="$ports $port_value"; grpcs="$grpcs $grpc_value"
    done
    if [ "$has_entry" -eq 0 ]; then
        echo "❌ 實例表不能是空白" >&2
        return 1
    fi
    return 0
}

# emu_running_instances "<pgrep -fl qemu-system 的輸出>" → 每台一行 "pid avd console grpc window"，
# window 欄為 windowed／headless，由執行檔名或完整 -no-window 參數判斷。
# 依 console 埠排序；沒帶 -grpc 的行程 grpc 欄印 `?`（那是隨機埠，Mirage 連不上）。
# 只認含 qemu-system 且有 -port 的行——pgrep -f 比對的是整條命令列，別的行程也可能提到埠號。
emu_running_instances() {
    printf '%s\n' "$1" | awk '
        /qemu-system/ {
            pid = $1; avd = "?"; port = ""; grpc = "?"
            window = ($2 ~ /(^|\/)qemu-system-aarch64-headless$/) ? "headless" : "windowed"
            for (i = 2; i <= NF; i++) {
                if ($i == "-no-window") window = "headless"
                if ($i == "-avd")  avd  = $(i + 1)
                if ($i == "-port") port = $(i + 1)
                if ($i == "-grpc") grpc = $(i + 1)
            }
            if (port != "") print pid, avd, port, grpc, window
        }' | sort -k3,3n
}

# emu_is_running "<pgrep 輸出>" <console 埠> → 該埠有 qemu 在跑回 0。
# 比對整個欄位，不是子字串：555 不會匹配 5554。
emu_is_running() {
    emu_running_instances "$1" | awk -v p="$2" '$3 == p { found = 1 } END { exit !found }'
}

# emu_avd_conflict "<pgrep 輸出>" <avd> <console 埠> → 同名 AVD 在別的埠上跑時回 0 並印那個埠。
# 同一個埠不算衝突（那是「已在執行」，由 emu_is_running 處理）。
emu_avd_conflict() {
    emu_running_instances "$1" | awk -v a="$2" -v p="$3" '
        $2 == a && $3 != p { print $3; found = 1 }
        END { exit !found }'
}

# emu_should_disable_soft_keyboard <目前 secure 設定值> → 需要 put 0 時回 0。
# adb 的 CR 由呼叫端去除；null／空值也要套用。
emu_should_disable_soft_keyboard() {
    [ "$1" != "0" ]
}
