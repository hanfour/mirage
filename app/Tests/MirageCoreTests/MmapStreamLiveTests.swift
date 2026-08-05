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
/// **已知現況（2026-08-05 重驗，D39）**：這條測試會失敗，而且是真的失敗——同一台
/// emulator、同尺寸的 Python client 拿得到持續更新的幀，這條拿不到。**不要再等 emulator
/// 新版**：37.1.11(stable)／37.2.1(canary)／37.2.3(dev) 三版行為一致，與版本無關。
///
/// ⚠️ **但這條測試自己製造過一個持續九天的錯誤結論，改它之前先讀這段（D52）。**
/// 它只取 **3 幀**就判定，而通知以約 60Hz 到達——窗口只有約 150ms。同日的根因調查把窗口
/// 拉到 400 幀，量到 `distinct=92／102／109／110／119`：**MMAP 從來沒有「凍結」過，
/// 它一直在更新，只是慢約 3.6 倍**（Swift 約 15Hz、Python 約 50Hz）。「凍結」這個寫進
/// D16、`RESULTS-mmap.md`、多處註解與 memory 的描述，整個來自這裡的窗口太短。
///
/// 所以：**斷言方向是對的（這條路徑確實不正常），但失敗訊息說的「映射區可能沒被寫入」
/// 是錯的**。要改這條測試時，把窗口拉長（≥30 幀，與 `mmap_client_parity.py` 對齊）並加
/// 逾時，不要只放寬斷言——放寬會讓它變成一條永遠綠的假斷言。
///
/// 一條窗口太短的測試不會報錯，它會給你一個**看起來很確定**的錯誤答案：三個 emulator
/// 版本每次都 `distinct=1`，一致性反而讓人更相信它。完整證據見 `app/RESULTS-mmap.md`
/// 的「2026-08-05 重驗」與「2026-08-05 根因調查」兩節。
@Suite struct MmapStreamLiveTests {
    @Test(.enabled(if: LiveGate.mmap,
                   "需 MIRAGE_TRANSPORT=mmap 且 MIRAGE_LIVE=1 且 MIRAGE_LIVE_MMAP=1；請跑 scripts/verify_mmap.sh"))
    func realEmulatorWritesIntoMappedBuffer() async throws {
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
