#!/bin/bash
# 一輪：冷開機 → 受控音源 → 追蹤到交付率掉破 50% 或跑滿上限。
# 音源是本機 HTTP 供應的 440Hz 定幅正弦波（loop），不依賴外部內容。
# ⚠️ 每輪都驗 PEAK 接近 12000：那證明收到的是我們送的訊號，
# 而不只是「有聲音」。先前用 YouTube 時無法做這個確認。
set -u
S="$(cd "$(dirname "$0")" && pwd)"
SDK="$HOME/Library/Android/sdk"; export PATH="$SDK/platform-tools:$PATH"
PY="/Users/hanfourhuang/Projects/mirage/phase0/harness/.venv-d45/bin/python"
HARNESS="/Users/hanfourhuang/Projects/mirage/phase0/harness"
LABEL="${1:?用法：round.sh <標籤> [上限輪數]}"; MAX="${2:-40}"

pkill -f qemu-system 2>/dev/null; for i in $(seq 1 30); do pgrep -f qemu-system >/dev/null || break; sleep 2; done
nohup "$SDK/emulator/emulator" -avd mirage-game -no-snapshot-load -no-snapshot-save \
  -port 5554 -grpc 8554 < /dev/null > "$S/emu_$LABEL.log" 2>&1 &
BOOT=$(date +%s); sleep 10
for i in $(seq 1 40); do
  [ "$(adb -s emulator-5554 shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && break; sleep 5
done
adb shell am start -n com.android.chrome/com.google.android.apps.chrome.Main \
  -a android.intent.action.VIEW -d "http://10.0.2.2:8099/index.html" >/dev/null 2>&1
sleep 10; adb shell input tap 540 1200; sleep 5
play=$(adb shell dumpsys audio 2>/dev/null | grep -c "state:started")
if [ "${play:-0}" -lt 1 ]; then adb shell input tap 540 1200; sleep 5; fi

printf '# %s：開機後秒數 交付率 峰值 playing\n' "$LABEL"
for ((i=0;i<MAX;i++)); do
  out=$("$PY" "$HARNESS/audio_amplitude_probe.py" --target localhost:8554 --seconds 10 --label r 2>&1)
  pct=$(printf '%s' "$out" | grep -oE "SUPPLY_PCT=[0-9.]+" | cut -d= -f2)
  pk=$(printf '%s' "$out" | grep -oE "PEAK=[0-9]+" | cut -d= -f2)
  pl=$(adb shell dumpsys audio 2>/dev/null | grep -c "state:started")
  t=$(( $(date +%s) - BOOT ))
  printf '%-6s %-8s %-8s %s\n' "$t" "${pct:-0}" "${pk:-0}" "$pl"
  awk -v v="${pct:-0}" 'BEGIN{exit !(v<50)}' && { echo "→ 第 ${t} 秒掉破 50%"; break; }
  sleep 5
done
