import Foundation
import Testing
@testable import MirageCore

/// 活體：真模擬器透過 streamScreenshot 與 MMAP 持續交付新畫面。
/// 需 MIRAGE_TRANSPORT=mmap、MIRAGE_LIVE=1、MIRAGE_LIVE_MMAP=1，且 guest 畫面正在變動。
@Suite struct MmapStreamLiveTests {
    @Test(.timeLimit(.minutes(1)), .enabled(if: LiveGate.mmap,
                   "需 MIRAGE_TRANSPORT=mmap、MIRAGE_LIVE=1、MIRAGE_LIVE_MMAP=1；請跑 scripts/verify_mmap.sh"))
    func realEmulatorWritesIntoMappedBuffer() async throws {
        let box = try GrpcChannelBox(host: "localhost", port: 8554)
        let status = try await box.client.getStatus(.init())
        try #require(MmapVersionGate.allows(versionString: status.version),
                     "emulator \(status.version) < 37 跑不動 MMAP，請使用 37 以上版本")

        let transport = MmapStreamTransport(channel: box)
        let requestedFrames = ProcessInfo.processInfo.environment["MIRAGE_MMAP_FRAMES"]
            .flatMap(Int.init) ?? 120
        let sampleFrames = max(120, requestedFrames)
        let windowStart = Date()
        var fingerprints: [UInt64] = []
        for try await frame in transport.frames(width: 898, height: 1996) {
            #expect(frame.isValid)
            let hasContent = !MmapSupport.isBlank(frame.rgba)
            #expect(hasContent)
            fingerprints.append(MmapSupport.fingerprint(of: frame.rgba))
            if fingerprints.count >= sampleFrames { break }
        }

        let elapsedMs = Int(Date().timeIntervalSince(windowStart) * 1000)
        let distinctCount = Set(fingerprints).count
        let distinctRatioPassed = !fingerprints.isEmpty
            && distinctCount * 100 >= fingerprints.count * 80
        print("[mmap-live] frames=\(fingerprints.count) distinct=\(distinctCount) window=\(elapsedMs)ms")
        #expect(fingerprints.count == sampleFrames,
                "未收到完整的 \(sampleFrames) 幀，請確認 guest 畫面正在變動")
        #expect(distinctRatioPassed,
                "相異畫面不足取樣幀數的 80%，請確認 MMAP 內容持續更新")
    }
}
