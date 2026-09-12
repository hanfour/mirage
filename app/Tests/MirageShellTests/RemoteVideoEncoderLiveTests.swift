import Foundation
import Testing
import VideoToolbox
@testable import MirageCore
@testable import MirageShell

/// 與 `MirageCoreTests/LiveGate.swift` 的 `LiveGate.remote` 讀同兩個變數；兩個 test target
/// 之間沒有共用檔的機制（比照 `KeymapReleaseLiveTests.swift:7-11`）。真正防止打錯變數名的是
/// `verify_remote_mirror.sh` 會斷言這條測試「passed」而不是「skipped」。
private enum LiveGate {
    static let remote = ProcessInfo.processInfo.environment["MIRAGE_LIVE"] == "1"
        && ProcessInfo.processInfo.environment["MIRAGE_LIVE_REMOTE"] == "1"
}

/// 收集回呼的存取單元。`CountGate` 只計數，這裡還要保留內容。
private final class AccessUnitRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [H264AccessUnit] = []
    let gate = CountGate()

    func record(_ unit: H264AccessUnit) {
        lock.lock(); stored.append(unit); lock.unlock()
        gate.increment()
    }

    var units: [H264AccessUnit] { lock.lock(); defer { lock.unlock() }; return stored }
}

/// 餵合成幀，斷言輸出 SPS 已含 VUI、每幀一個存取單元、尺寸變更會重建（spec 第 9 節階段 C）。
/// 需要硬體編碼器：spike 記載沙箱裡 VT 回 -12903，所以只在 `MIRAGE_LIVE_REMOTE=1` 下跑。
@Suite(.serialized, .timeLimit(.minutes(1))) struct RemoteVideoEncoderLiveTests {
    private static func frame(width: Int, height: Int, seed: UInt8) -> Frame {
        var rgba = Data(count: width * height * 4)
        for i in stride(from: 0, to: rgba.count, by: 4) {
            rgba[i] = UInt8(truncatingIfNeeded: i / 4 &+ Int(seed))   // 有梯度，不是純色
            rgba[i + 1] = seed
            rgba[i + 2] = UInt8(truncatingIfNeeded: i / 640)
            rgba[i + 3] = 255
        }
        return Frame(width: width, height: height, rgba: rgba)
    }

    @Test(.enabled(if: LiveGate.remote, "需 MIRAGE_LIVE=1 MIRAGE_LIVE_REMOTE=1，請跑 scripts/verify_remote_mirror.sh"))
    func emitsOneRewrittenAccessUnitPerFrameAndRecreatesOnResize() async throws {
        let recorder = AccessUnitRecorder()
        let encoder = RemoteVideoEncoder { recorder.record($0) }
        defer { encoder.invalidate() }

        for seed in 0..<5 {
            try encoder.encode(Self.frame(width: 320, height: 240, seed: UInt8(seed)))
            try await Task.sleep(for: .milliseconds(33))
        }
        await recorder.gate.wait(for: 5)
        for seed in 0..<3 {
            try encoder.encode(Self.frame(width: 480, height: 320, seed: UInt8(10 + seed)))
            try await Task.sleep(for: .milliseconds(33))
        }
        await recorder.gate.wait(for: 8)
        encoder.requestKeyframe()
        try encoder.encode(Self.frame(width: 480, height: 320, seed: 99))
        await recorder.gate.wait(for: 9)

        let units = recorder.units
        try #require(units.count == 9)                                   // 每幀一個存取單元
        #expect(units[0].isKeyframe)
        #expect(units[1...4].allSatisfy { !$0.isKeyframe })
        #expect(units[5].isKeyframe)                                // 新 session 第一幀
        #expect(units[8].isKeyframe)                                // requestKeyframe
        let sps = try H264SpsRewriter.summary(of: units[0].nals[0])
        #expect(sps.profileIdc == 66)                               // baseline
        #expect(sps.hasVui)
        #expect(sps.maxNumReorderFrames == 0)
        #expect(H264Nal.type(of: units[0].nals[1]) == .pps)
        #expect(units[0].nals.contains { H264Nal.type(of: $0) == .idrSlice })
        let stats = encoder.stats()
        #expect(stats.sessionsCreated == 2)
        // PM 的 Apple Silicon 主機實測：MaxFrameDelayCount 不支援，但仍應產出含 VUI 的 SPS。
        #expect(encoder.skippedProperties.contains {
            $0.0 == "MaxFrameDelayCount" && $0.1 == kVTPropertyNotSupportedErr
        })
        #expect(stats.framesSubmitted == 9)
        #expect(stats.accessUnitsEmitted == 9)
        #expect(stats.spsRewriteFailures == 0)
    }

    /// 尺寸不合法的幀不得進 VT，也不得建立 session。
    @Test(.enabled(if: LiveGate.remote, "需 MIRAGE_LIVE=1 MIRAGE_LIVE_REMOTE=1"))
    func invalidFrameThrowsBeforeCreatingSession() {
        let encoder = RemoteVideoEncoder { _ in }
        #expect(throws: RemoteVideoEncoderError.pixelBuffer(.invalidFrame)) {
            try encoder.encode(Frame(width: 4, height: 4, rgba: Data([0])))
        }
        #expect(encoder.stats().sessionsCreated == 0)
    }
}
