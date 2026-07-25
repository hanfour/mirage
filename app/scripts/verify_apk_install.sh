#!/usr/bin/env bash
# 驗收 2+3：Task 2 重構後 dumpsys 前景偵測不回歸；adb install -r 機制活體。
# 用法：verify_apk_install.sh [APK路徑]；未給則從裝置抓一個第三方 app 的 base.apk 重裝。
set -uo pipefail
export ANDROID_SERIAL=emulator-5554
ADB="$HOME/Library/Android/sdk/platform-tools/adb"

echo "=== 驗收 2：dumpsys 前景解析（P1-d 不回歸）==="
"$ADB" shell dumpsys activity activities 2>/dev/null \
  | grep -m1 ResumedActivity || echo "（無 ResumedActivity 行）"

echo ""
echo "=== 驗收 3：adb install -r 機制（InstallResult.parse 的輸入）==="
APK="${1:-}"
if [ -z "$APK" ]; then
  PKG="$("$ADB" shell pm list packages -3 2>/dev/null | head -1 | tr -d '\r' | cut -d: -f2)"
  if [ -n "$PKG" ]; then
    REMOTE="$("$ADB" shell pm path "$PKG" 2>/dev/null | head -1 | tr -d '\r' | cut -d: -f2)"
    APK="/tmp/mirage_verify_$PKG.apk"
    "$ADB" pull "$REMOTE" "$APK" >/dev/null 2>&1 && echo "抓到可重裝 APK：$PKG"
  fi
fi
if [ -z "$APK" ] || [ ! -f "$APK" ]; then
  echo "無可用 APK——請給路徑：verify_apk_install.sh /path/to/app.apk"; exit 1
fi
echo "--- adb install -r 原始輸出 ---"
"$ADB" install -r "$APK"
echo "--- 結束（Success → .success；Failure [X] → .failure(X)）---"
