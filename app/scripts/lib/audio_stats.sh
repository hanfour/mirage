#!/usr/bin/env bash
# 解析 MIRAGE_AUDIO_LOG 的每秒一行，算出音訊健康量測用的 KEY=VAL。
# 第二個參數可指定畸形原文輸出檔，最多寫入五行；呼叫端應提供空檔。
# 用法：source "$(dirname "$0")/lib/audio_stats.sh"
#
# **存在的理由與 verify_common.sh／gui_session.sh 同一條**：這段 awk 是 D32 判準的
# 核心，抽出來才能被 audio_stats_selftest.sh 直接 source 驗證，不必再用 sed 從
# verify_audio_gui.sh 中段把函式挖出來（原本 Task 3 的驗法：函式一改行號，
# sed 範圍就可能挖錯或挖到半截）。
#
# 輸入格式（MIRAGE_AUDIO_LOG=1，AppModel+Audio.swift）：
#   [audio] pkt=42 smp=96000 supply=100% sr=48000 ch=2 under=0 over=0 primes=1 ptimeouts=0 depth=96ms
#
# **PRIMES 是什麼、為什麼要單獨列一欄**：`AudioRingBuffer` 加了 pre-roll 之後，
# 重新蓄水期間 under 不增加、depth 看起來像正常爬升——對 USUM/UMAX/UWINDOWS 這三個
# 既有指標完全隱形，會讓「反覆重新蓄水、每次賠一段靜音」的緩衝被誤判成比沒有
# pre-roll 更健康。PRIMES 取自 `AudioStats.primes`（累積計數），只取最後一行的值——
# 它本身就是累積量，不需要像 USUM 那樣算 delta。
#
# **`primes=` 缺失時不算畸形行**（2026-08-03 審查裁決）：畸形判定維持只看 pkt= 與
# under= 這兩個既有欄位。理由是向後相容——已經存檔的舊格式日誌（例如 Task 3 那三次
# 量測）沒有 primes= 欄位，若把它納入畸形判定，這些檔案會被整批打成畸形、SOUND_SECS
# 等既有指標全部歸零，等於用一個新欄位追溯性地弄壞了舊資料。舊格式日誌因此解析出
# PRIMES=0（awk 變數從未被設定，未初始化即為 0），這是刻意的預設值，不是遺漏。
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
    awk -v malformed_log="${2:-}" '
      /\[audio\]/ {
          lines++
          original = $0
          message = $0
          sub(/^.*\[audio\] */, "", message)
          # 已知事件採完整形狀白名單，新增詞彙必須同步更新解析器。
          # 事件只增加總行數與 EVENTS，不進取樣、窗口或累積計數。
          if (message ~ /^degraded reason=emulator-output-stalled pkt=[0-9]+ supply=[0-9]+%$/ ||
              message ~ /^recovered pkt=[0-9]+ supply=[0-9]+%$/ ||
              message ~ /^degraded-cleared reason=guest-audio-stopped pkt=[0-9]+ supply=[0-9]+%$/ ||
              # 收到端的 ch／fmt 是 proto enum 的描述字串不是數字（實測 `ch=stereo`），
              # 請求端的 ch 才是 Int。列舉值取自 emulator_controller.pb.swift 的
              # Channels 與 SampleFormat，含 UNRECOGNIZED——用列舉而不是 `.+`，
              # 是為了讓 proto 換版新增列舉值時 A6 照樣紅。
              message ~ /^收到的格式：sr=[0-9]+ ch=(mono|stereo|UNRECOGNIZED\([0-9]+\)) fmt=(audFmtU8|audFmtS16|UNRECOGNIZED\([0-9]+\))（請求的是 sr=[0-9]+ ch=[0-9]+ fmt=audFmtS16）bytes=[0-9]+$/ ||
              message ~ /^stream ended: .+$/ ||
              message == "無法建立 48k/stereo/Float32 格式，降級為無音訊" ||
              message ~ /^engine 啟動失敗，降級為無音訊：.+$/) {
              events++
              next
          }
          # 其餘形狀必須是 pkt 開頭且同時有兩個必要欄位的每秒取樣。
          if (message !~ /^pkt=/ || message !~ /(^|[[:space:]])pkt=/ ||
              message !~ /(^|[[:space:]])under=/) {
              malformed++
              if (malformed_log != "" && malformed <= 5) print original > malformed_log
              next
          }
          pkt = 0; under = 0
          for (i = 1; i <= NF; i++) {
              if ($i ~ /^pkt=/)    { sub(/^pkt=/, "", $i);    pkt = $i + 0 }
              if ($i ~ /^under=/)  { sub(/^under=/, "", $i);  under = $i + 0 }
              # primes 刻意不參與畸形判定、也不每行重設——它是累積計數，缺欄位時
              # 沿用上一次看到的值（初始為 awk 未初始化變數的 0），讓舊格式日誌
              # 解析出 PRIMES=0 而不是被打成畸形行。
              if ($i ~ /^primes=/) { sub(/^primes=/, "", $i); primes = $i + 0 }
              # ptimeouts 同 primes 是累積計數，只取最後看到的值。舊日誌沒有此欄位，
              # 缺欄位不算畸形，也不每行重設；從未出現時輸出 PTIMEOUTS=0。
              if ($i ~ /^ptimeouts=/) { sub(/^ptimeouts=/, "", $i); ptimeouts = $i + 0 }
              # supply：該秒實際供應量佔即時需求的百分比。與 primes 同樣不參與畸形
              # 判定——它是 2026-08-07（D44）才加的欄位，舊日誌沒有，缺它不是格式錯誤。
              # 尾端的 `%` 不需要另外剝掉：awk 的數值強制轉型對 "6%" 就是取出 6。
              # 第一版有一行 sub(/%$/,...)，突變檢查證明它是死碼（改壞了測試不紅），
              # 已移除——沒有效果的分支只會讓下一個人以為它在防什麼。
              if ($i ~ /^supply=/) {
                  sub(/^supply=/, "", $i)
                  supply_sum += $i + 0; supply_n++
              }
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
          # BSD awk 不吃 printf 參數位置的三元運算子（「illegal statement」），先算進變數。
          supply_mean = 0
          if (supply_n > 0) supply_mean = supply_sum / supply_n
          printf "AUDIO_LINES=%d\nSOUND_SECS=%d\nUSUM=%d\nUMAX=%d\nUWINDOWS=%d\nMALFORMED=%d\nPRIMES=%d\nPTIMEOUTS=%d\nSUPPLY_MEAN=%d\nEVENTS=%d\n",
                 lines + 0, sound + 0, usum + 0, umax + 0, windows + 0, malformed + 0, primes + 0, ptimeouts + 0,
                 supply_mean, events + 0
      }
    ' "$1"
}
