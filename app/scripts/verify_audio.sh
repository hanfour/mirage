#!/usr/bin/env bash
# P1-e 音訊活體驗證：把媒體音量開到最大 → 觸發 guest 發聲 → 量測封包率與緩衝健康。
# 用法：verify_audio.sh    （需 emulator-5554 正在跑）
#
# Step 1 探測記錄（見 task-9-report.md 完整版）：
#   - brief 假設的 /system/media/audio/{ringtones,notifications}/ 在本機映像上不存在
#     （sdk_phone64_arm64, canary 37.2.1）；實際音檔在 /product/media/audio/ 底下。
#   - `adb shell media volume ...` 二進位不存在（"inaccessible or not found"），
#     改用 `input keyevent 24`（KEYCODE_VOLUME_UP）連按到頂當替代方案。
#   - `am start -a VIEW -d file://... -t audio/ogg` 確認會叫起 com.android.music/.AudioPreview
#     並讓 dumpsys audio 看到一個 MediaPlayer piid state:started（sampleRate=44100, stereo）。
set -uo pipefail
source "$(dirname "$0")/lib/verify_common.sh"
export ANDROID_SERIAL="${ANDROID_SERIAL:-emulator-5554}"
SOUND="/product/media/audio/ringtones/Ring_Synth_04.ogg"   # 實測存在（Step 1 用 adb shell ls 確認）

# 終審 Minor 8：這裡沒有 `-e`，前面幾步 adb 呼叫全靜默失敗也不會中止腳本——若 adb 根本
# 不存在（路徑寫死、不在 PATH），觸發發聲那幾步會全部無聲失敗，測試照跑，最後只得到
# 一個令人困惑的 writes=0 紅燈，看起來像產品碼壞了，其實只是環境沒裝好。加這道存在性/
# 可執行檢查，缺失時給清楚訊息並直接 exit 1，不留給後面的紅燈去猜。
if [ ! -x "$ADB" ]; then
  echo "找不到可執行的 adb：$ADB"
  echo "請確認 Android SDK platform-tools 已安裝於此路徑（本專案未把 adb 放進 PATH）。"
  exit 1
fi

echo "=== 前置：模擬器是否在跑 ==="
nc -z localhost 8554 && echo "gRPC 8554 ALIVE" || { echo "模擬器未啟動"; exit 1; }

echo ""
echo "=== 觸發 guest 發聲（媒體音量開最大 → 播放內建音檔）==="
# `media` shell 指令在本機映像上不存在，改用連續按 15 次音量鍵頂到 STREAM_MUSIC 上限。
for _ in $(seq 1 15); do "$ADB" shell input keyevent 24 > /dev/null; done
"$ADB" shell dumpsys audio 2>&1 | grep -A3 "STREAM_MUSIC:" | grep streamVolume
"$ADB" shell am start -a android.intent.action.VIEW -d "file://$SOUND" -t audio/ogg 2>&1 | tail -3

echo ""
echo "=== 量測：streamAudio → AudioRingBuffer（5 秒）==="
cd "$(dirname "$0")/.." || exit 1
# MIRAGE_LIVE_AUDIO=1：這支腳本是唯一保證「guest 正在發聲」前置條件成立的呼叫端
# （上面已把音量頂到最大並觸發播放），比照既有 MIRAGE_LIVE_MMAP 慣例，額外閘門避免
# 本測試掛在通用 MIRAGE_LIVE 下把專案的覆蓋率量測指令
# （MIRAGE_LIVE=1 MIRAGE_LIVE_MMAP=1 swift test --enable-code-coverage）無謂地紅掉。
AUDIO_LOG=$(mktemp -t mirage_audio_verify)
trap 'rm -f "$AUDIO_LOG"' EXIT
MIRAGE_LIVE=1 MIRAGE_LIVE_AUDIO=1 swift test --filter AudioLiveTests 2>&1 | tee "$AUDIO_LOG" \
  | grep -E "\[audio-live\]|Test.*(passed|failed)"
assert_ok "AudioLiveTests" "${PIPESTATUS[0]}"

echo ""
echo "=== 判定 ==="
# 修的是什麼（2026-07-30，D9）：原本這一段只是**印出門檻讓人自己判讀**，腳本本身
# 不檢查任何數字，而且 `swift test` 的退出碼也沒讀——最後一行是 echo，所以無論測試
# 紅綠、無論 writes 是 80 還是 0，這支腳本都 exit 0。門檻寫在說明裡卻沒人檢查，
# 等於沒有門檻。
WRITES=$(grep -o 'writes=[0-9]\{1,\}' "$AUDIO_LOG" | head -1 | cut -d= -f2)
UNDER=$(grep -o 'under=[0-9]\{1,\}' "$AUDIO_LOG" | head -1 | cut -d= -f2)

if [ -z "${WRITES:-}" ]; then
    echo "❌ 從測試輸出裡找不到 writes=N——輸出格式可能變了，本次結果不可信。"
    echo "   原始輸出："; grep "\[audio-live\]" "$AUDIO_LOG" | sed 's/^/     /'
    exit 1
fi

# 5 秒 ≥ 150 包的一半裕度（proto 稱 20–30ms/包）。這與測試自己的
# `#expect(stats.writes >= 75)` 是同一個門檻——腳本這一層再檢一次，是為了讓
# 「測試沒跑到」與「跑了但沒達標」在腳本的退出碼上都看得見。
assert_at_least "驗收線 5：封包率 writes" "$WRITES" 75

echo ""
echo "under=${UNDER:-?}（**這個數字在本腳本裡不是判準**）"
echo "  原本這一行寫的是「under == 0 → 驗收線 6 的必要條件」。2026-07-30 實測 under=406，"
echo "  查證後那個門檻在**這個測試情境下不成立**，不是產品回歸："
echo "  `drainRingAtRealTimeRate`（AudioLiveTests.swift:14）每 10ms **無條件**讀 960 樣本，"
echo "  而且從 t=0 就開始讀——連線都還沒建立。5 秒 = 500 次讀取，其中大部分讀到空的或"
echo "  不足的緩衝，於是 under 結構上必然很大。那個 drain 存在的目的只是避免緩衝填滿讓"
echo "  writes 卡住（見該檔 line 11-13），它不模擬真實播放，underrun 對它沒有意義。"
echo "  測試自己也只斷言 writes，沒有斷言 underruns。"
echo ""
echo "  驗收線 6 的真正判準在**GUI App** 下用 MIRAGE_AUDIO_LOG=1 觀察 60 秒（那裡的消費端"
echo "  是真的 AudioPlayer）——本腳本涵蓋不到，不要拿它當通過的依據。"
