#!/usr/bin/env bash
# verify_common.sh 的自我測試。**不需要模擬器、不需要 adb**——這正是把判斷抽成共用
# 函式的目的：斷言邏輯只有一份，就只需要注入故障驗一次。
#
# 用法：./scripts/lib/verify_common_selftest.sh（退出碼 0 = 全部通過）
set -uo pipefail
LIB="$(dirname "$0")/verify_common.sh"
FAILURES=0

# 在子 shell 裡跑一段會呼叫 assert_* 的程式碼，回報它的退出碼。
# 子 shell 是必要的：assert_* 失敗時會 `exit 1`，不隔離的話會把測試自己殺掉。
run_case() {
    ( set +e; source "$LIB" > /dev/null 2>&1; eval "$1" > /dev/null 2>&1 )
    echo $?
}

check() {
    local desc="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then
        echo "✅ $desc"
    else
        # 變數一律用 ${} 包起來——`$desc：`（裸變數緊接全形字元）會被 bash 當成變數名的
        # 一部分，`set -u` 當場報「未綁定的變數」。ci.sh:84-86 早就記載過這個坑並附最小
        # 重現，而這一行是**失敗路徑**、平常不會執行，所以直到注入突變才現形。
        echo "❌ ${desc}：退出碼 ${got}，期待 ${want}"
        FAILURES=$((FAILURES + 1))
    fi
}

echo "=== verify_common.sh 自我測試 ==="

check "assert_ok 收到 0 → 繼續執行"        "$(run_case 'assert_ok "測試" 0')"           0
check "assert_ok 收到非 0 → 中止（exit 1）" "$(run_case 'assert_ok "測試" 1')"           1
check "assert_ok 收到 130 → 一樣中止"       "$(run_case 'assert_ok "測試" 130')"         1
check "assert_at_least 達標 → 繼續"         "$(run_case 'assert_at_least "包數" 80 75')" 0
check "assert_at_least 剛好達標 → 繼續"     "$(run_case 'assert_at_least "包數" 75 75')" 0
check "assert_at_least 未達標 → 中止"       "$(run_case 'assert_at_least "包數" 74 75')" 1
check "assert_at_least 值為空 → 當作 0 中止" "$(run_case 'assert_at_least "包數" "" 75')" 1
check "assert_equals 相等 → 繼續"           "$(run_case 'assert_equals "abi" "arm64-v8a" "arm64-v8a"')" 0
check "assert_equals 不等 → 中止"           "$(run_case 'assert_equals "abi" "x86_64" "arm64-v8a"')"    1
# 空字串是這個函式最需要擋的輸入：`adb shell getprop` 在裝置沒回應時回空字串，
# 若把空字串當成「相等」，整組蒐證會在裝置根本沒起來時回報全綠。
check "assert_equals 實測為空 → 中止"       "$(run_case 'assert_equals "abi" "" "arm64-v8a"')"          1

# assert_at_most 是 assert_at_least 的反向：驗收線 6 的 underrun 增量要的是上限。
# 邊界（剛好等於門檻）刻意與 assert_at_least 同樣視為通過——門檻是「可接受的最大值」，
# 不是「必須低於」。
check "assert_at_most 低於門檻 → 繼續"      "$(run_case 'assert_at_most "欠位" 3 5')"  0
check "assert_at_most 剛好等於門檻 → 繼續"  "$(run_case 'assert_at_most "欠位" 5 5')"  0
check "assert_at_most 超過門檻 → 中止"      "$(run_case 'assert_at_most "欠位" 6 5')"  1
# 空字串當作 0：解析 log 沒抓到數字時，`assert_at_least` 的既有語意是「當作 0 → 中止」，
# 反向斷言若照抄「當作 0」則會**通過**——那就是假綠燈。所以這裡的空字串必須是呼叫端
# 自己先擋掉的（Task 4 的 A1/A2 斷言負責），本函式只保證行為明確可預期，不自作聰明。
check "assert_at_most 值為空 → 當作 0 通過" "$(run_case 'assert_at_most "欠位" "" 5')" 0
check "assert_at_most 中止後不執行後續指令" \
      "$(run_case 'assert_at_most "欠位" 6 5; exit 0')" 1

# 中止之後不得繼續執行後面的步驟——這是整組斷言的重點：
# 「印了 ❌ 但腳本照樣跑完並回傳 0」正是 D9 要修掉的那種假綠燈（verify_mmap.sh 的原狀）。
check "assert_ok 中止後不執行後續指令" \
      "$(run_case 'assert_ok "測試" 1; exit 0')" 1

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "全部通過"
    exit 0
fi
echo "$FAILURES 項失敗"
exit 1
