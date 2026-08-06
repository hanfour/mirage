#!/usr/bin/env bash
# guest_fps.sh 的自我測試。**不需要模擬器、不需要 adb**——解析邏輯與 adb 呼叫在
# guest_fps.sh 裡是分開的兩層，正是為了讓最容易出錯的那層（解析）能離線釘住。
#
# 用法：./scripts/lib/guest_fps_selftest.sh（退出碼 0 = 全部通過）
set -uo pipefail
source "$(dirname "$0")/guest_fps.sh"
FAILURES=0

check() {
    local desc="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then
        echo "✅ ${desc}"
    else
        echo "❌ ${desc}：實測 '${got}'，期待 '${want}'"
        FAILURES=$((FAILURES + 1))
    fi
}

FIX=$(mktemp -t d56_fixture)
trap 'rm -f "$FIX"' EXIT

# 取自 2026-08-06 真實跑次的 dumpsys 輸出（已裁剪，保留三個陷阱）：
#   1. 檔頭的**全域** totalFrames = 11859（不是遊戲的）
#   2. 目標 layer 的 totalFrames = 11854
#   3. 後面還有兩個別的 layer（StatusBar 12 幀、none 0 幀）
cat > "$FIX" <<'FIXEOF'
SurfaceFlinger TimeStats:
Legacy stats are as follows:
statsStart = 1785985670
statsEnd = 1785985911
totalFrames = 11859
missedFrames = 444
displayOnTime = 241026 ms
displayConfigStats is as below:
totalP2PTime = 236483 ms
layerName = SurfaceView[com.loomgames.pixelflow/com.scopely.unity.ScopelyUnityActivity](BLAST)#135
packageName =
gameMode = Unsupported
totalFrames = 11854
droppedFrames = 0
lateAcquireFrames = 0
averageFPS = 50.125
layerName = StatusBar#85
packageName =
gameMode = Unsupported
totalFrames = 12
droppedFrames = 3
lateAcquireFrames = 0
layerName = none
packageName =
gameMode = Unsupported
totalFrames = 0
droppedFrames = 0
FIXEOF

echo "=== guest_fps.sh 自我測試 ==="

# 11854 ÷ 241.026s = 49.18。**這一條同時釘住三件事**：有取到 layer 專屬的
# totalFrames（不是全域的 11859 → 49.20）、有除以 displayOnTime、沒有回傳 dumpsys
# 自己印的 averageFPS（50.125）。
check "解析真實 dump：fps／幀數／掉幀／窗口" \
      "$(guest_fps_from_dump "$FIX" com.loomgames.pixelflow)" \
      "49.18 11854 0 241026"

# **這一條是整組最重要的。** 檔頭的全域 totalFrames 排在目標 layer 之前，naive 的
# `grep totalFrames | head -1` 會拿到 11859——差距只有 0.02 fps，不會有人用肉眼發現，
# 但它代表解析器根本沒在看那個遊戲的 layer，換一個畫面就會錯得離譜。
check "不得取到檔頭的全域 totalFrames（11859 → 49.20）" \
      "$(guest_fps_from_dump "$FIX" com.loomgames.pixelflow | cut -d' ' -f2)" \
      "11854"

# 別的 layer 的數字不得混進來（StatusBar 的 droppedFrames=3）。
check "不得混到其他 layer 的 droppedFrames" \
      "$(guest_fps_from_dump "$FIX" com.loomgames.pixelflow | cut -d' ' -f3)" \
      "0"

# 遊戲不在前景／沒出幀時，該 layer 根本不存在。**必須回傳失敗，不是 0**——
# 「量到 0 fps」與「沒有這個 layer」是兩件事，混在一起會讓呼叫端把環境問題
# 誤判成效能問題。
check "找不到目標 layer → 回傳 1" \
      "$( guest_fps_from_dump "$FIX" com.nonexistent.game > /dev/null 2>&1; echo $? )" \
      "1"

# layerName 含套件名但不是 SurfaceView（例如 Unity App 的一般 View 階層）不算——
# D45 Step 1 已實測過那條路徑的 totalFrames 恆為 0，取到它會把好輪次誤判成壞的。
NOSV=$(mktemp -t d56_fixture2)
cat > "$NOSV" <<'FIXEOF'
displayOnTime = 20000 ms
layerName = com.loomgames.pixelflow/com.scopely.unity.ScopelyUnityActivity#7
totalFrames = 0
droppedFrames = 0
FIXEOF
check "layerName 沒有 SurfaceView → 不算目標 layer，回傳 1" \
      "$( guest_fps_from_dump "$NOSV" com.loomgames.pixelflow > /dev/null 2>&1; echo $? )" \
      "1"
rm -f "$NOSV"

# 空的／壞掉的 dump（adb 沒回應時就是這樣）必須回傳失敗而不是印出 0。
EMPTY=$(mktemp -t d56_fixture3)
: > "$EMPTY"
check "空 dump → 回傳 1" \
      "$( guest_fps_from_dump "$EMPTY" com.loomgames.pixelflow > /dev/null 2>&1; echo $? )" \
      "1"
# displayOnTime 為 0 會讓 totalFrames ÷ 窗口 除以零。
printf 'displayOnTime = 0 ms\nlayerName = SurfaceView[com.x/y](BLAST)#1\ntotalFrames = 5\ndroppedFrames = 0\n' > "$EMPTY"
check "displayOnTime = 0 → 回傳 1（不得除以零）" \
      "$( guest_fps_from_dump "$EMPTY" com.x > /dev/null 2>&1; echo $? )" \
      "1"
rm -f "$EMPTY"

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "全部通過"
    exit 0
fi
echo "$FAILURES 項失敗"
exit 1
