#!/usr/bin/env bash
# 往 guest 的文字欄位送字，專門處理 Unity app 的輸入問題。
# 用法：guest_text_input.sh <serial> <x> <y> <文字>
#
# **為什麼需要這支而不是直接 `adb shell input text`**
# （2026-09-10 在 Pikmin Bloom 的生日欄位上實測）：
#
# 1. **軟鍵盤在 Unity app 上不算繪**，畫面下方是一塊全黑區域。
#    但欄位的 focus 與 IME 都是正常的（狀態列會出現「123」之類的指示），
#    所以「看起來沒反應」不代表輸入路徑壞掉。**不要因此去改 hw.keyboard**：
#    那個值已經是 yes，而且 provision 的規格（lib/config_base.py）要求它是 yes。
#
# 2. **一次送整串會錯位。** `input text "01011990"` 實測變成 `00/10/1199`：
#    Unity 的欄位一邊吃字元一邊重排游標，送太快就對不上。
#    逐字送、每字之間留 0.8 秒才正確。
#
# 3. ⚠️ **不要送 `KEYCODE_ESCAPE` 去關軟鍵盤。** 在 Android 上它等同返回鍵，
#    會把整個 app 關掉（本輪踩過，Pikmin Bloom 直接退回桌面）。
#    要收鍵盤用 `KEYCODE_BACK` 也一樣危險，乾脆不收：欄位會自己讓位。
#
# 4. 送完務必**擷圖確認**。`input` 沒有回傳值可以判斷成功與否，
#    而本 repo 的教訓是「沒有訊號的失敗最貴」。
set -uo pipefail
ADB="${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}"
SERIAL="${1:?用法：guest_text_input.sh <serial> <x> <y> <文字>}"
X="${2:?}"; Y="${3:?}"; TEXT="${4:?}"
CHAR_DELAY="${CHAR_DELAY:-0.8}"

"$ADB" -s "$SERIAL" shell input tap "$X" "$Y" >/dev/null 2>&1
sleep 2
# 先清空：Unity 欄位可能已有殘留，而游標位置不保證在結尾。
for _ in $(seq 1 20); do "$ADB" -s "$SERIAL" shell input keyevent KEYCODE_FORWARD_DEL >/dev/null 2>&1; done
for _ in $(seq 1 20); do "$ADB" -s "$SERIAL" shell input keyevent KEYCODE_DEL >/dev/null 2>&1; done
sleep 1

len=${#TEXT}
for ((i=0; i<len; i++)); do
    "$ADB" -s "$SERIAL" shell input text "${TEXT:$i:1}" >/dev/null 2>&1
    sleep "$CHAR_DELAY"
done
echo "已逐字送出 ${len} 個字元（每字間隔 ${CHAR_DELAY}s）到 ${SERIAL} 的 (${X}, ${Y})"
echo "⚠️ input 沒有回傳值可判成敗，請擷圖確認：adb -s ${SERIAL} exec-out screencap -p > /tmp/check.png"
