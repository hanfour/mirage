#!/usr/bin/env bash
# 終審「新增」項：固化 P1-e 完整覆蓋率量測流程。
#
# 背景：MirageCore 的完整覆蓋率需要兩條指令各自的 .profdata 合併後才反映真實數字——
# 見 RESULTS-p1e.md「覆蓋率細節」一節：
#   1. `MIRAGE_LIVE=1 MIRAGE_LIVE_MMAP=1 swift test --enable-code-coverage`
#      （一般 live 套件）——單獨跑只得 TOTAL line ~89.25%，因為 AudioLiveTests 掛了
#      `MIRAGE_LIVE_AUDIO` 閘門（避免污染這條指令的全綠斷言，見 commit 8a1b694），
#      在這條指令下 early return，`GrpcAudioTransport.swift` 因此掉到 ~11.69%。
#   2. `MIRAGE_LIVE=1 MIRAGE_LIVE_AUDIO=1 swift test --filter AudioLiveTests
#      --enable-code-coverage`（比照 verify_audio.sh：先觸發 guest 發聲再跑）——補回
#      `GrpcAudioTransport` 的覆蓋。
# 把兩次個別的 `default.profdata` 用 `xcrun llvm-profdata merge -sparse` 合併，再對
# 合併後的結果跑 `llvm-cov report`，才得到完整的 ~95.9% TOTAL line coverage。
#
# 用法：./scripts/coverage.sh（需 emulator-5554 正在跑；本腳本會觸發音量鍵 + 播放音檔，
# 效果同 verify_audio.sh 的 Step 1，過程中畫面/输入不受影響）。
set -uo pipefail
export ANDROID_SERIAL=emulator-5554
ADB="$HOME/Library/Android/sdk/platform-tools/adb"

# 比照 verify_audio.sh 的 Minor 8 修法：先確認 adb 存在且可執行，避免前面幾步靜默失敗、
# 最後只得到一個令人困惑的低覆蓋率數字（看起來像回歸，其實只是環境沒裝好）。
if [ ! -x "$ADB" ]; then
  echo "找不到可執行的 adb：$ADB"
  echo "請確認 Android SDK platform-tools 已安裝於此路徑（本專案未把 adb 放進 PATH）。"
  exit 1
fi

cd "$(dirname "$0")/.." || exit 1

echo "=== 前置：模擬器是否在跑 ==="
nc -z localhost 8554 && echo "gRPC 8554 ALIVE" || { echo "模擬器未啟動"; exit 1; }

CODECOV_DIR=".build/debug/codecov"
TEST_BIN=".build/debug/MiragePackageTests.xctest/Contents/MacOS/MiragePackageTests"
RUN1_PROFDATA="/tmp/mirage_coverage_run1.profdata"
RUN2_PROFDATA="/tmp/mirage_coverage_run2.profdata"
MERGED_PROFDATA="/tmp/mirage_coverage_merged.profdata"
SOUND="/product/media/audio/ringtones/Ring_Synth_04.ogg"   # 同 verify_audio.sh，實測存在

echo ""
echo "=== Run 1/2：一般 live 套件（MIRAGE_LIVE_MMAP，AudioLiveTests 因閘門 early return）==="
rm -rf "$CODECOV_DIR"
MIRAGE_LIVE=1 MIRAGE_LIVE_MMAP=1 swift test --enable-code-coverage 2>&1 | tail -3
if [ ! -f "$CODECOV_DIR/default.profdata" ]; then
  echo "Run 1 未產生 default.profdata（測試可能失敗），中止"
  exit 1
fi
cp "$CODECOV_DIR/default.profdata" "$RUN1_PROFDATA"

echo ""
echo "=== 觸發 guest 發聲（同 verify_audio.sh：音量鍵頂到最大 + 播放內建音檔）==="
for _ in $(seq 1 15); do "$ADB" shell input keyevent 24 > /dev/null; done
"$ADB" shell am start -a android.intent.action.VIEW -d "file://$SOUND" -t audio/ogg 2>&1 | tail -3

echo ""
echo "=== Run 2/2：AudioLiveTests 專用（MIRAGE_LIVE_AUDIO，補回 GrpcAudioTransport 覆蓋）==="
rm -rf "$CODECOV_DIR"
MIRAGE_LIVE=1 MIRAGE_LIVE_AUDIO=1 swift test --filter AudioLiveTests --enable-code-coverage 2>&1 \
  | grep -E "\[audio-live\]|Test.*(passed|failed)"
if [ ! -f "$CODECOV_DIR/default.profdata" ]; then
  echo "Run 2 未產生 default.profdata（測試可能失敗），中止"
  exit 1
fi
cp "$CODECOV_DIR/default.profdata" "$RUN2_PROFDATA"

echo ""
echo "=== 合併兩次 .profdata 並產出報告 ==="
xcrun llvm-profdata merge -sparse "$RUN1_PROFDATA" "$RUN2_PROFDATA" -o "$MERGED_PROFDATA"
xcrun llvm-cov report "$TEST_BIN" -instr-profile "$MERGED_PROFDATA" \
  -ignore-filename-regex 'Generated|Tests|\.build'

echo ""
echo "=== 判讀 ==="
echo "TOTAL line coverage 應落在 ~95% 上下（RESULTS-p1e.md 記錄的參考值：95.92%）。"
echo "若明顯偏低（例如掉回 ~89%），先確認上面兩次 swift test 是否皆全綠、"
echo "以及 Run 2 前的發聲觸發是否成功（Run 2 的 [audio-live] writes 應 >= 75）——"
echo "單獨漏跑 Run 2 是最常見的誤判成因，不是真的覆蓋率回歸。"
