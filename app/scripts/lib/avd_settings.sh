#!/usr/bin/env bash
# AVD 設定 GUI 驗證器共用的純解析與判斷函式。

AVD_SETTINGS_MEM_MIN_KB=2400000
AVD_SETTINGS_MEM_MAX_KB=3100000
# 3072 MiB gives 3,145,728 KiB. The 2,400,000–3,100,000 kB MemTotal window allows
# roughly 45–728 MiB for the Android kernel and device reservations.

avd_settings_override_value() {
    local override="${1:-}" wanted="${2:-}" pair key
    local -a fields=()
    IFS=';' read -r -a fields <<< "${override}"
    for pair in "${fields[@]}"; do
        key="${pair%%=*}"
        if [ "${key}" = "${wanted}" ] && [ "${pair}" != "${key}" ]; then
            printf '%s\n' "${pair#*=}"
            return 0
        fi
    done
    return 1
}

avd_settings_wm_physical_size() {
    printf '%s\n' "${1:-}" | awk '
        /^Physical size:[[:space:]]*[0-9]+x[0-9]+[[:space:]]*$/ {
            sub(/^Physical size:[[:space:]]*/, "")
            sub(/[[:space:]]*$/, "")
            print
            found = 1
            exit
        }
        END { if (!found) exit 1 }
    '
}

avd_settings_wm_size_matches() {
    local actual
    actual=$(avd_settings_wm_physical_size "${1:-}") || return 1
    [ "${actual}" = "${2:-}" ]
}

avd_settings_cpu_count() {
    local output="${1:-}" first
    first=$(printf '%s\n' "${output}" | awk 'NF { print $1; exit }')
    case "${first}" in
        ''|*[!0-9]*) ;;
        *) printf '%s\n' "${first}"; return 0 ;;
    esac
    printf '%s\n' "${output}" | awk '
        /^[[:space:]]*processor[[:space:]]*:/ { count++ }
        END { if (count > 0) print count; else exit 1 }
    '
}

avd_settings_cpu_count_matches() {
    local actual
    actual=$(avd_settings_cpu_count "${1:-}") || return 1
    [ "${actual}" = "${2:-}" ]
}

avd_settings_memtotal_kb() {
    printf '%s\n' "${1:-}" | awk '
        /^MemTotal:[[:space:]]*[0-9]+[[:space:]]+kB([[:space:]]*)?$/ {
            print $2
            found = 1
            exit
        }
        END { if (!found) exit 1 }
    '
}

avd_settings_memtotal_in_range() {
    local total
    total=$(avd_settings_memtotal_kb "${1:-}") || return 1
    [ "${total}" -ge "${AVD_SETTINGS_MEM_MIN_KB}" ] \
        && [ "${total}" -le "${AVD_SETTINGS_MEM_MAX_KB}" ]
}

avd_settings_running_count() {
    [ -r "${1:-}" ] || return 1
    awk '/^\[launcher\].*--> running([[:space:]]|$)/ { count++ }
         END { print count + 0 }' "${1}"
}

avd_settings_has_restart_sequence() {
    [ -r "${1:-}" ] || return 1
    awk '
        /^\[launcher\].*--> running([[:space:]]|$)/ {
            if (firstRunning == 0) firstRunning = NR
            else if (secondRunning == 0) secondRunning = NR
        }
        /^\[settings\] applied .* restart=yes$/ && applied == 0 { applied = NR }
        END { exit !(firstRunning > 0 && applied > firstRunning && secondRunning > applied) }
    ' "${1}"
}

avd_settings_has_applied() {
    [ -r "${1:-}" ] || return 1
    awk -v cores="${2:-}" -v ram="${3:-}" -v resolution="${4:-}" -v restart="${5:-}" '
        $0 == "[settings] applied cores=" cores " ramMB=" ram " resolution=" resolution " restart=" restart {
            found = 1
        }
        END { exit !found }
    ' "${1}"
}

avd_settings_has_read_only() {
    local log="${1:-}" avd_directory="${2:-}"
    [ -r "${log}" ] && [ -n "${avd_directory}" ] || return 1
    grep -F -x -q "[settings] read-only ${avd_directory}" "${log}"
}

avd_settings_has_no_applied() {
    [ -r "${1:-}" ] || return 1
    ! grep -F -q '[settings] applied ' "${1}"
}

avd_settings_config_value() {
    local file="${1:-}" wanted="${2:-}"
    [ -r "${file}" ] || return 1
    awk -v wanted="${wanted}" '
        {
            line = $0
            sub(/^[[:space:]]*/, "", line)
            if (line == "" || line ~ /^#/) next
            equals = index(line, "=")
            if (equals == 0) next
            key = substr(line, 1, equals - 1)
            value = substr(line, equals + 1)
            sub(/[[:space:]]*$/, "", key)
            sub(/^[[:space:]]*/, "", value)
            sub(/[[:space:]]*$/, "", value)
            if (key == wanted) { result = value; found = 1 }
        }
        END { if (found) print result; else exit 1 }
    ' "${file}"
}

avd_settings_config_matches() {
    local file="${1:-}" cores="${2:-}" ram="${3:-}" width="${4:-}" height="${5:-}" density="${6:-}"
    [ "$(avd_settings_config_value "${file}" 'hw.cpu.ncore')" = "${cores}" ] || return 1
    [ "$(avd_settings_config_value "${file}" 'hw.ramSize')" = "${ram}" ] || return 1
    [ "$(avd_settings_config_value "${file}" 'hw.lcd.width')" = "${width}" ] || return 1
    [ "$(avd_settings_config_value "${file}" 'hw.lcd.height')" = "${height}" ] || return 1
    [ "$(avd_settings_config_value "${file}" 'hw.lcd.density')" = "${density}" ]
}
