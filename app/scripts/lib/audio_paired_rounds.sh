#!/bin/bash
# D44 配對重驗：同一版程式、每輪各自冷開機、兩種波形交錯執行。
#
# 交錯順序（不是先跑完一組再跑另一組）是因為跑次之間的變異已經大到能單獨解釋
# 92 到 355 秒的崩潰時點差距（§11）。連續跑完同一組時，機器狀態的漂移會與音源
# 的差異完全混在一起，分不出是哪一個在起作用。
#
# 每輪上限 45 個窗口（約 11 分鐘），掉破 50% 或音源停播就提早結束。
set -u
S="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${1:?用法：audio_paired_rounds.sh <輸出目錄> [起始輪次]}"
START="${2:-1}"
mkdir -p "$OUT_DIR"

run() {
  local name="$1" src="$2"
  echo "=== ${name}（${src}）$(date '+%H:%M:%S')"
  MIRAGE_ROUND_OUT="$OUT_DIR/$name.txt" bash "$S/audio_round_controlled.sh" "$name" "$src" 45 \
    || echo "⚠️ $name 這一輪作廢（守門欄未過），不納入比較"
}

case "$START" in
  1) run cont1 tone.wav; run gap2 tone_gap.wav; run cont2 tone.wav ;;
  *) run gap2 tone_gap.wav; run cont2 tone.wav ;;
esac
echo "=== 全部結束 $(date '+%H:%M:%S')"
