#!/usr/bin/env bash
# 驗證首次啟動精靈的本機假套件、第二次啟動、空間 gate 與選用的真下載。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${APP_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/gui_session.sh"
source "${SCRIPT_DIR}/lib/verify_common.sh"
source "${SCRIPT_DIR}/lib/first_run.sh"
cd "${APP_DIR}" || exit 1

ROUNDS=2
REAL_DOWNLOAD=0
KEEP=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --rounds)
            if [ "$#" -lt 2 ]; then echo "❌ --rounds 需要數字"; exit 2; fi
            ROUNDS="$2"
            shift 2
            ;;
        --real-download)
            REAL_DOWNLOAD=1
            shift
            ;;
        --keep)
            KEEP=1
            shift
            ;;
        -h|--help)
            echo "用法：$0 [--rounds N] [--real-download] [--keep]"
            exit 0
            ;;
        *)
            echo "❌ 不認得的參數：$1"
            exit 2
            ;;
    esac
done
case "$ROUNDS" in
    ''|*[!0-9]*) echo "❌ --rounds 必須是正整數"; exit 2 ;;
esac
if [ "$ROUNDS" -lt 1 ]; then echo "❌ --rounds 必須是正整數"; exit 2; fi

QEMU_PROCESSES="$(pgrep -fl '[q]emu' 2>/dev/null || true)"
if [ -n "$QEMU_PROCESSES" ]; then
    echo "❌ 偵測到 qemu 行程。請先自行停止模擬器，再重跑；腳本不會替你關閉。"
    echo "$QEMU_PROCESSES"
    exit 1
fi

unset MIRAGE_HOST MIRAGE_PORT MIRAGE_SDK_SPEC_FILE
unset MIRAGE_SETUP_AUTOSTART MIRAGE_SETUP_FAKE_AVAILABLE_BYTES MIRAGE_SKIP_BUILD
WORK=$(mktemp -d -t mirage_first_run)
LOG_DIR="${WORK}/logs"
mkdir -p "$LOG_DIR"
FAILURES=0
RESULT_LABELS=()
RESULT_VALUES=()
RESULT_DETAILS=()
BUILD_READY=0
SERVER_PID=""
ACTIVE_BUNDLE=""
TEST_SPEC=""
HTTP_ROOT=""
S2_SDK=""
S2_AVD=""
S2_SUCCEEDED=0
S2_RESULT_RECORDED=0

record_result() {
    local label="$1" value="$2" detail="$3"
    RESULT_LABELS+=("$label")
    RESULT_VALUES+=("$value")
    RESULT_DETAILS+=("$detail")
    if [ "$value" = "FAIL" ]; then FAILURES=$((FAILURES + 1)); fi
    echo "[$label] $value${detail:+：$detail}"
}

print_evidence() {
    local label="$1" log="$2" sdk="$3" avd="$4"
    echo "--- ${label} 證據：${log} ---"
    if [ -r "$log" ]; then
        grep -E '^\[(setup|launcher)\]' "$log" | tail -100 || true
    fi
    echo "--- SDK 目錄 ---"
    ls -la "$sdk" 2>&1 || true
    echo "--- AVD 目錄 ---"
    ls -la "$avd" 2>&1 || true
}

start_gui() {
    local log="$1" bundle="$2" sdk="$3" avd="$4"
    shift 4
    export ANDROID_SDK_ROOT="$sdk"
    export ANDROID_AVD_HOME="$avd"
    unset ANDROID_HOME
    if [ "$BUILD_READY" -eq 1 ]; then export MIRAGE_SKIP_BUILD=1; fi
    if gui_session_start "$log" "$bundle" "" --preserve-frontmost "$@"; then
        BUILD_READY=1
        return 0
    fi
    return 1
}

quit_gui() {
    local bundle="$1" status=0 pid
    pid="$(gui_session_pid_for_app "${bundle}/Mirage.app")"
    if [ -n "${pid}" ] && ! gui_session_quit_gracefully "${pid}"; then
        echo "❌ MirageApp 未在期限內正常結束"
        status=1
    fi
    gui_session_cleanup "$bundle"
    return "$status"
}

wait_for_log() {
    local log="$1" timeout="$2" predicate="$3" started="$SECONDS"
    while [ $((SECONDS - started)) -lt "$timeout" ]; do
        if "$predicate" "$log" > /dev/null 2>&1; then return 0; fi
        if ! gui_session_app_is_running "${ACTIVE_BUNDLE}/Mirage.app"; then return 1; fi
        sleep 1
    done
    "$predicate" "$log" > /dev/null 2>&1
}

scenario_assert_equals() {
    local description="$1" actual="$2" expected="$3"
    if (assert_equals "$description" "$actual" "$expected" > /dev/null); then
        return 0
    fi
    echo "❌ ${description}：實測 '${actual}'，期待 '${expected}'"
    return 1
}

wait_for_setup_done() {
    local log="$1" timeout="$2" report="$3" started="$4"
    local elapsed=$((SECONDS - started)) line item seen_items='|'
    while [ "$elapsed" -lt "$timeout" ]; do
        if [ "$report" -eq 1 ] && [ -r "$log" ]; then
            while IFS= read -r line; do
                case "$line" in
                    "[setup] "*" 完成")
                        item="${line#'[setup] '}"
                        item="${item%' 完成'}"
                        case "$seen_items" in
                            *"|${item}|"*) ;;
                            *)
                                seen_items="${seen_items}${item}|"
                                echo "S2 ${item} 完成時間：$((SECONDS - started)) 秒"
                                ;;
                        esac
                        ;;
                esac
            done < <(awk '/^\[setup\] .* 完成$/ { print }' "$log")
        fi
        if first_run_has_setup_done "$log"; then return 0; fi
        if ! gui_session_app_is_running "${ACTIVE_BUNDLE}/Mirage.app"; then return 1; fi
        sleep 1
        elapsed=$((SECONDS - started))
    done
    first_run_has_setup_done "$log"
}

make_fake_packages() {
    local root="$1" source="${1}/source" http="${1}/http"
    mkdir -p "${source}/emulator" "${source}/platform-tools" "${source}/arm64-v8a" "$http"
    printf '#!/bin/sh\nexit 1\n' > "${source}/emulator/emulator"
    printf '#!/bin/sh\nexit 1\n' > "${source}/platform-tools/adb"
    printf 'fake system image\n' > "${source}/arm64-v8a/system.img"
    chmod 755 "${source}/emulator/emulator" "${source}/platform-tools/adb" \
        "${source}/arm64-v8a/system.img"
    (cd "$source" && /usr/bin/zip -q -r "${http}/emulator.zip" emulator) || return 1
    (cd "$source" && /usr/bin/zip -q -r "${http}/platform-tools.zip" platform-tools) || return 1
    (cd "$source" && /usr/bin/zip -q -r "${http}/playstore-image.zip" arm64-v8a) || return 1
    return 0
}

make_test_spec() {
    local original="$1" destination="$2" port="$3" http="$4"
    python3 - "$original" "$destination" "$port" "$http" <<'PY'
import hashlib
import json
import pathlib
import sys

source, destination, port, http_root = sys.argv[1:]
data = json.loads(pathlib.Path(source).read_text(encoding="utf-8"))
replacements = {
    "emulator": "emulator.zip",
    "platform-tools": "platform-tools.zip",
    "system-images/android-35/google_apis_playstore/arm64-v8a": "playstore-image.zip",
}
for package in data["packages"]:
    filename = replacements.get(package["installPath"])
    if filename is None:
        continue
    archive = pathlib.Path(http_root, filename)
    body = archive.read_bytes()
    package["url"] = f"http://127.0.0.1:{port}/{filename}"
    package["size"] = len(body)
    package["sha1"] = hashlib.sha1(body).hexdigest()
if set(replacements) != {p["installPath"] for p in data["packages"] if p["installPath"] in replacements}:
    raise SystemExit("sdk-spec.json 缺少預期的三個套件")
pathlib.Path(destination).write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
}

start_fake_server() {
    local root="$1"
    SERVER_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()') || return 1
    python3 -m http.server "$SERVER_PORT" --bind 127.0.0.1 --directory "$root" \
        > "${WORK}/http-server.log" 2>&1 &
    SERVER_PID=$!
    local attempt=0
    while [ "$attempt" -lt 10 ]; do
        if curl -fsS "http://127.0.0.1:${SERVER_PORT}/emulator.zip" -o /dev/null; then return 0; fi
        sleep 1
        attempt=$((attempt + 1))
    done
    return 1
}

run_s1() {
    local round="$1" sdk avd log bundle passed=1 setup_started
    sdk=$(mktemp -d "${WORK}/s1-sdk-r${round}.XXXXXX") || return 1
    avd=$(mktemp -d "${WORK}/s1-avd-r${round}.XXXXXX") || return 1
    S1_SDK[$round]="$sdk"
    S1_AVD[$round]="$avd"
    log="${LOG_DIR}/s1-r${round}.log"
    bundle=$(mktemp -d "${WORK}/s1-bundle-r${round}.XXXXXX") || return 1
    ACTIVE_BUNDLE="$bundle"
    unset MIRAGE_SDK_SPEC_FILE MIRAGE_SETUP_AUTOSTART MIRAGE_SETUP_FAKE_AVAILABLE_BYTES
    echo "=== S1 round ${round}: 本機假套件 ==="
    if start_gui "$log" "$bundle" "$sdk" "$avd" \
            "MIRAGE_SDK_SPEC_FILE=${TEST_SPEC}" "MIRAGE_SETUP_AUTOSTART=1"; then
        setup_started=$((SECONDS - 6))
        if ! wait_for_setup_done "$log" 120 0 "$setup_started"; then
            echo "❌ 120 秒內沒有完成標記"
            passed=0
        fi
    else
        echo "❌ app 啟動失敗"
        passed=0
    fi
    if ! first_run_completed_in_order "$log" \
            "Android Emulator" "Android Platform Tools" "Android android-35 Google Play system image"; then
        echo "❌ 三個套件未依序完成"
        passed=0
    fi
    if ! first_run_has_setup_done "$log"; then
        echo "❌ 缺少 [setup] done"
        passed=0
    fi
    if [ ! -x "${sdk}/emulator/emulator" ]; then
        echo "❌ emulator/emulator 沒有執行權限"
        passed=0
    fi
    if ! python3 - "${sdk}/.mirage-provision.json" <<'PY'
import json
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
expected = {"emulator", "platform-tools", "system-images/android-35/google_apis_playstore/arm64-v8a"}
try:
    values = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if len(values) == 3 and expected.issubset(values) else 1)
PY
    then
        echo "❌ .mirage-provision.json 沒有恰好三筆預期紀錄"
        passed=0
    fi
    if [ ! -f "${avd}/mirage-game.ini" ] || [ ! -f "${avd}/mirage-game.avd/config.ini" ]; then
        echo "❌ mirage-game AVD 設定檔不完整"
        passed=0
    fi
    if ! quit_gui "$bundle"; then passed=0; fi
    ACTIVE_BUNDLE=""
    if [ "$passed" -eq 1 ]; then
        record_result "S1-r${round}" PASS "本機套件安裝、權限、紀錄與 AVD 通過"
    else
        record_result "S1-r${round}" FAIL "本機假套件安裝驗證失敗"
        print_evidence "S1-r${round}" "$log" "$sdk" "$avd"
    fi
    return 0
}

run_s2() {
    local free_bytes cache_free temp_free setup_started setup_elapsed passed=1 log bundle
    cache_free=$(python3 -c 'import shutil,sys; print(shutil.disk_usage(sys.argv[1]).free)' "$HOME") || cache_free=0
    temp_free=$(python3 -c 'import shutil,sys; print(shutil.disk_usage(sys.argv[1]).free)' "${TMPDIR:-/tmp}") || temp_free=0
    free_bytes="$cache_free"
    if [ "$temp_free" -lt "$free_bytes" ]; then free_bytes="$temp_free"; fi
    if [ "$free_bytes" -lt 10737418240 ]; then
        record_result S2 SKIP "可用空間 $((free_bytes / 1073741824)) GB，低於 10 GB"
        S2_RESULT_RECORDED=1
        return 0
    fi
    S2_SDK=$(mktemp -d "${WORK}/s2-sdk.XXXXXX") || return 1
    S2_AVD=$(mktemp -d "${WORK}/s2-avd.XXXXXX") || return 1
    log="${LOG_DIR}/s2-real-download.log"
    bundle=$(mktemp -d "${WORK}/s2-bundle.XXXXXX") || return 1
    ACTIVE_BUNDLE="$bundle"
    unset MIRAGE_SDK_SPEC_FILE MIRAGE_SETUP_FAKE_AVAILABLE_BYTES
    echo "=== S2: 真下載（可用空間 $((free_bytes / 1073741824)) GB）==="
    if start_gui "$log" "$bundle" "$S2_SDK" "$S2_AVD" "MIRAGE_SETUP_AUTOSTART=1"; then
        setup_started=$((SECONDS - 6))
        if wait_for_setup_done "$log" 3600 1 "$setup_started"; then
            setup_elapsed=$((SECONDS - setup_started))
            echo "S2 安裝完成，實際花費 ${setup_elapsed} 秒"
            if ! wait_for_log "$log" 150 first_run_has_running; then
                echo "❌ [setup] done 後 150 秒內沒有 --> running"
                passed=0
            fi
        else
            echo "❌ 3600 秒內沒有 [setup] done"
            passed=0
        fi
    else
        echo "❌ app 啟動失敗"
        passed=0
    fi
    echo "S2 暫存 SDK：${S2_SDK}"
    echo "S2 暫存 AVD：${S2_AVD}"
    du -sh "$S2_SDK" "$S2_AVD" 2>/dev/null || true
    echo "是否要保留上述暫存目錄？未指定 --keep 時腳本會在結束時自動刪除；加上 --keep 可保留檢查。"
    if ! quit_gui "$bundle"; then passed=0; fi
    ACTIVE_BUNDLE=""
    if [ "$passed" -eq 1 ]; then
        S2_SUCCEEDED=1
        record_result S2 PASS "下載完成 ${setup_elapsed:-0} 秒，啟動器進入 running"
    else
        record_result S2 FAIL "真下載或開機驗證失敗"
        print_evidence S2 "$log" "$S2_SDK" "$S2_AVD"
    fi
    S2_RESULT_RECORDED=1
    return 0
}

run_s3() {
    local round="$1" sdk="$2" avd="$3" require_running="$4"
    local log="${LOG_DIR}/s3-r${round}.log" bundle passed=1 started elapsed=0
    bundle=$(mktemp -d "${WORK}/s3-bundle-r${round}.XXXXXX") || return 1
    ACTIVE_BUNDLE="$bundle"
    unset MIRAGE_SDK_SPEC_FILE MIRAGE_SETUP_AUTOSTART MIRAGE_SETUP_FAKE_AVAILABLE_BYTES
    echo "=== S3 round ${round}: 第二次啟動 ==="
    started="$SECONDS"
    if ! start_gui "$log" "$bundle" "$sdk" "$avd"; then
        echo "❌ app 啟動失敗"
        passed=0
    else
        elapsed=$((SECONDS - started))
        while [ "$elapsed" -lt 30 ]; do
            if first_run_has_setup_activity "$log"; then
                echo "❌ 第二次啟動又進入首次設定流程"
                passed=0
                break
            fi
            if ! gui_session_app_is_running "${ACTIVE_BUNDLE}/Mirage.app"; then
                echo "❌ MirageApp 提前結束"
                passed=0
                break
            fi
            sleep 1
            elapsed=$((SECONDS - started))
        done
        if ! first_run_has_launch_requested "$log"; then
            echo "❌ 30 秒內沒有 [launcher] launchRequested"
            passed=0
        fi
        if [ "$require_running" -eq 1 ]; then
            local remaining=$((150 - elapsed))
            if [ "$remaining" -lt 0 ]; then remaining=0; fi
            if ! wait_for_log "$log" "$remaining" first_run_has_running; then
                echo "❌ 150 秒內沒有 --> running"
                passed=0
            fi
        fi
    fi
    if ! quit_gui "$bundle"; then passed=0; fi
    ACTIVE_BUNDLE=""
    if [ "$passed" -eq 1 ]; then
        if [ "$require_running" -eq 1 ]; then
            record_result "S3-r${round}" PASS "沒有設定階段，launcher 已要求啟動，150 秒內進入 running"
        else
            record_result "S3-r${round}" PASS "沒有設定階段，launcher 已要求啟動（假 emulator，不判 running）"
        fi
    else
        record_result "S3-r${round}" FAIL "第二次啟動驗證失敗"
        print_evidence "S3-r${round}" "$log" "$sdk" "$avd"
    fi
    return 0
}

run_s4() {
    local round="$1" sdk avd log bundle passed=1
    sdk=$(mktemp -d "${WORK}/s4-sdk-r${round}.XXXXXX") || return 1
    avd=$(mktemp -d "${WORK}/s4-avd-r${round}.XXXXXX") || return 1
    log="${LOG_DIR}/s4-r${round}.log"
    bundle=$(mktemp -d "${WORK}/s4-bundle-r${round}.XXXXXX") || return 1
    ACTIVE_BUNDLE="$bundle"
    unset MIRAGE_SDK_SPEC_FILE
    unset MIRAGE_SETUP_AUTOSTART MIRAGE_SETUP_FAKE_AVAILABLE_BYTES
    echo "=== S4 round ${round}: 空間不足 ==="
    if start_gui "$log" "$bundle" "$sdk" "$avd" \
            "MIRAGE_SETUP_AUTOSTART=1" "MIRAGE_SETUP_FAKE_AVAILABLE_BYTES=1073741824"; then
        if ! wait_for_log "$log" 24 first_run_gate_values; then
            echo "❌ 30 秒內沒有有效 gate 行"
            passed=0
        fi
        local gate can_start required available
        gate=$(first_run_gate_values "$log" 2>/dev/null || true)
        read -r can_start required available <<EOF
$gate
EOF
        if [ "${can_start:-}" != false ] || [ "${available:-}" != 1073741824 ] \
           || [ "${required:-0}" -le 1073741824 ]; then
            echo "❌ gate 值不符：${gate:-<missing>}"
            passed=0
        fi
        if ! scenario_assert_equals "S4 canStart" "${can_start:-missing}" false; then passed=0; fi
        if ! scenario_assert_equals "S4 available bytes" "${available:-missing}" 1073741824; then passed=0; fi
        sleep 30
        if first_run_has_download_started "$log"; then
            echo "❌ 空間不足時仍開始下載"
            passed=0
        fi
        if [ -n "$(ls -A "$sdk" 2>/dev/null)" ]; then
            echo "❌ gate 拒絕後 SDK 目錄不是空的"
            passed=0
        fi
    else
        echo "❌ app 啟動失敗"
        passed=0
    fi
    if ! quit_gui "$bundle"; then passed=0; fi
    ACTIVE_BUNDLE=""
    if [ "$passed" -eq 1 ]; then
        record_result "S4-r${round}" PASS "空間 gate 拒絕開始且沒有下載"
    else
        record_result "S4-r${round}" FAIL "空間不足 gate 驗證失敗"
        print_evidence "S4-r${round}" "$log" "$sdk" "$avd"
    fi
    return 0
}

cleanup() {
    if [ -n "$SERVER_PID" ]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    if [ -n "$ACTIVE_BUNDLE" ]; then gui_session_cleanup "$ACTIVE_BUNDLE"; fi
    if [ "$KEEP" -eq 1 ]; then
        echo "驗證檔案保留於：${WORK}"
    else
        rm -rf "$WORK"
        if [ "$FAILURES" -ne 0 ]; then
            echo "失敗證據已印出；暫存目錄已清除，使用 --keep 可保留下一次執行的檔案。"
        fi
    fi
}
handle_signal() {
    FAILURES=$((FAILURES + 1))
    exit 130
}
trap cleanup EXIT
trap handle_signal INT TERM

FAKE_ROOT="${WORK}/fake-packages"
HTTP_ROOT="${FAKE_ROOT}/http"
if ! make_fake_packages "$FAKE_ROOT"; then
    echo "❌ 建立本機假套件失敗"
    exit 1
fi
if ! start_fake_server "$HTTP_ROOT"; then
    echo "❌ 本機 HTTP server 未能提供假套件"
    exit 1
fi
TEST_SPEC="${WORK}/sdk-spec-local.json"
if ! make_test_spec "${REPO_ROOT}/app/Sources/MirageCore/Resources/sdk-spec.json" \
        "$TEST_SPEC" "$SERVER_PORT" "$HTTP_ROOT"; then
    echo "❌ 產生本機測試 sdk-spec.json 失敗"
    exit 1
fi

S1_SDK=()
S1_AVD=()
for ((round = 1; round <= ROUNDS; round++)); do
    run_s1 "$round"
    if [ "$REAL_DOWNLOAD" -eq 1 ] && [ "$S2_RESULT_RECORDED" -eq 0 ]; then
        run_s2
    fi
    if [ "$S2_SUCCEEDED" -eq 1 ]; then
        run_s3 "$round" "$S2_SDK" "$S2_AVD" 1
    else
        run_s3 "$round" "${S1_SDK[$round]}" "${S1_AVD[$round]}" 0
    fi
    run_s4 "$round"
done

if [ "$S2_RESULT_RECORDED" -eq 0 ]; then
    record_result S2 SKIP "未指定 --real-download"
fi

echo ""
echo "=== 結果 ==="
printf '%-10s %-8s %s\n' "情境" "結果" "說明"
for index in "${!RESULT_LABELS[@]}"; do
    printf '%-10s %-8s %s\n' "${RESULT_LABELS[$index]}" "${RESULT_VALUES[$index]}" "${RESULT_DETAILS[$index]}"
done
if [ "$FAILURES" -ne 0 ]; then
    echo "❌ ${FAILURES} 個情境失敗"
    exit 1
fi
echo "✅ 所有已執行情境通過"
