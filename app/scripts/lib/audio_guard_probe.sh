#!/bin/bash
# 量交付率，同時每秒記錄 guest 是否仍在播放。
# ⚠️ 存在的理由：只看交付率無法分辨「emulator 崩潰」與「音源自己停了」。
# 2026-09-10 實測踩過：YouTube 播完淡出被誤讀成崩潰（SUPPLY_PCT=55.6、
# 「封包中途停止」），但逐秒交付率全程 99%、只有峰值衰減到 0。
set -u
ADB="$HOME/Library/Android/sdk/platform-tools/adb"
SECONDS_TO_RUN="${1:-180}"
OUT="${2:?用法：$0 <秒數> <輸出檔>}"
: > "$OUT"
for ((t=0; t<SECONDS_TO_RUN; t++)); do
  n=$("$ADB" shell dumpsys audio 2>/dev/null | grep -c "state:started")
  printf '%ds playing=%s\n' "$t" "${n:-0}" >> "$OUT"
  sleep 1
done
