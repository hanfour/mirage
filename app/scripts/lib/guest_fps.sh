#!/usr/bin/env bash
# guest（emulator 內）render fps 的量測與解析（D56）。
# 用法：source "$(dirname "$0")/lib/guest_fps.sh"
#
# **存在的理由**：驗收線 7 量的是 Mirage 側的 fps，而 Mirage 不可能比 guest 產出的
# 還快。2026-08-06 實測到 guest 在真實負載下只有 **49.18 fps**（安靜 headless 窗口
# 下是 59.9）——那種輪次量到的 Mirage 數字既不能證明 Mirage 慢，也不能證明它快，
# 因為門檻 55 在那個窗口裡**算術上就到不了**。把這種輪次計進中位數，等於用環境雜訊
# 稀釋判定：同一顆 build、同一天量到 56／58（通過）與 31／48／54（未通過），這就是
# D56 記的那件事。
#
# **一個量測涵蓋三件事**（刻意的：消除特殊情況，而不是為每件事加一道閘門）：
# 主機負載過高、emulator 被餓死、量測窗口沒對齊——三者都會讓 guest fps 掉下來。
#
# ⚠️ **窗口必須與 Mirage 的擷取窗口逐輪對齊。** 前一版把 timestats 開在整個跑次外層，
# 量到的 241 秒窗口涵蓋三輪＋輪次間隔＋App 啟動＋一次 65.83 秒的重編，得到的 49.18
# 是跨全程的平均，不能與任何單輪的 Mirage 數字比較（D48 那列記的限制）。本檔的
# guest_window_start／_end 就是為了逐輪對齊而存在。

# 從一份 `dumpsys SurfaceFlinger --timestats -dump` 的輸出解析出 guest fps。
# 印出「<fps> <totalFrames> <droppedFrames> <窗口毫秒>」，解析不出來時回傳 1。
#
# **三個會讓人解錯的地方，這個函式全部處理，而且自我測試逐一釘住**：
#
# 1. **檔頭有一個全域 `totalFrames`（實測 11859），目標 layer 的在後面（11854）。**
#    `grep totalFrames | head -1` 拿到的是全域值——那是所有 layer 的合計，不是遊戲的。
# 2. **一份 dump 裡有多個 layer**（實測還有 `StatusBar#85` 的 12 幀、`none` 的 0 幀）。
#    必須用 layerName 圈出區塊，且同時要求含 `SurfaceView`——Unity 直接畫到
#    SurfaceView，其他同名 layer 不是我們要的。
# 3. **不要用 dumpsys 自己印的 `averageFPS`。** 它系統性偏高（實測 +1.9%～+3.3%），
#    根因已在 AOSP 原始碼層級確認：`TimeStats.cpp` 的 `toMs()` 對 present2present
#    間隔做 `duration_cast<milliseconds>` 無條件捨去，均勻分布下期望少 0.5ms，
#    三個獨立窗口實測偏差 0.50–0.53ms 完全吻合。正解是 `totalFrames ÷ displayOnTime`
#    ——不依賴 histogram 分桶的獨立算法。詳見 app/RESULTS-d45-guest-render.md。
guest_fps_from_dump() {
    local file="$1" pkg="$2"
    awk -v pkg="$pkg" '
        # 全域 displayOnTime（本次量測窗口的實際長度），只取第一個。
        /displayOnTime[ \t]*=/ && win == "" { win = $3 }
        # 進入／離開目標 layer 的區塊。
        /layerName[ \t]*=/ {
            inlayer = (index($0, pkg) > 0 && index($0, "SurfaceView") > 0) ? 1 : 0
        }
        inlayer && /totalFrames[ \t]*=/   && total == ""   { total = $3 }
        inlayer && /droppedFrames[ \t]*=/ && dropped == "" { dropped = $3 }
        END {
            if (win == "" || total == "" || win + 0 <= 0) { exit 1 }
            printf "%.2f %d %d %d\n", total / (win / 1000.0), total, dropped, win
        }
    ' "$file"
}

# 開始一個 guest 量測窗口。呼叫端要在**擷取窗口的正前方**呼叫它。
guest_window_start() {
    local serial="$1"
    "$ADB" -s "$serial" shell dumpsys SurfaceFlinger --timestats -clear  > /dev/null 2>&1
    "$ADB" -s "$serial" shell dumpsys SurfaceFlinger --timestats -enable > /dev/null 2>&1
}

# 結束窗口並印出 guest_fps_from_dump 的結果（同樣四個欄位）。解析失敗回傳 1。
guest_window_end() {
    local serial="$1" pkg="$2" dump
    dump=$(mktemp -t d56_timestats)
    "$ADB" -s "$serial" shell dumpsys SurfaceFlinger --timestats -dump > "$dump" 2>/dev/null
    "$ADB" -s "$serial" shell dumpsys SurfaceFlinger --timestats -disable > /dev/null 2>&1
    local out rc
    out=$(guest_fps_from_dump "$dump" "$pkg"); rc=$?
    rm -f "$dump"
    [ "$rc" -ne 0 ] && return 1
    printf '%s\n' "$out"
}
