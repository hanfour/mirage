#!/usr/bin/env bash
# D2 鍵盤直通的活體驗證。
#
# **儀器**：adb shell getevent -l，直接讀 guest kernel 的 evdev 事件流。
# 不用「開文字框打字看有沒有字」——那是代理指標，沒出現字可能是鍵沒送到、
# 焦點不在輸入框、或輸入法沒起來，三種原因看起來一模一樣。
#
# **職責**：斷言全部在本腳本。`KeyboardLiveTests` 只負責送鍵、自己不斷言，
# 它的綠燈什麼都不證明（該檔 doc comment 已寫明）。
#
# **不是零斷言腳本**：每個期待的 evdev 鍵都會被檢查，缺一個就退出碼非零。
# （D9 記載 verify_snapshot.sh 是「11 行零斷言、只存 PNG 印字」——不重蹈。）
#
# 注意：`$VAR` 後面若直接接全形字元（無 ASCII 分隔），bash 5.x 在 UTF-8 locale 下
# 會把該字元的第一個 byte 誤判成識別字的一部分，炸成「未綁定的變數」——實測重現過。
# 本檔遇到的兩處都改用 `${VAR}` 明確收邊字元界線來避開。
set -uo pipefail

TARGET_SERIAL="${MIRAGE_ADB_SERIAL:-emulator-5554}"
TARGET_PORT="${MIRAGE_PORT:-8554}"
ADB="$HOME/Library/Android/sdk/platform-tools/adb"

# 與 KeyboardLiveTests.sequence 一一對應。改一邊要同步改另一邊。
#
# KEY_HOME／KEY_APPSELECT（選單列的「主畫面」「最近任務」）是 2026-07-29 補上的：
# 這兩顆使用者可見功能先前既無單元測試、也不在這份活體清單裡，三個 Android 實體鍵
# 只驗了 GoBack 一個。evdev 名稱以設計文件 §2 的實測為準——GoHome 對應 `KEY_HOME`
# 而**不是** `KEY_HOMEPAGE`（猜錯名稱正是該次量測的兩個假陰性之一）。
EXPECTED=(KEY_A KEY_ENTER KEY_BACKSPACE KEY_BACK KEY_HOME KEY_APPSELECT)

cd "$(dirname "$0")/.." || exit 1
FAILURES=0

if [ ! -x "$ADB" ]; then
    echo "❌ 找不到可執行的 adb：$ADB"; exit 1
fi
if [ "$("$ADB" -s "$TARGET_SERIAL" get-state 2>/dev/null)" != "device" ]; then
    echo "❌ $TARGET_SERIAL 不在線。設 MIRAGE_ADB_SERIAL / MIRAGE_PORT 指定機器。"
    exit 1
fi
echo "✅ 目標：${TARGET_SERIAL}（gRPC ${TARGET_PORT}）"

LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT

echo "=== 開始擷取 evdev 事件並送鍵 ==="
"$ADB" -s "$TARGET_SERIAL" shell getevent -l > "$LOG" 2>/dev/null &
GE_PID=$!
sleep 1                       # 暖機。實測 0.4 秒太短會產生假陰性

MIRAGE_LIVE=1 MIRAGE_PORT="$TARGET_PORT" \
    swift test --filter KeyboardLiveTests 2>&1 | tail -3

sleep 1
kill "$GE_PID" 2>/dev/null; wait "$GE_PID" 2>/dev/null

echo ""
echo "=== 判定 ==="
for key in "${EXPECTED[@]}"; do
    n=$(grep -c " $key " "$LOG" 2>/dev/null || true)
    if [ "${n:-0}" -ge 2 ]; then          # 一次按放 = DOWN + UP 兩行
        echo "✅ ${key}（${n} 行）"
    else
        echo "❌ $key 只看到 ${n:-0} 行，期待 ≥2（DOWN + UP）"
        FAILURES=$((FAILURES + 1))
    fi
done

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "全部通過：${#EXPECTED[@]} 個鍵都送達 guest"
    exit 0
fi
echo "$FAILURES 個鍵沒送達"
exit 1
