#!/bin/bash
# 量 D44 的「健康窗口有多長」：emulator 的 CoreAudio 輸出裝置重新開啟之後，
# `streamAudio` 會以 100% 交付一段時間，然後閂鎖在約 6.5% 不再恢復。
# 這支腳本負責製造那個重新開啟，並量到崩潰為止。
#
# **這不是 verify_* 腳本，沒有任何斷言，退出碼不代表通過或失敗。**
# 崩潰時點的變異是 5 秒到超過 120 秒（實測三個 emulator 版本各三輪），
# 單跑一次沒有鑑別力，要比較條件必須多跑幾輪看分布。判定請人看數字。
#
# 重新開啟裝置的唯一已知手段：停掉 guest 所有音訊來源，等 emulator 關閉主機輸出裝置
# （`pmset -g assertions` 裡的 `Resources: audio-out` 消失，實測 3 到 4 秒），再重新播放。
# 用媒體鍵暫停再播放不夠，那不會讓 emulator 關閉裝置。
#
# 前置：guest 要有一個已知會發聲的來源在播（實測用 YouTube，峰值可到 24542／32767），
# 且它要能被媒體鍵暫停與續播。Pixel Flow 本身近乎無聲，不能拿來判交付率以外的事。
#
# 用法：
#     app/scripts/measure_audio_window.sh <標籤> [秒數，預設 120]
#
# 完整背景與量測記錄：app/RESULTS-audio-collapse.md
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS="$REPO_ROOT/phase0/harness"
PROBE="$HARNESS/audio_amplitude_probe.py"
PYTHON="$HARNESS/.venv-d45/bin/python"
SERIAL="${MIRAGE_SERIAL:-emulator-5556}"
CLOSE_TIMEOUT="${CLOSE_TIMEOUT:-40}"

LABEL="${1:?用法：measure_audio_window.sh <標籤> [秒數]}"
SECONDS_TO_RUN="${2:-120}"

export PATH="$HOME/Library/Android/sdk/platform-tools:$PATH"

if [ ! -x "$PYTHON" ]; then
  echo "找不到 ${PYTHON}，harness 的 venv 沒建起來（見 phase0/harness/README-venv.md）" >&2
  exit 2
fi

host_audio_device_open() {
  pmset -g assertions 2>/dev/null | grep -q "Resources: audio-out"
}

adb -s "$SERIAL" shell input keyevent KEYCODE_MEDIA_PAUSE

waited=0
while host_audio_device_open; do
  waited=$((waited + 1))
  if [ "$waited" -gt "$CLOSE_TIMEOUT" ]; then
    echo "$LABEL: 主機輸出裝置在 ${CLOSE_TIMEOUT}s 內沒有關閉，量到的不會是重新開啟後的窗口" >&2
    echo "$LABEL: 最可能的原因是 guest 還有別的音訊來源在播，先 force-stop 它們" >&2
    exit 3
  fi
  sleep 1
done
echo "$LABEL: 主機輸出裝置關閉於 ${waited}s"

adb -s "$SERIAL" shell input keyevent KEYCODE_MEDIA_PLAY
exec "$PYTHON" "$PROBE" --seconds "$SECONDS_TO_RUN" --label "$LABEL"
