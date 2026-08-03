#!/usr/bin/env bash
# P1-e 驗收線 6：真 GUI + 真 AudioPlayer 下的音訊健康與畫面存活。
#
# **與 verify_audio.sh 的分工**：那支驗 transport 層（封包率／驗收線 5，5 秒視窗，
# 消費端是測試裡的 Task.sleep 假件）；這支驗 playback 層（消費端健康／驗收線 6，
# 60 秒，消費端是真的 AVAudioSourceNode）。名字取 _gui 不取 _60s，因為關鍵差別
# 不是時長而是「需要真 GUI session」——那也是跑之前最需要知道的前置條件。
#
# **為什麼驗收線 6 的字面判準（underruns == 0）不能直接用**：
# spec §8-6 要求「連續 60 秒 underruns == 0」，但同一份 spec 的 §5 寫著「遊戲靜音時
# 本來就沒有封包」「緩衝欠位/溢位不是錯誤，是要被計數與觀測的正常現象」。render
# callback 每 ~10ms 要一次資料（AudioPlayer.swift:35），guest 只要有一刻不發聲，
# readStereo 排乾時就走 underrunCount.wrappingIncrement（AudioRingBuffer.swift 的
# readStereo 函式——引用函式名而非行號，因為 pre-roll 修法已把它往下推過一次）。
# 所以 == 0 在任何含靜音期的 60 秒裡結構上不可能。
# 本腳本改判「連續有聲期間的 underrun 增量」——見 audio_stats 的註解。
# 完整推導見 docs/specs/2026-08-03-d32-acceptance-6-automation-design.md §0。
#
# 用法：
#   ./scripts/verify_audio_gui.sh                                  # 預設 5556 / 8556 / Pixel Flow，量 60 秒
#   ./scripts/verify_audio_gui.sh -s emulator-5558 -p 8558 -d 90
#
# 前置：模擬器**不可**用 -no-audio 啟動。建議：
#   emulator -avd mirage-game -port 5556 -grpc 8556 -gpu host
set -uo pipefail
source "$(dirname "$0")/lib/verify_common.sh"
source "$(dirname "$0")/lib/gui_session.sh"
source "$(dirname "$0")/lib/audio_stats.sh"

SERIAL="emulator-5556"
GRPC_PORT="8556"
PACKAGE="com.loomgames.pixelflow"
DURATION=60

while getopts "s:p:g:d:h" opt; do
  case "$opt" in
    s) SERIAL="$OPTARG" ;;
    p) GRPC_PORT="$OPTARG" ;;
    g) PACKAGE="$OPTARG" ;;
    d) DURATION="$OPTARG" ;;
    h) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "用法：$0 [-s serial] [-p grpc_port] [-g package] [-d seconds]" >&2; exit 2 ;;
  esac
done

# **空 package 一律拒絕。** 下面前景檢查用的 `case "$FG" in *"$PACKAGE"*)`，在 PACKAGE
# 為空時 pattern 變成 `**`，會匹配任何字串——前景檢查誤判通過，然後跑完一個沒有發聲源
# 的 60 秒量測。verify_game_fps.sh 允許 `-g ""`（量 launcher 的 fps 仍然有意義），
# 這支不行：沒有發聲源，A2/A3 就沒有意義。
if [ -z "$PACKAGE" ]; then
    echo "❌ -g 不接受空字串：本腳本必須有發聲來源。" >&2
    exit 2
fi

# `audio_stats` 解析 MIRAGE_AUDIO_LOG 的每秒一行，算出六個可 eval 的 KEY=VAL
# （含 MALFORMED——缺 pkt=/under= 欄位的畸形行計數）。完整設計說明（判準邏輯、
# 畸形行處理、AUDIO_LINES 語意）見 `lib/audio_stats.sh` 的檔頭註解；本檔只 source 它，
# 不重複定義，理由與 `lib/gui_session.sh` 同一條：只有一份要驗。

require_device "$SERIAL"
require_grpc "$GRPC_PORT"

echo ""
echo "=== 啟動遊戲：$PACKAGE ==="
"$ADB" -s "$SERIAL" shell monkey -p "$PACKAGE" -c android.intent.category.LAUNCHER 1 \
    > /dev/null 2>&1
sleep 8
FG=$("$ADB" -s "$SERIAL" shell dumpsys activity activities 2>/dev/null \
     | grep topResumedActivity | tr -d '\r' | head -1)
echo "前景：${FG:-（查不到）}"
# **前景確認失敗一律中止**，不像 verify_game_fps.sh 只發警告：那支腳本沒有遊戲仍能量
# 到 launcher 的 fps，這支沒有發聲源則後面每一條斷言都失去意義，繼續跑只會產生一個
# 看起來像產品缺陷、其實是環境沒備好的紅燈。
case "$FG" in
  *"$PACKAGE"*) echo "✅ $PACKAGE 在前景" ;;
  *) echo "❌ $PACKAGE 不在前景——沒有發聲來源，後面的量測沒有意義。"; exit 1 ;;
esac

echo ""
echo "=== 媒體音量頂到最大 ==="
# `adb shell media volume` 在本機映像上不存在（verify_audio.sh:8 記載），
# 連按 15 次 KEYCODE_VOLUME_UP 是已驗證的替代手段。
for _ in $(seq 1 15); do "$ADB" -s "$SERIAL" shell input keyevent 24 > /dev/null; done
"$ADB" -s "$SERIAL" shell dumpsys audio 2>&1 | grep -A3 "STREAM_MUSIC:" | grep streamVolume

LOG=$(mktemp -t mirage_audio_gui)
BUNDLE=$(mktemp -d -t mirage_audio_bundle)
trap 'gui_session_cleanup "${BUNDLE:-}"' EXIT INT TERM

echo ""
echo "=== 啟動 Mirage（.app bundle）→ localhost:${GRPC_PORT}，量測 ${DURATION}s ==="
# 不注入動畫：遊戲進行中畫面本來就在變化，而注入器會真的去點畫面，可能叫出暫停選單
# 或退出關卡（verify_game_fps.sh:32-36 記載的同一個理由）。
if ! gui_session_start "$LOG" "$BUNDLE" "" \
        "MIRAGE_PORT=$GRPC_PORT" "MIRAGE_AUDIO_LOG=1" "MIRAGE_FPS_LOG=1" "MIRAGE_CONN_LOG=1"; then
    exit 1
fi
sleep "$DURATION"

echo ""
echo "===== 音訊每秒日誌（全部）====="
grep '\[audio\]' "$LOG"

echo ""
echo "===== 畫面 ====="
fps_summary "$LOG"

echo ""
echo "===== 解析結果 ====="
audio_stats "$LOG"
echo "FPS_SAMPLES=$(fps_samples "$LOG")"
echo "FPS_AVG=$(fps_average "$LOG")"

echo ""
echo "===== 判定 ====="
eval "$(audio_stats "$LOG")"
FPS_N=$(fps_samples "$LOG")
FPS_A=$(fps_average "$LOG")

# A1：App 活到最後。**這行日誌的 Task 跑在 MainActor 上**（AppModel+Audio.swift:35）
# ——MainActor 被打死就是 0 行。P1-e 那個 interleaved 格式丟 NSException 打死 MainActor、
# 讓 Mirage 三個階段黑畫面的回歸，這條是直接守門。
assert_at_least "A1 音訊日誌行數（App 存活）" "$AUDIO_LINES" 48

# A2：串流真的活著。排除「App 活著但音訊根本沒進來」的假綠燈——沒有這條，
# 一個從頭到尾靜音的 60 秒會讓 A3 以 0 個取樣窗「通過」。
assert_at_least "A2 有封包的秒數" "$SOUND_SECS" 48

# A3：核心判準。只統計連續有聲期間的 underrun 增量（見 audio_stats 註解）。
# **必須排在 A2 之後**：assert_at_most 對空值/0 是通過的，A2 先確認「有東西可量」，
# 這條才有意義。兩個斷言各自單純，組合起來才完整（見 verify_common.sh 的
# assert_at_most 註解）。
assert_at_most "A3 連續有聲期間的 underrun 增量總和" "$USUM" 350

# A4：畫面沒被拖垮。同一個行程、同一份 log——音訊真的拖垮鏡像時，這條與 A1 會一起紅。
assert_at_least "A4 fps 取樣筆數" "$FPS_N" 1
assert_at_least "A4 平均 fps" "$FPS_A" 27

# A5：重新蓄水次數。**沒有這條，A3 可以靠反覆蓄水作弊**——蓄水期 under 不增加、
# depth 看起來在健康地爬升、pkt 照常 > 0，所以 audio_stats 的窗口不會排除它。
# 一個每 2 秒就重新蓄水一次、每次賠 100ms 靜音的緩衝，只看 A3 會顯示為「很健康」。
assert_at_most "A5 重新蓄水次數" "$PRIMES" 72

# A6：畸形日誌行。這不是品質門檻是**解析可信度**門檻——有畸形行代表這次量測的
# 數字本身不可信（缺欄位會讓 delta 跨越遺失的取樣點），該紅。
assert_at_most "A6 畸形日誌行" "$MALFORMED" 0

echo ""
echo "================================================================"
echo "⚠️  以上六條是**回歸偵測**，不是驗收線 6 的通過判準。"
echo "    全綠只代表「沒有比 2026-08-03 的基準更糟」。"
echo ""
echo "    驗收線 6（spec §8-6）目前判定為 **未通過（已大幅改善）**："
echo "    pre-roll（AudioRingBuffer.primeThresholdSamples）讓 underrun 總量降約 97%"
echo "    （USUM 5481 → ~150），但本次 PRIMES=${PRIMES} —— 每次重新蓄水都賠約 100ms"
echo "    靜音，實測平均每 1.7 秒排乾一次、全程約 5.8% 在靜音。"
echo ""
echo "    根因：生產端供應量長期約為消費需求的 94%，兩個獨立時鐘之間沒有任何"
echo "    rate adaptation。這不在 D32 範圍內，已記為獨立債務。"
echo "    完整推導見 docs/specs/2026-08-03-d32-acceptance-6-automation-design.md"
echo "    與 app/RESULTS-d32.md。"
echo "================================================================"
echo "log：$LOG"
