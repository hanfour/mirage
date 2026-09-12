import Foundation
import Testing
@testable import MirageCore

@Suite struct H264NalTests {
    private let start = H264Nal.startCode
    private let short = Data([0, 0, 1])

    @Test func splitHandlesBothStartCodeLengthsAndDropsEmptyPieces() {
        let expected = [Data([0x67, 0x61, 0x62, 0x63]), Data([0x68, 0x78, 0x79]),
                        Data([0x65, 0x00, 0x00, 0x03, 0x01, 0x7a]), Data([0x41, 0x65, 0x6e, 0x64])]
        let stream = start + expected[0] + short + expected[1] + start + expected[2] + short + expected[3]
        #expect(H264Nal.split(annexB: stream) == expected)
        #expect(H264Nal.split(annexB: Data()) == [])
        #expect(H264Nal.split(annexB: start) == [])
        #expect(H264Nal.split(annexB: start + start + expected[0]) == [expected[0]])
    }

    @Test func splitIgnoresBytesBeforeFirstStartCode() {
        #expect(H264Nal.split(annexB: Data([0xaa, 0xbb]) + start + Data([0x65, 0x01])) == [Data([0x65, 0x01])])
    }

    @Test func joinRoundTripsThroughSplit() {
        let nals = [Data([0x67, 0x42]), Data([0x68, 0xce]), Data([0x65, 0x88, 0x00, 0x00, 0x03, 0x00])]
        let joined = H264Nal.join(nals)
        #expect(joined.prefix(4) == start)
        #expect(H264Nal.split(annexB: joined) == nals)
    }

    @Test func nalTypeReadsLowFiveBitsAndRejectsForbiddenBit() {
        #expect(H264Nal.type(of: Data([0x67])) == .sps)
        #expect(H264Nal.type(of: Data([0x27])) == .sps)
        #expect(H264Nal.type(of: Data([0x68])) == .pps)
        #expect(H264Nal.type(of: Data([0x65])) == .idrSlice)
        #expect(H264Nal.type(of: Data([0x41])) == .nonIdrSlice)
        #expect(H264Nal.type(of: Data([0x06])) == .sei)
        #expect(H264Nal.type(of: Data([0x09])) == .accessUnitDelimiter)
        #expect(H264Nal.rawType(of: Data([0x0c])) == 12)
        #expect(H264Nal.type(of: Data([0x0c])) == nil)
        #expect(H264Nal.type(of: Data()) == nil)
        #expect(H264Nal.rawType(of: Data([0xe5])) == nil)
    }

    @Test func packerPrefixesCachedParameterSetsOnKeyframesOnly() {
        let sps = Data([0x67, 0x73, 0x70, 0x73]), pps = Data([0x68, 0x70, 0x70, 0x73])
        let sei = Data([0x06, 0x73]), idr1 = Data([0x65, 0x31]), idr2 = Data([0x65, 0x32])
        let p1 = Data([0x41, 0x31]), p2 = Data([0x41, 0x32])
        let identity: (Data) -> Data? = { $0 }

        let (afterKey, key) = H264AccessUnitPacker().pack([sps, pps, sei, idr1, idr2], rewriteSps: identity)
        #expect(key == H264AccessUnit(nals: [sps, pps, sei, idr1, idr2], isKeyframe: true))
        #expect(afterKey.sps == sps)
        #expect(afterKey.pps == pps)

        let (afterDelta, delta) = afterKey.pack([p1, p2], rewriteSps: identity)
        #expect(delta == H264AccessUnit(nals: [p1, p2], isKeyframe: false))
        #expect(afterDelta == afterKey)

        let (_, secondKey) = afterDelta.pack([idr1], rewriteSps: identity)
        #expect(secondKey == H264AccessUnit(nals: [sps, pps, idr1], isKeyframe: true))
    }

    @Test func packerRewritesSpsOnceAndKeepsOriginalWhenRewriteFails() {
        let sps = Data([0x67, 0x01]), pps = Data([0x68, 0x01]), idr = Data([0x65, 0x01])
        var seen: [Data] = []
        let (rewritten, unit) = H264AccessUnitPacker().pack([sps, pps, idr]) { input in
            seen.append(input)
            return Data([0x67, 0xff])
        }
        #expect(seen == [sps])
        #expect(rewritten.sps == Data([0x67, 0xff]))
        #expect(unit?.nals.first == Data([0x67, 0xff]))

        let (kept, _) = H264AccessUnitPacker().pack([sps, pps, idr], rewriteSps: { _ in nil })
        #expect(kept.sps == sps)
    }

    @Test func packerReturnsNilWithoutVclOrWithoutParameterSets() {
        let identity: (Data) -> Data? = { $0 }
        let (p, none) = H264AccessUnitPacker().pack([Data([0x06, 0x01]), Data([0x09, 0xf0])], rewriteSps: identity)
        #expect(none == nil)
        #expect(p == H264AccessUnitPacker())

        let (q, dropped) = H264AccessUnitPacker().pack([Data([0x65, 0x01])], rewriteSps: identity)
        #expect(dropped == nil)
        #expect(q == H264AccessUnitPacker())

        let (_, deltaOnly) = H264AccessUnitPacker().pack([Data([0x41, 0x01])], rewriteSps: identity)
        #expect(deltaOnly == H264AccessUnit(nals: [Data([0x41, 0x01])], isKeyframe: false))
    }

    @Test func packerUsesNewestParameterSetsAndDropsAudFromOutput() {
        let identity: (Data) -> Data? = { $0 }
        let old = [Data([0x67, 0x01]), Data([0x68, 0x01])], new = [Data([0x67, 0x02]), Data([0x68, 0x02])]
        let (p1, _) = H264AccessUnitPacker().pack(old, rewriteSps: identity)
        let (p2, unit) = p1.pack([Data([0x09, 0xf0])] + new + [Data([0x65, 0x09])], rewriteSps: identity)
        #expect(p2.sps == new[0])
        #expect(unit == H264AccessUnit(nals: new + [Data([0x65, 0x09])], isKeyframe: true))
    }

    @Test func realParameterSetsSplitAndJoin() {
        let sps = Data([0x27, 0x42, 0x00, 0x32, 0xab, 0x40, 0x22, 0x00, 0x96, 0xf2, 0xe8])
        let pps = Data([0x28, 0xce, 0x3c, 0x80])
        #expect(H264Nal.type(of: sps) == .sps)
        #expect(H264Nal.type(of: pps) == .pps)
        #expect(H264Nal.split(annexB: H264Nal.join([sps, pps])) == [sps, pps])
    }
}
