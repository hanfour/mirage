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
export ANDROID_SERIAL=emulator-5554
ADB="$HOME/Library/Android/sdk/platform-tools/adb"
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
MIRAGE_LIVE=1 MIRAGE_LIVE_AUDIO=1 swift test --filter AudioLiveTests 2>&1 | grep -E "\[audio-live\]|Test.*(passed|failed)"

echo ""
echo "=== 判讀 ==="
echo "writes >= 75  → 驗收線 5 通過（5 秒 ≥ 150 包的一半裕度；proto 稱 20–30ms/包）"
echo "under == 0    → 驗收線 6 的必要條件（完整 60 秒版本需在 GUI App 下用 MIRAGE_AUDIO_LOG=1 觀察）"
