import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import MirageCore
@testable import MirageShell

/// 三個純函式層不需要 VideoToolbox session，headless 可跑。
@Suite struct RemoteEncoderHelpersTests {
    // MARK: AVCC

    @Test func splitsFourByteLengthPrefixedNals() {
        let avcc = Data([0, 0, 0, 3, 0x65, 0x88, 0x84, 0, 0, 0, 2, 0x41, 0x9a])
        #expect(H264AvccSplitter.split(avcc, headerLength: 4) == [Data([0x65, 0x88, 0x84]), Data([0x41, 0x9a])])
    }

    @Test func splitsTwoByteLengthPrefix() {
        let avcc = Data([0, 1, 0x67, 0, 2, 0x68, 0xce])
        #expect(H264AvccSplitter.split(avcc, headerLength: 2) == [Data([0x67]), Data([0x68, 0xce])])
    }

    /// 長度前綴指到緩衝區外：那個 NAL 與之後的全部丟掉，前面完整的保留。
    @Test func truncatedTailIsDropped() {
        let avcc = Data([0, 0, 0, 1, 0x65, 0, 0, 0, 9, 0x41])
        #expect(H264AvccSplitter.split(avcc, headerLength: 4) == [Data([0x65])])
        #expect(H264AvccSplitter.split(Data(), headerLength: 4).isEmpty)
        #expect(H264AvccSplitter.split(Data([0, 0, 0, 0, 0x65]), headerLength: 4).isEmpty)   // 長度 0 不是 NAL
    }

    // MARK: PTS

    @Test func presentationTimeIsNanosecondsSinceEpoch() {
        let epoch = ContinuousClock.now
        let later = epoch + .milliseconds(1_500) + .nanoseconds(7)
        let pts = RemoteEncoderClock.presentationTime(of: later, since: epoch)
        #expect(pts.timescale == 1_000_000_000)
        #expect(pts.value == 1_500_000_007)
        #expect(RemoteEncoderClock.presentationTime(of: epoch, since: epoch).value == 0)
    }

    // MARK: 像素緩衝

    @Test func rgbaBecomesBGRAWithSameGeometry() throws {
        let frame = Frame(width: 2, height: 1, rgba: Data([1, 2, 3, 4, 5, 6, 7, 8]))
        let buffer = try RGBAPixelBuffer.makeBGRA(from: frame)
        #expect(CVPixelBufferGetWidth(buffer) == 2)
        #expect(CVPixelBufferGetHeight(buffer) == 1)
        #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
        let bytes = [UInt8](Data(bytes: base, count: 8))
        #expect(bytes == [3, 2, 1, 4, 7, 6, 5, 8])
    }

    /// 尺寸與位元組數不符的幀不得進編碼器：`LatestFrameBox.put` 已擋掉（`rejected`），
    /// 這裡是第二道，因為 `takeLatest` 的來源未來可能換。
    @Test func invalidFrameIsRejected() {
        let frame = Frame(width: 2, height: 2, rgba: Data([0, 0, 0, 0]))
        #expect(throws: RGBAPixelBufferError.invalidFrame) { _ = try RGBAPixelBuffer.makeBGRA(from: frame) }
    }
}
