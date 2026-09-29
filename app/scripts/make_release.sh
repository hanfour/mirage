#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
APP_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"

log() { printf '%s\n' "$*" >&2; }
fail() { log "❌ $*"; exit 1; }

usage() {
    log "用法：make_release.sh [--notarize] [--identity <名稱>] [--out <目錄>]"
    exit 2
}

NOTARIZE=0
IDENTITY_OPTION=""
OUT_DIR="${APP_ROOT}/dist"
while (($#)); do
    case "$1" in
        --notarize)
            NOTARIZE=1
            shift
            ;;
        --identity)
            (($# >= 2)) || usage
            [[ -n "$2" ]] || usage
            IDENTITY_OPTION="$2"
            shift 2
            ;;
        --out)
            (($# >= 2)) || usage
            [[ -n "$2" ]] || usage
            OUT_DIR="$2"
            shift 2
            ;;
        *)
            usage
            ;;
    esac
done

APP_VERSION="$(tr -d '[:space:]' < "${APP_ROOT}/VERSION")" || fail "無法讀取 app/VERSION。"
[[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "VERSION 格式錯誤，必須是數字.數字.數字：${APP_VERSION}"

if [[ -n "$IDENTITY_OPTION" ]]; then
    SIGN_IDENTITY="$IDENTITY_OPTION"
    IDENTITY_REASON="由 --identity 指定"
elif [[ -n "${MIRAGE_SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY="$MIRAGE_SIGN_IDENTITY"
    IDENTITY_REASON="由 MIRAGE_SIGN_IDENTITY 指定"
else
    IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    SIGN_IDENTITY="$(printf '%s\n' "$IDENTITIES" | awk -F '\"' '/"Developer ID Application:/ { print $2; exit }')"
    if [[ -n "$SIGN_IDENTITY" ]]; then
        IDENTITY_REASON="自動選擇第一個 Developer ID Application 身分"
    else
        SIGN_IDENTITY="$(printf '%s\n' "$IDENTITIES" | awk -F '\"' '/"Apple Development:/ { print $2; exit }')"
        if [[ -n "$SIGN_IDENTITY" ]]; then
            IDENTITY_REASON="沒有 Developer ID Application，改選第一個 Apple Development 身分"
        else
            SIGN_IDENTITY="-"
            IDENTITY_REASON="找不到可用的 Developer ID Application 或 Apple Development 身分，使用 ad-hoc"
        fi
    fi
fi

# 固定簽章身分可保留使用者已授權的麥克風、語音辨識與防火牆規則；ad-hoc 每次打包的身分不同，防火牆會再次詢問。
log "簽章身分：${SIGN_IDENTITY}"
log "選擇原因：${IDENTITY_REASON}"

if ((NOTARIZE)); then
    [[ -n "${MIRAGE_NOTARY_PROFILE:-}" ]] || fail "--notarize 需要 MIRAGE_NOTARY_PROFILE。請先執行 xcrun notarytool store-credentials <profile-name> --apple-id <Apple ID> --team-id <Team ID> --password <app-specific-password>，再把 profile 名稱設為 MIRAGE_NOTARY_PROFILE。"
    [[ "$SIGN_IDENTITY" == "Developer ID Application:"* ]] || fail "--notarize 只接受 Developer ID Application 身分，目前是：${SIGN_IDENTITY}"
fi

case "$OUT_DIR" in
    /*) ;;
    *) OUT_DIR="${APP_ROOT}/${OUT_DIR}" ;;
esac
mkdir -p "$OUT_DIR" || fail "無法建立輸出目錄：${OUT_DIR}"
OUT_DIR="$(cd -- "$OUT_DIR" && pwd -P)" || fail "無法解析輸出目錄：${OUT_DIR}"

TEMP_ROOT="$(mktemp -d -t mirage_release)" || fail "無法建立暫存目錄。"
cleanup() { rm -rf "$TEMP_ROOT"; }
trap cleanup EXIT

PACKAGE_DIR="${TEMP_ROOT}/package"
mkdir -p "$PACKAGE_DIR" || fail "無法建立 app 暫存目錄。"
APP_PATH="$("${APP_ROOT}/scripts/package_app.sh" "$PACKAGE_DIR" release)" || fail "package_app.sh 失敗。"
[[ -d "$APP_PATH" ]] || fail "package_app.sh 沒有產生 app：${APP_PATH}"

if ((NOTARIZE)); then
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp \
        --entitlements "${APP_ROOT}/Mirage.entitlements" "$APP_PATH" >&2 \
        || fail "app 簽章失敗。"
else
    codesign --force --sign "$SIGN_IDENTITY" "$APP_PATH" >&2 \
        || fail "app 簽章失敗。"
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH" >&2 \
    || fail "app 簽章驗證失敗。"

SIGNING_INFO="$(codesign -dv --verbose=4 "$APP_PATH" 2>&1)" \
    || fail "無法讀取簽章資訊。"
printf '%s\n' "$SIGNING_INFO" | awk -F= '
    /^Identifier=/ && !identifier { identifier = substr($0, index($0, "=") + 1) }
    /^Authority=/ && !authority { authority = substr($0, index($0, "=") + 1) }
    /^TeamIdentifier=/ { team = substr($0, index($0, "=") + 1) }
    END {
        print "Identifier: " (identifier ? identifier : "（無）")
        print "Authority: " (authority ? authority : "（無）")
        print "TeamIdentifier: " (team ? team : "（無）")
    }
' >&2

DMG_SOURCE="${TEMP_ROOT}/dmg-source"
mkdir -p "$DMG_SOURCE" || fail "無法建立 DMG 暫存目錄。"
cp -R "$APP_PATH" "${DMG_SOURCE}/Mirage.app" || fail "無法複製 Mirage.app 到 DMG 暫存目錄。"
ln -s /Applications "${DMG_SOURCE}/Applications" || fail "無法建立 Applications 捷徑。"

DMG_PATH="${OUT_DIR}/Mirage-${APP_VERSION}.dmg"
hdiutil create -ov -volname "Mirage ${APP_VERSION}" -srcfolder "$DMG_SOURCE" \
    -fs HFS+ -format UDZO "$DMG_PATH" >&2 || fail "建立 .dmg 失敗。"
hdiutil verify "$DMG_PATH" >&2 || fail ".dmg 驗證失敗。"

if ((NOTARIZE)); then
    # notarytool 提交與 stapling 流程目前尚未經實測。
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$MIRAGE_NOTARY_PROFILE" --wait >&2 \
        || fail "Apple 公證失敗。"
    xcrun stapler staple "$DMG_PATH" >&2 || fail "公證票證 stapling 失敗。"
fi

printf '%s\n' "$DMG_PATH"
