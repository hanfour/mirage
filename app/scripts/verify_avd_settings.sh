#!/usr/bin/env bash
# 驗證 AVD 設定套用、managed restart、guest 資源與開發機唯讀保護。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/gui_session.sh"
source "${SCRIPT_DIR}/lib/verify_common.sh"
source "${SCRIPT_DIR}/lib/first_run.sh"
source "${SCRIPT_DIR}/lib/avd_settings.sh"
cd "${APP_DIR}" || exit 1

ROUNDS=2
KEEP=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --rounds)
            [ "$#" -ge 2 ] || { echo "用法：${BASH_SOURCE[0]} [--rounds N] [--keep]" >&2; exit 2; }
            ROUNDS="$2"
            shift 2
            ;;
        --keep)
            KEEP=1
            shift
            ;;
        -h|--help)
            echo "用法：${BASH_SOURCE[0]} [--rounds N] [--keep]"
            exit 0
            ;;
        *) echo "不認得的參數：$1" >&2; exit 2 ;;
    esac
done
case "${ROUNDS}" in
    ''|*[!0-9]*|0) echo "--rounds 必須是大於零的整數：${ROUNDS}" >&2; exit 2 ;;
esac

if pgrep -x MirageApp >/dev/null 2>&1; then
    echo "❌ 前置檢查失敗：MirageApp 正在執行。請先自行結束；腳本不會替你關閉。"
    pgrep -alf MirageApp || true
    exit 1
fi
INITIAL_QEMU="$(pgrep -fl '[q]emu' 2>/dev/null || true)"
if [ -n "${INITIAL_QEMU}" ]; then
    echo "❌ 前置檢查失敗：偵測到 qemu 行程。請先自行停止；腳本不會替你關閉。"
    echo "${INITIAL_QEMU}"
    exit 1
fi

export ANDROID_SDK_ROOT="${HOME}/Library/Android/sdk"
unset ANDROID_HOME
ADB="${ANDROID_SDK_ROOT}/platform-tools/adb"
require_adb
SERIAL="emulator-5554"
export ANDROID_SERIAL="${SERIAL}"
PRIMARY_AVD_NAME="mirage-game"
SETTINGS_OVERRIDE='cores=2;ramMB=3072;resolution=720x1600'
# 開發機空間不足以滿足 emulator 預設分割區（8 GiB）首次建立時約 9.8 GB 的需求；縮小分割區不影響 CPU、記憶體或解析度驗證。
# 值是 6 GiB 而不是更小：2026-09-30 實測設 2 GiB 時，emulator 開機後把 config.ini 改回 6442450944，
# 並回報 need 7372.80 MB（= 6144 MiB × 1.2），推斷 Play 映像要求的最小分割區是 6 GiB。設更小等於沒設。
TEST_DATA_PARTITION_BYTES=6442450944
DATA_PARTITION_SIZE_KEY='disk.dataPartition.size'
EXPECTED_CORES="$(avd_settings_override_value "${SETTINGS_OVERRIDE}" cores)"
EXPECTED_RAM_MB="$(avd_settings_override_value "${SETTINGS_OVERRIDE}" ramMB)"
EXPECTED_RESOLUTION="$(avd_settings_override_value "${SETTINGS_OVERRIDE}" resolution)"
EXPECTED_WIDTH="${EXPECTED_RESOLUTION%x*}"
EXPECTED_HEIGHT="${EXPECTED_RESOLUTION#*x}"
EXPECTED_DENSITY=280
MARKER_FILENAME="$(sed -nE 's/^[[:space:]]*public static let managedMarkerFilename = "([^"]+)"/\1/p' \
    "${APP_DIR}/Sources/MirageCore/Settings/AvdSettings.swift")"
if [ -z "${MARKER_FILENAME}" ]; then
    echo "❌ 從 AvdSettings.swift 找不到 managed marker 常數"
    exit 1
fi
DEVELOPER_AVD_DIRECTORY="${HOME}/.android/avd/${PRIMARY_AVD_NAME}.avd"
DEVELOPER_CONFIG="${DEVELOPER_AVD_DIRECTORY}/config.ini"
if [ ! -r "${DEVELOPER_CONFIG}" ]; then
    echo "❌ 找不到開發機 AVD 設定檔：${DEVELOPER_CONFIG}"
    exit 1
fi

sha1_file() {
    shasum -a 1 "$1" | awk '{ print $1 }'
}

INITIAL_DEVELOPER_SHA1="$(sha1_file "${DEVELOPER_CONFIG}")"
WORK="$(mktemp -d -t mirage_avd_settings)" || exit 1
LOG_DIR="${WORK}/logs"
mkdir -p "${LOG_DIR}"
cp "${DEVELOPER_CONFIG}" "${WORK}/developer-config.initial"
FAILURES=0
RESULT_LABELS=()
RESULT_STATUS=()
RESULT_DETAILS=()
BUILD_READY=0
ACTIVE_BUNDLE=""
LAST_WM_OUTPUT=""
LAST_CPU_OUTPUT=""
LAST_MEM_OUTPUT=""

record_result() {
    local label="$1" status="$2" details="$3"
    RESULT_LABELS+=("${label}")
    RESULT_STATUS+=("${status}")
    RESULT_DETAILS+=("${details}")
    if [ "${status}" != PASS ]; then FAILURES=$((FAILURES + 1)); fi
    echo "[${label}] ${status}${details:+：${details}}"
}

# launcher 的 running 由 gRPC getStatus().booted 判定；重新啟動後 adb 要再過幾秒才會重新連上新行程。
# 2026-09-30 實測：running 之後立刻查，wm size 得到 "device offline"、下一項得到 "not found"，
# 稍後的查詢才成功（同一輪 CPU 與記憶體通過、較早的 wm size 失敗）。所以查 guest 前先等 adb 回報開機完成。
wait_for_guest_adb() {
    local timeout="$1" started="$SECONDS" value
    while [ $((SECONDS - started)) -lt "${timeout}" ]; do
        value="$("${ADB}" -s "${SERIAL}" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" || true
        if [ "${value}" = "1" ]; then
            GUEST_ADB_WAIT=$((SECONDS - started))
            return 0
        fi
        sleep 2
    done
    GUEST_ADB_WAIT=$((SECONDS - started))
    return 1
}

wait_for_running_count() {
    local log="$1" expected="$2" timeout="$3" started="$SECONDS" count
    while [ "$((SECONDS - started))" -lt "${timeout}" ]; do
        count="$(avd_settings_running_count "${log}" 2>/dev/null || printf '0')"
        if [ "${count}" -ge "${expected}" ]; then return 0; fi
        if ! pgrep -x MirageApp >/dev/null 2>&1; then return 1; fi
        sleep 1
    done
    count="$(avd_settings_running_count "${log}" 2>/dev/null || printf '0')"
    [ "${count}" -ge "${expected}" ]
}

wait_for_applied() {
    local log="$1" mode="$2" timeout="$3" started="$SECONDS"
    while [ "$((SECONDS - started))" -lt "${timeout}" ]; do
        if avd_settings_has_applied "${log}" "${EXPECTED_CORES}" "${EXPECTED_RAM_MB}" \
            "${EXPECTED_RESOLUTION}@${EXPECTED_DENSITY}" "${mode}"; then
            return 0
        fi
        if ! pgrep -x MirageApp >/dev/null 2>&1; then return 1; fi
        sleep 1
    done
    avd_settings_has_applied "${log}" "${EXPECTED_CORES}" "${EXPECTED_RAM_MB}" \
        "${EXPECTED_RESOLUTION}@${EXPECTED_DENSITY}" "${mode}"
}

wait_for_read_only() {
    local log="$1" avd_directory="$2" timeout="$3" started="$SECONDS"
    while [ "$((SECONDS - started))" -lt "${timeout}" ]; do
        if avd_settings_has_read_only "${log}" "${avd_directory}"; then return 0; fi
        if ! pgrep -x MirageApp >/dev/null 2>&1; then return 1; fi
        sleep 1
    done
    avd_settings_has_read_only "${log}" "${avd_directory}"
}

wait_for_no_qemu() {
    local timeout="$1" started="$SECONDS"
    while [ "$((SECONDS - started))" -lt "${timeout}" ]; do
        if ! pgrep -fl '[q]emu' >/dev/null 2>&1; then return 0; fi
        sleep 1
    done
    ! pgrep -fl '[q]emu' >/dev/null 2>&1
}

start_app() {
    local log="$1" bundle="$2" avd_home="$3"
    shift 3
    ACTIVE_BUNDLE="${bundle}"
    export ANDROID_SDK_ROOT ANDROID_AVD_HOME="${avd_home}"
    unset ANDROID_HOME MIRAGE_HOST MIRAGE_PORT MIRAGE_AVD MIRAGE_GRPC MIRAGE_SETUP_DATA_PARTITION_BYTES
    if [ "${BUILD_READY}" -eq 1 ]; then
        export MIRAGE_SKIP_BUILD=1
    else
        unset MIRAGE_SKIP_BUILD
    fi
    if gui_session_start "${log}" "${bundle}" "" "$@"; then
        BUILD_READY=1
        return 0
    fi
    return 1
}

focus_mirage() {
    osascript -e 'tell application "System Events" to set frontmost of process "MirageApp" to true' \
        >/dev/null 2>&1
}

quit_app() {
    local status=0 elapsed=0 bundle="${ACTIVE_BUNDLE}"
    if pgrep -x MirageApp >/dev/null 2>&1; then
        focus_mirage || status=1
        osascript -l JavaScript "${SCRIPT_DIR}/lib/cgkey.js" 12 1048576 >/dev/null 2>&1 || status=1
        while [ "${elapsed}" -lt 30 ] && pgrep -x MirageApp >/dev/null 2>&1; do
            sleep 1
            elapsed=$((elapsed + 1))
        done
        if pgrep -x MirageApp >/dev/null 2>&1; then
            echo "❌ MirageApp 沒有在 ⌘Q 後結束"
            status=1
        fi
    fi
    if [ -n "${bundle}" ] && [ "${KEEP}" -eq 0 ]; then
        gui_session_cleanup "${bundle}"
    fi
    ACTIVE_BUNDLE=""
    if ! wait_for_no_qemu 30; then
        echo "❌ ⌘Q 後 qemu 仍在執行；送出 adb emu kill 清理本輪模擬器"
        "${ADB}" -s "${SERIAL}" emu kill >/dev/null 2>&1 || true
        status=1
    fi
    return "${status}"
}

print_evidence() {
    local label="$1" log="$2" config="${3:-}"
    echo "--- ${label} 證據：${log} ---"
    if [ -r "${log}" ]; then
        grep -E '^\[(setup|launcher|settings)\]' "${log}" | tail -100 || true
    else
        echo "（app log 不存在）"
    fi
    [ -n "${LAST_WM_OUTPUT}" ] && printf 'adb wm size:\n%s\n' "${LAST_WM_OUTPUT}"
    [ -n "${LAST_CPU_OUTPUT}" ] && printf 'adb CPU 查詢:\n%s\n' "${LAST_CPU_OUTPUT}"
    [ -n "${LAST_MEM_OUTPUT}" ] && printf 'adb /proc/meminfo:\n%s\n' "${LAST_MEM_OUTPUT}"
    if [ -n "${config}" ] && [ -r "${config}" ]; then
        echo "config.ini 設定欄位："
        for key in hw.cpu.ncore hw.ramSize hw.lcd.width hw.lcd.height hw.lcd.density "${DATA_PARTITION_SIZE_KEY}"; do
            value="$(avd_settings_config_value "${config}" "${key}" 2>/dev/null || true)"
            printf '  %s = %s\n' "${key}" "${value:-（缺少）}"
        done
    fi
    echo "--- 證據結束 ---"
}

run_v1() {
    local round="$1" log="${LOG_DIR}/v1-round-${1}.log" bundle="${WORK}/v1-round-${1}-bundle"
    local avd_home config marker failures_before="${FAILURES}" partition_size=""
    avd_home="$(mktemp -d "${WORK}/v1-avd-r${round}.XXXXXX")" || {
        record_result "V1-r${round}" FAIL "無法建立暫存 AVD_HOME"
        return 0
    }
    config="${avd_home}/${PRIMARY_AVD_NAME}.avd/config.ini"
    marker="${avd_home}/${PRIMARY_AVD_NAME}.avd/${MARKER_FILENAME}"
    LAST_WM_OUTPUT=""
    LAST_CPU_OUTPUT=""
    LAST_MEM_OUTPUT=""
    echo "=== round ${round}/${ROUNDS} V1：暫存 AVD ==="
    if ! start_app "${log}" "${bundle}" "${avd_home}" \
        "MIRAGE_SETUP_AUTOSTART=1" "MIRAGE_SETTINGS_AUTOAPPLY=${SETTINGS_OVERRIDE}" \
        "MIRAGE_SETUP_DATA_PARTITION_BYTES=${TEST_DATA_PARTITION_BYTES}"; then
        record_result "V1-r${round} 啟動" FAIL "gui_session_start 失敗"
        print_evidence "V1-r${round}" "${log}" "${config}"
        quit_app || true
        return 0
    fi

    if wait_for_running_count "${log}" 1 150; then
        record_result "V1-r${round} 第一次 running" PASS "150 秒內進入 running"
    else
        record_result "V1-r${round} 第一次 running" FAIL "150 秒內未進入 running"
    fi
    if first_run_has_setup_done "${log}"; then
        record_result "V1-r${round} 設定精靈完成" PASS "有 [setup] done"
    else
        record_result "V1-r${round} 設定精靈完成" FAIL "沒有 [setup] done"
    fi
    if first_run_has_download_started "${log}"; then
        record_result "V1-r${round} 不下載套件" FAIL "log 出現套件下載行"
    else
        record_result "V1-r${round} 不下載套件" PASS "沒有套件下載行"
    fi
    if wait_for_applied "${log}" yes 150; then
        record_result "V1-r${round} settings restart=yes" PASS "AUTOAPPLY 已套用"
    else
        record_result "V1-r${round} settings restart=yes" FAIL "150 秒內沒有預期 applied log"
    fi
    if wait_for_running_count "${log}" 2 150 \
        && avd_settings_has_restart_sequence "${log}"; then
        record_result "V1-r${round} 重新進入 running" PASS "套用後 launcher 再次進入 running"
    else
        record_result "V1-r${round} 重新進入 running" FAIL "套用後沒有第二次 running"
    fi

    if [ -r "${config}" ] && avd_settings_config_matches "${config}" \
        "${EXPECTED_CORES}" "${EXPECTED_RAM_MB}" "${EXPECTED_WIDTH}" \
        "${EXPECTED_HEIGHT}" "${EXPECTED_DENSITY}"; then
        record_result "V1-r${round} config.ini" PASS "CPU、RAM、解析度與 density 都符合"
    else
        record_result "V1-r${round} config.ini" FAIL "config.ini 欄位值不符或檔案缺少"
    fi
    if [ -r "${config}" ]; then
        partition_size="$(avd_settings_config_value "${config}" "${DATA_PARTITION_SIZE_KEY}" 2>/dev/null || true)"
    fi
    if [ "${partition_size}" = "${TEST_DATA_PARTITION_BYTES}" ]; then
        record_result "V1-r${round} data partition" PASS \
            "${DATA_PARTITION_SIZE_KEY}=${TEST_DATA_PARTITION_BYTES}"
    else
        record_result "V1-r${round} data partition" FAIL \
            "${DATA_PARTITION_SIZE_KEY}=${partition_size:-（缺少）}，預期 ${TEST_DATA_PARTITION_BYTES}"
    fi
    if [ -f "${marker}" ]; then
        record_result "V1-r${round} managed 標記" PASS "AVD 有 Mirage managed 標記"
    else
        record_result "V1-r${round} managed 標記" FAIL "找不到 ${MARKER_FILENAME}"
    fi

    if wait_for_guest_adb 60; then
        record_result "V1-r${round} guest adb 就緒" PASS "${GUEST_ADB_WAIT} 秒"
    else
        record_result "V1-r${round} guest adb 就緒" FAIL "60 秒內 adb 沒有回報 sys.boot_completed=1"
    fi
    LAST_WM_OUTPUT="$("${ADB}" -s "${SERIAL}" shell wm size 2>&1)" || true
    if avd_settings_wm_size_matches "${LAST_WM_OUTPUT}" "${EXPECTED_RESOLUTION}"; then
        record_result "V1-r${round} guest resolution" PASS "${EXPECTED_RESOLUTION}"
    else
        record_result "V1-r${round} guest resolution" FAIL "wm size 未回報 Physical size: ${EXPECTED_RESOLUTION}"
    fi

    LAST_CPU_OUTPUT="$("${ADB}" -s "${SERIAL}" shell nproc 2>/dev/null)"
    if [ -z "${LAST_CPU_OUTPUT}" ]; then
        LAST_CPU_OUTPUT="$("${ADB}" -s "${SERIAL}" shell cat /proc/cpuinfo 2>&1)"
    fi
    if avd_settings_cpu_count_matches "${LAST_CPU_OUTPUT}" "${EXPECTED_CORES}"; then
        record_result "V1-r${round} guest CPU" PASS "processor count=${EXPECTED_CORES}"
    else
        record_result "V1-r${round} guest CPU" FAIL "CPU 核心數解析結果為 $(avd_settings_cpu_count "${LAST_CPU_OUTPUT}" 2>/dev/null || printf '無法解析')"
    fi

    LAST_MEM_OUTPUT="$("${ADB}" -s "${SERIAL}" shell cat /proc/meminfo 2>&1)"
    if avd_settings_memtotal_in_range "${LAST_MEM_OUTPUT}"; then
        record_result "V1-r${round} guest MemTotal" PASS "$(avd_settings_memtotal_kb "${LAST_MEM_OUTPUT}") kB"
    else
        record_result "V1-r${round} guest MemTotal" FAIL "MemTotal 不在 2400000–3100000 kB 範圍"
    fi

    if quit_app; then
        record_result "V1-r${round} ⌘Q 與模擬器停止" PASS "app 與 qemu 已停止"
    else
        record_result "V1-r${round} ⌘Q 與模擬器停止" FAIL "app 或 qemu 未正常結束"
    fi
    if [ "${FAILURES}" -gt "${failures_before}" ]; then
        print_evidence "V1-r${round}" "${log}" "${config}"
    fi
}

run_v2() {
    local round="$1" log="${LOG_DIR}/v2-round-${1}.log" bundle="${WORK}/v2-round-${1}-bundle"
    local failures_before="${FAILURES}" before after
    LAST_WM_OUTPUT=""
    LAST_CPU_OUTPUT=""
    LAST_MEM_OUTPUT=""
    echo "=== round ${round}/${ROUNDS} V2：開發機 AVD 唯讀 ==="
    before="$(sha1_file "${DEVELOPER_CONFIG}")"
    unset MIRAGE_SETUP_AUTOSTART
    if ! start_app "${log}" "${bundle}" "${HOME}/.android/avd" \
        "MIRAGE_SETTINGS_AUTOAPPLY=${SETTINGS_OVERRIDE}"; then
        record_result "V2-r${round} 啟動" FAIL "gui_session_start 失敗"
        print_evidence "V2-r${round}" "${log}" "${DEVELOPER_CONFIG}"
        quit_app || true
        return 0
    fi

    if wait_for_running_count "${log}" 1 150; then
        record_result "V2-r${round} running" PASS "150 秒內進入 running"
    else
        record_result "V2-r${round} running" FAIL "150 秒內未進入 running"
    fi
    if wait_for_guest_adb 60; then
        record_result "V2-r${round} guest adb 就緒" PASS "${GUEST_ADB_WAIT} 秒"
    else
        record_result "V2-r${round} guest adb 就緒" FAIL "60 秒內 adb 沒有回報 sys.boot_completed=1"
    fi
    LAST_WM_OUTPUT="$("${ADB}" -s "${SERIAL}" shell wm size 2>&1)" || true
    LAST_CPU_OUTPUT="$("${ADB}" -s "${SERIAL}" shell nproc 2>/dev/null)"
    if [ -z "${LAST_CPU_OUTPUT}" ]; then
        LAST_CPU_OUTPUT="$("${ADB}" -s "${SERIAL}" shell cat /proc/cpuinfo 2>&1)"
    fi
    LAST_MEM_OUTPUT="$("${ADB}" -s "${SERIAL}" shell cat /proc/meminfo 2>&1)"
    if wait_for_read_only "${log}" "${DEVELOPER_AVD_DIRECTORY}" 30; then
        record_result "V2-r${round} read-only" PASS "記錄開發機 AVD 路徑"
    else
        record_result "V2-r${round} read-only" FAIL "沒有預期 [settings] read-only log"
    fi
    if avd_settings_has_no_applied "${log}"; then
        record_result "V2-r${round} 未套用" PASS "沒有 [settings] applied log"
    else
        record_result "V2-r${round} 未套用" FAIL "唯讀 AVD 不應有 [settings] applied"
    fi
    after="$(sha1_file "${DEVELOPER_CONFIG}")"
    if [ "${before}" = "${after}" ]; then
        record_result "V2-r${round} SHA1" PASS "開發機 config.ini 未變"
    else
        record_result "V2-r${round} SHA1" FAIL "開發機 config.ini SHA1 改變：${before} → ${after}"
        diff -u "${WORK}/developer-config.initial" "${DEVELOPER_CONFIG}" || true
    fi
    if quit_app; then
        record_result "V2-r${round} ⌘Q 與模擬器停止" PASS "app 與 qemu 已停止"
    else
        record_result "V2-r${round} ⌘Q 與模擬器停止" FAIL "app 或 qemu 未正常結束"
    fi
    if [ "${FAILURES}" -gt "${failures_before}" ]; then
        print_evidence "V2-r${round}" "${log}" "${DEVELOPER_CONFIG}"
    fi
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    if pgrep -x MirageApp >/dev/null 2>&1; then
        echo "⚠️ 清理由本腳本啟動的 MirageApp"
        quit_app || status=1
    fi
    if ! wait_for_no_qemu 5; then
        "${ADB}" -s "${SERIAL}" emu kill >/dev/null 2>&1 || true
    fi
    if [ "${KEEP}" -eq 0 ]; then
        rm -rf "${WORK}"
    else
        echo "暫存 AVD、app logs 與證據保留於：${WORK}"
    fi
    exit "${status}"
}
trap cleanup EXIT INT TERM

for ((round = 1; round <= ROUNDS; round++)); do
    run_v1 "${round}"
    run_v2 "${round}"
done

FINAL_DEVELOPER_SHA1="$(sha1_file "${DEVELOPER_CONFIG}")"
if [ "${INITIAL_DEVELOPER_SHA1}" = "${FINAL_DEVELOPER_SHA1}" ]; then
    record_result "開發機 AVD 最終 SHA1" PASS "${FINAL_DEVELOPER_SHA1}"
else
    echo "🚨 開發機 AVD config.ini SHA1 改變：${INITIAL_DEVELOPER_SHA1} → ${FINAL_DEVELOPER_SHA1}"
    diff -u "${WORK}/developer-config.initial" "${DEVELOPER_CONFIG}" || true
    record_result "開發機 AVD 最終 SHA1" FAIL "config.ini 與前置內容不同"
fi

echo ""
echo "=== AVD 設定驗證結果 ==="
printf '%-34s %-7s %s\n' "檢查項目" "結果" "說明"
for index in "${!RESULT_LABELS[@]}"; do
    printf '%-34s %-7s %s\n' "${RESULT_LABELS[${index}]}" \
        "${RESULT_STATUS[${index}]}" "${RESULT_DETAILS[${index}]}"
done
if [ "${FAILURES}" -ne 0 ]; then
    echo "❌ AVD 設定驗證失敗：${FAILURES} 項"
    exit 1
fi
if [ "${KEEP}" -eq 1 ]; then
    echo "app log 目錄：${LOG_DIR}"
else
    echo "app log 已在結束時清除；需要保留時請加 --keep"
fi
echo "✅ AVD 設定驗證通過（${ROUNDS} 輪）"
