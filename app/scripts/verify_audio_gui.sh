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
#
# 前置（同樣必要）：遊戲必須停在**會連續發聲**的畫面。A2 假紅是這支腳本最常見的一種
# 紅——不是斷言邏輯錯，是環境沒備好：Pixel Flow 停在只有點擊才出聲的收集/選單畫面時，
# `pkt` 全程為 0，A2（有封包的秒數）先攔下、後面每一條斷言都失去意義。故障注入會期
# 就被它擋掉四次（`app/RESULTS-d32.md` 附錄 C）。**A2 紅時先檢查**：截圖或 `dumpsys
# activity` 確認遊戲當下停留的關卡畫面，而不是先懷疑腳本或產品程式碼。
set -uo pipefail

source "$(dirname "$0")/lib/load_sentinel.sh"
source "$(dirname "$0")/lib/verify_common.sh"
source "$(dirname "$0")/lib/gui_session.sh"
source "$(dirname "$0")/lib/audio_stats.sh"
source "$(dirname "$0")/lib/guest_fps.sh"

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

# **`-d` 低於下限一律拒絕。** A1/A2/A3/A5 這幾條門檻是用 `$DURATION` 現場算的整數
# 算術（例如 `$((DURATION * 8 / 10))`）——`DURATION` 夠小時，整數除法會把門檻截斷成
# 0，讓「至少要有 0 行 [audio] 日誌」這種恆真斷言通過任何結果，包括 App 整個沒啟動
# 起來（D32 故障注入驗證過這個確切現象：`-d 1` 讓 A1/A2 雙雙截斷成 0）。這正是本專案
# 吃過虧的「結構上不可能失敗的斷言」的同一種形狀，只是換了個觸發方式。
# 下限定在 10：本腳本前置的兩個 `sleep`（啟動遊戲後的 `sleep 8`、`gui_session_start`
# 內等 Mirage 視窗合成的 `sleep 6`）已經吃掉 14 秒，`$DURATION` 本身再省也省不到多少
# 總執行時間；換來的代價是 A3（`*350/60`，10 秒下算出 58）／A5（`*72/60`，10 秒下算出
# 12）這兩條比例門檻不會被整數除法截到 0 或 1、形同虛設。10 秒是換算這件事得出的下限，
# 不是隨手取的數字。
#
# **非整數輸入必須先擋在這裡**（2026-08-03 審查發現，Important-4）：`[ "$DURATION"
# -lt 10 ]` 遇到非數字會印 `integer expression expected` 並回傳 2，`if` 視為 false，
# 這道下限守門直接被繞過——而繞過的後果正是上一段在防的那件事：`$((DURATION * 8 /
# 10))` 之類的門檻算術對非數字一樣會炸，但已經晚了，繞過守門的輸入形同不設限。
case "$DURATION" in
  ''|*[!0-9]*)
    echo "❌ -d 只接受正整數秒數：實測 '${DURATION}'。" >&2
    exit 2
    ;;
esac
if [ "$DURATION" -lt 10 ]; then
    echo "❌ -d 不接受低於 10 秒：低於此值 A3/A5 的門檻算術會被整數除法截到 0 或 1，斷言形同虛設。" >&2
    exit 2
fi

# D60(a)：參數解析與驗證完成後，量測前才檢查主機磁碟。
disk_preflight "$(dirname "$0")" || exit 1

# `audio_stats` 分類音訊日誌，算出可 eval 的 KEY=VAL
# （含 MALFORMED 畸形計數與 EVENTS 已知事件計數）。完整設計說明（判準邏輯、
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
trap 'gui_session_cleanup "${BUNDLE:-}"; rm -f "${FPS_LOG:-}" "${MALFORMED_LOG:-}"' EXIT INT TERM

echo ""
echo "=== 啟動 Mirage（.app bundle）→ localhost:${GRPC_PORT}，量測 ${DURATION}s ==="
# 不注入動畫：遊戲進行中畫面本來就在變化，而注入器會真的去點畫面，可能叫出暫停選單
# 或退出關卡（verify_game_fps.sh:32-36 記載的同一個理由）。
if ! gui_session_start "$LOG" "$BUNDLE" "" \
        "MIRAGE_PORT=$GRPC_PORT" "MIRAGE_AUDIO_LOG=1" "MIRAGE_FPS_LOG=1" "MIRAGE_CONN_LOG=1"; then
    exit 1
fi
# D47／D56／D48：guest 與 fps 只量同一段窗口，不含啟動與建置。
# 用行號截取快照，後續印表與斷言不再讀仍持續增加的 fps 日誌。
FPS_LOG=$(mktemp -t mirage_audio_fps)
BEFORE=$(wc -l < "$LOG")
guest_window_start "$SERIAL"
sleep "$DURATION"
AFTER=$(wc -l < "$LOG")
GUEST_RAW=$(guest_window_end "$SERIAL" "$PACKAGE") || GUEST_RAW=""
GUEST_FPS=$(printf '%s' "$GUEST_RAW" | cut -d' ' -f1)
sed -n "$((BEFORE + 1)),${AFTER}p" "$LOG" > "$FPS_LOG"

echo ""
echo "===== 音訊每秒日誌（全部）====="
grep '\[audio\]' "$LOG"

echo ""
echo "===== 畫面 ====="
fps_summary "$FPS_LOG"

echo ""
echo "===== 解析結果 ====="
audio_stats "$LOG"
echo "FPS_SAMPLES=$(fps_samples "$FPS_LOG")"
echo "FPS_AVG=$(fps_average "$FPS_LOG")"

echo ""
echo "===== 判定 ====="
MALFORMED_LOG=$(mktemp -t mirage_audio_malformed)
eval "$(audio_stats "$LOG" "$MALFORMED_LOG")"
FPS_N=$(fps_samples "$FPS_LOG")
FPS_A=$(fps_average "$FPS_LOG")

# 跟時長成正比的門檻一律用 $DURATION 現場算，不寫死絕對值。腳本檔頭把 `-d 90` 列為
# 合法用法，`DURATION` 預設只是 60——寫死用 60 秒推出來的絕對值，換一個時長跑就會
# 產生**假紅燈**（時長變短時 A1/A2 這種下限先紅、蓋掉真正該紅的斷言；例如
# `-d 30` 搭配沒有發聲來源，預期只有 A2 該紅，但寫死 48 的 A1 會在 A2 之前先紅，
# 「有紅」卻紅錯地方）或**假綠燈**（時長變長時上限門檻沒跟著放寬，看起來更嚴格，
# 但也可能在 `-d 120` 之類的長跑次上因為門檻算法本身沒被檢驗過而默默失效）。
#
# 下面所有比例常數（8/10、350/60、72/60）都是以 `DURATION=60`（腳本預設值）下的
# 五次實測（本次三次 + 控制端兩次：USUM 129–175、PRIMES 34–36、AUDIO_LINES／
# SOUND_SECS 60–63）換算回來的每秒基準——看到 `/ 60` 就是在問「60 秒下量到多少」。

# A1：App 活到最後。**這行日誌的 Task 跑在 MainActor 上**（AppModel+Audio.swift:35）
# ——MainActor 被打死就是 0 行。P1-e 那個 interleaved 格式丟 NSException 打死 MainActor、
# 讓 Mirage 三個階段黑畫面的回歸，這條是直接守門。
# 門檻＝DURATION 的 80%（規則本來就是比例，寫死 48 只是把 60 代進去而已）。
assert_at_least "A1 音訊日誌行數（App 存活）" "$AUDIO_LINES" $((DURATION * 8 / 10))

# A2：串流真的活著。排除「App 活著但音訊根本沒進來」的假綠燈——沒有這條，
# 一個從頭到尾靜音的 60 秒會讓 A3 以 0 個取樣窗「通過」。
# 門檻同 A1：五次實測的 SOUND_SECS 都等於 AUDIO_LINES（Pixel Flow 全程有聲），
# 同一個比例成立。
assert_at_least "A2 有封包的秒數" "$SOUND_SECS" $((DURATION * 8 / 10))

# A2b：供應不足時，後續緩衝量測不能當成 Mirage 側健康度的判定。
# D44 已推翻「內容稀疏」歸因：6.5% 是主機輸出後端停止排空時的後備速率。
# 完整證據與產品決策見 app/RESULTS-audio-collapse.md §1、§8。
SUPPLY_MIN="${SUPPLY_MIN:-90}"
if [ "${SUPPLY_MEAN:-0}" -lt "$SUPPLY_MIN" ]; then
    echo ""
    echo "================================================================"
    echo "❌ A2b 前置未滿足：音訊供應率只有 ${SUPPLY_MEAN:-0}%（門檻 ${SUPPLY_MIN}%）。"
    echo "   emulator 的主機音訊輸出後端會閂鎖崩潰，沒有正常主機接收端時交付率為 6.5%。"
    echo "   驗收線 6 判不通過、歸 emulator 側，Mirage 只做偵測與告知，不做繞法。"
    echo "   完整證據：app/RESULTS-audio-collapse.md §1、§8。"
    echo "   要在明知供應不足的情況下硬跑：SUPPLY_MIN=0 $0 $*"
    echo "================================================================"
fi
assert_at_least "A2b 前置：音訊供應率" "${SUPPLY_MEAN:-0}" "$SUPPLY_MIN"

# A3：核心判準。只統計連續有聲期間的 underrun 增量（見 audio_stats 註解）。
# **必須排在 A2 之後**：assert_at_most 對空值/0 是通過的，A2 先確認「有東西可量」，
# 這條才有意義。兩個斷言各自單純，組合起來才完整（見 verify_common.sh 的
# assert_at_most 註解）。
# 門檻是上限，也跟時長成正比：五次最大值 175 的兩倍是 350（60 秒下），換算成
# 每秒 350/60 再乘上實際 DURATION。上限門檻時長變短只會更寬鬆、不會假紅，但不按
# 比例縮放的話，時長變長時就形同沒有這條斷言。
assert_at_most "A3 連續有聲期間的 underrun 增量總和" "$USUM" $((DURATION * 350 / 60))

# A4：guest 在同一窗口持續出幀，fps 行數才可用來判斷 Mirage 中途凍住。
# 預設 27 與下方平均 fps 要求一致；0 表示明知前置不成立仍硬跑。
A4_GUEST_MIN="${A4_GUEST_MIN:-27}"
if [ "$A4_GUEST_MIN" != 0 ]; then
    if [ -z "$GUEST_FPS" ] || ! awk -v g="$GUEST_FPS" -v t="$A4_GUEST_MIN" 'BEGIN { exit !(g >= t) }'; then
        echo "================================================================"
        echo "❌ 前置未滿足：guest ${GUEST_FPS:-（找不到 layer）} fps，門檻 ${A4_GUEST_MIN}。"
        echo "   **這不是產品的紅燈，是環境的紅燈。** guest 沒在出幀時，streamScreenshot"
        echo "   不會送畫面，量到的 fps 反映的是畫面多久變一次，不是傳輸能力。"
        echo "   找不到 layer 通常代表遊戲雖在前景但已停止算繪（Unity 閒置會暫停算繪）。"
        echo "   下一步：把遊戲切到會**持續變化**的畫面（遊玩中，不是選單／收集畫面）再跑。"
        echo "   要在明知 guest 沒出幀的情況下硬跑：A4_GUEST_MIN=0 $0 $*"
        echo "================================================================"
        exit 1
    fi
else
    echo "⚠️ A4 guest 前置已覆寫，fps 紅燈不能直接歸因於 Mirage。"
fi
echo "GUEST_FPS=${GUEST_FPS:-無資料}"
# 派工者兩次 -d 60 實測皆為 64 筆，門檻 48 保留 25% 裕度。
# 此比例只有在 guest 前置成立時才有意義；平均 fps 維持絕對值 27。
assert_at_least "A4 fps 取樣筆數" "$FPS_N" $((DURATION * 8 / 10))
assert_at_least "A4 平均 fps" "$FPS_A" 27

# A5：重新蓄水次數。**沒有這條，A3 可以靠反覆蓄水作弊**——蓄水期 under 不增加、
# depth 看起來在健康地爬升、pkt 照常 > 0，所以 audio_stats 的窗口不會排除它。
# 一個每 2 秒就重新蓄水一次、每次賠 100ms 靜音的緩衝，只看 A3 會顯示為「很健康」。
# 門檻跟 A3 同理，也是跟時長成正比的上限：五次最大值 36 的兩倍是 72（60 秒下），
# 換算成每秒 72/60 再乘上實際 DURATION。
assert_at_most "A5 重新蓄水次數" "$PRIMES" $((DURATION * 72 / 60))

# A6：畸形日誌行。這不是品質門檻是**解析可信度**門檻——有畸形行代表這次量測的
# 數字本身不可信（缺欄位會讓 delta 跨越遺失的取樣點），該紅。跟時長無關，永遠是 0，
# **不**跟著 DURATION 縮放。
if [ "$MALFORMED" -gt 0 ]; then
    echo "A6 畸形日誌原文（最多 5 行）："
    cat "$MALFORMED_LOG"
fi
rm -f "$MALFORMED_LOG" "$FPS_LOG"
assert_at_most "A6 畸形日誌行" "$MALFORMED" 0

echo ""
echo "================================================================"
echo "⚠️  以上六條是**回歸偵測**，不是驗收線 6 的通過判準。"
echo "    全綠只代表「沒有比 2026-08-03 的基準更糟」。"
echo ""
echo "    驗收線 6 判不通過、歸 emulator 側，Mirage 只做偵測與告知，不做繞法。"
echo "    emulator 的主機音訊輸出後端會閂鎖崩潰，三個版本都會，換版本不是解法。"
echo "    streamAudio 的交付速率等於主機接收端排空 emulator 混音緩衝的速率。"
echo "    有正常運作的 CoreAudio 輸出裝置在拉資料時是 100%；沒有時是 6.5%。"
echo "    繞法需要停掉 guest 全部音訊才能重設輸出裝置，做不到無縫，玩家會聽到斷音。"
echo "    完整證據與產品決策見 app/RESULTS-audio-collapse.md §1、§8。"
echo "================================================================"
echo "log：$LOG"
