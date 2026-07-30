#!/usr/bin/env bash
# 驗收 4：對執行中模擬器 save 快照。
#
# > **更正（2026-07-30，D9）**：本檔原本的說明寫「save → 改變畫面 → load，畫面回到 save
# > 當時」，而那是一件**刻意不做的事**——`SnapshotRoundTripLiveTests` 的註解白紙黑字寫著：
# > 在運行中的模擬器上呼叫 `loadSnapshot` 會使模擬器崩潰（canary 37.2.1，載入 ~2.3GB RAM
# > 快照進 live VM），且與 spec §8「suspend 期間 qemu 仍在跑」矛盾（load 會 rewind 丟狀態）。
# > 產品的 `wake()` 因此只恢復拉幀、不 load。**這支腳本不會、也不該做 round trip。**
# > 那個測試的名字（`SnapshotRoundTripLiveTests`）同樣已經名不副實，記在 D31。
#
# 原本的實作是 11 行零斷言：存一張 PNG、印兩行字，然後叫使用者**自己**去跑測試。
# 它不執行任何驗證，卻叫 verify_*，於是「跑過 verify_snapshot.sh」看起來像個驗收訊號。
# 現在它真的跑那條測試並檢查退出碼。
set -uo pipefail
source "$(dirname "$0")/lib/verify_common.sh"

require_device "${ANDROID_SERIAL:-emulator-5554}"
require_grpc 8554

cd "$(dirname "$0")/.." || exit 1

echo "=== save 快照（gRPC，SnapshotRoundTripLiveTests）==="
MIRAGE_LIVE=1 swift test --filter SnapshotRoundTripLiveTests 2>&1 | tail -4
assert_ok "SnapshotRoundTripLiveTests（只驗 save）" "${PIPESTATUS[0]}"

echo ""
echo "涵蓋範圍，如實說明："
echo "  ✅ 已驗：save 成功回傳（gRPC round trip 本身）"
echo "  ❌ 未驗：load 之後畫面是否回到 save 當時——load 會弄崩模擬器，見上方更正"
echo "  ⚠️  被驗的 GrpcSnapshotService 目前是死碼（D14）：產品沒有任何路徑呼叫它。"
echo "     這支腳本證明的是那個服務可用，不是產品用了它。"
