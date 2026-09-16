import Foundation
import Testing
@testable import MirageCore

@Suite struct RemoteAudioMessageTests {
    private let wire = Data([
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x11, 0x22, 0x33, 0x44,
        0x00, 0x00, 0xbb, 0x80, 0x02,
        0x34, 0x12, 0xfe, 0xff,
    ])

    private var message: RemoteAudioMessage {
        RemoteAudioMessage(sentAtNanoseconds: 0x0102030405060708, sequence: 0x11223344,
                           samplingRate: 48_000, channels: 2, samples: Data([0x34, 0x12, 0xfe, 0xff]))
    }

    @Test func headerUsesBigEndianAndSamplesKeepLittleEndianBytes() {
        #expect(RemoteAudioMessage.headerSize == 17)
        #expect(message.encoded() == wire)
        #expect(RemoteAudioMessage.decode(wire) == message)
    }

    @Test(arguments: [UInt32(8_000), 44_100, 48_000], [UInt8(1), 2])
    func roundTripIncludesFormatBoundaries(samplingRate: UInt32, channels: UInt8) {
        let original = RemoteAudioMessage(sentAtNanoseconds: .max, sequence: .max,
                                          samplingRate: samplingRate, channels: channels,
                                          samples: Data([0, 0x80, 0xff, 0x7f]))
        #expect(RemoteAudioMessage.decode(original.encoded()) == original)
    }

    @Test func rejectsHeaderOnlyAndTruncatedHeaders() {
        for length in 0...17 {
            #expect(RemoteAudioMessage.decode(wire.prefix(length)) == nil)
        }
    }

    @Test func rejectsEmptyPayload() {
        let empty = RemoteAudioMessage(sentAtNanoseconds: 1, sequence: 2,
                                       samplingRate: 48_000, channels: 2, samples: Data())
        #expect(RemoteAudioMessage.decode(empty.encoded()) == nil)
    }

    @Test(arguments: [UInt8(0), 3])
    func rejectsInvalidChannels(channels: UInt8) {
        var invalid = wire
        invalid[16] = channels
        #expect(RemoteAudioMessage.decode(invalid) == nil)
    }

    @Test(arguments: [UInt32(7_999), 48_001])
    func rejectsInvalidSamplingRate(samplingRate: UInt32) {
        let invalid = RemoteAudioMessage(sentAtNanoseconds: 1, sequence: 2,
                                         samplingRate: samplingRate, channels: 2, samples: message.samples)
        #expect(RemoteAudioMessage.decode(invalid.encoded()) == nil)
    }

    @Test(arguments: [UInt8(1), 2], [1, 3, 5])
    func rejectsIncompleteSamples(channels: UInt8, payloadCount: Int) {
        var invalid = Data(wire.prefix(17))
        invalid[16] = channels
        invalid.append(Data(count: payloadCount))
        #expect(RemoteAudioMessage.decode(invalid) == nil)
    }

    @Test func rejectsIncompleteStereoFrame() {
        #expect(RemoteAudioMessage.decode(wire.prefix(19)) == nil)
    }

    @Test func decodesSliceWithNonZeroStartIndex() {
        let padded = Data([0xff, 0xff]) + wire
        let slice = padded.dropFirst(2)
        #expect(slice.startIndex == 2)
        #expect(RemoteAudioMessage.decode(slice) == message)
    }
}
