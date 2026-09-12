import Foundation
import Testing
@testable import MirageCore

@Suite struct RemoteVideoMessageTests {
    private let payload = H264Nal.startCode + Data([0x65, 0x70, 0x61, 0x79, 0x6c, 0x6f, 0x61, 0x64])

    @Test func headerIsBigEndianTimeSequenceAndFlag() {
        let message = RemoteVideoMessage(sentAtNanoseconds: 0x0102030405060708, sequence: 0x11223344,
                                         isKeyframe: true, accessUnit: payload)
        let wire = message.encoded()
        #expect(wire.count == RemoteVideoMessage.headerSize + payload.count)
        #expect(wire.prefix(13) == Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x11, 0x22, 0x33, 0x44, 0x01]))
        #expect(wire.suffix(from: 13) == payload)
        #expect(RemoteVideoMessage.decode(wire) == message)
    }

    @Test func deltaFrameFlagIsZero() throws {
        let wire = RemoteVideoMessage(sentAtNanoseconds: 1, sequence: 2, isKeyframe: false, accessUnit: payload).encoded()
        #expect(wire[12] == 0)
        let decoded = try #require(RemoteVideoMessage.decode(wire))
        #expect(!decoded.isKeyframe)
    }

    @Test func decodeAcceptsThreeByteStartCode() {
        let short = Data([0, 0, 1, 0x41, 0x01])
        let message = RemoteVideoMessage(sentAtNanoseconds: 9, sequence: 9, isKeyframe: false, accessUnit: short)
        #expect(RemoteVideoMessage.decode(message.encoded()) == message)
    }

    @Test func decodeRejectsTruncatedBadFlagOrMissingStartCode() {
        let good = RemoteVideoMessage(sentAtNanoseconds: 1, sequence: 1, isKeyframe: true, accessUnit: payload).encoded()
        #expect(RemoteVideoMessage.decode(Data()) == nil)
        #expect(RemoteVideoMessage.decode(good.prefix(13)) == nil)
        var badFlag = good
        badFlag[12] = 2
        #expect(RemoteVideoMessage.decode(badFlag) == nil)
        let noStartCode = good.prefix(13) + Data([0x65, 0x01, 0x02, 0x03])
        #expect(RemoteVideoMessage.decode(noStartCode) == nil)
    }

    @Test func decodeWorksOnSlicesWithNonZeroStartIndex() {
        let wire = RemoteVideoMessage(sentAtNanoseconds: 5, sequence: 6, isKeyframe: true, accessUnit: payload).encoded()
        let padded = Data([0xff, 0xff]) + wire
        #expect(RemoteVideoMessage.decode(padded.dropFirst(2)) == RemoteVideoMessage.decode(wire))
    }
}
