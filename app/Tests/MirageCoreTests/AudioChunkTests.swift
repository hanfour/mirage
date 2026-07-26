import Foundation
import Testing
@testable import MirageCore

@Suite struct AudioChunkTests {
    @Test func emptyDataYieldsNoSamples() {
        #expect(AudioChunk.fromS16LE(Data()).samples.isEmpty)
    }

    @Test func silenceDecodesToZero() {
        let chunk = AudioChunk.fromS16LE(Data([0x00, 0x00, 0x00, 0x00]))
        #expect(chunk.samples == [0.0, 0.0])
    }

    /// S16 最小值 -32768 → -1.0（除以 32768，非 32767：避免正負不對稱與 clipping）。
    @Test func minimumSampleMapsToNegativeOne() {
        let chunk = AudioChunk.fromS16LE(Data([0x00, 0x80]))   // little-endian 0x8000
        #expect(chunk.samples == [-1.0])
    }

    /// S16 最大值 32767 → 略小於 1.0。
    @Test func maximumSampleMapsJustBelowOne() {
        let chunk = AudioChunk.fromS16LE(Data([0xFF, 0x7F]))   // little-endian 0x7FFF
        #expect(chunk.samples.count == 1)
        #expect(abs(chunk.samples[0] - 0.999969) < 0.000_01)
    }

    @Test func littleEndianByteOrderIsRespected() {
        // 0x0100 little-endian = 256 → 256 / 32768 = 0.0078125
        let chunk = AudioChunk.fromS16LE(Data([0x00, 0x01]))
        #expect(chunk.samples == [0.0078125])
    }

    /// 防禦：位元組數為奇數（截斷的封包）不得崩潰，尾端半個 sample 直接丟棄。
    @Test func oddByteCountTruncatesInsteadOfCrashing() {
        let chunk = AudioChunk.fromS16LE(Data([0x00, 0x00, 0x7F]))
        #expect(chunk.samples == [0.0])
    }

    @Test func standardFormatIs48kStereo() {
        #expect(AudioStreamFormat.standard == AudioStreamFormat(samplingRate: 48_000, channels: 2))
    }
}
