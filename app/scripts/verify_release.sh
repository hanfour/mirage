#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
APP_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
CALLER_DIR="$PWD"

log() { printf '%s\n' "$*" >&2; }
record_r1_failure() {
    R1_OK=0
    log "❌ R1：$*"
}
record_r4_failure() {
    R4_OK=0
    log "❌ R4：$*"
}

if (($# > 1)); then
    log "用法：verify_release.sh [dmg 路徑]"
    exit 2
fi
if pgrep -x MirageApp >/dev/null 2>&1; then
    log "❌ 已有 MirageApp 正在執行，請先自行結束後再驗證；腳本不會替你關閉。"
    pgrep -alf MirageApp >&2 || true
    exit 1
fi

if (($# == 1)); then
    DMG_PATH="$1"
else
    DMG_PATH="$("${APP_ROOT}/scripts/make_release.sh")" || {
        log "❌ make_release.sh 失敗。"
        exit 1
    }
fi
case "$DMG_PATH" in
    /*) ;;
    *) DMG_PATH="${CALLER_DIR}/${DMG_PATH}" ;;
esac
if [[ ! -f "$DMG_PATH" ]]; then
    log "❌ 找不到 .dmg：${DMG_PATH}"
    exit 1
fi

TEMP_ROOT="$(mktemp -d -t mirage_verify_release)" || {
    log "❌ 無法建立驗證暫存目錄。"
    exit 1
}
MOUNT_POINT="${TEMP_ROOT}/mount"
mkdir -p "$MOUNT_POINT" || {
    log "❌ 無法建立掛載目錄。"
    rm -rf "$TEMP_ROOT"
    exit 1
}

R1_OK=1
R2_RESULT="未執行"
R3_RESULT="未記錄"
R4_OK=1
R1_RESULT="FAIL"
R4_RESULT="FAIL"
MOUNTED=0
RESTORE_FAILED=0
RESTORE_FAILURE_REPORTED=0
CLEANUP_DONE=0
ORIGINAL_BUNDLES=()
HIDDEN_BUNDLES=()

restore_bundles() {
    local index original hidden
    for ((index=${#ORIGINAL_BUNDLES[@]} - 1; index >= 0; index--)); do
        original="${ORIGINAL_BUNDLES[$index]}"
        hidden="${HIDDEN_BUNDLES[$index]}"
        if [[ ! -e "$hidden" ]]; then
            if [[ ! -e "$original" ]]; then
                log "❌ 嚴重錯誤：找不到待還原的資源 bundle：${hidden}"
                RESTORE_FAILED=1
            fi
            continue
        fi
        if [[ -e "$original" ]]; then
            log "❌ 嚴重錯誤：原路徑已重新出現，無法安全還原 bundle：${original}"
            log "   備份仍保留在：${hidden}"
            RESTORE_FAILED=1
            continue
        fi
        if mv "$hidden" "$original"; then
            log "已還原資源 bundle：${original}"
        else
            log "❌ 嚴重錯誤：資源 bundle 還原失敗：${hidden} -> ${original}"
            RESTORE_FAILED=1
        fi
    done
}

detach_image() {
    if ((MOUNTED)); then
        if hdiutil detach "$MOUNT_POINT" >&2; then
            MOUNTED=0
        else
            log "❌ 嚴重錯誤：無法卸載 .dmg：${MOUNT_POINT}"
            R1_OK=0
        fi
    fi
}

cleanup() {
    restore_bundles
    detach_image
    if ((RESTORE_FAILED && !RESTORE_FAILURE_REPORTED)); then
        log "❌ 嚴重錯誤：一個或多個 Mirage_MirageCore.bundle 未能還原。"
        RESTORE_FAILURE_REPORTED=1
    fi
    if ((MOUNTED)); then
        log "❌ 嚴重錯誤：保留掛載點供手動卸載：${MOUNT_POINT}"
    else
        rm -rf "$TEMP_ROOT"
    fi
}

on_exit() {
    local status=$?
    trap - EXIT
    if ((!CLEANUP_DONE)); then cleanup; fi
    if ((RESTORE_FAILED || R1_OK == 0)); then status=1; fi
    exit "$status"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 129' HUP
trap 'exit 143' TERM

show_paths() {
    local path
    for path in "$@"; do
        if [[ -e "$path" || -L "$path" ]]; then
            log "--- ls -la ${path}"
            ls -la "$path" >&2 || true
        else
            log "--- 不存在：${path}"
        fi
    done
}

RESOURCE_BUNDLE=""
MOUNTED_APP="${MOUNT_POINT}/Mirage.app"
if hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT_POINT" "$DMG_PATH" >&2; then
    MOUNTED=1
else
    record_r1_failure ".dmg 掛載失敗。"
fi

if ((MOUNTED)); then
    [[ -d "$MOUNTED_APP" ]] || record_r1_failure "映像檔沒有 Mirage.app。"

    APPLICATIONS_LINK="${MOUNT_POINT}/Applications"
    if [[ ! -L "$APPLICATIONS_LINK" ]] || [[ "$(readlink "$APPLICATIONS_LINK" 2>/dev/null || true)" != "/Applications" ]]; then
        record_r1_failure "Applications 捷徑不存在或沒有指向 /Applications。"
    fi

    RESOURCE_BUNDLE="${MOUNTED_APP}/Contents/Resources/Mirage_MirageCore.bundle"
    [[ -d "$RESOURCE_BUNDLE" ]] || record_r1_failure "Contents/Resources/Mirage_MirageCore.bundle 不存在。"
    if [[ -d "$RESOURCE_BUNDLE" ]]; then
        [[ -n "$(find "$RESOURCE_BUNDLE" -type f -name instances.conf -print -quit)" ]] \
            || record_r1_failure "資源 bundle 缺少 instances.conf。"
        [[ -n "$(find "$RESOURCE_BUNDLE" -type f -name sdk-spec.json -print -quit)" ]] \
            || record_r1_failure "資源 bundle 缺少 sdk-spec.json。"
        [[ -n "$(find "$RESOURCE_BUNDLE" -type d -name profiles -print -quit)" ]] \
            || record_r1_failure "資源 bundle 缺少 profiles/。"
    fi

    if [[ -d "$MOUNTED_APP" ]]; then
        shopt -s dotglob nullglob
        for path in "$MOUNTED_APP"/*; do
            if [[ "${path##*/}" != "Contents" ]]; then
                record_r1_failure "app 根目錄有 Contents 以外的項目：${path##*/}"
            fi
        done
        shopt -u dotglob nullglob
    fi

    INFO_PLIST="${MOUNTED_APP}/Contents/Info.plist"
    if [[ ! -f "$INFO_PLIST" ]]; then
        record_r1_failure "Contents/Info.plist 不存在。"
    elif [[ -x /usr/libexec/PlistBuddy ]]; then
        SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null || true)"
        BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST" 2>/dev/null || true)"
        MINIMUM_SYSTEM="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO_PLIST" 2>/dev/null || true)"
        EXPECTED_VERSION="$(tr -d '[:space:]' < "${APP_ROOT}/VERSION")"
        [[ "$SHORT_VERSION" == "$EXPECTED_VERSION" ]] || record_r1_failure "CFBundleShortVersionString 缺少或不等於 ${EXPECTED_VERSION}。"
        [[ "$BUILD_VERSION" =~ ^[0-9]+$ ]] || record_r1_failure "CFBundleVersion 缺少或不是數字。"
        [[ "$MINIMUM_SYSTEM" == "14.0" ]] || record_r1_failure "LSMinimumSystemVersion 缺少或不是 14.0。"
    else
        record_r1_failure "找不到 /usr/libexec/PlistBuddy，無法檢查 Info.plist。"
    fi

    COPY_ROOT="${TEMP_ROOT}/copies"
    mkdir -p "$COPY_ROOT/R2" "$COPY_ROOT/R3" "$COPY_ROOT/R4"
    R2_APP="${COPY_ROOT}/R2/Mirage.app"
    R3_APP="${COPY_ROOT}/R3/Mirage.app"
    R4_APP="${COPY_ROOT}/R4/Mirage.app"
    if cp -R "$MOUNTED_APP" "$R2_APP"; then
        R2_RESULT="待驗證"
    else
        R2_RESULT="FAIL"
        log "❌ R2：無法複製 app 供簽章驗證。"
        show_paths "$MOUNTED_APP" "$COPY_ROOT/R2"
    fi
    if cp -R "$MOUNTED_APP" "$R3_APP"; then
        R3_RESULT="待驗證"
    else
        R3_RESULT="複製失敗"
        log "R3：無法複製 app，Gatekeeper 狀態未記錄。"
    fi
    if cp -R "$MOUNTED_APP" "$R4_APP"; then
        R4_RESULT="待驗證"
    else
        record_r4_failure "無法建立不帶 quarantine 的 app 複本。"
    fi
else
    R2_RESULT="SKIP（無法掛載）"
    R3_RESULT="SKIP（無法掛載）"
    record_r4_failure "無法掛載 .dmg，沒有 app 可供啟動。"
fi

if ((R1_OK == 0)); then
    show_paths "$MOUNT_POINT" "$MOUNTED_APP" "${MOUNTED_APP}/Contents" \
        "${MOUNTED_APP}/Contents/Resources" "$RESOURCE_BUNDLE"
fi
detach_image
if ((R1_OK)); then R1_RESULT="PASS"; else R1_RESULT="FAIL"; fi

R2_LOG="${TEMP_ROOT}/R2-codesign.log"
if [[ -d "${R2_APP:-}" ]]; then
    if codesign --verify --deep --strict "$R2_APP" >"$R2_LOG" 2>&1; then
        R2_RESULT="PASS"
    else
        R2_RESULT="FAIL"
        log "❌ R2：複製出的 app 簽章驗證失敗。"
        cat "$R2_LOG" >&2
        show_paths "$R2_APP" "${R2_APP}/Contents" "${R2_APP}/Contents/Resources"
    fi
elif [[ "$R2_RESULT" == "待驗證" ]]; then
    R2_RESULT="FAIL"
fi

R3_LOG="${TEMP_ROOT}/R3-gatekeeper.log"
if [[ -d "${R3_APP:-}" ]]; then
    QUARANTINE_TIME="$(date +%s)"
    QUARANTINE_VALUE="0081;$(printf '%x' "$QUARANTINE_TIME");Safari;"
    if xattr -w com.apple.quarantine "$QUARANTINE_VALUE" "$R3_APP" 2>"${TEMP_ROOT}/R3-xattr.log"; then
        if spctl --assess --type execute -vv "$R3_APP" >"$R3_LOG" 2>&1; then
            SPCTL_STATUS=0
        else
            SPCTL_STATUS=$?
        fi
        log "R3 Gatekeeper 結果（只記錄，不作為失敗判準；spctl exit ${SPCTL_STATUS}）："
        cat "$R3_LOG" >&2
        R3_RESULT="已記錄（spctl exit ${SPCTL_STATUS}）"
    else
        R3_RESULT="設定 quarantine 失敗"
        log "❌ R3：無法加上 quarantine 屬性；此項只記錄，不影響總結果。"
        cat "${TEMP_ROOT}/R3-xattr.log" >&2
        show_paths "$R3_APP"
    fi
fi

R4_LOG="${TEMP_ROOT}/R4-startup.log"
if [[ -d "${R4_APP:-}" ]]; then
    CACHE_MOVE_FAILED=0
    DEBUG_BIN_PATH=""
    RELEASE_BIN_PATH=""
    for CONFIG in debug release; do
        SWIFT_ERROR_LOG="${TEMP_ROOT}/swift-${CONFIG}.log"
        if BIN_PATH="$(cd "$APP_ROOT" && swift build -c "$CONFIG" --show-bin-path 2>"$SWIFT_ERROR_LOG")"; then
            [[ ! -s "$SWIFT_ERROR_LOG" ]] || cat "$SWIFT_ERROR_LOG" >&2
        else
            log "❌ R4：無法取得 ${CONFIG} 的 SwiftPM bin path。"
            cat "$SWIFT_ERROR_LOG" >&2
            CACHE_MOVE_FAILED=1
            continue
        fi
        case "$BIN_PATH" in
            /*) ;;
            *) BIN_PATH="${APP_ROOT}/${BIN_PATH}" ;;
        esac
        if [[ "$CONFIG" == "debug" ]]; then
            DEBUG_BIN_PATH="$BIN_PATH"
        else
            RELEASE_BIN_PATH="$BIN_PATH"
        fi
        CACHED_BUNDLE="${BIN_PATH}/Mirage_MirageCore.bundle"
        if [[ ! -d "$CACHED_BUNDLE" ]]; then
            log "R4：${CONFIG} 沒有既存的編譯資源 bundle：${CACHED_BUNDLE}"
            continue
        fi
        HIDDEN_BUNDLE="${CACHED_BUNDLE}.verify-release-$$"
        if [[ -e "$HIDDEN_BUNDLE" ]]; then
            log "❌ R4：暫存名稱已存在，拒絕覆寫：${HIDDEN_BUNDLE}"
            CACHE_MOVE_FAILED=1
            continue
        fi
        ORIGINAL_BUNDLES+=("$CACHED_BUNDLE")
        HIDDEN_BUNDLES+=("$HIDDEN_BUNDLE")
        if mv "$CACHED_BUNDLE" "$HIDDEN_BUNDLE"; then
            log "R4：暫時隱藏 ${CONFIG} bundle：${CACHED_BUNDLE}"
        else
            log "❌ R4：無法暫時隱藏 ${CONFIG} bundle：${CACHED_BUNDLE}"
            CACHE_MOVE_FAILED=1
        fi
    done
    if ((CACHE_MOVE_FAILED)); then
        record_r4_failure "無法完整隱藏 debug/release 編譯資源 bundle。"
    fi

    if ((CACHE_MOVE_FAILED)); then
        :
    elif pgrep -x MirageApp >/dev/null 2>&1; then
        record_r4_failure "啟動前已有 MirageApp 正在執行，拒絕建立第二個 GUI session。"
    elif [[ -d "$R4_APP" ]]; then
        EMPTY_SDK="${TEMP_ROOT}/empty-android-sdk"
        EMPTY_AVD="${TEMP_ROOT}/empty-android-avd"
        mkdir -p "$EMPTY_SDK" "$EMPTY_AVD"
        : > "$R4_LOG"
        if open -n -a "$R4_APP" --stdout "$R4_LOG" --stderr "$R4_LOG" \
            --env MIRAGE_BACKGROUND_MODE=0 \
            --env "ANDROID_SDK_ROOT=${EMPTY_SDK}" \
            --env "ANDROID_AVD_HOME=${EMPTY_AVD}" >&2; then
            APP_PID=""
            STARTUP_READY=0
            for ((elapsed = 0; elapsed < 15; elapsed++)); do
                APP_PID="$(pgrep -x MirageApp 2>/dev/null | head -n 1 || true)"
                if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null \
                    && grep -q '^\[setup\] ' "$R4_LOG" 2>/dev/null; then
                    STARTUP_READY=1
                    break
                fi
                if grep -Eiq '讀取失敗|Fatal error' "$R4_LOG" 2>/dev/null; then
                    record_r4_failure "啟動 log 出現讀取失敗或 Fatal error。"
                fi
                sleep 1
            done
            if ((STARTUP_READY)); then
                if grep -Eiq '讀取失敗|Fatal error' "$R4_LOG"; then
                    record_r4_failure "啟動 log 出現讀取失敗或 Fatal error。"
                else
                    log "R4：MirageApp 在 15 秒內存活並輸出 [setup]。"
                fi
            else
                record_r4_failure "15 秒內沒有觀察到存活行程與 [setup] log。"
            fi

            if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
                if osascript -e 'tell application "System Events" to set frontmost of process "MirageApp" to true' >&2; then
                    if osascript -l JavaScript "${APP_ROOT}/scripts/lib/cgkey.js" 12 1048576 >&2; then
                        APP_EXITED=0
                        for ((elapsed = 0; elapsed < 10; elapsed++)); do
                            if ! kill -0 "$APP_PID" 2>/dev/null; then
                                APP_EXITED=1
                                break
                            fi
                            sleep 1
                        done
                        if ((APP_EXITED)); then
                            log "R4：MirageApp 在 ⌘Q 後 10 秒內結束。"
                        else
                            record_r4_failure "MirageApp 沒有在 ⌘Q 後 10 秒內結束。"
                        fi
                    else
                        record_r4_failure "無法送出 ⌘Q。"
                    fi
                else
                    record_r4_failure "無法先將 MirageApp 設為前景，未送出 ⌘Q。"
                fi
            else
                record_r4_failure "無法確認 MirageApp 行程，未送出 ⌘Q。"
            fi
        else
            record_r4_failure "open 無法啟動複製出的 Mirage.app。"
        fi
    fi
else
    record_r4_failure "沒有 app 複本可供啟動。"
fi

restore_bundles
if ((RESTORE_FAILED)); then
    record_r4_failure "一個或多個 Mirage_MirageCore.bundle 無法還原，請依錯誤訊息手動處理。"
    RESTORE_FAILURE_REPORTED=1
fi
if ((R4_OK)); then R4_RESULT="PASS"; else R4_RESULT="FAIL"; fi
if [[ "$R2_RESULT" == "待驗證" ]]; then R2_RESULT="FAIL"; fi

if [[ "$R4_RESULT" == "FAIL" ]]; then
    log "--- R4 app log：${R4_LOG}"
    if [[ -f "$R4_LOG" ]]; then cat "$R4_LOG" >&2; fi
    show_paths "${R4_APP:-}" "${R4_APP:-}/Contents" "${R4_APP:-}/Contents/Resources" \
        "$APP_ROOT/.build"
    if [[ -n "${DEBUG_BIN_PATH:-}" ]]; then
        show_paths "$DEBUG_BIN_PATH" "${DEBUG_BIN_PATH}/Mirage_MirageCore.bundle"
    fi
    if [[ -n "${RELEASE_BIN_PATH:-}" ]]; then
        show_paths "$RELEASE_BIN_PATH" "${RELEASE_BIN_PATH}/Mirage_MirageCore.bundle"
    fi
fi

cleanup
CLEANUP_DONE=1
trap - EXIT INT HUP TERM
if ((R1_OK)); then R1_RESULT="PASS"; else R1_RESULT="FAIL"; fi
if ((RESTORE_FAILED)); then R4_RESULT="FAIL"; fi

printf '\n%-5s %-20s\n' '項目' '結果'
printf '%-5s %-20s\n' 'R1' "$R1_RESULT"
printf '%-5s %-20s\n' 'R2' "$R2_RESULT"
printf '%-5s %-20s\n' 'R3' "$R3_RESULT"
printf '%-5s %-20s\n' 'R4' "$R4_RESULT"

if [[ "$R1_RESULT" == "FAIL" || "$R2_RESULT" == "FAIL" || "$R4_RESULT" == "FAIL" ]]; then
    exit 1
fi
exit 0
