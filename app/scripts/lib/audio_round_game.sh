#!/bin/bash
# 對照輪：任意遊戲的實際音訊。與 round.sh（定幅正弦波）逐項對齊，
# 唯一變因是音源，這樣三組（純訊號／稀疏音效／持續 BGM）才能並列比較。
#
# ⚠️ 峰值不能當「有在播」的判準：稀疏音效的遊戲峰值只有 2 到 4，
# 與崩潰態讀到的 4 分不開（RESULTS-audio-collapse.md §4）。
# 判準用 state:started 與交付率本身，峰值只記錄。
#
# 用法：round_game.sh <標籤> <package> [上限輪數] [進入遊戲後的等待秒數]
set -u
S="$(cd "$(dirname "$0")" && pwd)"
SDK="$HOME/Library/Android/sdk"; export PATH="$SDK/platform-tools:$PATH"
PY="/Users/hanfourhuang/Projects/mirage/phase0/harness/.venv-d45/bin/python"
HARNESS="/Users/hanfourhuang/Projects/mirage/phase0/harness"
LABEL="${1:?用法：round_game.sh <標籤> <package> [輪數] [等待秒數]}"
PKG="${2:?}"; MAX="${3:-40}"; WARMUP="${4:-60}"

pkill -f qemu-system 2>/dev/null; for i in $(seq 1 30); do pgrep -f qemu-system >/dev/null || break; sleep 2; done
nohup "$SDK/emulator/emulator" -avd mirage-game -no-snapshot-load -no-snapshot-save \
  -port 5554 -grpc 8554 < /dev/null > "$S/emu_$LABEL.log" 2>&1 &
BOOT=$(date +%s); sleep 10
for i in $(seq 1 40); do [ "$(adb -s emulator-5554 shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && break; sleep 5; done
# 定位：Niantic 類遊戲沒有 GPS fix 會停在載入畫面，沒有 BGM 就量不到東西。
adb emu geo fix 121.5654 25.0330 >/dev/null 2>&1 || true
for i in $(seq 1 15); do adb shell input keyevent KEYCODE_VOLUME_UP >/dev/null 2>&1; done
adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep "$WARMUP"
fg=$(adb shell dumpsys activity activities 2>/dev/null | grep -m1 topResumedActivity | grep -oE 'com\.[a-zA-Z.]+' | head -1)
pl=$(adb shell dumpsys audio 2>/dev/null | grep -c "state:started")
echo "# $LABEL  package=$PKG  前景=$fg  暖機後 playing=$pl"
printf '# 開機後秒數 交付率 峰值 playing\n'
for ((i=0;i<MAX;i++)); do
  out=$("$PY" "$HARNESS/audio_amplitude_probe.py" --target localhost:8554 --seconds 10 --label r 2>&1)
  pct=$(printf '%s' "$out" | grep -oE "SUPPLY_PCT=[0-9.]+" | cut -d= -f2)
  pk=$(printf '%s' "$out" | grep -oE "PEAK=[0-9]+" | cut -d= -f2)
  pl=$(adb shell dumpsys audio 2>/dev/null | grep -c "state:started")
  printf '%-6s %-8s %-8s %s\n' "$(( $(date +%s) - BOOT ))" "${pct:-無封包}" "${pk:-0}" "$pl"
  sleep 5
done
