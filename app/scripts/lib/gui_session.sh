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
# 從 `ioreg -n Root -d1 -a` 的 plist 文字判斷 console 使用者的螢幕是否鎖定。
# 純函式：吃字串、印 locked／unlocked／unknown，讓自我測試釘得住解析。
# ioreg 的 plist 是一 key 一行、值在下一行，所以用「看到 key 就記住、下一行看值」的狀態機。
#
# 為什麼需要它（D65）：螢幕鎖定時 `open -a` 照樣成功、app 照樣連線收幀、`fps=` 照樣印，
# 只有 SwiftUI 的視窗不會放上畫面，於是 AX 列不出視窗、全螢幕永遠進不去。症狀與 D63
# 的「視窗 N 秒內未在 AX 出現」一字不差，2026-09-04 與 09-07 各害一次活體整跑次作廢。
gui_screen_lock_state() {
    printf '%s' "$1" | awk '
        /<key>CGSSessionScreenIsLocked<\/key>/ { want = 1; next }
        want && /<true\/>/  { print "locked";   found = 1; exit }
        want && /<false\/>/ { print "unlocked"; found = 1; exit }
        want { want = 0 }
        END { if (!found) print "unknown" }'
}

gui_session_start() {
    local log="$1" bundle="$2" app_override="$3"; shift 3
    # D65：鎖定就直接紅，訊息要說「螢幕鎖定」而不是留給下游印「視窗未出現」。
    local lock_state
    lock_state=$(gui_screen_lock_state "$(ioreg -n Root -d1 -a 2>/dev/null)")
    if [ "$lock_state" = "locked" ]; then
        echo "❌ 螢幕已鎖定（CGSSessionScreenIsLocked）：鎖定時 app 會啟動並收幀，但視窗不會放上畫面，" >&2
        echo "   AX 列不出視窗、全螢幕進不去。解鎖後再跑。" >&2
        return 1
    fi
    if ! "$(dirname "${BASH_SOURCE[0]}")/../package_app.sh" \
            "$bundle" release "$app_override" > /dev/null; then
        echo "❌ 打包 .app 失敗（見上方訊息）" >&2
        return 1
    fi
    # 背景模式不建視窗，等視窗或 fps 的腳本會失敗；一律以一般模式啟動，不動使用者的設定。
    local env_args=(--env MIRAGE_BACKGROUND_MODE=0)
    local kv
    for kv in "$@"; do env_args+=(--env "$kv"); done
    open -n -a "$bundle/Mirage.app" --stdout "$log" --stderr "$log" ${env_args[@]+"${env_args[@]}"} || return 1
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

# 等待 Mirage 視窗出現在 Accessibility API，設定全螢幕並等待串流尺寸收斂。
# 呼叫端負責決定失敗後是否重開；本函式只回傳 0（收斂）或 1（未收斂）。
gui_session_fullscreen() {
    local log="$1" bundle="$2" min_width="$3"
    local window_timeout="${FULLSCREEN_WINDOW_TIMEOUT:-15}"
    local window_poll_interval="${FULLSCREEN_WINDOW_POLL_INTERVAL:-0.5}"
    local window_poll_count
    local poll_timeout="${FULLSCREEN_POLL_TIMEOUT:-10}"
    local poll_interval="${FULLSCREEN_POLL_INTERVAL:-1}"
    local resend_interval="${FULLSCREEN_RESEND_INTERVAL:-2}"
    local resend_max="${FULLSCREEN_RESEND_MAX:-3}"
    local latest_width ax_fullscreen
    local fullscreen_set_output fullscreen_set_rc resend_count resend_elapsed
    local poll

    window_poll_count=$(awk -v timeout="${window_timeout}" \
        -v interval="${window_poll_interval}" 'BEGIN { printf "%d", timeout / interval }')

    WINDOW_FOUND=0
    WINDOW_COUNT=0
    poll=1
    while [ "${poll}" -le "${window_poll_count}" ]; do
        sleep "${window_poll_interval}"
        WINDOW_COUNT=$(osascript -e 'tell application "System Events" to count of windows of process "MirageApp"' \
            2>/dev/null) || WINDOW_COUNT=0
        case "${WINDOW_COUNT}" in
            ''|*[!0-9]*) WINDOW_COUNT=0 ;;
        esac
        if [ "${WINDOW_COUNT}" -ge 1 ]; then
            WINDOW_FOUND=1
            break
        fi
        poll=$((poll + 1))
    done
    if [ "${WINDOW_FOUND}" -eq 0 ]; then
        echo "   視窗 ${window_timeout} 秒內未在 AX 出現，這次啟動失敗，關掉重開"
        gui_session_cleanup "${bundle}"
        rm -f "${log}"
        return 1
    fi

    fullscreen_set_output=$(osascript -e 'tell application "System Events" to tell process "MirageApp" to set value of attribute "AXFullScreen" of window 1 to true' \
        2>&1)
    fullscreen_set_rc=$?
    if [ "${fullscreen_set_rc}" -ne 0 ]; then
        echo "   ⚠️ AXFullScreen 設定失敗：${fullscreen_set_output}"
    fi
    resend_count=0
    resend_elapsed=0
    poll=1
    while [ "${poll}" -le "${poll_timeout}" ]; do
        sleep "${poll_interval}"
        LATEST_ATTACH=$(grep 'attachStream' "${log}" | tail -1)
        latest_width=$(printf '%s' "${LATEST_ATTACH}" | sed -n 's/.*請求 \([0-9]*\)x.*/\1/p')
        if [ -n "${latest_width}" ] && [ "${latest_width}" -ge "${min_width}" ]; then
            return 0
        fi

        resend_elapsed=$((resend_elapsed + poll_interval))
        if [ "${resend_elapsed}" -ge "${resend_interval}" ]; then
            resend_elapsed=0
            ax_fullscreen=$(osascript -e 'tell application "System Events" to tell process "MirageApp" to get value of attribute "AXFullScreen" of window 1' \
                2>/dev/null) || ax_fullscreen=""
            if [ "${ax_fullscreen}" != "true" ] && [ "${resend_count}" -lt "${resend_max}" ]; then
                fullscreen_set_output=$(osascript -e 'tell application "System Events" to tell process "MirageApp" to set value of attribute "AXFullScreen" of window 1 to true' \
                    2>&1)
                fullscreen_set_rc=$?
                resend_count=$((resend_count + 1))
                if [ "${fullscreen_set_rc}" -ne 0 ]; then
                    echo "   ⚠️ AXFullScreen 第 ${resend_count} 次重送失敗：${fullscreen_set_output}"
                fi
            fi
        fi
        poll=$((poll + 1))
    done

    gui_session_cleanup "${bundle}"
    rm -f "${log}"
    return 1
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

# `[app] <tag>` 欄位的中位數。接受 frames、draw、transit、inject，第三個
# 參數是欄位，第四個參數是要略過的前置同 tag 行數，讓量測窗口與 fps_samples
# 的 BEFORE 對齊。欄位值可帶小數與 `ms` 後綴。
tagged_median() {
    local log="$1" tag="$2" field="$3" skip="${4:-0}"
    case "$tag:$field" in
        frames:arrived|frames:dropped|frames:presented \
        |transit:p50|transit:p95|inject:p50|inject:p95 \
        |draw:calls|draw:gap20|draw:maxgap|draw:in_p95|draw:nodrawable|draw:noframe) ;;
        *) echo 0; return 0 ;;
    esac
    [ -r "$log" ] || { echo 0; return 0; }
    awk -v tag="$tag" -v field="$field" -v skip="$skip" '
        function number(raw) {
            sub(/ms$/, "", raw)
            if (raw !~ /^[0-9]+([.][0-9]+)?$/) { return -1 }
            return raw + 0
        }
        $0 ~ ("^\\[app\\] " tag "([[:space:]]|$)") {
            if (seen < skip) { seen++; next }
            found = 0
            for (i = 3; i <= NF; i++) {
                split($i, pair, "=")
                value = number(pair[2])
                if (pair[1] == field && value >= 0) {
                    values[++n] = value
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
            median = values[int((n + 1) / 2)]
            if (median == int(median)) {
                printf "%d\n", median
            } else {
                printf "%.1f\n", median
            }
        }' "$log" 2>/dev/null
}

# `[app] lat` 欄位的中位數。欄位值預期帶 `ms` 後綴，回傳保留一位小數。
latency_median() {
    local log="$1" field="$2" skip="${3:-0}"
    case "$field" in
        p50|p95) ;;
        *) echo 0; return 0 ;;
    esac
    [ -r "$log" ] || { echo 0; return 0; }
    awk -v field="$field" -v skip="$skip" '
        function number(raw) {
            sub(/ms$/, "", raw)
            if (raw !~ /^[0-9]+([.][0-9]+)?$/) { return -1 }
            return raw + 0
        }
        $0 ~ /^\[app\] lat([[:space:]]|$)/ {
            if (seen < skip) { seen++; next }
            for (i = 3; i <= NF; i++) {
                split($i, pair, "=")
                value = number(pair[2])
                if (pair[1] == field && value >= 0) {
                    values[++n] = value
                    break
                }
            }
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
            printf "%.1f\n", values[int((n + 1) / 2)]
        }' "$log" 2>/dev/null
}

# `[app] frames` 的中位數。維持既有呼叫端與輸出語意。
frames_samples() {
    local log="$1"
    [ -r "$log" ] || { echo 0; return 0; }
    grep -c '^\[app\] frames ' "$log" 2>/dev/null || true
}

frames_median() {
    tagged_median "$1" frames "$2" "${3:-0}"
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
