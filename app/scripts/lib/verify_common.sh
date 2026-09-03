#!/usr/bin/env bash
# 驗證腳本的共用工具。用法：source "$(dirname "$0")/lib/verify_common.sh"
#
# **存在的理由是「只有一份要驗」**（2026-07-30，D9）。在此之前「檢查 swift test 的退出碼」
# 這件事在每支腳本裡各寫一次——結果是 coverage.sh 在 D29 被修好，而 verify_audio.sh、
# verify_mmap.sh、verify_keymap_inject.sh 三支各自帶著同一個缺陷沒人發現。重複的檢查
# 會漂移；共用的檢查只需要注入故障驗一次。
#
# 這裡刻意**不**提供「跑 swift test」的包裝函式：各腳本的輸出整形不同
# （`| tail -3`、`| grep -E "…"`），包起來只會多一層難懂的參數傳遞。共用的是**判斷**，
# 不是呼叫方式。

# adb 路徑。允許呼叫端先設好 ADB 覆寫（例如指向另一份 SDK）。
ADB="${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}"

# 確認 adb 存在且可執行。少了這步，後面每一步都會靜默失敗，最後只得到一個
# 令人困惑的結果（看起來像回歸，其實只是環境沒裝好）。
require_adb() {
    if [ ! -x "$ADB" ]; then
        echo "❌ 找不到可執行的 adb：$ADB"
        echo "   請確認 Android SDK platform-tools 已安裝於此路徑（本專案未把 adb 放進 PATH）。"
        exit 1
    fi
}

# 指定目標裝置並確認它真的在。
#
# **`ANDROID_SERIAL` 不是可選的**：不指定時 adb 會挑「唯一連著的裝置」，而開發機上
# 常常插著實體手機——量到的就不是模擬器，卻不會有任何錯誤訊息。這是 D9 記載的
# `verify_reconnect.sh:77` 與 `verify_snapshot.sh:10` 的本體。
require_device() {
    local serial="${1:-emulator-5554}"
    export ANDROID_SERIAL="$serial"
    require_adb
    if ! "$ADB" -s "$serial" shell true > /dev/null 2>&1; then
        echo "❌ 裝置 $serial 沒有回應。"
        echo "   目前連著的裝置："
        "$ADB" devices | sed 's/^/     /'
        exit 1
    fi
}

# 確認 gRPC 埠有人監聽（模擬器在跑）。
require_grpc() {
    local port="${1:-8554}"
    if ! nc -z localhost "$port" 2>/dev/null; then
        echo "❌ gRPC $port 無回應——模擬器未啟動。"
        exit 1
    fi
    echo "✅ gRPC $port ALIVE"
}

# 斷言某個步驟成功；非零就中止。
#
#   swift test --filter Foo 2>&1 | tail -3
#   assert_ok "Foo 活體測試" "${PIPESTATUS[0]}"
#
# **必須緊接在管線後面取 `${PIPESTATUS[0]}`**：下一個指令就會把它覆寫掉。
# 取 `[0]` 而不是 `$?` 是因為 `$?` 會被管線右端污染（例如 `grep` 沒配到就回 1），
# 而「grep 沒印出東西」與「測試失敗」是兩件不同的事。
assert_ok() {
    local desc="$1" code="$2"
    if [ "$code" -ne 0 ]; then
        echo "❌ ${desc}失敗（退出碼 ${code}）——本次驗證結果不可信，中止。"
        exit 1
    fi
    echo "✅ ${desc}通過"
}

# 斷言某個值等於期待值。
#
# 存在的理由與 assert_at_least 同一條：**「印出來讓人自己看」不是驗證**。
# D42 那次要驗的是「產出的 AVD 規格有沒有真的生效」——解析度、density、abi、
# 記憶體。這些都是等值比較而非門檻比較，沒有這個函式就會退回「印出來自己判讀」，
# 而那正是 D9 記載的假訊號來源。
assert_equals() {
    local desc="$1" actual="$2" expected="$3"
    if [ "$actual" != "$expected" ]; then
        echo "❌ ${desc}：實測 '${actual}'，期待 '${expected}'"
        exit 1
    fi
    echo "✅ ${desc}：${actual}"
}

# 斷言某個數值達到門檻。把「印出數字讓人自己判讀」換成真的斷言——
# 人工判讀是這批腳本最常見的假訊號來源：門檻寫在說明裡，卻沒有任何東西檢查它。
assert_at_least() {
    local desc="$1" actual="$2" threshold="$3"
    if [ "${actual:-0}" -lt "$threshold" ]; then
        echo "❌ ${desc}：實測 ${actual:-0}，門檻 ${threshold}"
        exit 1
    fi
    echo "✅ ${desc}：${actual}（門檻 ${threshold}）"
}

# 斷言某個數值不超過上限。`assert_at_least` 的反向。
#
# **為什麼空字串在這裡當作 0（通過），與 assert_at_least 相反**：at_least 把空字串
# 當 0 會中止，那是安全的方向（抓不到數字 → 紅）。at_most 若照抄，抓不到數字就會
# **通過**——正好是 D9 要修掉的那種假綠燈。這裡不加特殊分支去猜呼叫端的意圖，而是
# 把責任放在呼叫端：先用 assert_at_least 確認「有東西可量」（例如日誌行數 > 0），
# 再用本函式判上限。兩個斷言各自單純，組合起來才完整。
assert_at_most() {
    local desc="$1" actual="$2" threshold="$3"
    if [ "${actual:-0}" -gt "$threshold" ]; then
        echo "❌ ${desc}：實測 ${actual:-0}，上限 ${threshold}"
        exit 1
    fi
    echo "✅ ${desc}：${actual:-0}（上限 ${threshold}）"
}

# === 建置快取暖機（D57）===
#
# **一次成功的 `swift build` 不保證下一次是 no-op。** 2026-08-06 實測：工作樹全程
# 乾淨，連跑兩次相同的 `swift build -c release` → **73.85s（`Compiling SwiftProtobuf
# AnyMessageStorage.swift`）然後 0.58s**。根因未鎖定（`SwiftProtobufPlugin` 每次都
# 重跑，疑似讓下游 target 偶發失效），但不必鎖定就能防：**建到真的 no-op 為止再開始量測。**
#
# 為什麼這件事重要：`verify_fps_fullscreen.sh` 原本是**每一輪內**經 `package_app.sh`
# 建置的，建置就落在該輪 20 秒擷取窗口之前。撞到冷快取的輪次會被 CPU 餓死——實測
# 那一輪量到 31 fps，同跑次另兩輪是 48／54。這是 D50／D54「窗口沒對齊，量到的是別的
# 東西」的第三次同形復發。

# 判斷一次 `swift build` 的輸出裡有沒有 **target 原始檔**被重新編譯。
#
# **唯一的難點是必須排除 `Compiling plugin …`**：SwiftPM 每次建置都會重跑 build
# plugin（`GRPCSwiftPlugin`／`SwiftProtobufPlugin`），那兩行在「73.85 秒的真重編」與
# 「0.58 秒的 no-op」輸出裡**都會出現**。拿它當訊號會永遠判定成「還沒暖」，於是
# build_warm 每次都建滿上限次數然後失敗——一個看起來很像環境壞掉的假紅燈。
#
# 抽成純函式是刻意的：這是 build_warm 唯一會判錯的地方，而純函式可以在**不跑
# swift build** 的情況下用自我測試釘住（見 verify_common_selftest.sh）。
build_output_recompiled() {
    printf '%s\n' "$1" | grep -E '^\[[0-9]+/[0-9]+\] Compiling ' | grep -qv 'Compiling plugin'
}

# 反覆 `swift build` 直到某一次沒有 target 被重編，確保之後的量測窗口不含建置。
# 用法：build_warm [release|debug] [最多幾次] [package 目錄] [product]
build_warm() {
    local config="${1:-release}" max="${2:-3}" dir="${3:-$PWD}" product="${4:-}"
    local attempt out rc label
    local -a build_args=(swift build -c "$config")
    if [ -n "${product}" ]; then
        build_args+=(--product "${product}")
    fi
    label="swift build -c ${config}"
    if [ -n "${product}" ]; then
        label="${label} --product ${product}"
    fi
    for attempt in $(seq 1 "$max"); do
        out=$( cd "$dir" && "${build_args[@]}" 2>&1 )
        rc=$?
        if [ "$rc" -ne 0 ]; then
            printf '%s\n' "$out" | tail -20
            echo "❌ ${label} 失敗（退出碼 ${rc}）"
            return 1
        fi
        if build_output_recompiled "$out"; then
            echo "   第 ${attempt} 次仍有 target 被重編，再建一次"
            continue
        fi
        echo "   第 ${attempt} 次已是 no-op，建置快取確定是暖的"
        return 0
    done
    # **這裡回 1 而不是「算了繼續」是刻意的**：每次都在重編，代表下一輪的擷取窗口
    # 一定會撞到建置，量出來的數字不可信。與其產出一個看起來正常的髒數字，不如紅。
    echo "❌ 建了 ${max} 次仍每次都有 target 被重編——量測窗口會被建置污染，不繼續。"
    return 1
}
