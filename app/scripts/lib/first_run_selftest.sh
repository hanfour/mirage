#!/usr/bin/env bash
# first_run.sh 的 log 判斷正反例；不需要 GUI、網路或模擬器。
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "${HERE}/first_run.sh"
WORK=$(mktemp -d -t first_run_selftest)
trap 'rm -rf "$WORK"' EXIT
FAILURES=0

check() {
    local description="$1" expected="$2"
    shift 2
    local actual=no
    if "$@"; then actual=yes; fi
    if [ "$actual" = "$expected" ]; then
        echo "✅ ${description}"
    else
        echo "❌ ${description}：得到 ${actual}，期待 ${expected}"
        FAILURES=$((FAILURES + 1))
    fi
}

check_output() {
    local description="$1" expected="$2"
    shift 2
    local actual
    if ! actual=$("$@"); then actual='(failure)'; fi
    if [ "$actual" = "$expected" ]; then
        echo "✅ ${description}"
    else
        echo "❌ ${description}：得到 ${actual}，期待 ${expected}"
        FAILURES=$((FAILURES + 1))
    fi
}

printf '%s\n' \
    '[setup] warning preserved version' \
    '[setup] Android Emulator 下載中 1/2 bytes' \
    '[setup] Android Emulator 完成' \
    '[setup] Android Platform Tools 完成' \
    '[setup] Android image 完成' \
    '[setup] gate canStart=false required=900 available=100' \
    '[setup] done' \
    '[launcher] mirage-game --launchRequested--> launching' \
    '[launcher] mirage-game --booted--> running' \
    > "${WORK}/valid.log"
printf '%s\n' '[setup] warning preserved version' > "${WORK}/warning-only.log"
printf '%s\n' '[setup] Android Emulator 等待中' > "${WORK}/waiting.log"
printf '%s\n' '[setup] gate canStart=false required=x available=100' > "${WORK}/bad-gate.log"
printf '%s\n' '[launcher] mirage-game --spawnFailed--> failed' > "${WORK}/failed-launch.log"
printf '%s\n' '[launcher] mirage-game --booted--> booting' > "${WORK}/booting.log"

check "setup activity is detected" yes first_run_has_setup_activity "${WORK}/valid.log"
check "warnings alone are not setup activity" no first_run_has_setup_activity "${WORK}/warning-only.log"
check "download start is detected" yes first_run_has_download_started "${WORK}/valid.log"
check "waiting is not a download start" no first_run_has_download_started "${WORK}/waiting.log"
check "matching completion is detected" yes first_run_has_completed_item "${WORK}/valid.log" "Android Emulator"
check "other item completion does not match" no first_run_has_completed_item "${WORK}/valid.log" "Unknown package"
check "package completion order is detected" yes first_run_completed_in_order \
    "${WORK}/valid.log" "Android Emulator" "Android Platform Tools" "Android image"
printf '%s\n' '[setup] Android Platform Tools 完成' '[setup] Android Emulator 完成' \
    '[setup] Android image 完成' > "${WORK}/wrong-order.log"
check "reverse completion order is rejected" no first_run_completed_in_order \
    "${WORK}/wrong-order.log" "Android Emulator" "Android Platform Tools" "Android image"
check "setup done marker is detected" yes first_run_has_setup_done "${WORK}/valid.log"
check "missing setup done marker is rejected" no first_run_has_setup_done "${WORK}/waiting.log"
check_output "valid gate line parses its values" "false 900 100" first_run_parse_gate_line \
    '[setup] gate canStart=false required=900 available=100'
check "malformed gate line is rejected" no first_run_parse_gate_line \
    '[setup] gate canStart=false required=x available=100'
check_output "gate is read from a log" "false 900 100" first_run_gate_values "${WORK}/valid.log"
check_output "malformed gate in a log is rejected" '(failure)' first_run_gate_values "${WORK}/bad-gate.log"
check "launch request is detected" yes first_run_has_launch_requested "${WORK}/valid.log"
check "failed launch is not a launch request" no first_run_has_launch_requested "${WORK}/failed-launch.log"
check "running transition is detected" yes first_run_has_running "${WORK}/valid.log"
check "booting is not running" no first_run_has_running "${WORK}/booting.log"

if [ "$FAILURES" -eq 0 ]; then
    echo "全部通過"
    exit 0
fi
echo "${FAILURES} 項失敗"
exit 1
