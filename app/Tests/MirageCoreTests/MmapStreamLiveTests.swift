import Foundation
import Testing
@testable import MirageCore

/// 活體：真模擬器 → streamScreenshot + MMAP → 非零且逐幀變動的 Frame。
/// 需 `MIRAGE_TRANSPORT=mmap` 且 `MIRAGE_LIVE=1` 且 `MIRAGE_LIVE_MMAP=1` 三者皆備
/// （沿用既有環境變數名稱，另加上 MMAP 現在需要的 opt-in 開關），
/// 並且 guest 畫面必須正在變動——由 scripts/verify_mmap.sh 負責。
/// 三道環境變數閘之後，本測試自己再打一次 `getStatus` 過 `MmapVersionGate`——
/// 這是唯一沒有走 `EmulatorClient.makeDisplayTransport()` 互鎖的實際發送路徑，
/// 連到 36.x 穩定版會 SIGSEGV 弄死整台 VM，不能只靠呼叫端的環境變數猜版本。
///
/// **已知現況（2026-07-27）**：這條測試目前在 emulator 37.2.1.0 上會失敗——Swift client
/// 只收到映射區的一次寫入，之後畫面凍結不再更新（同一時刻、同尺寸的 Python client
/// 完全正常）。這是已知的產品缺陷（上游 b/537802959，已標記 fixed 但含修正的 build
/// 尚未發布），不是這條測試本身的問題，因此**刻意不刪除、不放寬斷言**——它是根治後
/// 的驗收標準。等含修正的 emulator 發布後，應重新啟用並驗證是否轉綠；在那之前，
/// 預設不開 `MIRAGE_TRANSPORT=mmap` 就不會執行到這裡（見 DisplayTransportSelector）。
@Suite struct MmapStreamLiveTests {
    @Test func realEmulatorWritesIntoMappedBuffer() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MIRAGE_TRANSPORT"] == "mmap", env["MIRAGE_LIVE"] == "1", env["MIRAGE_LIVE_MMAP"] == "1" else {
            print("[mmap-live] skipped: 需 MIRAGE_TRANSPORT=mmap 且 MIRAGE_LIVE=1 且 MIRAGE_LIVE_MMAP=1；請跑 scripts/verify_mmap.sh")
            return
        }
        let box = try GrpcChannelBox(host: "localhost", port: 8554)
        // 終審 Important 1：這是唯一沒有版本閘的實際發送路徑——被刪除的舊
        // `UnaryMmapTransport` 把閘放在型別內部，本分支把互鎖搬到單一呼叫端
        // `EmulatorClient.makeDisplayTransport()` 之後，這條活體測試若不自己補一次
        // `getStatus` + `MmapVersionGate.allows`，就會對任何版本的 emulator（含穩定版
        // 36.x）直接發出 MMAP 請求——36.x 收到 MMAP 請求會 SIGSEGV，弄死整台 VM
        // （phase0/RESULTS-0b.md，3/3 確定性重現）。
        let status = try await box.client.getStatus(.init())
        guard MmapVersionGate.allows(versionString: status.version) else {
            print("[mmap-live] skipped: emulator \(status.version) < 37——MMAP 請求會使其 SIGSEGV")
            return
        }
        let transport = MmapStreamTransport(channel: box)
        var digests: [Int] = []
        for try await frame in transport.frames(width: 540, height: 1200) {
            #expect(frame.isValid)
            #expect(!MmapSupport.isBlank(frame.rgba))
            digests.append(frame.rgba.hashValue)
            if digests.count >= 3 { break }
        }
        print("[mmap-live] frames=\(digests.count) distinct=\(Set(digests).count)")
        #expect(digests.count == 3, "未收到 3 幀——guest 畫面是否在變動？")
        #expect(Set(digests).count >= 2, "幀內容未變化——映射區可能沒被寫入")
    }
}
