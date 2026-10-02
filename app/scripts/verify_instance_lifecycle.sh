#!/usr/bin/env bash
# InstanceManager L1-L5 macOS 實機驗證。此腳本會啟動 GUI 與模擬器。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/gui_session.sh"
source "${SCRIPT_DIR}/lib/verify_common.sh"
source "${SCRIPT_DIR}/lib/instance_lifecycle.sh"
source "${SCRIPT_DIR}/lib/emu_instances.sh" || exit 1
cd "${SCRIPT_DIR}/.." || exit 1

unset MIRAGE_HOST MIRAGE_PORT MIRAGE_AVD MIRAGE_GRPC

ROUNDS=2
while [ "$#" -gt 0 ]; do
    case "$1" in
        --rounds)
            [ "$#" -ge 2 ] || { echo "用法：$0 [--rounds N]" >&2; exit 2; }
            ROUNDS="$2"
            shift 2
            ;;
        *) echo "用法：$0 [--rounds N]" >&2; exit 2 ;;
    esac
done
case "$ROUNDS" in
    ''|*[!0-9]*|0) echo "--rounds 必須是大於零的整數：${ROUNDS}" >&2; exit 2 ;;
esac

require_adb

INITIAL_QEMU="$(pgrep -fl qemu-system 2>/dev/null || true)"
INITIAL_INSTANCES="$(emu_running_instances "$INITIAL_QEMU")"
RUNNING_DIR="$HOME/Library/Caches/TemporaryItems/avd/running"
OWNED_FILE="$HOME/Library/Application Support/Mirage/owned-instances.json"

echo "初始執行中的模擬器（pgrep -fl qemu-system）："
if [ -n "$INITIAL_QEMU" ]; then
    printf '%s\n' "$INITIAL_QEMU"
else
    echo "（無）"
fi
echo "初始模擬器解析結果（pid avd console grpc 視窗）："
if [ -n "$INITIAL_INSTANCES" ]; then
    printf '%s\n' "$INITIAL_INSTANCES"
else
    echo "（無）"
fi

EMU_SCRIPT="${SCRIPT_DIR}/emu.sh"
EMU_TABLE="${MIRAGE_INSTANCES:-$EMU_DEFAULT_INSTANCES}"
emu_table_check "$EMU_TABLE" || exit 1
FIRST_TRIPLET="${EMU_TABLE%% *}"
IFS=: read -r TEST_AVD TEST_PORT TEST_GRPC <<< "$FIRST_TRIPLET"
APP_PID=""
ACTIVE_LOG=""
ACTIVE_BUNDLE=""
TEMP_DIR="$(mktemp -d -t mirage_instance_lifecycle)" || exit 1
RESULT_SCENARIOS=()
RESULT_ROUNDS=()
RESULT_STATUS=()
RESULT_DETAILS=()
LOG_PATHS=()
TOTAL_FAILURES=0
CASE_OK=1
CLEANUP_DONE=0

owned_contents() {
    if [ -r "$OWNED_FILE" ]; then
        /bin/cat "$OWNED_FILE"
    else
        printf '[]'
    fi
}

qemu_output() {
    pgrep -fl qemu-system 2>/dev/null || true
}

qemu_count() {
    emu_running_instances "$(qemu_output)" | awk 'NF { count++ } END { print count + 0 }'
}

evidence() {
    local log="${1:-}" owned
    echo "--- 驗證證據 ---"
    echo "launcher log：${log:-（無 log 路徑）}"
    if [ -r "$log" ]; then
        grep '^\[launcher\]' "$log" || echo "（沒有 [launcher] 行）"
    else
        echo "（log 不存在或無法讀取）"
    fi
    echo "所有權檔：${OWNED_FILE}"
    owned="$(owned_contents 2>&1)"
    printf '%s\n' "$owned"
    echo "當下 qemu 行程："
    qemu_output || true
    echo "--- 證據結束 ---"
}

record_failure() {
    local desc="$1" log="${2:-$ACTIVE_LOG}"
    CASE_OK=0
    echo "❌ ${desc}"
    evidence "$log"
}

check_equals() {
    local desc="$1" actual="$2" expected="$3" log="${4:-$ACTIVE_LOG}"
    local output rc
    output="$(assert_equals "$desc" "$actual" "$expected" 2>&1)"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "$output"
    else
        CASE_OK=0
        echo "$output"
        evidence "$log"
    fi
}

check_at_most_decimal() {
    local desc="$1" actual="$2" limit="$3" log="${4:-$ACTIVE_LOG}"
    local ok
    ok="$(awk -v value="$actual" -v limit="$limit" 'BEGIN { print (value <= limit) ? "yes" : "no" }')"
    check_equals "$desc" "$ok" yes "$log"
}

add_result() {
    local scenario="$1" round="$2" ok="$3" details="$4"
    RESULT_SCENARIOS+=("$scenario")
    RESULT_ROUNDS+=("$round")
    RESULT_STATUS+=("$ok")
    RESULT_DETAILS+=("$details")
    [ "$ok" = PASS ] || TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
}

monotonic_time() {
    python3 -c 'import time; print(f"{time.monotonic():.6f}")'
}

remaining_time() {
    awk -v start="$1" -v limit="$2" -v now="$(monotonic_time)" \
        'BEGIN { left = limit - (now - start); printf "%.3f", (left > 0) ? left : 0 }'
}

app_pid_alive() {
    local wanted="$1"
    gui_session_pid_matches_app "${ACTIVE_BUNDLE}/Mirage.app" "${wanted}"
}

wait_app_exit() {
    local pid="$1" tenths="$2" i=0
    while [ "$i" -lt "$tenths" ]; do
        app_pid_alive "$pid" || return 0
        sleep 0.1
        i=$((i + 1))
    done
    ! app_pid_alive "$pid"
}

discovery_pid_for() {
    local wanted_avd="$1" wanted_port="$2" ini pid avd port
    local best_pid="" best_mtime=-1 mtime
    for ini in "$RUNNING_DIR"/pid_*.ini; do
        [ -r "$ini" ] || continue
        pid="${ini##*/pid_}"
        pid="${pid%.ini}"
        case "$pid" in ''|*[!0-9]*) continue ;; esac
        avd="$(awk -F= '$1 == "avd.name" { sub(/^[^=]*=/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print; exit }' "$ini")"
        port="$(awk -F= '$1 == "port.serial" { sub(/^[^=]*=/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print; exit }' "$ini")"
        [ "$avd" = "$wanted_avd" ] && [ "$port" = "$wanted_port" ] || continue
        kill -0 "$pid" 2>/dev/null || continue
        mtime="$(stat -f %m "$ini" 2>/dev/null || echo 0)"
        case "$mtime" in ''|*[!0-9]*) mtime=0 ;; esac
        if [ "$mtime" -ge "$best_mtime" ]; then
            best_pid="$pid"
            best_mtime="$mtime"
        fi
    done
    printf '%s\n' "$best_pid"
}

start_app() {
    local log="$1"
    ACTIVE_LOG="$log"
    LOG_PATHS+=("$log")
    ACTIVE_BUNDLE="$(mktemp -d -t mirage_instance_bundle)" || return 1
    : > "$log"
    gui_session_start "$log" "$ACTIVE_BUNDLE" "" --preserve-frontmost
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        APP_PID="$(gui_session_pid_for_app "${ACTIVE_BUNDLE}/Mirage.app")"
        record_failure "gui_session_start 失敗（退出碼 ${rc}）" "$log"
        return 1
    fi
    APP_PID="$(gui_session_pid_for_app "${ACTIVE_BUNDLE}/Mirage.app")"
    if [ -z "$APP_PID" ]; then
        record_failure "open 成功但找不到 MirageApp 行程" "$log"
        return 1
    fi
    echo "MirageApp pid=${APP_PID}，app log=${log}"
    return 0
}

remove_bundle() {
    if [ -n "$ACTIVE_BUNDLE" ] && [ -d "$ACTIVE_BUNDLE" ]; then
        rm -rf "$ACTIVE_BUNDLE"
    fi
    ACTIVE_BUNDLE=""
}

request_command_q() {
    local log="$1" max_seconds="$2" before after elapsed
    if [ -z "$APP_PID" ] || ! app_pid_alive "$APP_PID"; then
        record_failure "送出 ⌘Q 前 MirageApp pid 不存在" "$log"
        return 1
    fi
    before="$(monotonic_time)"
    Q_SENT_MONO="$before"
    # NSRunningApplication.terminate 與 ⌘Q 都會走 applicationShouldTerminate／WillTerminate。
    if gui_session_quit_gracefully "$APP_PID" "$max_seconds"; then
        after="$(monotonic_time)"
        elapsed="$(awk -v before="$before" -v after="$after" 'BEGIN { printf "%.3f", after - before }')"
        echo "⌘Q 到 MirageApp 行程消失：${elapsed} 秒"
        check_at_most_decimal "app 行程 ${max_seconds} 秒內消失" "$elapsed" "$max_seconds" "$log"
        return 0
    fi
    after="$(monotonic_time)"
    elapsed="$(awk -v before="$before" -v after="$after" 'BEGIN { printf "%.3f", after - before }')"
    echo "⌘Q 到 MirageApp 行程消失：超過 ${elapsed} 秒"
    record_failure "app 行程在 ${max_seconds} 秒內未消失" "$log"
    return 1
}

wait_destination() {
    local log="$1" avd="$2" state="$3" timeout="$4" started now in_time
    DESTINATION_FOUND_AT=""
    started="$(monotonic_time)"
    while :; do
        now="$(monotonic_time)"
        if il_log_has_destination "$(/bin/cat "$log" 2>/dev/null)" "$avd" "$state"; then
            DESTINATION_FOUND_AT="$now"
            in_time="$(awk -v start="$started" -v now="$now" -v timeout="$timeout" \
                'BEGIN { print (now - start <= timeout) ? "yes" : "no" }')"
            [ "$in_time" = yes ] && return 0
            return 1
        fi
        in_time="$(awk -v start="$started" -v now="$now" -v timeout="$timeout" \
            'BEGIN { print (now - start < timeout) ? "yes" : "no" }')"
        [ "$in_time" = yes ] || return 1
        sleep 0.25
    done
}

run_emu() {
    env -u MIRAGE_HOST -u MIRAGE_PORT -u MIRAGE_AVD -u MIRAGE_GRPC "$EMU_SCRIPT" "$@"
}

stop_configured_instances() {
    local entry avd rc failed=0
    for entry in $EMU_TABLE; do
        avd="${entry%%:*}"
        run_emu -n "$avd" stop
        rc=$?
        if [ "$rc" -ne 0 ]; then
            echo "❌ emu.sh stop 失敗：${avd}（退出碼 ${rc}）"
            failed=1
        fi
    done
    return "$failed"
}

terminate_tracked_app() {
    local failed=0
    if [ -n "$APP_PID" ] && app_pid_alive "$APP_PID"; then
        kill -TERM "$APP_PID" 2>/dev/null || true
        if ! wait_app_exit "$APP_PID" 300; then
            echo "⚠️ MirageApp pid=${APP_PID} 未在 30 秒清理期限內結束"
            failed=1
        fi
    fi
    return "$failed"
}

stop_remaining_qemu() {
    local rows line pid avd port grpc window rc failed=0 triplet
    rows="$(emu_running_instances "$(qemu_output)")"
    [ -n "$rows" ] || return 0
    while read -r pid avd port grpc window; do
        [ -n "$pid" ] || continue
        [ "$avd" != "?" ] || { echo "無法透過 emu.sh 辨識 qemu pid=${pid} 的 AVD"; failed=1; continue; }
        if [ "$grpc" = "?" ]; then grpc=8554; fi
        triplet="${avd}:${port}:${grpc}"
        MIRAGE_INSTANCES="$triplet" env -u MIRAGE_HOST -u MIRAGE_PORT -u MIRAGE_AVD -u MIRAGE_GRPC \
            "$EMU_SCRIPT" -n "$avd" stop
        rc=$?
        if [ "$rc" -ne 0 ]; then
            echo "❌ emu.sh stop 失敗：${avd} pid=${pid}（退出碼 ${rc}）"
            failed=1
        fi
    done <<< "$rows"
    return "$failed"
}

stop_all_simulators() {
    local failed=0
    stop_configured_instances || failed=1
    stop_remaining_qemu || failed=1
    return "$failed"
}

cleanup() {
    local rc remaining
    [ "$CLEANUP_DONE" -eq 0 ] || return 0
    CLEANUP_DONE=1
    echo "=== 清理：停止 MirageApp 與所有模擬器 ==="
    if ! terminate_tracked_app; then
        echo "❌ 清理時 MirageApp 未結束"
        TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
        evidence "$ACTIVE_LOG"
    fi
    stop_all_simulators
    rc=$?
    if [ "$rc" -ne 0 ]; then echo "⚠️ 有模擬器停止命令失敗，檢查下方最終行程狀態"; fi
    remaining="$(qemu_output)"
    if [ -n "$remaining" ]; then
        echo "❌ 清理後仍有 qemu 行程："
        printf '%s\n' "$remaining"
        TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
    else
        echo "✅ 清理結果：所有模擬器均已停止"
    fi
    remove_bundle
    echo "初始在跑的模擬器也已納入全部停止清理；初始記錄共 ${INITIAL_INSTANCES_LINES} 台。"
}

INITIAL_INSTANCES_LINES="$(printf '%s\n' "$INITIAL_INSTANCES" | awk 'NF { n++ } END { print n + 0 }')"
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "=== InstanceManager L1-L5 實機驗證，rounds=${ROUNDS} ==="
echo "目標實例：${TEST_AVD}（console ${TEST_PORT}／gRPC ${TEST_GRPC}）"
echo "所有權檔：${OWNED_FILE}"

for round in $(seq 1 "$ROUNDS"); do
    round_label="$(printf '%02d' "$round")"
    echo ""
    echo "=== L1 冷啟動 + L3 ⌘Q，第 ${round}/${ROUNDS} 輪 ==="
    CASE_OK=1
    ACTIVE_LOG="${TEMP_DIR}/L1-round-${round_label}.log"
    if [ -n "$APP_PID" ] && ! app_pid_alive "$APP_PID"; then APP_PID=""; fi
    DISCOVERY_PID=""
    PRINTED_DISCOVERY_PID=""
    DESTINATION_FOUND_AT=""
    if ! stop_all_simulators; then
        record_failure "L1 前置停止模擬器失敗" "$ACTIVE_LOG"
    fi
    L1_STARTED_MONO="$(monotonic_time)"
    if start_app "$ACTIVE_LOG"; then
        L1_REMAINING="$(remaining_time "$L1_STARTED_MONO" 120)"
        if wait_destination "$ACTIVE_LOG" "$TEST_AVD" running "$L1_REMAINING"; then
            echo "✅ 120 秒內 log 出現 running"
        else
            record_failure "120 秒內 log 沒有 running 狀態" "$ACTIVE_LOG"
        fi
        DISCOVERY_PID="$(discovery_pid_for "$TEST_AVD" "$TEST_PORT")"
        DISCOVERY_LINE="$(il_discovery_line "$(/bin/cat "$ACTIVE_LOG")" "$TEST_AVD")"
        if [ -n "$DISCOVERY_LINE" ]; then
            echo "$DISCOVERY_LINE"
            PID_PAIR="$(il_discovery_pids "$DISCOVERY_LINE")"
            SPAWN_PID="${PID_PAIR%% *}"
            PRINTED_DISCOVERY_PID="${PID_PAIR##* }"
            if [ "$SPAWN_PID" = "$PRINTED_DISCOVERY_PID" ]; then
                echo "spawnPid 與 discoveryPid 相同：是"
            else
                echo "spawnPid 與 discoveryPid 相同：否"
            fi
        else
            SPAWN_PID=""
            PRINTED_DISCOVERY_PID=""
            record_failure "log 缺少 spawnPid/discoveryPid 探索行" "$ACTIVE_LOG"
        fi
        check_equals "所有權檔恰有一筆" "$(il_owned_count "$(owned_contents)" 2>/dev/null || echo invalid)" 1 "$ACTIVE_LOG"
        check_equals "探索檔找到模擬器 pid" "$( [ -n "$DISCOVERY_PID" ] && echo yes || echo no )" yes "$ACTIVE_LOG"
        if [ -n "$DISCOVERY_PID" ]; then
            check_equals "探索 pid 存活" "$(kill -0 "$DISCOVERY_PID" 2>/dev/null && echo yes || echo no)" yes "$ACTIVE_LOG"
            check_equals "所有權 pid 等於探索 pid" \
                "$(il_owned_has_record "$(owned_contents)" "$TEST_AVD" "$TEST_PORT" "$DISCOVERY_PID" && echo yes || echo no)" yes "$ACTIVE_LOG"
            check_equals "log discoveryPid 等於探索檔 pid" "${PRINTED_DISCOVERY_PID:-missing}" "$DISCOVERY_PID" "$ACTIVE_LOG"
        fi
    else
        record_failure "L1 app 無法啟動" "$ACTIVE_LOG"
    fi
    L1_END_MONO="${DESTINATION_FOUND_AT:-$(monotonic_time)}"
    L1_ELAPSED="$(awk -v start="$L1_STARTED_MONO" -v end="$L1_END_MONO" \
        'BEGIN { printf "%.3f", end - start }')"
    echo "L1 等待時間：${L1_ELAPSED} 秒（上限 120 秒）"
    check_at_most_decimal "L1 啟動等待在上限內" "$L1_ELAPSED" 120 "$ACTIVE_LOG"
    if [ "$CASE_OK" -eq 1 ]; then L1_STATUS=PASS; else L1_STATUS=FAIL; fi
    add_result L1 "$round" "$L1_STATUS" "冷啟動、owned pid 與存活"

    echo "--- L3 ⌘Q 停止，第 ${round}/${ROUNDS} 輪 ---"
    CASE_OK=1
    Q_SENT_MONO="$(monotonic_time)"
    if [ -n "$APP_PID" ] && app_pid_alive "$APP_PID"; then
        request_command_q "$ACTIVE_LOG" 6 || true
    else
        record_failure "L3 開始時沒有可送 ⌘Q 的 MirageApp" "$ACTIVE_LOG"
    fi
    if [ -n "${DISCOVERY_PID:-}" ]; then
        L3_PID_EXITED=no
        L3_OWNED_EMPTY=no
        while { [ "$L3_PID_EXITED" != yes ] || [ "$L3_OWNED_EMPTY" != yes ]; }; do
            if ! kill -0 "$DISCOVERY_PID" 2>/dev/null; then L3_PID_EXITED=yes; fi
            L3_COUNT="$(il_owned_count "$(owned_contents 2>/dev/null)" 2>/dev/null || echo invalid)"
            if [ "$L3_COUNT" = 0 ]; then L3_OWNED_EMPTY=yes; fi
            [ "$L3_PID_EXITED" = yes ] && [ "$L3_OWNED_EMPTY" = yes ] && break
            L3_NOW="$(monotonic_time)"
            L3_IN_TIME="$(awk -v sent="$Q_SENT_MONO" -v now="$L3_NOW" \
                'BEGIN { print (now - sent < 30) ? "yes" : "no" }')"
            [ "$L3_IN_TIME" = yes ] || break
            sleep 0.25
        done
        check_equals "⌘Q 後 30 秒內模擬器 pid 結束" "$L3_PID_EXITED" yes "$ACTIVE_LOG"
        check_equals "⌘Q 後 30 秒內所有權檔為空陣列或不存在" "$L3_OWNED_EMPTY" yes "$ACTIVE_LOG"
    else
        record_failure "L3 缺少 L1 探索 pid" "$ACTIVE_LOG"
    fi
    L3_LOG="${TEMP_DIR}/L3-round-${round_label}.log"
    if cp "$ACTIVE_LOG" "$L3_LOG"; then
        LOG_PATHS+=("$L3_LOG")
    else
        record_failure "無法另存 L3 app log：${L3_LOG}" "$ACTIVE_LOG"
    fi
    if ! terminate_tracked_app; then record_failure "L3 後無法結束 MirageApp" "$ACTIVE_LOG"; fi
    if [ "$CASE_OK" -eq 1 ]; then L3_STATUS=PASS; else L3_STATUS=FAIL; fi
    add_result L3 "$round" "$L3_STATUS" "app ≤6 秒、模擬器與 ownership ≤30 秒停止"
    remove_bundle
    if ! app_pid_alive "${APP_PID:-0}"; then APP_PID=""; fi

    echo ""
    echo "=== L4 自動重開，第 ${round}/${ROUNDS} 輪 ==="
    CASE_OK=1
    ACTIVE_LOG="${TEMP_DIR}/L4-round-${round_label}.log"
    if [ -n "$APP_PID" ] && ! app_pid_alive "$APP_PID"; then APP_PID=""; fi
    L4_COMPLETED_MONO=""
    DESTINATION_FOUND_AT=""
    if ! stop_all_simulators; then
        record_failure "L4 前置停止模擬器失敗" "$ACTIVE_LOG"
    fi
    L4_COLD_STARTED_MONO="$(monotonic_time)"
    if start_app "$ACTIVE_LOG"; then
        L4_COLD_REMAINING="$(remaining_time "$L4_COLD_STARTED_MONO" 120)"
        if wait_destination "$ACTIVE_LOG" "$TEST_AVD" running "$L4_COLD_REMAINING"; then
            echo "✅ L4 初始啟動進入 running"
            L4_COLD_ELAPSED="$(awk -v start="$L4_COLD_STARTED_MONO" -v end="$DESTINATION_FOUND_AT" \
                'BEGIN { printf "%.3f", end - start }')"
            check_at_most_decimal "L4 前置冷啟動在 120 秒內 running" "$L4_COLD_ELAPSED" 120 "$ACTIVE_LOG"
        else
            record_failure "L4 初始啟動未進入 running" "$ACTIVE_LOG"
        fi
        OLD_PID="$(discovery_pid_for "$TEST_AVD" "$TEST_PORT")"
        if [ -n "$OLD_PID" ]; then
            echo "對探索檔 pid=${OLD_PID} 送 SIGTERM"
            L4_STARTED_MONO="$(monotonic_time)"
            kill -TERM "$OLD_PID" 2>/dev/null
            if [ "$?" -ne 0 ]; then record_failure "無法對探索檔 pid=${OLD_PID} 送 SIGTERM" "$ACTIVE_LOG"; fi
            L4_WAITED=0
            NEW_PID=""
            while [ "$L4_WAITED" -lt 300 ]; do
                CURRENT_LOG="$(/bin/cat "$ACTIVE_LOG" 2>/dev/null)"
                NEW_PID="$(discovery_pid_for "$TEST_AVD" "$TEST_PORT")"
                if il_log_states_in_order "$CURRENT_LOG" "$TEST_AVD" restarting running \
                        && [ -n "$NEW_PID" ] && [ "$NEW_PID" != "$OLD_PID" ]; then
                    L4_COMPLETED_MONO="$(monotonic_time)"
                    break
                fi
                sleep 0.5
                L4_WAITED=$((L4_WAITED + 1))
            done
            check_equals "log 依序進入 restarting、running，且新 pid 不同" \
                "$(il_log_states_in_order "$(/bin/cat "$ACTIVE_LOG")" "$TEST_AVD" restarting running \
                    && [ -n "$NEW_PID" ] && [ "$NEW_PID" != "$OLD_PID" ] && echo yes || echo no)" yes "$ACTIVE_LOG"
            L4_END_MONO="${L4_COMPLETED_MONO:-$(monotonic_time)}"
            L4_ELAPSED="$(awk -v start="$L4_STARTED_MONO" -v end="$L4_END_MONO" \
                'BEGIN { printf "%.3f", end - start }')"
            echo "L4 自動重開等待時間：${L4_ELAPSED} 秒（上限 150 秒）"
            check_at_most_decimal "L4 在 150 秒內完成" "$L4_ELAPSED" 150 "$ACTIVE_LOG"
            check_equals "重新探索到新的 pid" "$( [ -n "$NEW_PID" ] && echo yes || echo no )" yes "$ACTIVE_LOG"
            if [ -n "$NEW_PID" ]; then
                check_equals "新探索檔 pid 與舊 pid 不同" "$( [ "$NEW_PID" != "$OLD_PID" ] && echo yes || echo no )" yes "$ACTIVE_LOG"
                echo "新的探索檔 pid：${NEW_PID}（舊 pid ${OLD_PID}）"
            fi
        else
            OLD_PID=""
            record_failure "L4 找不到初始探索檔 pid" "$ACTIVE_LOG"
        fi
    else
        OLD_PID=""
        record_failure "L4 app 無法啟動" "$ACTIVE_LOG"
    fi
    if [ -n "$APP_PID" ] && app_pid_alive "$APP_PID"; then
        request_command_q "$ACTIVE_LOG" 6 || true
    else
        record_failure "L4 結束時 MirageApp 已不在執行，無法用 ⌘Q 收掉" "$ACTIVE_LOG"
    fi
    if ! terminate_tracked_app; then record_failure "L4 後無法結束 MirageApp" "$ACTIVE_LOG"; fi
    if [ "$CASE_OK" -eq 1 ]; then L4_STATUS=PASS; else L4_STATUS=FAIL; fi
    add_result L4 "$round" "$L4_STATUS" "SIGTERM 後 restarting → running 且 pid 改變"
    remove_bundle
    if ! app_pid_alive "${APP_PID:-0}"; then APP_PID=""; fi

    echo ""
    echo "=== L2 接上外部實例 + L5 ⌘Q 不停止外部實例，第 ${round}/${ROUNDS} 輪 ==="
    CASE_OK=1
    ACTIVE_LOG="${TEMP_DIR}/L2-round-${round_label}.log"
    if [ -n "$APP_PID" ] && ! app_pid_alive "$APP_PID"; then APP_PID=""; fi
    DESTINATION_FOUND_AT=""
    if ! stop_all_simulators; then
        record_failure "L2 前置停止模擬器失敗" "$ACTIVE_LOG"
    fi
    run_emu -n "$TEST_AVD" start
    EMU_START_RC=$?
    check_equals "emu.sh start 外部實例成功" "$EMU_START_RC" 0 "$ACTIVE_LOG"
    QEMU_BEFORE="$(qemu_count)"
    EXTERNAL_PID="$(discovery_pid_for "$TEST_AVD" "$TEST_PORT")"
    if [ -z "$EXTERNAL_PID" ]; then record_failure "emu.sh start 後找不到外部探索檔 pid" "$ACTIVE_LOG"; fi
    L2_STARTED_MONO="$(monotonic_time)"
    if start_app "$ACTIVE_LOG"; then
        L2_REMAINING="$(remaining_time "$L2_STARTED_MONO" 30)"
        if wait_destination "$ACTIVE_LOG" "$TEST_AVD" external "$L2_REMAINING"; then
            echo "✅ 30 秒內 log 出現 external"
        else
            record_failure "30 秒內 log 沒有 external 狀態" "$ACTIVE_LOG"
        fi
        check_equals "接上 app 前後 qemu 行程數相同" "$(qemu_count)" "$QEMU_BEFORE" "$ACTIVE_LOG"
        OWNED_VALUE="$(owned_contents)"
        if il_owned_records "$OWNED_VALUE" >/dev/null 2>&1; then
            check_equals "所有權檔沒有外部實例" \
                "$(il_owned_has_instance "$OWNED_VALUE" "$TEST_AVD" "$TEST_PORT" && echo yes || echo no)" no "$ACTIVE_LOG"
        else
            record_failure "L2 所有權檔不是有效的 ownership JSON" "$ACTIVE_LOG"
        fi
    else
        record_failure "L2 app 無法啟動" "$ACTIVE_LOG"
    fi
    if [ "$CASE_OK" -eq 1 ]; then L2_STATUS=PASS; else L2_STATUS=FAIL; fi
    add_result L2 "$round" "$L2_STATUS" "external、qemu 數量不變、未列入 ownership"

    echo "--- L5 ⌘Q 不停止外部實例，第 ${round}/${ROUNDS} 輪 ---"
    CASE_OK=1
    if [ -n "$APP_PID" ] && app_pid_alive "$APP_PID"; then
        request_command_q "$ACTIVE_LOG" 6 || true
    else
        record_failure "L5 開始時沒有可送 ⌘Q 的 MirageApp" "$ACTIVE_LOG"
    fi
    sleep 10
    check_equals "app 結束 10 秒後外部模擬器 pid 仍存活" \
        "$( [ -n "$EXTERNAL_PID" ] && kill -0 "$EXTERNAL_PID" 2>/dev/null && echo yes || echo no )" yes "$ACTIVE_LOG"
    L5_LOG="${TEMP_DIR}/L5-round-${round_label}.log"
    if cp "$ACTIVE_LOG" "$L5_LOG"; then
        LOG_PATHS+=("$L5_LOG")
    else
        record_failure "無法另存 L5 app log：${L5_LOG}" "$ACTIVE_LOG"
    fi
    run_emu -n "$TEST_AVD" stop
    STOP_RC=$?
    if [ "$STOP_RC" -ne 0 ]; then
        record_failure "L5 後 emu.sh stop 外部實例失敗（退出碼 ${STOP_RC}）" "$ACTIVE_LOG"
    fi
    if ! terminate_tracked_app; then record_failure "L5 後無法結束 MirageApp" "$ACTIVE_LOG"; fi
    if [ "$CASE_OK" -eq 1 ]; then L5_STATUS=PASS; else L5_STATUS=FAIL; fi
    add_result L5 "$round" "$L5_STATUS" "app 結束後等待 10 秒，外部 pid 仍存活"
    remove_bundle
    if ! app_pid_alive "${APP_PID:-0}"; then APP_PID=""; fi
done

cleanup

echo ""
echo "=== 每個情境每輪結果 ==="
printf '%-5s %-7s %-7s %s\n' 情境 輪次 結果 判準
for i in "${!RESULT_SCENARIOS[@]}"; do
    printf '%-5s %-7s %-7s %s\n' \
        "${RESULT_SCENARIOS[$i]}" "${RESULT_ROUNDS[$i]}" "${RESULT_STATUS[$i]}" "${RESULT_DETAILS[$i]}"
done
echo ""
echo "=== App log 路徑 ==="
for log in "${LOG_PATHS[@]}"; do echo "$log"; done

if [ "$TOTAL_FAILURES" -ne 0 ]; then
    echo "❌ 實機驗證失敗：${TOTAL_FAILURES} 項情境或清理失敗"
    exit 1
fi
echo "✅ L1-L5 所有輪次通過"
exit 0
