#!/usr/bin/env bash
# emu_instances.sh 與 emu.sh 的自我測試。不需要模擬器或真 adb：行程與 SDK 都用假資料。
#
# 假資料的來源（fixtures-must-come-from-real-logs）：
#   PS_ONE 是 2026-09-12 在開發機上 `pgrep -fl qemu-system` 的實際輸出（路徑原樣保留）。
#   PS_TWO 的第二行照 RESULTS-multi-instance.md 記載的兩台啟動旗標（含 -read-only）依同一形狀寫成。
#   PS_NOGRPC 是 emu.sh 檔頭記載的「不指定 -grpc 會拿到隨機埠」那種行程。
#
# 用法：./scripts/lib/emu_selftest.sh（退出碼 0 = 全部通過）
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="${SCRIPT_DIR}/emu_instances.sh"
unset MIRAGE_HEADLESS
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

echo "--- emu_should_disable_soft_keyboard ---"
check "目前是 0 → 不重複 put" "$(run_case 'emu_should_disable_soft_keyboard 0')" 1
check "目前是 1 → put 0" "$(run_case 'emu_should_disable_soft_keyboard 1')" 0
check "目前是 null → put 0" "$(run_case 'emu_should_disable_soft_keyboard null')" 0
check "目前是空值 → put 0" "$(run_case 'emu_should_disable_soft_keyboard ""')" 0

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

echo "--- emu_select_triplet ---"
check "沒有 -n → 預設三元組" \
      "$(run_out 'emu_select_triplet ""')" "mirage-game 5554 8554"
check "沒有 -n → MIRAGE_PORT 覆寫生效" \
      "$(run_out 'emu_select_triplet "" "$EMU_DEFAULT_INSTANCES" "" 5558 ""')" "mirage-game 5558 8554"
check "沒有 -n → 三個覆寫皆生效" \
      "$(run_out 'emu_select_triplet "" "$EMU_DEFAULT_INSTANCES" custom 5558 8558')" "custom 5558 8558"
check "沒有 -n → 採用表格第一台" \
      "$(run_out 'emu_select_triplet "" "alt:5560:8560 mirage-game:5554:8554"')" "alt 5560 8560"
check "有 -n → 忽略三個覆寫" \
      "$(run_out 'emu_select_triplet mirage-poc "$EMU_DEFAULT_INSTANCES" custom 5558 8558')" "mirage-poc 5556 8556"
check "選取未知名稱 → 1" "$(run_case 'emu_select_triplet nope')" 1
check "選取重複表格 → 1" "$(run_case 'emu_select_triplet "" "a:5554:8554 a:5556:8556"')" 1
check "無效 console 覆寫 → 1" \
      "$(run_case 'emu_select_triplet "" "$EMU_DEFAULT_INSTANCES" "" 5555')" 1
check "純空白表格 → 1" "$(run_case 'emu_select_triplet "" " "')" 1

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
check "一台 → 一行 pid avd console grpc window" \
      "$(run_out "emu_running_instances '${PS_ONE}'")" "62234 mirage-game 5554 8554 windowed"
check "兩台 → 兩行" \
      "$(run_out "emu_running_instances '${PS_TWO}'")" \
      "62234 mirage-game 5554 8554 windowed
62911 mirage-poc 5556 8556 windowed"
check "倒序輸入 → 仍依 console 埠排序" \
      "$(run_out "emu_running_instances '${PS_REVERSED}'")" \
      "62234 mirage-game 5554 8554 windowed
62911 mirage-poc 5556 8556 windowed"
check "沒有 -grpc → grpc 欄印 ?" \
      "$(run_out "emu_running_instances '${PS_NOGRPC}'")" "70001 mirage-game 5554 ? windowed"
check "空輸入 → 空" "$(run_out "emu_running_instances ''")" ""
check "不含 qemu-system 的行被忽略" \
      "$(run_out "emu_running_instances '123 /bin/bash ./emu.sh -n mirage-poc start -port 5556'")" ""

# 依 2026-09-15 實測的 qemu 路徑格式建立 headless 行程。
PS_HEADLESS="62911 ${QEMU}-headless -avd mirage-poc -no-snapshot -port 5556 -grpc 8556 -grpc-use-token"
check "headless 執行檔（沒有 -no-window）" \
      "$(run_out "emu_running_instances '${PS_HEADLESS}'")" "62911 mirage-poc 5556 8556 headless"
check "一般執行檔帶 -no-window" \
      "$(run_out "emu_running_instances '${PS_ONE} -no-window'")" "62234 mirage-game 5554 8554 headless"
check "AVD 名含 headless 或相似旗標不算無視窗" \
      "$(run_out "emu_running_instances '70002 ${QEMU} -avd qemu-system-aarch64-headless -port 5554 -no-window-extra'")" "70002 qemu-system-aarch64-headless 5554 ? windowed"

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

echo "--- emu.sh status 接線：adb 吃光 stdin 仍列出兩台 ---"
SDK_FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/mirage-emu-selftest.XXXXXX") || exit 1
trap 'rm -rf "$SDK_FIXTURE"' EXIT
mkdir -p "${SDK_FIXTURE}/platform-tools" || exit 1
# 真 adb 會讀 stdin；故意吃光它，才能抓出 status 迴圈共用 stdin 的接線錯誤。
cat > "${SDK_FIXTURE}/platform-tools/adb" <<'FAKE_ADB'
#!/usr/bin/env bash
cat > /dev/null
case "$*" in
    *'shell getprop sys.boot_completed') printf '1\n' ;;
    *'shell dumpsys activity activities')
        printf '  topResumedActivity=ActivityRecord{123 u0 com.example.game/.MainActivity t1}\n' ;;
    *) exit 1 ;;
esac
FAKE_ADB
chmod +x "${SDK_FIXTURE}/platform-tools/adb" || exit 1
STATUS_OUT=$(ANDROID_SDK_ROOT="$SDK_FIXTURE" MIRAGE_EMU_PS_LINES="${PS_ONE}
${PS_HEADLESS}" \
    MIRAGE_INSTANCES='mirage-game:5554:8554 mirage-poc:5556:8556' \
    MIRAGE_AVD='' MIRAGE_PORT='' MIRAGE_GRPC='' \
    bash "$(dirname "$0")/../emu.sh" status < /dev/null)
check "status 接線退出碼" "$?" 0
printf '%s\n' "$STATUS_OUT"
check "status 兩台各自顯示視窗模式" "$(printf '%s\n' "$STATUS_OUT" | grep '視窗：')" "  視窗：有
  視窗：headless"
for serial in emulator-5554 emulator-5556; do
    [[ "$STATUS_OUT" == *"執行中：${serial}（開機完成"* ]]
    check "吃光 stdin 後仍列出 ${serial} 且開機完成" "$?" 0
done

echo "--- emu.sh start 接線：已開機仍套用，第二次不 put ---"
cat > "${SDK_FIXTURE}/platform-tools/adb" <<'FAKE_ADB'
#!/usr/bin/env bash
case "$*" in
    *'shell getprop sys.boot_completed') printf '1\r\n' ;;
    *'shell settings get secure show_ime_with_hard_keyboard')
        cat "$ANDROID_SDK_ROOT/keyboard-value" ;;
    *'shell settings put secure show_ime_with_hard_keyboard 0')
        printf 'put\n' >> "$ANDROID_SDK_ROOT/keyboard-writes"
        printf '0\r\n' > "$ANDROID_SDK_ROOT/keyboard-value" ;;
    *) exit 1 ;;
esac
FAKE_ADB
printf '1\r\n' > "$SDK_FIXTURE/keyboard-value"
for attempt in 1 2; do
    START_OUT=$(ANDROID_SDK_ROOT="$SDK_FIXTURE" MIRAGE_EMU_PS_LINES="$PS_TWO" \
        MIRAGE_INSTANCES='mirage-game:5554:8554 mirage-poc:5556:8556' \
        MIRAGE_AVD='' MIRAGE_PORT='' MIRAGE_GRPC='' \
        bash "$(dirname "$0")/../emu.sh" start < /dev/null)
    check "start 第 ${attempt} 次成功" "$?" 0
    if [ "$attempt" = 1 ]; then
        [[ "$START_OUT" == *'show_ime_with_hard_keyboard：1 → 0'* ]]
        check "修改時印設定行" "$?" 0
    fi
done
check "兩次 start 只 put 一次" "$(cat "$SDK_FIXTURE/keyboard-writes")" put

echo "--- emu.sh start 接線：settings 失敗不影響開機成功 ---"
cat > "${SDK_FIXTURE}/platform-tools/adb" <<'FAKE_ADB'
#!/usr/bin/env bash
case "$*" in
    *'shell getprop sys.boot_completed')
        if [ -f "$ANDROID_SDK_ROOT/boot-pending" ]; then
            rm "$ANDROID_SDK_ROOT/boot-pending"
            printf '0\n'
        else
            printf '1\n'
        fi ;;
    *'shell settings get secure show_ime_with_hard_keyboard')
        if [ "$KEYBOARD_FAILURE" = get ]; then
            echo 'settings service unavailable' >&2; exit 1
        fi
        printf '1\n' ;;
    *'shell settings put secure show_ime_with_hard_keyboard 0')
        echo 'settings service unavailable' >&2; exit 1 ;;
    *) exit 1 ;;
esac
FAKE_ADB
for boot_state in ready pending; do
    for failure in get put; do
        if [ "$boot_state" = pending ]; then touch "$SDK_FIXTURE/boot-pending"; fi
        START_OUT=$(ANDROID_SDK_ROOT="$SDK_FIXTURE" MIRAGE_EMU_PS_LINES="$PS_TWO" \
            MIRAGE_INSTANCES='mirage-game:5554:8554 mirage-poc:5556:8556' \
            MIRAGE_AVD='' MIRAGE_PORT='' MIRAGE_GRPC='' KEYBOARD_FAILURE="$failure" \
            bash "$(dirname "$0")/../emu.sh" start < /dev/null 2> "$SDK_FIXTURE/start-stderr")
        check "${boot_state}：settings ${failure} 失敗仍退出 0" "$?" 0
        if [ "$boot_state" = pending ]; then
            [[ "$START_OUT" == *'✅ 開機完成'* ]]
        else
            [[ "$START_OUT" == *'✅ 已在執行且開機完成'* ]]
        fi
        check "${boot_state}：settings ${failure} 失敗仍印開機成功" "$?" 0
        START_ERR=$(cat "$SDK_FIXTURE/start-stderr")
        [[ "$START_ERR" == '⚠️ '* && "$START_ERR" == *'guest 軟體鍵盤'* && "$START_ERR" != *$'\n'* ]]
        check "${boot_state}：settings ${failure} 失敗 stderr 只有一行警告" "$?" 0
    done
done

echo "--- headless 啟動接線（假 SDK，不啟動模擬器） ---"
mkdir -p "$SDK_FIXTURE/emulator" "$SDK_FIXTURE/bin" || exit 1
cat > "$SDK_FIXTURE/emulator/emulator" <<'FAKE_EMULATOR'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$@" > "$ANDROID_SDK_ROOT/launch-args"
FAKE_EMULATOR
cat > "$SDK_FIXTURE/bin/sleep" <<'FAKE_SLEEP'
#!/usr/bin/env bash
exit 0
FAKE_SLEEP
cat > "$SDK_FIXTURE/platform-tools/adb" <<'FAKE_ADB'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >> "$ANDROID_SDK_ROOT/adb-calls"
case "$*" in
    *'shell getprop sys.boot_completed')
        if [ "${MIRAGE_EMU_PS_LINES:-}" = "" ]; then
            for ((i=0; i<100; i++)); do
                [ -f "$ANDROID_SDK_ROOT/launch-args" ] && break
                /bin/sleep 0.01
            done
            [ -f "$ANDROID_SDK_ROOT/launch-args" ] || exit 1
        fi
        printf '1\n' ;;
    *'shell settings get secure show_ime_with_hard_keyboard') printf '0\n' ;;
    *) exit 1 ;;
esac
FAKE_ADB
chmod +x "$SDK_FIXTURE/emulator/emulator" "$SDK_FIXTURE/bin/"* || exit 1
fixture_emu() {
    ANDROID_SDK_ROOT="$SDK_FIXTURE" PATH="$SDK_FIXTURE/bin:$PATH" \
        MIRAGE_INSTANCES='mirage-game:5554:8554 mirage-poc:5556:8556' \
        MIRAGE_AVD='' MIRAGE_PORT='' MIRAGE_GRPC='' \
        bash "$SCRIPT_DIR/../emu.sh" "$@" < /dev/null
}
for mode in default flag_first name_first command_first env; do
    rm -f "$SDK_FIXTURE/launch-args"
    case "$mode" in
      default) args=(start); headless=0; avd=mirage-game ;;
      flag_first) args=(-H -n mirage-poc start); headless=0; avd=mirage-poc ;;
      name_first) args=(-n mirage-poc -H start); headless=0; avd=mirage-poc ;;
      command_first) args=(start -H -n mirage-poc); headless=0; avd=mirage-poc ;;
      env) args=(start); headless=1; avd=mirage-game ;;
    esac
    START_OUT=$(MIRAGE_EMU_PS_LINES='' MIRAGE_HEADLESS="$headless" fixture_emu "${args[@]}")
    check "${mode}：啟動成功" "$?" 0
    check "${mode}：正確 AVD" "$(sed -n '2p' "$SDK_FIXTURE/launch-args")" "$avd"
    if [ "$mode" = default ]; then expected=0; else expected=1; fi
    check "${mode}：-no-window 數量" "$(grep -c -- '^-no-window$' "$SDK_FIXTURE/launch-args")" "$expected"
done
for mode in flag env; do
    rm -f "$SDK_FIXTURE/launch-args" "$SDK_FIXTURE/adb-calls"
    if [ "$mode" = flag ]; then args=(-H start); headless=0; else args=(start); headless=1; fi
    START_OUT=$(MIRAGE_EMU_PS_LINES="$PS_ONE" MIRAGE_HEADLESS="$headless" fixture_emu "${args[@]}")
    check "${mode}：有視窗實例退出 0" "$?" 0
    check "${mode}：提示手動重開" "$START_OUT" '已在執行（有視窗）；要換成 headless 請 stop 後重開'
    [ ! -f "$SDK_FIXTURE/launch-args" ] && [ ! -f "$SDK_FIXTURE/adb-calls" ]
    check "${mode}：不重啟、不呼叫 adb 或等待開機" "$?" 0
done
START_OUT=$(MIRAGE_EMU_PS_LINES="$PS_HEADLESS" fixture_emu -n mirage-poc -H start)
check "已有 headless 實例退出 0" "$?" 0
[[ "$START_OUT" == *'已在執行且開機完成'* ]]
check "已有 headless 實例保持冪等" "$?" 0
[ ! -f "$SDK_FIXTURE/launch-args" ]
check "已有 headless 實例不重開" "$?" 0
fixture_emu -H -n > /dev/null 2>&1
check "-n 缺名稱退出 2" "$?" 2
fixture_emu -n -H start > /dev/null 2>&1
check "-n 不會吞掉 -H" "$?" 2

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "全部通過"
    exit 0
fi
echo "$FAILURES 項失敗"
exit 1
