import Darwin
import Foundation
import Testing
@testable import MirageCore

/// 行程內活著的執行緒數。用 mach 的 `task_threads` 而非外部 `ps`／`sample`：
/// 整個測試套件只跑 2–3 秒，從外面取樣抓不準時機（實測 `sample` 的呼叫圖是空的，
/// 因為行程在 1 秒的取樣期間就結束了）。
private func liveThreadCount() -> Int {
    var list: thread_act_array_t?
    var count: mach_msg_type_number_t = 0
    guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return -1 }
    // task_threads 回傳的每個 port 都持有一份參照，且陣列本身是 vm_allocate 出來的，
    // 兩者都要自己還回去，否則這個「量測工具」本身就會洩漏 port 而污染量測。
    for i in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[i]) }
    vm_deallocate(mach_task_self_,
                  vm_address_t(UInt(bitPattern: list)),
                  vm_size_t(Int(count) * MemoryLayout<thread_t>.size))
    return Int(count)
}

/// NIO 拆除是否**真的收斂**——不是「有沒有卡住」。
///
/// **為什麼需要這條，而 5 次乾淨的套件跑不夠**：D1 的驗收訊號是
/// 「`Cannot schedule tasks on an EventLoop that has already shut down` 出現 0 次」。
/// 那行的語意是「pool 想在已關閉的 loop 上排程」——如果 group **根本沒被關掉**，
/// 也一樣不會有這行。也就是說 0 行 ERROR 同時相容於「修好了」與「靜默洩漏 NIO 執行緒」。
/// 這條測試補上那個盲區：直接數執行緒。
///
/// **預設不跑，需 `MIRAGE_THREAD_AUDIT=1`**（比照 `MIRAGE_LIVE_METAL` 的既有慣例）。
/// 理由不是它慢，是 swift-testing 預設並行執行測試，而執行緒數是行程級的全域可觀測量——
/// 與其他測試同時跑會讀到別人建立的執行緒，變成一條會偶爾紅的測試。
/// 這個碼庫最不需要的就是又一個不可信的訊號。單獨跑：
/// `MIRAGE_THREAD_AUDIT=1 swift test --filter shutdownReleasesNioThreads`
@Suite struct ChannelTeardownTests {
    static let boxCount = 12

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MIRAGE_THREAD_AUDIT"] == "1",
                   "需 MIRAGE_THREAD_AUDIT=1——見上方說明（會讀行程級執行緒數，不能與其他測試並行）"))
    func shutdownReleasesNioThreads() async throws {
        let baseline = liveThreadCount()
        try #require(baseline > 0)

        // 每個 GrpcChannelBox 建一個 numberOfThreads:1 的 MultiThreadedEventLoopGroup，
        // 也就是一條 NIO-ELT 執行緒。指向真的有人監聽的埠（模擬器 gRPC 8554）——
        // 連不上的埠會讓 close() 變得太容易，量不到真實情境。
        var boxes: [GrpcChannelBox] = []
        for _ in 0..<Self.boxCount {
            boxes.append(try GrpcChannelBox(host: "localhost", port: 8554))
        }
        let peak = liveThreadCount()
        #expect(peak >= baseline + Self.boxCount,
                "建了 \(Self.boxCount) 條 channel 卻沒看到對應的執行緒（baseline=\(baseline) peak=\(peak)），量測本身有問題")

        // 性質一：不阻塞。這是死鎖的成因——舊碼在 deinit 裡呼叫阻塞式的
        // syncShutdownGracefully()，而 dropChannel() 跑在 cooperative 執行緒上，
        // 8 核就是 8 條，佔滿即全域死鎖。12 條 channel 的拆除必須是「發出去就回來」。
        let t0 = ContinuousClock.now
        for box in boxes { box.shutdown() }
        let elapsed = ContinuousClock.now - t0
        #expect(elapsed < .milliseconds(100),
                "shutdown() 阻塞了呼叫端：\(Self.boxCount) 條花了 \(elapsed)")
        boxes.removeAll()

        // 收斂是非同步的（shutdown() 刻意不阻塞），輪詢等它跑完。
        // 容忍 +2：量測期間 Swift runtime 自己也可能起 cooperative 執行緒。
        var settled = -1
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(50))
            settled = liveThreadCount()
            if settled <= baseline + 2 { break }
        }
        #expect(settled <= baseline + 2,
                "shutdown() 之後執行緒沒有收斂：baseline=\(baseline) peak=\(peak) 5 秒後=\(settled)")
    }
}
