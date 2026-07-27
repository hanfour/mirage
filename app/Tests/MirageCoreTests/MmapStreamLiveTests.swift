import Foundation
import Testing
@testable import MirageCore

/// 活體：真模擬器 → streamScreenshot + MMAP → 非零且逐幀變動的 Frame。
/// 需 `MIRAGE_LIVE=1` 且 `MIRAGE_LIVE_MMAP=1`（沿用既有環境變數名稱），
/// 並且 guest 畫面必須正在變動——由 scripts/verify_mmap.sh 負責。
@Suite struct MmapStreamLiveTests {
    @Test func realEmulatorWritesIntoMappedBuffer() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MIRAGE_LIVE"] == "1", env["MIRAGE_LIVE_MMAP"] == "1" else {
            print("[mmap-live] skipped: 需 MIRAGE_LIVE=1 且 MIRAGE_LIVE_MMAP=1；請跑 scripts/verify_mmap.sh")
            return
        }
        let box = try GrpcChannelBox(host: "localhost", port: 8554)
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
