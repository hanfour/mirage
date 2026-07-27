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

echo ""
echo "=== 覆蓋率（分兩段報告）==="
echo ""
# 終審 Minor 3：改用 include 式的位置參數（直接點名 Sources/MirageCore 或
# Sources/MirageShell）決定「這段算哪個 target」，取代原本純靠 -ignore-filename-regex
# 排除對方 target 名稱的寫法。純排除法會靜默吸收未來新增的 target——哪天多一個 MirageFoo
# target，它同時滿足兩段各自的排除規則（因為兩段都沒點名它），會兩段都算進去而沒有任何提醒。
# include 式沒有這個問題：新 target 預設不出現在任何一段，除非有人明確把它加進某一段的位置
# 參數。若路徑打錯，llvm-cov 會直接報錯（非 0 exit）而非印出一張空表，比純排除法的失敗模式
# 更安全。
#
# 仍保留 `Generated|Tests|\.build` 這三個詞的排除：它們與「這段算哪個 target」是正交的兩件
# 事——這三個詞排除的是「不算數的程式碼」（自動產生的 protobuf 樁碼、測試自己的程式碼、
# build 產物），不是「另一個 target」。實測驗證過：若只留位置參數、拿掉這三個詞，
# Sources/MirageCore/Generated/*.pb.swift 這些手寫覆蓋率原本就很低的產生檔會被算進 TOTAL，
# 把段 1 從 87.80% 拉低到 20.80%——這不是本次修法要改變的行為，純粹是遺漏了這三個詞的副作用，
# 因此保留。
echo "--- 段 1：MirageCore（判定用這一段）---"
xcrun llvm-cov report "$TEST_BIN" -instr-profile "$MERGED_PROFDATA" \
  -ignore-filename-regex 'Generated|Tests|\.build' Sources/MirageCore
echo ""
echo "--- 段 2：MirageShell（App 層，進度指標不是門檻）---"
xcrun llvm-cov report "$TEST_BIN" -instr-profile "$MERGED_PROFDATA" \
  -ignore-filename-regex 'Generated|Tests|\.build' Sources/MirageShell

echo ""
echo "=== 判讀 ==="
echo "**必須分兩段看，不要看合併後的 TOTAL。**"
echo ""
echo "段 1（MirageCore）：判定依據。要求是「不因改動而下降」，不是某個絕對數字——"
echo "  目前基準約 87.80%，其中 MmapStreamTransport.swift 為 0%（MMAP 是 opt-in 路徑，"
echo "  本腳本不設 MIRAGE_TRANSPORT=mmap，故一行都不會執行到）。那是已記錄的預期後果，"
echo "  見 app/RESULTS-mmap.md 驗收線 4，不是回歸。"
echo ""
echo "段 2（MirageShell）：App 層，從接近 0 起算，是**進度指標不是門檻**。"
echo "  這批 App 層程式碼的覆蓋率一直是 0，只是在抽成 library target 之前結構上被排除在報告外。"
echo "  看到它很低不代表退步——代表這筆債現在終於**看得見**了。"
echo "  唯一的棘輪：段 2 的 TOTAL line 不得低於上次記錄值（目前是 2.62%）——這不是門檻，"
echo "  只是最低限度的『不能悄悄變更差』。低於上次記錄值時，代表新增了 App 層程式碼卻沒有"
echo "  補對應測試，值得在 PR 說明。"
echo ""
echo "若段 1 明顯低於基準，先確認上面兩次 swift test 是否皆全綠、以及 Run 2 前的"
echo "發聲觸發是否成功（Run 2 的 [audio-live] writes 應 >= 75）——單獨漏跑 Run 2"
echo "是最常見的誤判成因，不是真的覆蓋率回歸。"
