import Foundation
import Testing
@testable import MirageCore

@Suite struct H264RbspTests {
    private func hex(_ s: String) -> Data {
        var out = Data()
        var chars = Array(s)
        while chars.count >= 2 {
            out.append(UInt8(String(chars[0...1]), radix: 16)!)
            chars.removeFirst(2)
        }
        return out
    }

    private func bitString(_ bits: [Bool]) -> String { bits.map { $0 ? "1" : "0" }.joined() }
    private func bits(_ s: String) -> [Bool] { s.map { $0 == "1" } }

    /// 預期值由 spike 的 `_escape` 算出（`python3`，四種 00 00 XX 尾巴各一）。
    @Test(arguments: [
        ("0000000000000001", "0000030000030000030001"),
        ("0000010000000001", "0000030100000300000301"),
        ("0000020000000001", "0000030200000300000301"),
        ("0000030000000001", "0000030300000300000301"),
    ])
    func escapeInsertsPreventionBytesAndUnescapeRemovesThem(raw: String, escaped: String) throws {
        #expect(H264Rbsp.escape(hex(raw)) == hex(escaped))
        let actual27 = try H264Rbsp.unescape(hex(escaped))
        #expect(actual27 == hex(raw))
    }

    @Test func escapeLeavesDataWithoutZeroRunsAlone() throws {
        let plain = hex("420032ab40220096f2e8")
        #expect(H264Rbsp.escape(plain) == plain)
        let actual33 = try H264Rbsp.unescape(plain)
        #expect(actual33 == plain)
    }

    @Test(arguments: ["000003ff", "000003", "00000304"])
    func unescapeRejectsInvalidPreventionByte(raw: String) {
        #expect(throws: H264SpsError.invalidEmulationPrevention) { try H264Rbsp.unescape(hex(raw)) }
    }

    @Test func bitsAreMostSignificantFirst() {
        #expect(bitString(H264Rbsp.bits(of: hex("a1"))) == "10100001")
        #expect(H264Rbsp.bits(of: Data()).isEmpty)
    }

    @Test(arguments: [(0, "1"), (1, "010"), (2, "011"), (3, "00100"), (16, "000010001"), (255, "00000000100000000")])
    func ueBitsMatchExpGolomb(value: UInt32, expected: String) {
        #expect(bitString(H264Rbsp.ueBits(value)) == expected)
    }

    @Test func finishRbspAppendsStopBitAndPads() {
        #expect(H264Rbsp.finishRbsp(bits("101")) == hex("b0"))
        #expect(H264Rbsp.finishRbsp(bits("1111111")) == hex("ff"))
        #expect(H264Rbsp.finishRbsp(bits("11111111")) == hex("ff80"))
        #expect(H264Rbsp.finishRbsp([]) == hex("80"))
    }

    @Test func readerDecodesFixedExpGolombAndSigned() throws {
        var reader = H264BitReader(bits: bits("10100001" + "1" + "010" + "011" + "000010001" + "011" + "00100"))
        let actual60 = try reader.u(8)
        #expect(actual60 == 0xa1)
        let actual61 = try reader.ue()
        #expect(actual61 == 0)
        let actual62 = try reader.ue()
        #expect(actual62 == 1)
        let actual63 = try reader.ue()
        #expect(actual63 == 2)
        let actual64 = try reader.ue()
        #expect(actual64 == 16)
        let actual65 = try reader.se()
        #expect(actual65 == -1)
        let actual66 = try reader.se()
        #expect(actual66 == 2)
        #expect(reader.position == reader.bits.count)
        let actual68 = try reader.u(0)
        #expect(actual68 == 0)
    }

    @Test func readerFlagAndPositionAdvance() throws {
        var reader = H264BitReader(bits: bits("10"))
        let actual73 = try reader.flag()
        #expect(actual73)
        #expect(reader.position == 1)
        let actual75 = try !reader.flag()
        #expect(actual75)
        #expect(reader.position == 2)
    }

    @Test func readerThrowsOnTruncationAndOversizedCodes() {
        let shortBits = bits("101")
        #expect(throws: H264SpsError.truncated) {
            var reader = H264BitReader(bits: shortBits)
            _ = try reader.u(4)
        }
        #expect(throws: H264SpsError.truncated) {
            var reader = H264BitReader(bits: [])
            _ = try reader.ue()
        }
        let oversized = Array(repeating: false, count: 33) + [true]
        #expect(throws: H264SpsError.oversizedExpGolomb) {
            var reader = H264BitReader(bits: oversized)
            _ = try reader.ue()
        }
    }

    @Test func maximumUnsignedValueEncodesWithoutOverflow() {
        let encoded = H264Rbsp.ueBits(UInt32.max)
        #expect(encoded.count == 65)
        #expect(encoded == Array(repeating: false, count: 32) + [true]
            + Array(repeating: false, count: 32))
    }

    @Test func largestSupportedReaderValuesRoundTrip() throws {
        var reader = H264BitReader(bits: H264Rbsp.ueBits(UInt32.max - 1))
        let unsigned = try reader.ue()
        #expect(unsigned == UInt32.max - 1)
        var signedReader = H264BitReader(bits: H264Rbsp.ueBits(UInt32.max - 2))
        let signed = try signedReader.se()
        #expect(signed == Int32.max)
    }

}
