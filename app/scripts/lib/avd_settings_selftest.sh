#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/avd_settings.sh"
FAILURES=0

expect_success() {
    local label="$1"
    shift
    if "$@"; then
        echo "✅ ${label}"
    else
        echo "❌ ${label}"
        FAILURES=$((FAILURES + 1))
    fi
}

expect_failure() {
    local label="$1"
    shift
    if "$@"; then
        echo "❌ ${label}（錯誤輸入被接受）"
        FAILURES=$((FAILURES + 1))
    else
        echo "✅ ${label}"
    fi
}

test_override_parse() {
    [ "$(avd_settings_override_value 'cores=2;ramMB=3072;resolution=720x1600' cores)" = 2 ] \
        && [ "$(avd_settings_override_value 'cores=2;ramMB=3072;resolution=720x1600' resolution)" = 720x1600 ]
}

test_override_missing() {
    avd_settings_override_value 'cores=2;ramMB=3072' resolution
}

test_wm_parse() {
    avd_settings_wm_size_matches $'Physical size: 720x1600\nOverride size: 1080x2400' 720x1600
}

test_wm_mismatch() {
    avd_settings_wm_size_matches 'Physical size: 1080x2400' 720x1600
}

test_cpu_nproc() {
    avd_settings_cpu_count_matches '2' 2
}

test_cpuinfo_parse() {
    avd_settings_cpu_count_matches $'processor : 0\nBogoMIPS : 38\nprocessor : 1' 2
}

test_cpu_mismatch() {
    avd_settings_cpu_count_matches '4' 2
}

test_running_count() {
    local log count
    log=$(mktemp)
    printf '%s\n' '[launcher] mirage-game --> running' '[launcher] mirage-game --> running' > "${log}"
    count="$(avd_settings_running_count "${log}")"
    rm -f "${log}"
    [ "${count}" = 2 ]
}

test_running_count_zero() {
    local log count
    log=$(mktemp)
    printf '%s\n' '[launcher] mirage-game --> booting' > "${log}"
    count="$(avd_settings_running_count "${log}")"
    rm -f "${log}"
    [ "${count}" = 0 ]
}

test_mem_in_range() {
    avd_settings_memtotal_in_range 'MemTotal:       2800000 kB'
}

test_mem_too_low() {
    avd_settings_memtotal_in_range 'MemTotal:       2200000 kB'
}

test_mem_too_high() {
    avd_settings_memtotal_in_range 'MemTotal:       3200000 kB'
}

test_mem_missing() {
    avd_settings_memtotal_in_range 'MemFree:       2800000 kB'
}

test_applied_match() {
    local log
    log=$(mktemp)
    printf '%s\n' '[settings] applied cores=2 ramMB=3072 resolution=720x1600@280 restart=yes' > "${log}"
    avd_settings_has_applied "${log}" 2 3072 720x1600@280 yes
    local status=$?
    rm -f "${log}"
    return "${status}"
}

test_applied_mismatch() {
    local log
    log=$(mktemp)
    printf '%s\n' '[settings] applied cores=4 ramMB=3072 resolution=720x1600@280 restart=yes' > "${log}"
    avd_settings_has_applied "${log}" 2 3072 720x1600@280 yes
    local status=$?
    rm -f "${log}"
    return "${status}"
}

test_read_only_match() {
    local log
    log=$(mktemp)
    printf '%s\n' '[settings] read-only /avd/mirage-game.avd' > "${log}"
    avd_settings_has_read_only "${log}" /avd/mirage-game.avd
    local status=$?
    rm -f "${log}"
    return "${status}"
}

test_read_only_mismatch() {
    local log
    log=$(mktemp)
    printf '%s\n' '[settings] read-only /avd/other.avd' > "${log}"
    avd_settings_has_read_only "${log}" /avd/mirage-game.avd
    local status=$?
    rm -f "${log}"
    return "${status}"
}

test_no_applied() {
    local log
    log=$(mktemp)
    printf '%s\n' '[launcher] mirage-game --> running' > "${log}"
    avd_settings_has_no_applied "${log}"
    local status=$?
    rm -f "${log}"
    return "${status}"
}

test_applied_present() {
    local log
    log=$(mktemp)
    printf '%s\n' '[settings] applied cores=2 ramMB=3072 resolution=720x1600@280 restart=no' > "${log}"
    avd_settings_has_no_applied "${log}"
    local status=$?
    rm -f "${log}"
    return "${status}"
}

test_restart_sequence() {
    local log
    log=$(mktemp)
    printf '%s\n' '[launcher] mirage-game --> running' '[settings] applied cores=2 ramMB=3072 resolution=720x1600@280 restart=yes' '[launcher] mirage-game --> running' > "${log}"
    avd_settings_has_restart_sequence "${log}"
    local status=$?
    rm -f "${log}"
    return "${status}"
}

test_restart_sequence_missing() {
    local log
    log=$(mktemp)
    printf '%s\n' '[launcher] mirage-game --> running' '[settings] applied cores=2 ramMB=3072 resolution=720x1600@280 restart=yes' > "${log}"
    avd_settings_has_restart_sequence "${log}"
    local status=$?
    rm -f "${log}"
    return "${status}"
}

test_config_match() {
    local config
    config=$(mktemp)
    printf '%s\n' 'hw.cpu.ncore = 2' 'hw.ramSize=3072' 'hw.lcd.width = 720' 'hw.lcd.height=1600' 'hw.lcd.density = 280' > "${config}"
    avd_settings_config_matches "${config}" 2 3072 720 1600 280
    local status=$?
    rm -f "${config}"
    return "${status}"
}

test_config_mismatch() {
    local config
    config=$(mktemp)
    printf '%s\n' 'hw.cpu.ncore = 4' 'hw.ramSize=3072' 'hw.lcd.width = 720' 'hw.lcd.height=1600' 'hw.lcd.density = 280' > "${config}"
    avd_settings_config_matches "${config}" 2 3072 720 1600 280
    local status=$?
    rm -f "${config}"
    return "${status}"
}

test_config_missing() {
    local config
    config=$(mktemp)
    printf '%s\n' 'hw.cpu.ncore = 2' 'hw.ramSize=3072' > "${config}"
    avd_settings_config_matches "${config}" 2 3072 720 1600 280
    local status=$?
    rm -f "${config}"
    return "${status}"
}

expect_success "覆寫欄位解析" test_override_parse
expect_failure "覆寫缺欄位反例" test_override_missing
expect_success "wm size 解析" test_wm_parse
expect_failure "wm size 尺寸反例" test_wm_mismatch
expect_success "nproc 解析" test_cpu_nproc
expect_success "cpuinfo fallback 解析" test_cpuinfo_parse
expect_failure "CPU 數量反例" test_cpu_mismatch
expect_success "launcher running 次數解析" test_running_count
expect_success "沒有 running 的次數解析" test_running_count_zero
expect_success "MemTotal 範圍解析" test_mem_in_range
expect_failure "MemTotal 低於範圍反例" test_mem_too_low
expect_failure "MemTotal 高於範圍反例" test_mem_too_high
expect_failure "MemTotal 缺值反例" test_mem_missing
expect_success "applied log 精確比對" test_applied_match
expect_failure "applied log 欄位反例" test_applied_mismatch
expect_success "read-only log 與路徑比對" test_read_only_match
expect_failure "read-only 路徑反例" test_read_only_mismatch
expect_success "未套用 log 判斷" test_no_applied
expect_failure "已套用 log 反例" test_applied_present
expect_success "重啟前後 running 順序解析" test_restart_sequence
expect_failure "缺少第二次 running 反例" test_restart_sequence_missing
expect_success "config 欄位完整比對" test_config_match
expect_failure "config 欄位值反例" test_config_mismatch
expect_failure "config 缺欄位反例" test_config_missing

if [ "${FAILURES}" -ne 0 ]; then
    echo "❌ avd_settings 自我測試：${FAILURES} 項失敗"
    exit 1
fi
echo "✅ avd_settings 自我測試通過"
