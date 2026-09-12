import Foundation
import Testing
@testable import MirageCore

@Suite struct H264SpsRewriterTests {
    private func hex(_ s: String) -> Data {
        var out = Data()
        var chars = Array(s)
        while chars.count >= 2 {
            out.append(UInt8(String(chars[0...1]), radix: 16)!)
            chars.removeFirst(2)
        }
        return out
    }

    /// 真實素材：ffmpeg 7.1 h264_videotoolbox、1080×2400。
    static let realCases: [(name: String, input: String, output: String, profile: UInt8)] = [
        ("baseline", "27420032ab40220096f2e8", "27420032ab40220096f2f00f08846a", 66),
        ("high", "27640032ac568044012de5d0", "27640032ac568044012de5e01e1108d4", 100),
    ]

    @Test(arguments: realCases)
    func realVideoToolboxSpsGetsZeroReorderRestriction(_ c: (name: String, input: String, output: String, profile: UInt8)) throws {
        let input = hex(c.input)
        let before = try H264SpsRewriter.summary(of: input)
        #expect(before.profileIdc == c.profile)
        #expect(before.constraintFlags == 0)
        #expect(before.levelIdc == 50)
        #expect(before.numRefFrames == 1)
        #expect(before.picOrderCntType == 0)
        #expect(!before.hasVui)
        #expect(before.maxNumReorderFrames == nil)

        let output = try H264SpsRewriter.rewrite(input)
        #expect(output == hex(c.output))

        let after = try H264SpsRewriter.summary(of: output)
        #expect(after.profileIdc == before.profileIdc)
        #expect(after.constraintFlags == before.constraintFlags)
        #expect(after.levelIdc == before.levelIdc)
        #expect(after.numRefFrames == before.numRefFrames)
        #expect(after.picOrderCntType == before.picOrderCntType)
        #expect(after.hasVui)
        #expect(after.maxNumReorderFrames == 0)
        #expect(after.maxDecFrameBuffering == 1)
    }

    @Test(arguments: realCases)
    func rewriteIsIdempotent(_ c: (name: String, input: String, output: String, profile: UInt8)) throws {
        let once = try H264SpsRewriter.rewrite(hex(c.input))
        let actual50 = try H264SpsRewriter.rewrite(once)
        #expect(actual50 == once)
        #expect(H264SpsRewriter.rewriteOrNil(once) == once)
    }

    @Test func nalHeaderByteIsPreserved() throws {
        let output = try H264SpsRewriter.rewrite(hex("67420032ab40220096f2e8"))
        #expect(output == hex("67420032ab40220096f2f00f08846a"))
    }

    /// 合成 SPS（high profile、chroma 4:4:4、scaling list、POC type 1、完整 VUI 含 HRD），
    /// 且含 emulation prevention byte `00 00 03`。已有 restriction `[0,2,3,4,5,2,4]` 的版本
    /// 與沒有 restriction 的版本改寫後必須相同。
    @Test(arguments: [
        "2764003291b08ffffc00a14cd908022012dd3217ff00010001f7010203b240000003004000001e354a51528ad6b5ab990a6658",
        "2764003291b08ffffc00a14cd908022012dd3217ff00010001f7010203b240000003004000001e354a51528ad6b5ab40",
    ])
    func syntheticSpsWithVuiHrdAndEmulationPreventionRoundTrips(_ raw: String) throws {
        let expected = hex("2764003291b08ffffc00a14cd908022012dd3217ff00010001f7010203b240000003004000001e354a51528ad6b5abf0884648")
        let input = hex(raw)
        #expect(input.range(of: Data([0, 0, 3])) != nil)
        let before = try H264SpsRewriter.summary(of: input)
        #expect(before.profileIdc == 100)
        #expect(before.numRefFrames == 3)
        #expect(before.picOrderCntType == 1)
        #expect(before.hasVui)

        let output = try H264SpsRewriter.rewrite(input)
        #expect(output == expected)
        #expect(output.range(of: Data([0, 0, 3])) != nil)
        let after = try H264SpsRewriter.summary(of: output)
        #expect(after.maxNumReorderFrames == 0)
        #expect(after.maxDecFrameBuffering == 3)
        let actual82 = try H264SpsRewriter.rewrite(output)
        #expect(actual82 == output)
    }

    @Test func existingRestrictionIsReportedBeforeRewrite() throws {
        let before = try H264SpsRewriter.summary(of: hex("2764003291b08ffffc00a14cd908022012dd3217ff00010001f7010203b240000003004000001e354a51528ad6b5ab990a6658"))
        #expect(before.maxNumReorderFrames == 2)
        #expect(before.maxDecFrameBuffering == 4)
    }

    @Test func baselineWithoutVuiAndThreeRefsUsesRefsAsBuffering() throws {
        let output = try H264SpsRewriter.rewrite(hex("27420032ec8022012dd32150"))
        #expect(output == hex("27420032ec8022012dd321601e1108c9"))
        let actual94 = try H264SpsRewriter.summary(of: output).maxDecFrameBuffering
        #expect(actual94 == 3)
    }

    @Test(arguments: [
        ("", H264SpsError.notSps),
        ("68616263", H264SpsError.notSps),
        ("e7420032", H264SpsError.notSps),
        ("67", H264SpsError.truncated),
        ("67000003ff", H264SpsError.invalidEmulationPrevention),
    ])
    func invalidInputThrowsAndRewriteOrNilReturnsNil(raw: String, error: H264SpsError) {
        #expect(throws: error) { try H264SpsRewriter.rewrite(hex(raw)) }
        #expect(H264SpsRewriter.rewriteOrNil(hex(raw)) == nil)
    }

    @Test func oversizedScalingDeltaThrowsInsteadOfOverflowing() {
        // high profile、4:2:0、scaling matrix 第一個 list 的第一個 delta。
        let header = H264Rbsp.bits(of: Data([100, 0, 50]))
        let fields = H264Rbsp.ueBits(0) + H264Rbsp.ueBits(1)
            + H264Rbsp.ueBits(0) + H264Rbsp.ueBits(0)
            + [false, true, true] + H264Rbsp.ueBits(UInt32.max - 2)
        let sps = Data([0x67]) + H264Rbsp.escape(H264Rbsp.finishRbsp(header + fields))
        #expect(throws: H264SpsError.invalidField("delta_scale")) {
            try H264SpsRewriter.rewrite(sps)
        }
        #expect(H264SpsRewriter.rewriteOrNil(sps) == nil)
    }

    @Test func missingStopBitIsRejected() {
        // 真實 baseline 的最後一個 byte 清掉 stop bit，保留原 SPS 欄位。
        let sps = hex("27420032ab40220096f2e0")
        #expect(throws: H264SpsError.invalidTrailingBits) {
            try H264SpsRewriter.rewrite(sps)
        }
    }

}
