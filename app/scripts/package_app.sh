#!/usr/bin/env bash
# 組出一個**可以帶到別台機器**的 Mirage.app（D25）。
#
# 用法：./scripts/package_app.sh [輸出目錄] [debug|release]
#       印出組好的 .app 路徑到 stdout（最後一行），其餘訊息走 stderr，方便被其他腳本吃。
#
# **要修的是什麼**：SwiftPM 產生的 `Bundle.module` 存取器（`.build/…/MirageCore.build/
# DerivedSources/resource_bundle_accessor.swift`）只查兩條路徑：
#
#     mainPath  = Bundle.main.bundleURL/Mirage_MirageCore.bundle
#     buildPath = "<編譯當下寫死的絕對路徑>/.build/arm64-apple-macosx/debug/Mirage_MirageCore.bundle"
#     guard let bundle = Bundle(path: mainPath) ?? Bundle(path: buildPath) else { fatalError(...) }
#
# 兩條都不中是 **fatalError，不是回傳 nil**。而全 repo 唯一組 .app 的地方
# （`verify_game_fps.sh`）原本只 `cp` executable，不複製 resource bundle——在這台開發機上
# 照跑（默默從第二條 `.build/` 路徑讀），**換一台機器或 `swift package clean` 之後就是
# 啟動即崩**。設計文件 §4.1 那條「.app bundle + open」的手動驗法因此在有 `.build/` 的
# 機器上**結構上測不出這個缺陷**。
#
# 注意 bundle 要放在 `.app` 的**根目錄**（`Mirage.app/Mirage_MirageCore.bundle`），
# 不是慣例的 `Contents/Resources/`——`Bundle.main.bundleURL` 對 .app 回傳的就是 .app 自己。
# 這不是我們選的位置，是上面那段產生碼決定的。
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT_DIR="${1:-$(mktemp -d -t mirage_app)}"
CONFIG="${2:-debug}"
# 第三參數：指定另一個執行檔（`verify_game_fps.sh -a` 的版本對照用途）。
# **資源 bundle 仍取自目前的建置**——做版本對照時要留意這一點：比的是那顆二進位，
# 不是那個版本的資源。資源內容變動時這個組合會失真，屆時要改成連 bundle 一起指定。
EXEC_OVERRIDE="${3:-}"
APP="$OUT_DIR/Mirage.app"

log() { echo "$@" >&2; }

# `MIRAGE_SKIP_BUILD=1` 讓呼叫端把建置移到量測窗口之外（D57）。
#
# **為什麼是選擇性關閉而不是直接拿掉**：本腳本是組 .app 的唯一入口（D25），三支
# verify_* 與兩份 plan 文件都直接呼叫它，其中多數就是靠它順便建置的。預設行為必須
# 一字不變。只有「要在量測窗口內反覆打包」的呼叫端才需要關掉它，而那些呼叫端有義務
# 先自己 `build_warm`（verify_common.sh）。
#
# **跳過是安全的，因為下面兩條斷言擋著**：沒建過的話 `$EXECUTABLE` 與
# `$RESOURCE_BUNDLE` 都不存在，會以具名訊息中止——不會靜默組出一個壞掉的 .app。
if [ "${MIRAGE_SKIP_BUILD:-0}" = "1" ]; then
    log "=== 跳過建置（MIRAGE_SKIP_BUILD=1；呼叫端已在量測窗口外建好）==="
else
    log "=== 建置（${CONFIG}）==="
    if ! swift build -c "$CONFIG" >&2; then
        log "❌ 建置失敗，中止。"
        exit 1
    fi
fi

BIN_PATH=$(swift build -c "$CONFIG" --show-bin-path)
EXECUTABLE="${EXEC_OVERRIDE:-$BIN_PATH/MirageApp}"
RESOURCE_BUNDLE="$BIN_PATH/Mirage_MirageCore.bundle"

if [ ! -x "$EXECUTABLE" ]; then
    log "❌ 找不到執行檔：$EXECUTABLE"
    exit 1
fi
# 這一條是本腳本存在的理由：資源 bundle 沒被建出來的話，組出來的 .app 一定是壞的，
# 而壞法是「在這台機器上看起來正常」——必須在打包當下就擋掉，不能留到啟動時才炸。
if [ ! -d "$RESOURCE_BUNDLE" ]; then
    log "❌ 找不到資源 bundle：$RESOURCE_BUNDLE"
    # 單引號：雙引號裡的反引號會被 bash 當成命令替換，真的去執行 `Package.swift`。
    # 這是錯誤路徑，平常不跑——與 verify_common_selftest.sh 那個全形標點 bug 同一種盲區。
    log '   Package.swift 的 MirageCore target 應有 resources: [.copy("Resources/profiles")]。' 
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$EXECUTABLE" "$APP/Contents/MacOS/MirageApp"
cp -R "$RESOURCE_BUNDLE" "$APP/Mirage_MirageCore.bundle"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>MirageApp</string>
  <key>CFBundleIdentifier</key><string>com.mirage.app</string>
  <key>CFBundleName</key><string>Mirage</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>NSLocalNetworkUsageDescription</key><string>Mirage 需要本機網路權限，將畫面串流到同一網路的手機，並接收手機遙控操作。</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# === 打包後自檢：組出來的 .app 必須自帶資源 ===
# 這幾條斷言的重點是**不依賴 `.build/`**。只檢查 .app 內部，所以在有 `.build/` 的開發機上
# 也抓得到缺漏——而「開發機上測不出來」正是 D25 能存在這麼久的原因。
BUNDLED="$APP/Mirage_MirageCore.bundle"
if [ ! -d "$BUNDLED" ]; then
    log "❌ 組出來的 .app 缺少 Mirage_MirageCore.bundle——換一台機器就會啟動即崩。"
    exit 1
fi
PROFILE_COUNT=$(find "$BUNDLED" -name "*.json" | wc -l | tr -d ' ')
if [ "$PROFILE_COUNT" -eq 0 ]; then
    log "❌ .app 裡的 Mirage_MirageCore.bundle 沒有任何 .json——bundle 在但內容是空的。"
    log '   （BuiltInProfiles.bundledSources() 回傳空陣列**不是**「找不到 bundle」，'
    log '     找不到 bundle 是 fatalError；空陣列代表就是這個情況。）' 
    exit 1
fi

log "✅ .app 自帶資源 bundle，內含 ${PROFILE_COUNT} 份 profile"
log "✅ 打包完成：$APP"
echo "$APP"
