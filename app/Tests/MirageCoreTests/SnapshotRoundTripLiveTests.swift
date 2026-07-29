import Foundation
import Testing
import GRPC
import NIOPosix
@testable import MirageCore

/// 活體快照驗證（MIRAGE_LIVE 開啟，需模擬器）。
///
/// 只驗 **save**：Task 7 活體驗收發現，在運行中的模擬器上呼叫 `loadSnapshot`
/// 會使模擬器崩潰（canary 37.2.1，載入 ~2.3GB RAM 快照進 live VM），且與 spec §8
/// 「suspend 期間 qemu 仍在跑」矛盾（load 會 rewind 丟狀態）。因此 wake() 已改為
/// 只恢復拉幀、不 load（見 EmulatorClient.wake 與 RESULTS-p1b §4），此處亦不驗 load。
@Suite struct SnapshotRoundTripLiveTests {
    @Test(.enabled(if: LiveGate.live, "需 MIRAGE_LIVE=1 與真模擬器；請跑 scripts/verify_snapshot.sh"))
    func saveSnapshotSucceeds() async throws {
        let boxCh = try GrpcChannelBox(host: "localhost", port: 8554)
        let snap = GrpcSnapshotService(channelBox: boxCh)
        #expect(await snap.save("mirage_suspend") == true)
    }
}
