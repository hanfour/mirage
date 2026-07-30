#!/usr/bin/env bash
# Mirage 的品質閘門。**CI 設定檔只該呼叫這一支**——閘門的邏輯放在這裡，
# 好處是它今天就能在本機執行與驗證，不必先有 CI 平台、也不會跟著平台換而重寫。
#
# 設計上刻意迴避這個 repo 已經踩過的三個坑：
#
# 1. **不依賴本機模擬器**。整個測試套件在 2026-07-29 之前從未在「沒有模擬器」的條件下
#    跑過——測試用 `EmulatorClient()`，而它的預設端點寫死 `localhost:8554`，開發機上
#    剛好都有 AVD 在跑。CI runner 上不會有。本腳本明確把端點指向一個沒人監聽的埠，
#    並且**先斷言那個埠真的沒人監聽**——否則「hermetic」只是一句沒查證的宣稱。
#
# 2. **跑不只一次**。D1 那個 NIO 死鎖的命中率約 60%（5 跑 3 卡）。單次綠燈有四成機率
#    只是運氣，而這個 repo 歷來每一份「N tests passed」都是單次的。預設跑 3 次。
#
# 3. **每一步都有斷言，而且失敗會讓退出碼非零**。D9 記錄了 `verify_snapshot.sh`
#    「11 行零斷言，只存 PNG + 印字」——一支永遠成功的驗證腳本比沒有更糟，
#    因為它會產生「驗過了」的錯覺。本腳本每個檢查都累加 FAILURES 並反映在退出碼上。
set -uo pipefail

RUNS="${CI_RUNS:-3}"
DEAD_PORT="${CI_DEAD_PORT:-45999}"
# 單次逾時。沒有它，D1 那類死鎖會讓 CI 掛到平台的全域逾時才失敗，
# 而「卡住」與「還在跑」在儀表板上長得一樣。實測正常單次為 2–7 秒。
RUN_TIMEOUT="${CI_RUN_TIMEOUT:-180}"
ERR_PAT='Cannot schedule tasks on an EventLoop that has already shut down'

cd "$(dirname "$0")/.." || exit 1
FAILURES=0
fail() { echo "❌ $*"; FAILURES=$((FAILURES + 1)); }
ok()   { echo "✅ $*"; }

echo "=== 閘門 0：確認 $DEAD_PORT 真的沒人監聽 ==="
# 這一步不是形式。若這個埠恰好有服務，下面所有跑次都會靜默地變成「有後端」的測試，
# 而 CI 會回報綠燈——正是我們要防的那種假訊號。
if nc -z localhost "$DEAD_PORT" 2>/dev/null; then
    fail "$DEAD_PORT 有人監聽，無法保證 hermetic。設 CI_DEAD_PORT 換一個沒被佔用的埠。"
    echo "閘門 0 失敗即中止——後面的結果在這個前提下沒有意義。"
    exit 1
fi
ok "$DEAD_PORT 無人監聽，端點將指向它（等同 runner 上沒有模擬器）"
export MIRAGE_PORT="$DEAD_PORT"

echo ""
echo "=== 閘門 1：建置（含測試 target）==="
if swift build --build-tests 2>&1 | tail -3; then
    ok "建置通過"
else
    fail "建置失敗"
    echo "建置失敗即中止。"
    exit 1
fi

echo ""
echo "=== 閘門 2：連跑 $RUNS 次完整測試套件 ==="
LOGDIR=$(mktemp -d)
# **只在全過時清掉 log**。原本是無條件 `trap 'rm -rf "$LOGDIR"' EXIT`，於是失敗那一刻
# 證據就跟著消失——2026-07-30 追一次間歇失敗時，就是因為這行而拿不到失敗的 run log，
# 只能記成「未重現、原因未確立」。閘門存在的意義是說清楚出了什麼事，不是只說「紅了」。
cleanup_logs() { [ "$FAILURES" -eq 0 ] && rm -rf "$LOGDIR"; }
trap cleanup_logs EXIT

for i in $(seq 1 "$RUNS"); do
    log="$LOGDIR/run-$i.log"
    start=$SECONDS
    swift test > "$log" 2>&1 &
    pid=$!
    ( sleep "$RUN_TIMEOUT"; kill -9 "$pid" 2>/dev/null ) &
    watcher=$!
    wait "$pid"; rc=$?
    kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null
    dur=$((SECONDS - start))

    # kill -9 只殺得到 swift-test，測試 binary（swiftpm-testing-helper）會變孤兒繼續
    # 佔資源、污染下一次跑。逾時後一律清乾淨。
    if [ "$rc" -ne 0 ] && [ "$dur" -ge "$RUN_TIMEOUT" ]; then
        pkill -9 -f swiftpm-testing-helper 2>/dev/null
        fail "第 $i 次：逾時 ${RUN_TIMEOUT}s 未結束（疑似死鎖，見 D1）"
        # log 早就留著了（cleanup_logs 只在全過時刪），但先前沒印路徑——於是**最需要
        # 證據的那一格**（死鎖，唯一線索是卡在哪條測試）反而要人自己去猜 mktemp 的目錄。
        echo "   完整 log 保留在：$log"
        continue
    fi
    if [ "$rc" -ne 0 ]; then
        # 變數一律用 ${} 包起來：bash 5.3.9 在 `set -u` 下把 `$rc，`（裸變數緊接全形字元）
        # 解析成變數名 `rc` + 全形逗號的第一個位元組，判定為「未綁定的變數」而中止。
        # 最小重現：`set -u; rc=1; echo "$rc，"` → `rc?: 未綁定的變數`；`${rc}` 則正常。
        # 這一行只在**測試失敗時**才跑，所以這個 bug 的效果是「真的失敗時，用一個看不懂的
        # 錯誤蓋掉真正的失敗原因」——閘門最需要說清楚的那一刻反而啞掉。
        fail "第 ${i} 次：測試失敗（退出碼 ${rc}，${dur}s）"
        # **不能只 grep ✘**：swift-testing 用同一個 ✘ 標記 skip 與 failure，而本專案有 10 條
        # 環境閘門的 skip，所以原本那行印出來的全是 skip、真正的失敗被埋在下面看不到
        # （2026-07-30 追間歇失敗時實際踩到）。改成只抓失敗的標記，並明確排除 skip。
        grep -E 'recorded an issue|failed after [0-9]|error:' "$log" | grep -v 'skipped:' | head -10
        echo "   完整 log 保留在：$log"
        continue
    fi

    # D1 的回歸哨兵。注意這個訊號單獨用是不夠的——group 根本沒被關掉時也不會有這行
    # （見 ChannelTeardownTests 的說明），所以它是必要條件不是充分條件。
    errln=$(grep -c "$ERR_PAT" "$log" 2>/dev/null || true)
    if [ "${errln:-0}" -ne 0 ]; then
        fail "第 $i 次：出現 $errln 行 NIO teardown ERROR（D1 回歸）"
        echo "   完整 log 保留在：$log"
        continue
    fi
    ok "第 $i 次：通過，${dur}s，0 行 NIO ERROR（$(grep -oE '[0-9]+ tests? passed' "$log" | tail -1)）"
done

echo ""
echo "=== 閘門 3：不得再出現「假 skip」 ==="
# D3 的回歸哨兵。`guard <條件> else { return }` 會讓測試回報 passed 但零斷言；
# 正確寫法是 @Test(.enabled(if:))，env 閘門集中在 Tests/MirageCoreTests/LiveGate.swift。
#
# **樣式為什麼要擴**：原本只有 `guard.*MIRAGE.*else\|guard env\[`，也就是**只認 env 形式**。
# 2026-07-30 的 D4 分支就地重建了同一種病的另一個形態——`ProfileStoreTests` 用
# `guard FileManager.default.fileExists(atPath: src.path) else { return }` 早退，而那個
# 路徑在資源搬家後永遠不存在，於是該測試回報 `✔ passed after 0.007 seconds` 卻零斷言。
# 舊樣式抓不到它。**哨兵漏抓比沒有哨兵更糟**，因為綠燈被當成證據。
#
# 現在抓兩類：(a) env 形式；(b) 任何 `guard … else { … return }` 單行早退。
# `return -1` / `return nil` 這種**帶值**的 return 不算——測試函式回傳 Void，
# 帶值 return 必然來自輔助函式（例如 ChannelTeardownTests 的執行緒計數），不是假 skip。
#
# **已知盲區，寫在這裡免得下一個人以為它全包**：只掃單行。跨行的
# `guard … else {\n print(…)\n return\n }` 抓不到——`MmapStreamLiveTests.swift:31-34`
# 就是活的一例（見 D26）。要補得用 AST 而不是 grep，那是另一輪的事。
FAKE_SKIP_PAT='guard.*MIRAGE.*else|guard env\[|guard.*else[[:space:]]*\{[^}]*return[[:space:]]*\}'
# 註解行要排除：LiveGate.swift 與 AudioLiveTests.swift 的說明文字裡逐字引用了
# `guard ... else { return }`（那正是它們在解釋「以前錯在哪」），本身不是程式碼。
BAD=$(grep -rnE "$FAKE_SKIP_PAT" Tests/ 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//')
if [ -n "$BAD" ]; then
    fail "測試裡出現假 skip 形式的早退（未命中條件時會回報 passed 但零斷言）："
    echo "$BAD"
else
    ok "無單行形式的假 skip（env 形式與 guard…else { return } 皆無命中）"
fi

echo ""
echo "=== 閘門 4：shell 腳本裡不得有「裸變數緊接全形標點」 ==="
# 2026-07-30 新增。加這道閘門的理由不是理論風險，是**同一個 session 內犯了三次**：
# coverage.sh（D29）、verify_common_selftest.sh（D9）、package_app.sh（D25）。
#
# bash 在 `set -u` 下會把 `$rc，` 的全形字元吃進變數名，當場報「未綁定的變數」。
# 最小重現：`set -u; rc=1; echo "$rc，"` → `rc?: 未綁定的變數`；`${rc}` 則正常。
# （ci.sh:84-86 早就記載過這個坑——**記載過但還是重複踩，所以需要的是閘門不是註解**。）
#
# 這個 bug 幾乎總是長在**錯誤路徑**上：那些行平常不執行，所以正常跑一百次都不會現形，
# 偏偏在真的出事、最需要訊息的那一刻啞掉並蓋掉真正的失敗原因。
#
# 註解行排除：本檔與 coverage.sh 的說明文字刻意逐字寫出這個壞樣式當範例。
SHELL_LINT=$(python3 - <<'PYLINT'
import re, pathlib, sys
pat = re.compile(r'\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F\s]')
hits = []
for p in sorted(pathlib.Path("scripts").rglob("*.sh")):
    for i, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        for m in pat.finditer(line):
            hits.append(f"{p}:{i}: {m.group()}  → 請改用 ${{{m.group()[1:-1]}}}")
print("\n".join(hits))
PYLINT
)
if [ -n "$SHELL_LINT" ]; then
    fail "shell 腳本裡有裸變數緊接全形標點（set -u 下會炸成「未綁定的變數」）："
    echo "$SHELL_LINT"
else
    ok "無裸變數緊接全形標點"
fi

echo ""
echo "======================================"
if [ "$FAILURES" -eq 0 ]; then
    echo "全部通過（$RUNS 次跑次、0 行 NIO ERROR、無假 skip、無全形標點陷阱）"
    exit 0
fi
echo "$FAILURES 項失敗"
exit 1
