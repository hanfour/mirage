import Foundation
import Testing
@testable import MirageCore

/// 活體：真模擬器 → streamScreenshot + MMAP → 非零且在取樣窗口內持續更新的 Frame。
/// 需 `MIRAGE_TRANSPORT=mmap` 且 `MIRAGE_LIVE=1` 且 `MIRAGE_LIVE_MMAP=1` 三者皆備
/// （沿用既有環境變數名稱，另加上 MMAP 現在需要的 opt-in 開關），
/// 並且 guest 畫面必須正在變動，由 scripts/verify_mmap.sh 負責。
/// 三道環境變數閘之後，本測試自己再打一次 `getStatus` 過 `MmapVersionGate`：
/// 這是唯一沒有走 `EmulatorClient.makeDisplayTransport()` 互鎖的實際發送路徑，
/// 連到 36.x 穩定版會 SIGSEGV 弄死整台 VM，不能只靠呼叫端的環境變數猜版本。
///
/// ⚠️ **但這條測試自己製造過一個持續九天的錯誤結論，改它之前先讀這段（D52）。**
/// 當時它只取 **3 幀**就判定，而通知以約 60Hz 到達，窗口只有約 150ms。同日的根因調查把窗口
/// 拉到 400 幀，量到 `distinct=92／102／109／110／119`：**MMAP 從來沒有「凍結」過，
/// 它一直在更新，只是慢約 3.6 倍**（Swift 約 15Hz、Python 約 50Hz）。「凍結」這個寫進
/// D16、`RESULTS-mmap.md`、多處註解與 memory 的描述，整個來自這裡的窗口太短。
///
/// 本測試的職責是活體性，不是速率：取 30 幀，與 `mmap_client_parity.py` 預設值對齊。
/// Swift 約 15Hz 對 Python 約 50Hz 的速率差距由 D16（P3）追蹤，不由這條測試代管。
/// `distinct > 1` 直接推翻「凍結」的描述，那正是這條測試當初製造的錯誤。
/// **2026-09-10 實測：窗口大小在 30 到 400 幀之間不改變答案。** 用
/// `MIRAGE_MMAP_FRAMES` 覆寫跑了 30／100／200／400 幀各兩次，八次全部 `distinct=1`；
/// 400 幀的實際跨度是 6672ms，不是「幀數不夠所以看不到變化」。
/// 決定性對照（Python → Swift → Python，同一分鐘內）：
/// Python 30/30 distinct（499ms）→ Swift 1/30（495ms）→ Python 30/30（493ms）。
/// guest 內容全程在變，Swift 這條路徑確實交付相同內容。
/// ⚠️ **這與債務表 D52 記載的「400 幀量到 distinct=92／102／109／110／119」對不上。**
/// 那筆記載未被本次重現，兩者都保留在債務表裡，沒有互相覆寫。
/// 預設維持 30 幀（與 `mmap_client_parity.py` 對齊、跑得快），而不是借註解裡的數字：
/// 這個預設現在有實測支撐，不是猜的。
/// 另設一分鐘測試逾時，避免 guest 完全靜止、不送幀時無限等待；逾時不是速率判準。
///
/// 一條窗口太短的測試不會報錯，它會給你一個**看起來很確定**的錯誤答案：三個 emulator
/// 版本每次都 `distinct=1`，一致性反而讓人更相信它。完整證據見 `app/RESULTS-mmap.md`
/// 的「2026-08-05 重驗」與「2026-08-05 根因調查」兩節。
@Suite struct MmapStreamLiveTests {
    @Test(.timeLimit(.minutes(1)), .enabled(if: LiveGate.mmap,
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
        // **失敗而不是安靜跳過（D26）**：原本這裡 print 一行然後 return，於是這條測試在
        // 舊 emulator 上回報 passed 而零斷言——閘門 3 的哨兵當時只掃單行，抓不到跨行形式。
        // 使用者是明確設了 `MIRAGE_LIVE_MMAP=1` 才會跑到這裡的，配了跑不動 MMAP 的
        // emulator 是該知道的環境錯誤。`#require` 會 throw，所以危險的 MMAP 請求
        // 同樣不會送出（36.x 收到它會 SIGSEGV 弄死整台 VM，phase0/RESULTS-0b.md 3/3 重現）。
        try #require(MmapVersionGate.allows(versionString: status.version),
                     "emulator \(status.version) < 37 跑不動 MMAP，請用 37 以上的版本或不要設 MIRAGE_LIVE_MMAP=1")
        let transport = MmapStreamTransport(channel: box)
        // 窗口大小可用 MIRAGE_MMAP_FRAMES 覆寫，供校準用（見下方註解的實測紀錄）。
        let sampleFrames = ProcessInfo.processInfo.environment["MIRAGE_MMAP_FRAMES"]
            .flatMap(Int.init) ?? 30
        let windowStart = Date()
        var digests: [Int] = []
        for try await frame in transport.frames(width: 540, height: 1200) {
            #expect(frame.isValid)
            #expect(!MmapSupport.isBlank(frame.rgba))
            digests.append(frame.rgba.hashValue)
            if digests.count >= sampleFrames { break }
        }
        // ⚠️ **幀數不是時間窗口**：印出實際跨度才能與 Python 對照的 window= 並排比較。
        // 2026-09-10 實測發現：只看幀數會把「通知到達很快但內容不變」誤讀成「窗口夠長」。
        let elapsedMs = Int((Date().timeIntervalSince(windowStart)) * 1000)
        print("[mmap-live] frames=\(digests.count) distinct=\(Set(digests).count) window=\(elapsedMs)ms")
        #expect(digests.count == sampleFrames, "未收到完整的 \(sampleFrames) 幀，無法判讀活體性；guest 畫面是否在變動？")
        #expect(Set(digests).count > 1, "取樣窗口內幀內容全同，未觀察到傳輸更新；請確認 guest 畫面持續變動")
    }
}
