#!/usr/bin/env bash
# 啟動 Mirage GUI session 並解析它的每秒日誌。
# 用法：source "$(dirname "$0")/lib/gui_session.sh"
#
# **存在的理由與 verify_common.sh 同一條**（D9）：「怎麼啟動 App 並收 log」原本只寫在
# verify_game_fps.sh 裡，D32 的 verify_audio_gui.sh 需要一模一樣的東西加上 fps 解析。
# 複製一份的下場已經有前例——D9 記載 coverage.sh 被修好而三支 verify_* 沒跟上。
#
# package_app.sh 由 D25 建立，是組 .app 的唯一入口；本檔只負責「啟動它、拉到前景、
# 收 log、解析」，不重複打包邏輯。

# 打包並啟動 MirageApp，把 stdout/stderr 導向 log。
#
# **必須以 .app bundle 啟動，不能直接跑 bare executable**：直接跑時 macOS 不一定把
# 視窗合成上螢幕，MTKView 的 currentDrawable 為 nil、Renderer 早退，present 一次都
# 不發生——而幀其實都正常進來了。2026-07-28 實測這是**不穩定**的（同樣的指令有時量
# 得到有時完全量不到），所以不是「偏低」而是「不可信」。包成 bundle 之後 activation
# policy 才是 .regular。
gui_session_start() {
    local log="$1" bundle="$2" app_override="$3"; shift 3
    if ! "$(dirname "${BASH_SOURCE[0]}")/../package_app.sh" \
            "$bundle" release "$app_override" > /dev/null; then
        echo "❌ 打包 .app 失敗（見上方訊息）" >&2
        return 1
    fi
    local env_args=()
    local kv
    for kv in "$@"; do env_args+=(--env "$kv"); done
    open -a "$bundle/Mirage.app" --stdout "$log" --stderr "$log" "${env_args[@]}"
    sleep 6
    # 視窗要在前景才會被合成。取不到就繼續——量測本身仍可能成功，而 fps_summary
    # 的診斷分辨得出來。
    osascript -e 'tell application "System Events" to set frontmost of process "MirageApp" to true' \
        > /dev/null 2>&1
}

gui_session_cleanup() {
    local bundle="${1:-}"
    pkill -x MirageApp 2>/dev/null
    [ -n "$bundle" ] && rm -rf "$bundle"
    return 0
}

# 取樣筆數。**`grep -c` 沒命中時已經會印 0 並回傳 1**，寫成 `|| echo 0` 會再補一個 0，
# 讓結果變成兩行、後面的 `-eq` 直接爆掉——而那正是沒量到幀時必然走到的路徑。
fps_samples() {
    grep -c 'fps=' "$1" 2>/dev/null || true
}

# 平均 fps（整數，無條件捨去）。沒有取樣時回 0。
fps_average() {
    local n
    n=$(fps_samples "$1")
    [ "$n" -eq 0 ] && { echo 0; return 0; }
    grep 'fps=' "$1" | sed 's/.*fps=//' | awk -v n="$n" '{ s += $1 } END { printf "%d\n", s/n }'
}

# fps 中位數（整數，無條件捨去）。沒有取樣時回 0。
#
# **為什麼 D45 要中位數而不是 fps_average**：這台開發機是共用的，一次 CPU 負載尖峰
# 會讓某一秒量到 0，平均被整組拖歪而中位數不受影響（見 lib/load_sentinel_selftest.sh
# 的「離群的 0」案例：同一份資料平均 47、中位數 59）。D45 的判準是比值，被拖歪的
# 分子或分母會直接變成錯誤的結論。
#
# 偶數筆取中間兩筆的**下位**，不做內插——樣本本身是整數 fps，內插只會製造假精度。
fps_median() {
    local n
    n=$(fps_samples "$1")
    [ "$n" -eq 0 ] && { echo 0; return 0; }
    grep 'fps=' "$1" | sed 's/.*fps=//' | sort -n | awk -v n="$n" '
        { v[NR] = $1 }
        END { printf "%d\n", v[int((n + 1) / 2)] }'
}

# `[app] frames` 的中位數。只讀取幀計數行，不改動 fps 解析的既有語意。
# 第三個參數是要略過的前置幀計數行數，讓量測窗口與 fps_samples 的 BEFORE 對齊。
frames_samples() {
    local log="$1"
    [ -r "$log" ] || { echo 0; return 0; }
    grep -c '^\[app\] frames ' "$log" 2>/dev/null || true
}

frames_median() {
    local log="$1" field="$2" skip="${3:-0}"
    case "$field" in
        arrived|dropped|presented) ;;
        *) echo 0; return 0 ;;
    esac
    [ -r "$log" ] || { echo 0; return 0; }
    awk -v field="$field" -v skip="$skip" '
        /^\[app\] frames([[:space:]]|$)/ {
            if (seen < skip) { seen++; next }
            found = 0
            for (i = 3; i <= NF; i++) {
                split($i, pair, "=")
                if (pair[1] == field && pair[2] ~ /^[0-9]+$/) {
                    values[++n] = pair[2]
                    found = 1
                    break
                }
            }
            if (!found) next
        }
        END {
            if (!n) { print 0; exit }
            for (i = 1; i <= n; i++) {
                for (j = i + 1; j <= n; j++) {
                    if (values[j] < values[i]) {
                        temp = values[i]
                        values[i] = values[j]
                        values[j] = temp
                    }
                }
            }
            printf "%d\n", values[int((n + 1) / 2)]
        }' "$log" 2>/dev/null
}

# 人看的摘要。取樣為 0 時印診斷並回傳 1。
fps_summary() {
    local log="$1" samples frames
    samples=$(fps_samples "$log")
    if [ "$samples" -eq 0 ]; then
        frames=$(grep -c '幀 #' "$log" 2>/dev/null || true)
        echo "取樣數 0——Mirage 沒有 present 任何一幀。"
        echo ""
        if [ "$frames" -gt 0 ]; then
            echo "但幀有進來（log 裡有 ${frames} 行「幀 #N」）。**所以問題不在串流，在視窗**："
            echo "視窗沒有被合成上螢幕，MTKView 的 currentDrawable 為 nil，Renderer 早退。"
            echo "檢查：Mirage 視窗有沒有真的出現在螢幕上、有沒有被其他視窗完全遮住、"
            echo "螢幕是否鎖定。這條路徑實測是不穩定的，重跑一次往往就好。"
        else
            echo "而且幀也沒進來（log 裡沒有「幀 #N」）。問題在串流或連線："
            head -3 "$log"
            echo "（若上面出現 [transport]，代表健康探測通過、狀態已連上，那就是串流不出幀；"
            echo "  記得 streamScreenshot 是變化驅動的，畫面靜止時本來就不出幀。）"
        fi
        echo "log：$log"
        return 1
    fi
    grep 'fps=' "$log" | sed 's/.*fps=//' | awk -v n="$samples" '
      { s += $1; if (min == "" || $1 < min) min = $1; if ($1 > max) max = $1 }
      END { printf "取樣 %d 筆　平均 %.1f fps　最低 %d　最高 %d\n", n, s/n, min, max }'
    # 沒有串流尺寸就無法解讀 fps：fps 對串流解析度敏感（launcher 上 540x1200 約 50fps、
    # 888x1972 約 20fps），而尺寸由視窗大小經 resizeDebounced 決定，會隨視窗變動。
    echo -n "串流尺寸："
    grep 'attachStream' "$log" | sed 's/.*請求 //' | sort -u | tr '\n' ' '
    echo ""
    return 0
}
