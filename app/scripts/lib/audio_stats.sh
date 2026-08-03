#!/usr/bin/env bash
# 解析 MIRAGE_AUDIO_LOG 的每秒一行，算出音訊健康量測用的六個 KEY=VAL。
# 用法：source "$(dirname "$0")/lib/audio_stats.sh"
#
# **存在的理由與 verify_common.sh／gui_session.sh 同一條**：這段 awk 是 D32 判準的
# 核心，抽出來才能被 audio_stats_selftest.sh 直接 source 驗證，不必再用 sed 從
# verify_audio_gui.sh 中段把函式挖出來（原本 Task 3 的驗法：函式一改行號，
# sed 範圍就可能挖錯或挖到半截）。
#
# 輸入格式（MIRAGE_AUDIO_LOG=1，AppModel+Audio.swift）：
#   [audio] pkt=42 sr=48000 ch=2 under=0 over=0 depth=96ms
#
# **只統計「本秒 pkt>0 且前一秒也 pkt>0」的 underrun 增量**。這一刀砍掉兩個結構上
# 不可能的區間：
#   1. 啟動期——App 一啟動 AudioPlayer 就在 render，連線還沒建立，前幾秒必然狂
#      underrun。這是 D32 記載的「drain 從 t=0 就開始讀」在真 AudioPlayer 下的等價物，
#      換成真消費端並不會讓它消失。
#   2. 靜音期與它的過渡秒——spec §5 明說靜音沒封包是正常的。靜音秒本身 pkt=0 被排除；
#      緊接其後的第一個有聲秒，其增量包含靜音期末尾的欠位，靠「前一秒也有聲」一併排除。
#
# 用「前一秒也有聲」取代「固定丟掉前 N 秒的 warm-up」是刻意的：後者要選一個魔術數字，
# 前者自適應，消除特殊情況。
#
# **畸形行（缺 pkt= 或 under= 欄位）一律整行跳過，且不更新 prev_pkt/prev_under。**
# 2026-08-03 審查發現的問題：改動前的版本裡 `pkt = 0; under = 0` 在每行開頭重設，
# 若某行缺 under=，under 會靜默停在 0——delta 變成大負數，被下面的防禦性下限吃掉，
# **不印任何警告**，是這個專案最忌諱的「安靜算錯」形狀（代號 D9：印了 ❌ 卻照樣
# exit 0、門檻寫在說明裡卻沒人檢查）。更糟的是 prev_under 會被這個 0 污染，讓
# 下一個有效行算出異常大的正 delta，跟真實的 underrun 增量混在一起。
# 現在缺欄位的行改計一個新的 MALFORMED 計數並整行跳過：不進 SOUND_SECS、不進
# window、也不拿它的值當下一行的基準——下一行的 delta 改以「畸形行之前那一行」
# 為基準，不會被畸形行污染成 0。
#
# **AUDIO_LINES 的語意維持「[audio] 總行數」，包含畸形行**：它的用途是判斷 App
# 有沒有活到最後（這行的迴圈跑在 MainActor 上，MainActor 被打死就是 0 行），跟
# 「這一行的欄位是否完整」是兩件事，後者由 MALFORMED 單獨呈現，不混進同一個數字。
audio_stats() {
    awk '
      /\[audio\]/ {
          lines++
          pkt = 0; under = 0
          pkt_found = 0; under_found = 0
          for (i = 1; i <= NF; i++) {
              if ($i ~ /^pkt=/)   { sub(/^pkt=/, "", $i);   pkt = $i + 0;   pkt_found = 1 }
              if ($i ~ /^under=/) { sub(/^under=/, "", $i); under = $i + 0; under_found = 1 }
          }
          if (!pkt_found || !under_found) {
              malformed++
              next    # 整行跳過：不進 sound/window，也不更新 prev_pkt/prev_under
          }
          if (pkt > 0) sound++
          if (pkt > 0 && prev_pkt > 0) {
              d = under - prev_under
              if (d < 0) d = 0          # 累積計數理論上單調，防禦性下限
              usum += d
              if (d > umax) umax = d
              windows++
          }
          prev_pkt = pkt; prev_under = under
      }
      END {
          printf "AUDIO_LINES=%d\nSOUND_SECS=%d\nUSUM=%d\nUMAX=%d\nUWINDOWS=%d\nMALFORMED=%d\n",
                 lines + 0, sound + 0, usum + 0, umax + 0, windows + 0, malformed + 0
      }
    ' "$1"
}
