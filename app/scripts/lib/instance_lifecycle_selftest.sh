#!/usr/bin/env bash
# instance_lifecycle.sh 的離線解析自我測試。
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/instance_lifecycle.sh"
FAILURES=0

check() {
    local desc="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then
        echo "✅ ${desc}"
    else
        echo "❌ ${desc}：得到 ${got}，期待 ${want}"
        FAILURES=$((FAILURES + 1))
    fi
}

check_true() {
    local desc="$1"
    shift
    if "$@"; then
        echo "✅ ${desc}"
    else
        echo "❌ ${desc}：判斷為 false"
        FAILURES=$((FAILURES + 1))
    fi
}

check_false() {
    local desc="$1"
    shift
    if "$@"; then
        echo "❌ ${desc}：判斷為 true"
        FAILURES=$((FAILURES + 1))
    else
        echo "✅ ${desc}"
    fi
}

echo "=== launcher log 格式（取自 EmulatorLauncher.logChange 與 print）==="
LOG=$(printf '%s\n' \
    '[launcher] mirage-game stopped --launchRequested--> launching' \
    '[launcher] mirage-game launching --discoveryFileAppeared--> booting' \
    '[launcher] mirage-game booting --booted--> running' \
    '[launcher] mirage-game running --processExited--> restarting' \
    '[launcher] mirage-game restarting --launchStarted--> launching' \
    '[launcher] mirage-game launching --discoveryFileAppeared--> booting' \
    '[launcher] mirage-game booting --booted--> running' \
    '[launcher] mirage-game spawnPid=501 discoveryPid=502')
TRANSITIONS=$(il_log_transitions "$LOG")
check "只解析狀態轉移，不把 spawnPid 行當成轉移" "$(printf '%s\n' "$TRANSITIONS" | wc -l | tr -d ' ')" 7
check_true "解析實際 discoveryFileAppeared 轉移" \
    il_log_has_transition "$LOG" mirage-game launching discoveryFileAppeared booting
check_false "不同事件不能冒充 discoveryFileAppeared" \
    il_log_has_transition "$LOG" mirage-game launching booted booting
check_true "launcher 有 external 目的狀態" \
    il_log_has_destination '[launcher] mirage-game stopped --discovered--> external' mirage-game external
check_false "缺少目標狀態時判斷失敗" \
    il_log_has_destination '[launcher] mirage-game stopped --discovered--> external' mirage-game running

echo ""
echo "=== 狀態依序出現 ==="
check_true "restarting 後再次 running" il_log_states_in_order "$LOG" mirage-game restarting running
check_false "restarting 後沒有 running" \
    il_log_states_in_order '[launcher] mirage-game running --processExited--> restarting' mirage-game restarting running
check_false "只有 running 出現在 restarting 之前" \
    il_log_states_in_order '[launcher] mirage-game booting --booted--> running
[launcher] mirage-game running --processExited--> restarting' mirage-game restarting running

echo ""
echo "=== 探索行 pid ==="
DISCOVERY_LINE=$(il_discovery_line "$LOG" mirage-game)
check "原樣解析 spawnPid 與 discoveryPid log" "$DISCOVERY_LINE" \
    '[launcher] mirage-game spawnPid=501 discoveryPid=502'
check "解析出的 pid 欄位" "$(il_discovery_pids "$DISCOVERY_LINE")" '501 502'
check "spawnPid none 的實際輸出格式" \
    "$(il_discovery_pids '[launcher] mirage-game spawnPid=none discoveryPid=502')" 'none 502'
check "不匹配 AVD 時沒有探索行" "$(il_discovery_line "$LOG" mirage-poc)" ""

echo ""
echo "=== owned-instances.json ==="
OWNED='[{"avd":"mirage-game","consolePort":5554,"pid":502,"startedAt":"2026-09-29T10:00:00Z"}]'
EMPTY='[]'
check "一筆所有權紀錄" "$(il_owned_count "$OWNED")" 1
check_true "AVD、埠、pid 完全相符" il_owned_has_record "$OWNED" mirage-game 5554 502
check_false "錯誤 pid 不相符" il_owned_has_record "$OWNED" mirage-game 5554 503
check_true "查詢該實例存在" il_owned_has_instance "$OWNED" mirage-game 5554
check_false "不同 AVD 不視為同一實例" il_owned_has_instance "$OWNED" mirage-poc 5554
check "空陣列筆數為零" "$(il_owned_count "$EMPTY")" 0
check_false "空陣列沒有實例" il_owned_has_instance "$EMPTY" mirage-game 5554
check_false "非 JSON 內容解析失敗" il_owned_records '{bad json'
check_false "非陣列 JSON 解析失敗" il_owned_records '{"avd":"mirage-game"}'
check_false "缺少欄位的 ownership 紀錄解析失敗" \
    il_owned_records '[{"avd":"mirage-game","consolePort":5554,"pid":502}]'
check_false "無時區的 startedAt 解析失敗" \
    il_owned_records '[{"avd":"mirage-game","consolePort":5554,"pid":502,"startedAt":"2026-09-29T10:00:00"}]'

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "全部通過"
    exit 0
fi
echo "${FAILURES} 項失敗"
exit 1
