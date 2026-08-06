#!/usr/bin/env bash
# D48：在 `verify_fps_fullscreen.sh` 的量測進行中，同步量 guest 端的 render fps。
#
# **存在的理由**（`app/RESULTS-d45-guest-render.md` 的「下一步：決定性實驗」）：
# D45 量到 guest 穩定 59.9 fps、`droppedFrames=0`，據此推翻了「瓶頸在 guest」。
# **但那是在 headless、主機 load≈3 的安靜窗口下量的**，而驗收線 7 的實際量測條件是
# 真 GUI 全螢幕、load 8–18。D45 自己標明這是限制 5：**沒有在問題會發作的條件下驗證過。**
#
# 這支腳本補上那一格：讓真正的 Mirage.app 全螢幕跑著、產生本機真實負載（含打包、
# 視窗合成、Metal 上傳），同時看 guest 有沒有掉幀。
#
#   guest 仍 0 掉幀 → 「瓶頸不在 guest」才算在正確條件下驗證過，損失全在下游鏈路
#   guest 開始掉幀 → 直接找到「43–51」的部分成因，不必再往下游猜
#
# 用法：./scripts/verify_fps_with_guest.sh [傳給 verify_fps_fullscreen.sh 的參數]
#   例：./scripts/verify_fps_with_guest.sh -r 1 -d 20
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.." || exit 1
source "$SCRIPT_DIR/lib/verify_common.sh"

SERIAL="${MIRAGE_SERIAL:-emulator-5556}"
OUT="${TMPDIR:-/tmp}/d48-timestats.txt"

require_adb
require_device "$SERIAL"

ts() { "$ADB" -s "$SERIAL" shell dumpsys SurfaceFlinger --timestats "$@" 2>/dev/null; }

# **窗口必須對齊擷取窗口，這是第一版最大的錯誤**。第一版在跑 verify 之前就
# enable，於是窗口涵蓋了 249 秒的 release build——那段時間 load 20+、guest 被 CPU
# 餓死，把 guest 的平均 fps 從真值拉到 34.28，而我差點把那個數字當成「真實負載下的
# guest 表現」寫進結論。這正是 D50／D54 記的形狀：**窗口沒對齊，量到的是別的東西。**
#
# 修法：先把 release build 跑完（不計入窗口），再 enable，然後才跑 verify。
echo "=== 預先建置 release（不計入量測窗口）==="
( cd "$SCRIPT_DIR/.." && swift build -c release > /dev/null 2>&1 )
assert_ok "release 預先建置" "$?"

# 等負載從 build 的餘波回落。**門檻對齊 verify_fps_fullscreen.sh 自己的 LOAD_LIMIT
# （預設 18），不要更嚴**——第一版寫死 8，比被包裝的腳本還嚴格，於是在這台機器的
# 常態負載（D45 實測 8–18）下永遠等不到，白等 5 分鐘再讓 verify 自己去擋。
# 包裝層的門檻比被包裝層嚴，只會製造假的等待，不會讓數字更乾淨。
WAIT_LOAD="${WAIT_LOAD:-18}"
echo "=== 等負載回落到 ${WAIT_LOAD} 以下（build 餘波）==="
for _ in $(seq 1 60); do
    la=$(uptime | sed 's/.*load averages*: *//' | awk '{print $1}')
    awk -v a="$la" -v l="$WAIT_LOAD" 'BEGIN { exit !(a < l) }' && break
    sleep 5
done
la=$(uptime | sed 's/.*load averages*: *//' | awk '{print $1}')
echo "   目前負載 ${la}"
# **量測前先確認機器上沒有別人的重負載工作。** 2026-08-06 第二次跑就撞到：三個 java
# 行程吃掉 356% CPU（使用者的其他工作），load 卡在 25–32，verify 的 load gate 一直擋。
# 那不是本腳本該解決的問題，但它該講清楚，而不是讓人盯著一個沒有進展的畫面。
busy=$(ps aux | sort -nrk3 | awk 'NR<=5 && $3>50 {printf "%.0f%% %s\n", $3, $11}' \
       | grep -vE "qemu-system|MirageApp" | head -3)
if [ -n "$busy" ]; then
    echo "⚠️  機器上有其他高 CPU 行程，fps 量測會被 load gate 擋或被污染："
    echo "$busy" | sed 's/^/      /'
    echo "   建議等它們結束再跑；硬跑出來的數字不可信（D54）。"
fi

echo ""
echo "=== 啟用 guest timestats ==="
ts -clear > /dev/null
ts -enable > /dev/null
echo "✅ 已啟用"

echo ""
echo "=== 跑 verify_fps_fullscreen.sh（真 GUI 全螢幕）==="
"$SCRIPT_DIR/verify_fps_fullscreen.sh" "$@"
VERIFY_STATUS=$?

echo ""
echo "=== 抓 guest timestats ==="
ts -dump > "$OUT"
ts -disable > /dev/null
echo "已寫入 ${OUT}（$(wc -l < "$OUT" | tr -d ' ') 行）"

echo ""
echo "=== guest render fps（Pixel Flow 的 Unity SurfaceView layer）==="
# **不要用 dumpsys 印的 `averageFPS`**：D45 已在 AOSP 原始碼層級確認它偏高約 3%
# （`TimeStats.cpp` 的 `toMs()` 對 present2present 間隔做 `duration_cast<milliseconds>`
# 無條件捨去，均勻分布下期望少 0.5ms，實測三個窗口偏差 0.50–0.53ms 完全吻合）。
# 用 `totalFrames ÷ displayOnTime` —— 不依賴 histogram 分桶的獨立算法。
python3 - "$OUT" <<'PYEOF'
import re, sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()

on = re.search(r"displayOnTime\s*=\s*(\d+)\s*ms", text)
display_on_ms = int(on.group(1)) if on else None

# 只看 Pixel Flow 自己那個 SurfaceView layer，不是全域聚合值。
block = None
for m in re.finditer(r"layerName\s*=\s*(.+)", text):
    if "pixelflow" in m.group(1).lower() and "SurfaceView" in m.group(1):
        block = text[m.start():m.start() + 2000]
        break

if block is None:
    print("❌ 找不到 Pixel Flow 的 SurfaceView layer——遊戲可能沒在前景，")
    print("   或這一輪 guest 根本沒出幀。原始 dump 見上面的路徑。")
    raise SystemExit(1)

def field(name, src=block):
    m = re.search(rf"{name}\s*=\s*([0-9.]+)", src)
    return float(m.group(1)) if m else None

total = field("totalFrames")
dropped = field("droppedFrames")
avg_reported = field("averageFPS")

print(f"  layer totalFrames  = {total:.0f}" if total is not None else "  totalFrames  = ?")
print(f"  droppedFrames      = {dropped:.0f}" if dropped is not None else "  droppedFrames = ?")
if display_on_ms and total:
    corrected = total / (display_on_ms / 1000.0)
    print(f"  窗口長度           = {display_on_ms / 1000:.2f}s")
    print(f"  **修正後 fps**     = {corrected:.2f}  (totalFrames ÷ 窗口)")
    if avg_reported:
        bias = (avg_reported - corrected) / corrected * 100
        print(f"  dumpsys averageFPS = {avg_reported:.2f}（偏高 {bias:.1f}%，已知的量測工具偏差）")
print("")
# **判定不能只看 droppedFrames，第一版就是這樣判錯的。**
# droppedFrames 只表示 SurfaceFlinger 沒有丟棄「已提交」的幀；如果 Unity 根本沒送滿
# 60，那 dropped 會是 0 而 guest 仍然是瓶頸。第一版量到 fps=34.28、dropped=0，
# 卻印出「瓶頸不在 guest」——正好相反。**真正的判準是 guest 的 fps 有沒有接近 60。**
if display_on_ms and total:
    corrected = total / (display_on_ms / 1000.0)
    print("")
    if corrected >= 55:
        print(f"→ **guest 在真實負載下維持 {corrected:.1f} fps**（≥55），"
              "「瓶頸不在 guest」在正確條件下成立。")
        print("   損失全在 guest 之後的鏈路——下一步該分解傳輸段與 macOS 端。")
    else:
        print(f"→ ⚠️ **guest 只有 {corrected:.1f} fps**（D45 安靜條件下是 59.9）。")
        print("   **guest 本身就是瓶頸的一部分**，而 droppedFrames=0 不能推翻這件事")
        print("   ——它只說 SurfaceFlinger 沒丟棄已提交的幀，不說 Unity 送了幾幀。")
        print("   把這個數字與同一輪的 MIRAGE_MEDIAN 並排看：兩者接近就表示 Mirage")
        print("   沒有額外損失，差距大才是下游的問題。")
if dropped is not None and dropped > 0:
    print(f"   （另外 droppedFrames={dropped:.0f}，與 D45 安靜窗口的 0 不同）")
PYEOF

echo ""
echo "（verify_fps_fullscreen.sh 退出碼 ${VERIFY_STATUS}）"
exit "$VERIFY_STATUS"
