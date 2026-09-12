#!/usr/bin/env bash
# 模擬器多開切換的活體驗證：只連已啟動的兩台，不負責啟停。
# 使用者先用 emu.sh -n <名稱> start 啟動兩台，再執行本腳本。
# 依序對第一台、第二台、第一台跑 guest getevent 鍵盤判定，
# 每段確認另一台 sys.boot_completed = 1；GUI 選單切換仍需人工驗收。
# 用法：./scripts/verify_instance_switch.sh
# MIRAGE_FIRST／MIRAGE_SECOND：預設 mirage-game／mirage-poc。
# MIRAGE_INSTANCES：可覆寫 lib/emu_instances.sh 的實例表。
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/verify_common.sh"
source "${SCRIPT_DIR}/lib/emu_instances.sh"
source "${SCRIPT_DIR}/lib/load_sentinel.sh"

FIRST="${MIRAGE_FIRST:-mirage-game}"
SECOND="${MIRAGE_SECOND:-mirage-poc}"
TABLE="${MIRAGE_INSTANCES:-$EMU_DEFAULT_INSTANCES}"

test "$FIRST" != "$SECOND"
assert_ok '兩台必須是不同的實例' "$?"
emu_table_check "$TABLE"
assert_ok '實例表有效且 AVD／console／gRPC 不重複' "$?"
FIRST_T=$(emu_resolve "$FIRST" "$TABLE")
assert_ok "解析第一台 ${FIRST}" "$?"
SECOND_T=$(emu_resolve "$SECOND" "$TABLE")
assert_ok "解析第二台 ${SECOND}" "$?"
read -r FIRST_AVD FIRST_PORT FIRST_GRPC <<< "$FIRST_T"
read -r SECOND_AVD SECOND_PORT SECOND_GRPC <<< "$SECOND_T"

# require_grpc 失敗會 exit；用子殼層收集結果，兩個埠都檢查並列出缺少的啟動指令。
MISSING=0
check_grpc() {
    local name="$1" grpc="$2"
    if ! (require_grpc "$grpc"); then
        printf '請先啟動 %s（gRPC %s）：\n' "$name" "$grpc"
        printf '  MIRAGE_INSTANCES=%q %q -n %q start\n' "$TABLE" "${SCRIPT_DIR}/emu.sh" "$name"
        MISSING=1
    fi
}
check_grpc "$FIRST" "$FIRST_GRPC"
check_grpc "$SECOND" "$SECOND_GRPC"
assert_ok '兩台 gRPC 都有人監聽' "$MISSING"

require_adb
disk_preflight "$SCRIPT_DIR"
assert_ok '主機磁碟前置檢查' "$?"
require_device "emulator-${FIRST_PORT}"
require_device "emulator-${SECOND_PORT}"
echo "✅ 兩台：${FIRST}（${FIRST_PORT}／${FIRST_GRPC}）與 ${SECOND}（${SECOND_PORT}／${SECOND_GRPC}）"

# verify_keyboard.sh 會呼叫 Swift 活體測試，並以 guest getevent 判斷鍵是否送達。
# 它自行 cd 到 app/，所以使用絕對路徑呼叫，並明確指定每一段的目標。
check_target() {
    local label="$1" port="$2" grpc="$3" other_label="$4" other_port="$5" booted
    echo ""
    echo "=== 驗證 ${label}（emulator-${port}，gRPC ${grpc}）==="
    ANDROID_SERIAL="emulator-${port}" MIRAGE_ADB_SERIAL="emulator-${port}" MIRAGE_PORT="$grpc" \
        "${SCRIPT_DIR}/verify_keyboard.sh"
    assert_ok "${label} 的鍵盤判定" "$?"
    booted=$("$ADB" -s "emulator-${other_port}" shell getprop sys.boot_completed | tr -d '\r')
    assert_ok "讀取另一台 ${other_label} 的開機狀態" "$?"
    assert_equals "另一台 ${other_label} 仍在開機狀態（sys.boot_completed）" "$booted" '1'
}

check_target "$FIRST"  "$FIRST_PORT"  "$FIRST_GRPC"  "$SECOND" "$SECOND_PORT"
check_target "$SECOND" "$SECOND_PORT" "$SECOND_GRPC" "$FIRST"  "$FIRST_PORT"
check_target "$FIRST"  "$FIRST_PORT"  "$FIRST_GRPC"  "$SECOND" "$SECOND_PORT"

echo ""
echo "全部通過：${FIRST} → ${SECOND} → ${FIRST} 三段鍵盤判定皆送達，每段確認另一台仍開機"
