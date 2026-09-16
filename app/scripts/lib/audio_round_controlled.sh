#!/bin/bash
# 一輪：冷開機 → 受控音源 → 追蹤到交付率掉破 50% 或跑滿上限。
# 音源是本機 HTTP 供應的 440Hz 正弦波（振幅 12000、loop），不依賴外部內容。
# 第二個參數選波形，兩者取樣率／聲道／振幅／長度相同，唯一差別是音訊有沒有中斷：
#   tone.wav      整段連續（§11 已量過兩輪各 640 秒零崩潰）
#   tone_gap.wav  每 8 秒響、2 秒數位靜音
# ⚠️ 每輪都驗 PEAK 接近 12000：那證明收到的是我們送的訊號，
# 而不只是「有聲音」。先前用 YouTube 時無法做這個確認。
#
# 交付率的四種讀法（判準無歧義）：約 100% 健康；約 80% 表示 emulator 略過靜音段；
# 約 6.5% 且不自行恢復是 D44 的崩潰態；0% 要先看 playing 欄是不是音源自己停了。
set -u
S="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$S/../../.." && pwd)"
SDK="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"; export PATH="$SDK/platform-tools:$PATH"
PY="$REPO/phase0/harness/.venv-d45/bin/python"
HARNESS="$REPO/phase0/harness"
LABEL="${1:?用法：audio_round_controlled.sh <標籤> [tone.wav|tone_gap.wav] [上限輪數]}"
SRC="${2:-tone.wav}"; MAX="${3:-40}"
OUT="${MIRAGE_ROUND_OUT:-${TMPDIR:-/tmp}/mirage-audio-round-$LABEL.txt}"

# 音源伺服器：已經在 8099 上就沿用，不重開（重開會讓上一輪的連線斷掉）。
if ! lsof -nP -iTCP:8099 -sTCP:LISTEN >/dev/null 2>&1; then
  nohup "$PY" -m http.server 8099 --directory "$S/audio_www" \
    < /dev/null > "${TMPDIR:-/tmp}/mirage-audio-www.log" 2>&1 &
  echo "音源伺服器 pid $!"
  sleep 1
fi

MIRAGE_HEADLESS=1 "$REPO/app/scripts/emu.sh" stop >/dev/null
MIRAGE_HEADLESS=1 "$REPO/app/scripts/emu.sh" start || exit 1
BOOT=$(date +%s)

adb shell am start -n com.android.chrome/com.google.android.apps.chrome.Main \
  -a android.intent.action.VIEW -d "http://10.0.2.2:8099/index.html?src=$SRC" >/dev/null 2>&1
sleep 10; adb shell input tap 540 1200; sleep 5
play=$(adb shell dumpsys audio 2>/dev/null | grep -c "state:started")
if [ "${play:-0}" -lt 1 ]; then adb shell input tap 540 1200; sleep 5; fi

# 開跑前先驗一次峰值。播放沒真的開始時交付率仍會是 0 到 60 的散亂值，
# 與崩潰態的形狀相同；不擋掉的話整輪資料會混進一種完全不同的失效。
gate=$("$PY" "$HARNESS/audio_amplitude_probe.py" --target localhost:8554 --seconds 12 --label gate 2>&1)
gate_pk=$(printf '%s' "$gate" | grep -oE "PEAK=[0-9]+" | cut -d= -f2)
if [ "${gate_pk:-0}" -lt 10000 ]; then
  echo "❌ 峰值 ${gate_pk:-0}（期望約 11994），音源沒有真的在播，這一輪不算數。" >&2
  printf '%s\n' "$gate" >&2
  exit 1
fi
echo "✅ 守門欄：峰值 ${gate_pk}，收到的是本機送出的訊號"

{
printf '# %s src=%s headless 冷開機\n' "$LABEL" "$SRC"
printf '# 開機後秒數 交付率 峰值 playing\n'
for ((i=0;i<MAX;i++)); do
  out=$("$PY" "$HARNESS/audio_amplitude_probe.py" --target localhost:8554 --seconds 10 --label r 2>&1)
  pct=$(printf '%s' "$out" | grep -oE "SUPPLY_PCT=[0-9.]+" | cut -d= -f2)
  pk=$(printf '%s' "$out" | grep -oE "PEAK=[0-9]+" | cut -d= -f2)
  pl=$(adb shell dumpsys audio 2>/dev/null | grep -c "state:started")
  t=$(( $(date +%s) - BOOT ))
  printf '%-6s %-8s %-8s %s\n' "$t" "${pct:-0}" "${pk:-0}" "$pl"
  # 音源自己停了（playing=0）也會讓交付率歸零，形狀與崩潰相同，分開報。
  if [ "${pl:-0}" -lt 1 ]; then echo "→ 第 ${t} 秒音源停播，不是交付崩潰"; break; fi
  awk -v v="${pct:-0}" 'BEGIN{exit !(v<50)}' && { echo "→ 第 ${t} 秒掉破 50%"; break; }
  sleep 5
done
} | tee "$OUT"
