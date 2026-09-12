#!/usr/bin/env bash
# emu_instances.sh 的自我測試。**不需要模擬器、不需要 adb**：所有 pgrep 輸出都是假的。
#
# 假資料的來源（fixtures-must-come-from-real-logs）：
#   PS_ONE 是 2026-09-12 在開發機上 `pgrep -fl qemu-system` 的實際輸出（路徑原樣保留）。
#   PS_TWO 的第二行照 RESULTS-multi-instance.md 記載的兩台啟動旗標（含 -read-only）依同一形狀寫成。
#   PS_NOGRPC 是 emu.sh 檔頭記載的「不指定 -grpc 會拿到隨機埠」那種行程。
#
# 用法：./scripts/lib/emu_selftest.sh（退出碼 0 = 全部通過）
set -uo pipefail
LIB="$(dirname "$0")/emu_instances.sh"
FAILURES=0

run_case() {
    ( set +e; source "$LIB" > /dev/null 2>&1; eval "$1" > /dev/null 2>&1 )
    echo $?
}

run_out() {
    ( set +e; source "$LIB" > /dev/null 2>&1; eval "$1" 2>/dev/null )
}

check() {
    local desc="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then
        echo "✅ $desc"
    else
        echo "❌ ${desc}：得到 '${got}'，期待 '${want}'"
        FAILURES=$((FAILURES + 1))
    fi
}

QEMU='/Users/hanfourhuang/Library/Android/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64'
PS_ONE="62234 ${QEMU} -avd mirage-game -no-snapshot -port 5554 -grpc 8554 -grpc-use-token"
PS_TWO="${PS_ONE}
62911 ${QEMU} -avd mirage-poc -read-only -no-snapshot -port 5556 -grpc 8556 -grpc-use-token"
PS_NOGRPC="70001 ${QEMU} -avd mirage-game -no-snapshot -port 5554"
# 倒序：status 的輸出要依埠排序，不能依 pgrep 的順序。
PS_REVERSED="62911 ${QEMU} -avd mirage-poc -no-snapshot -port 5556 -grpc 8556 -grpc-use-token
${PS_ONE}"

echo "=== emu_instances.sh 自我測試 ==="

echo "--- emu_names ---"
check "名稱依表格順序列出" "$(run_out 'emu_names "a:5554:8554 b:5556:8556"')" "a, b"
check "空表格名稱清單為空" "$(run_out 'emu_names ""')" ""

echo "--- emu_validate_triplet ---"
check "有效三元組通過" "$(run_case 'emu_validate_triplet a 5554 8554')" 0
check "空 AVD 被拒絕" "$(run_case 'emu_validate_triplet "" 5554 8554')" 1
check "gRPC 零被拒絕" "$(run_case 'emu_validate_triplet a 5554 0')" 1
check "gRPC 超出上限被拒絕" "$(run_case 'emu_validate_triplet a 5554 65536')" 1

echo "--- emu_resolve ---"
check "預設名稱 → 現在的三元組" \
      "$(run_out 'emu_resolve mirage-game')" "mirage-game 5554 8554"
check "第二台 → 5556／8556" \
      "$(run_out 'emu_resolve mirage-poc')" "mirage-poc 5556 8556"
check "未知名稱 → 1" "$(run_case 'emu_resolve nope')" 1
check "未知名稱 → 不印任何三元組" "$(run_out 'emu_resolve nope')" ""
check "自訂表格可覆寫" \
      "$(run_out 'emu_resolve alt "alt:5558:8558"')" "alt 5558 8558"
check "console 埠是奇數 → 1（emulator 只接受偶數埠）" \
      "$(run_case 'emu_resolve bad "bad:5555:8555"')" 1
check "console 埠超出 5554–5682 → 1" \
      "$(run_case 'emu_resolve bad "bad:5000:8000"')" 1
check "gRPC 埠不是數字 → 1" \
      "$(run_case 'emu_resolve bad "bad:5554:x"')" 1
check "少一欄 → 1" "$(run_case 'emu_resolve bad "bad:5554"')" 1

echo "--- emu_table_check ---"
check "預設表格通過" "$(run_case 'emu_table_check')" 0
check "同一個 AVD 出現兩次 → 1" \
      "$(run_case 'emu_table_check "a:5554:8554 a:5556:8556"')" 1
check "同一個 console 埠出現兩次 → 1" \
      "$(run_case 'emu_table_check "a:5554:8554 b:5554:8556"')" 1
check "同一個 gRPC 埠出現兩次 → 1" \
      "$(run_case 'emu_table_check "a:5554:8554 b:5556:8554"')" 1
check "表格裡有無效三元組 → 1" \
      "$(run_case 'emu_table_check "a:5554:8554 b:5557:8556"')" 1

echo "--- emu_running_instances ---"
check "一台 → 一行 pid avd console grpc" \
      "$(run_out "emu_running_instances '${PS_ONE}'")" "62234 mirage-game 5554 8554"
check "兩台 → 兩行" \
      "$(run_out "emu_running_instances '${PS_TWO}'")" \
      "62234 mirage-game 5554 8554
62911 mirage-poc 5556 8556"
check "倒序輸入 → 仍依 console 埠排序" \
      "$(run_out "emu_running_instances '${PS_REVERSED}'")" \
      "62234 mirage-game 5554 8554
62911 mirage-poc 5556 8556"
check "沒有 -grpc → grpc 欄印 ?" \
      "$(run_out "emu_running_instances '${PS_NOGRPC}'")" "70001 mirage-game 5554 ?"
check "空輸入 → 空" "$(run_out "emu_running_instances ''")" ""
check "不含 qemu-system 的行被忽略" \
      "$(run_out "emu_running_instances '123 /bin/bash ./emu.sh -n mirage-poc start -port 5556'")" ""

echo "--- emu_is_running ---"
check "一台在 5554，問 5554 → 0" "$(run_case "emu_is_running '${PS_ONE}' 5554")" 0
# 這一條是整組的核心：舊的 running() 匹配任何 qemu，第二台會被當成「已在執行」。
check "一台在 5554，問 5556 → 1" "$(run_case "emu_is_running '${PS_ONE}' 5556")" 1
check "兩台，問 5556 → 0" "$(run_case "emu_is_running '${PS_TWO}' 5556")" 0
check "兩台，問 5558 → 1" "$(run_case "emu_is_running '${PS_TWO}' 5558")" 1
check "埠要整段相等，555 不能匹配 5554" "$(run_case "emu_is_running '${PS_ONE}' 555")" 1
check "空輸入 → 1" "$(run_case "emu_is_running '' 5554")" 1

echo "--- emu_avd_conflict ---"
check "mirage-game 在 5554 跑，要在 5556 再開 → 衝突（0）" \
      "$(run_case "emu_avd_conflict '${PS_ONE}' mirage-game 5556")" 0
check "衝突時印出佔用的埠" \
      "$(run_out "emu_avd_conflict '${PS_ONE}' mirage-game 5556")" "5554"
check "同一個 AVD 同一個埠 → 不算衝突（1），那是「已在執行」" \
      "$(run_case "emu_avd_conflict '${PS_ONE}' mirage-game 5554")" 1
check "不同 AVD → 1" "$(run_case "emu_avd_conflict '${PS_ONE}' mirage-poc 5556")" 1
check "沒有任何 qemu → 1" "$(run_case "emu_avd_conflict '' mirage-game 5554")" 1

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "全部通過"
    exit 0
fi
echo "$FAILURES 項失敗"
exit 1
