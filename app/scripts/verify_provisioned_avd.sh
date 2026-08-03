#!/usr/bin/env bash
# D42：把 `tools/provision` 產出的 AVD 真的開起來，並斷言規格有沒有生效。
#
# **存在的理由**：D33 完成時，「兩台一致的 AVD 可被重建」是**宣稱不是示範**——
# 當時的驗證只到「檔案寫出來了」與「第二次跑說符合」。一個從沒開過機的 AVD
# 設定檔，跟沒有設定檔的差別只是心理上的。
#
# **為什麼要做成腳本而不是驗一次就算**：驗過一次不等於能重驗，而「有人手工驗過」
# 正是 D33 這筆債的病本身。升 pin、改 AvdSpec、換 system image 之後都要能重跑。
#
# **安全性**：全程用暫存的 AVD home（`ANDROID_AVD_HOME`），**不會動到
# `~/.android/avd` 底下任何東西**；SDK 端不帶旗標所以只讀不寫。腳本結束時
# 會把暫存目錄清掉。
#
# 用法：./scripts/verify_provisioned_avd.sh          （兩台都驗）
#       ./scripts/verify_provisioned_avd.sh mirage-poc
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
source "$(dirname "$0")/lib/verify_common.sh"

PROVISION="../tools/provision/provision.py"
SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
EMULATOR="${SDK}/emulator/emulator"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-300}"

require_adb
if [ ! -x "$EMULATOR" ]; then
    echo "❌ 找不到可執行的 emulator：${EMULATOR}"
    echo "   先跑 python3 tools/provision/provision.py 把 SDK 備妥。"
    exit 1
fi

TMPAVD=$(mktemp -d "${TMPDIR:-/tmp}/verify-avd-XXXXXX")
# trap 要涵蓋中途 exit：留下 8GB 的暫存 AVD 比沒驗還糟。
cleanup() {
    [ -n "${EMU_PID:-}" ] && kill "$EMU_PID" 2>/dev/null
    rm -rf "$TMPAVD"
}
trap cleanup EXIT

echo "=== 產生 AVD 到暫存目錄 ${TMPAVD} ==="
# 不帶旗標：AVD 不存在會直接建立，SDK 端只報告不寫。退出碼可能是 1
# （SDK 有漂移），那與本次要驗的事無關——所以這裡只斷言 AVD 那兩列真的建了，
# 不斷言整體退出碼。
python3 "$PROVISION" --sdk-root "$SDK" --avd-home "$TMPAVD" | sed 's/^/   /'

for name in ${1:-mirage-poc mirage-game}; do
    if [ ! -f "${TMPAVD}/${name}.ini" ] || [ ! -f "${TMPAVD}/${name}.avd/config.ini" ]; then
        echo "❌ ${name} 的設定檔沒有被產生出來"
        exit 1
    fi
done
echo "✅ 設定檔已產生"

boot_and_check() {
    local name="$1" port="$2" want_playstore="$3"
    local serial="emulator-${port}"

    echo ""
    echo "=== ${name}（port ${port}）==="
    ANDROID_AVD_HOME="$TMPAVD" "$EMULATOR" -avd "$name" \
        -port "$port" -no-window -no-audio -no-snapshot -no-boot-anim \
        > "${TMPAVD}/${name}.emulator.log" 2>&1 &
    EMU_PID=$!

    local start=$SECONDS booted=0
    while [ $((SECONDS - start)) -lt "$BOOT_TIMEOUT" ]; do
        if ! kill -0 "$EMU_PID" 2>/dev/null; then
            echo "❌ ${name}：emulator 行程在開機完成前就結束了"
            tail -30 "${TMPAVD}/${name}.emulator.log" | sed 's/^/   /'
            exit 1
        fi
        if [ "$("$ADB" -s "$serial" get-state 2>/dev/null)" = "device" ] \
           && [ "$("$ADB" -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then
            booted=1
            break
        fi
        sleep 5
    done

    if [ "$booted" -ne 1 ]; then
        echo "❌ ${name}：${BOOT_TIMEOUT}s 內沒有到 sys.boot_completed=1"
        tail -30 "${TMPAVD}/${name}.emulator.log" | sed 's/^/   /'
        exit 1
    fi
    echo "✅ ${name} 開機完成（$((SECONDS - start))s）"

    # **只斷言「開機了」是不夠的**：要證明開起來的是我們寫的那台規格。
    # 這幾項逐一對應 AvdSpec 與 config_base 的關鍵欄位。
    local size density abi sdkver memkb playstore
    size=$("$ADB" -s "$serial" shell wm size 2>/dev/null | tr -d '\r' | awk '{print $NF}')
    density=$("$ADB" -s "$serial" shell wm density 2>/dev/null | tr -d '\r' | awk '{print $NF}')
    abi=$("$ADB" -s "$serial" shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r')
    sdkver=$("$ADB" -s "$serial" shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')
    memkb=$("$ADB" -s "$serial" shell cat /proc/meminfo 2>/dev/null | head -1 | tr -d '\r' | awk '{print $2}')
    playstore=$("$ADB" -s "$serial" shell pm list packages 2>/dev/null | grep -c "com.android.vending")

    assert_equals "${name} 解析度" "$size" "1080x2400"
    assert_equals "${name} density" "$density" "420"
    assert_equals "${name} abi" "$abi" "arm64-v8a"
    assert_equals "${name} SDK 版本" "$sdkver" "35"
    # hw.ramSize=4096 → guest 看到的 MemTotal 會略低於 4096MiB（核心自己留走一些），
    # 所以用門檻而不是等值。3.5GiB 足以區分「4096」與 mirage-poc 舊有的「2G」。
    assert_at_least "${name} 記憶體 kB" "${memkb:-0}" 3670016
    assert_equals "${name} Play Store 套件數" "$playstore" "$want_playstore"

    # 證明用的是暫存目錄那台：userdata 只會被寫進實際使用的 .avd 目錄。
    if [ ! -f "${TMPAVD}/${name}.avd/userdata-qemu.img" ]; then
        echo "❌ ${name}：暫存目錄裡沒有 userdata-qemu.img——開起來的可能不是這一台"
        exit 1
    fi
    echo "✅ ${name} 用的是暫存目錄那台（userdata 寫在 ${TMPAVD} 底下）"

    "$ADB" -s "$serial" emu kill > /dev/null 2>&1
    wait "$EMU_PID" 2>/dev/null
    EMU_PID=""
}

# mirage-poc 用 default（AOSP）映像 → 沒有 Play Store；
# mirage-game 用 google_apis_playstore 映像 → 有。這個差異是兩台唯一的實質不同，
# 所以它同時是「映像掛對了」的證據。
for name in ${1:-mirage-poc mirage-game}; do
    case "$name" in
        mirage-poc)  boot_and_check "$name" 5560 0 ;;
        mirage-game) boot_and_check "$name" 5562 1 ;;
        *) echo "❌ 不認識的 AVD 名稱：${name}"; exit 1 ;;
    esac
done

echo ""
echo "======================================"
echo "✅ 全部通過——產出的 AVD 開得起來，且規格與 AvdSpec 相符"
